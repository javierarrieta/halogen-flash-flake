# NixOS deployment for peonist-ai/halogen-flash-server.
#
# Runs the release image (engine + OpenAI front-end, one tag) under Podman,
# following upstream's own container contract (see their docker-compose.yml):
#   --device /dev/kfd --device /dev/dri  ROCm access to the iGPU (GTT memory)
#   --group-add keep-groups              podman extension: pass GID memberships through
#   --ipc=host                           load-bearing; no shm_size substitutes for it
#   --ulimit memlock=-1:-1
# The weights are NOT fetched from inside the container: this module either
# uses a pre-provisioned directory or runs `hf download` (the hf-hub CLI is
# idempotent and resumes/re-verifies), so the models volume can be read-only
# and a deployed server makes no outbound connections.
#
# Versioned weights layout (the default, `download.toVersionedDir = true`).
# `modelsDir` is the BASE directory, not the tree the server reads:
#
#   modelsDir/
#   ├── .cache/                     hf metadata (survives version pruning)
#   ├── versions/
#   │   ├── e053f488.../            one weight tree per revision
#   │   └── a1b2c3d4.../
#   └── current -> versions/a1b2c3d4...
#
# The units mount `current`, so the mount path is CONSTANT across revisions.
# That is what makes a weights update non-blocking: `halogen-flash-weights`
# fetches the new tree while the old server keeps serving, flips the symlink,
# and only then restarts the server to load it. A bind mount pins the inode
# it was created from, so flipping the symlink never disturbs a running
# container — the old tree stays valid for it until it is restarted.
#
# The fetch is NOT part of the deploy. The switch writes the desired revision to
# /etc/halogen-flash/target-revision and returns; `halogen-flash-weights.path`
# watches that file and starts the sync unit when its contents change. For that
# to hold, the sync unit's generated text must be byte-identical across
# revisions: switch-to-configuration restarts any unit whose text changed, so
# interpolating the revision into the description or the ExecStart script would
# restart the fetch unit on every bump and hold the server behind it. The
# revision is read from the intent file at run time instead.
#
# Two things follow from that and must not be "helpfully" reverted:
#   * the sync unit's `description` is a fixed string;
#   * the sync unit has NO RemainAfterExit — a PathUnit activates with StartUnit,
#     which is a no-op on an already-active RemainAfterExit oneshot, so keeping
#     it would make every bump after the first silently do nothing.
# tests/test-unit-invariance.sh asserts the first and pins the second.
#
# Disk is capped at TWO versions: the sync unit prunes every version dir that
# is not the live one before it starts a fetch, so a revision bump never needs
# room for three. That prune is unchanged and load-bearing.
#
# Lifecycle: stopping the unit is podman-mediated, NOT cgroup-mediated.
# Under rootless podman (`user` != root, which is how llm01 runs) the unit has
# no logind session, so podman logs "Falling back to --cgroup-manager=cgroupfs"
# and the container's cgroup is not a descendant of the unit's. Measured on
# 2026-10-19 when a deploy restarted the unit and the old container survived it:
#   * KillMode=control-group reaches only the unit's own cgroup, so
#     `systemctl stop` kills the `podman run` client and leaves the container
#     running under conmon — holding ~29 GB of GTT, reporting `Up` to podman
#     while `halogen:engine_up` is 0;
#   * TimeoutStopSec cannot fix that: a longer stop timeout only delays the
#     same KILL, which misses the container identically;
#   * the survivor keeps the fixed --name, so every later start exits 125 (that
#     part is recovered by --replace on ExecStart, which stays as the backstop).
# So the unit stops and removes the container through podman itself, which
# addresses it via podman's own state rather than through a cgroup it does not
# own. Check 9 in tests/test-unit-invariance.sh pins ExecStop/ExecStopPost.
#
# Do NOT "fix" this by moving podman to the systemd cgroup manager or by adding
# Delegate=. Rootless podman creates its scopes under
# user.slice/user-<uid>.slice/user@<uid>.service/, which is not under
# system.slice/halogen-flash.service either — enabling lingering changes where
# the scope lives, not whether this system unit owns it, so KillMode still would
# not reach the container. That is why the explicit stop directives are the
# cause-level fix here and not a symptom patch; it is also what podman's own
# quadlet unit generator emits for the same reason.
{
  lib,
  pkgs,
  config,
  ...
}:

let
  cfg = config.services.halogenFlash;

  defaultRepo = "peonist-ai/halogen-qwen3.8-flash-next";

  # The weights are pinned here, next to the image pin below, because they are
  # a matched pair: this server version is only known-good with this model
  # version. flake.lock freezes this source tree, so the string is transitively
  # pinned exactly like the image digest is -- neither artifact's bytes live in
  # the Nix store, the lock freezes the text that names them. Bump deliberately:
  # a new revision makes the next sync fetch ~118 GiB. scripts/bump-image.sh
  # reports the upstream sha.
  defaultWeightsRevision = "647e3814953e8435d58f5d5aa13b97aca85a7d93";

  # Rootless runs need the setuid newuidmap/newgidmap: plain pkgs.podman
  # bundles crun/passt/etc. next to its binary, but the uid-mapping helpers
  # must be the system's setuid wrappers. virtualisation.podman.package is
  # exactly that (it bakes /run/wrappers into the helper lookup — same store
  # path as the host's own podman when it is enabled, so no rebuild).
  podmanPkg = if cfg.user != "root" then config.virtualisation.podman.package else pkgs.podman;

  # The versioned layout only exists when the module is the one fetching. With
  # downloads off the operator owns modelsDir outright, so mount it directly
  # and keep the pre-versioning behaviour byte-for-byte.
  versionedActive = cfg.download.enable && cfg.download.toVersionedDir;

  versionsDir = "${cfg.modelsDir}/versions";
  currentLink = "${cfg.modelsDir}/current";
  targetRevision =
    if cfg.download.revision != "" then cfg.download.revision else defaultWeightsRevision;

  # What the container actually mounts as /models. Constant under the
  # versioned layout (that constancy is the whole point); the raw base dir
  # otherwise.
  mountSource = if versionedActive then currentLink else cfg.modelsDir;

  # Units that read the weights tree, and therefore have to be restarted when
  # the symlink flips. Names are spelled out rather than derived from mkRoleUnit
  # so the restart target is obvious in the generated unit.
  roleUnitNames =
    if cfg.mode == "all" then
      [ "halogen-flash" ]
    else
      [
        "halogen-flash-engine"
        "halogen-flash-api"
      ];

  # Fetch the pinned revision, prune what it displaced, then move the server
  # onto it. Runs as root: it must be able to restart the server units, and
  # the weight files it writes are world-readable, so the service user reads
  # them without owning them.
  weightsSyncScript = pkgs.writeShellScript "halogen-weights-sync" ''
    set -eu

    modelsDir=${cfg.modelsDir}
    versionsDir=${versionsDir}
    currentLink=${currentLink}
    repo=${cfg.download.repo}
    targetRevisionFile=/etc/halogen-flash/target-revision
    hf=${pkgs.python3Packages.huggingface-hub}/bin/hf
    systemctl=${pkgs.systemd}/bin/systemctl
    restartUnits=${lib.escapeShellArg (lib.concatMapStringsSep " " (u: u + ".service") roleUnitNames)}
    excludeArgs=( ${lib.escapeShellArgs cfg.download.exclude} )
    excludeFlags=()
    for _p in "''${excludeArgs[@]}"; do excludeFlags+=( --exclude "$_p" ); done
    exclusionsStr=${lib.escapeShellArg (lib.concatStringsSep "|" cfg.download.exclude)}

    mkdir -p "$versionsDir"

    textfileDir=${lib.escapeShellArg cfg.metricsTextfileDir}
    write_metric() {
      # Empty dir means metrics disabled on this host.
      [ -n "$textfileDir" ] || return 0
      mkdir -p "$textfileDir"
      {
        printf 'halogen_weights_desired_revision_info{revision="%s"} 1\n' "''${revision:-unknown}"
        printf 'halogen_weights_current_revision_info{revision="%s"} 1\n' "''${active:-none}"
        printf 'halogen_weights_state{state="%s"} 1\n' "$1"
      } > "$textfileDir/halogen-weights.prom.tmp.$$"
      mv "$textfileDir/halogen-weights.prom.tmp.$$" "$textfileDir/halogen-weights.prom"
    }

    # Installed before anything can fail, so a failure that happens before the
    # intent file is even readable still publishes `failed` instead of leaving a
    # previous run's `complete` on the wire while the unit churns. The success
    # paths below clear the trap so they are not overwritten on the way out.
    trap 'write_metric failed' EXIT

    # The revision is run-time state, not build-time text: baking it into the
    # script made every bump rewrite the unit's ExecStart path, which is exactly
    # the restart we are trying to avoid.
    if [ ! -r "$targetRevisionFile" ]; then
      echo "halogen-weights: $targetRevisionFile not readable; nothing to do" >&2
      exit 1
    fi
    revision="$(tr -d '[:space:]' < "$targetRevisionFile")"
    if [ -z "$revision" ]; then
      echo "halogen-weights: $targetRevisionFile is empty; refusing to guess" >&2
      exit 1
    fi
    targetDir="$versionsDir/$revision"

    # The symlink is the single source of truth for what is live: the running
    # container has whatever it pointed at bind-mounted, and that binding
    # survives the link being flipped underneath it.
    active=""
    if [ -L "$currentLink" ]; then
      active="$(basename "$(readlink "$currentLink")")"
    fi

    if [ "$active" = "$revision" ] && [ -d "$targetDir" ]; then
      echo "halogen-weights: revision $revision already active, nothing to do"
      trap - EXIT
      write_metric complete
      exit 0
    fi

    # One-time migration guard. A pre-versioning install left the .hgn files
    # flat in modelsDir, and nothing on them says which revision they are.
    # Fetching a second copy into versions/ would need double the volume, so
    # refuse and let a human decide rather than silently filling the disk.
    if [ ! -L "$currentLink" ] && ls "$modelsDir"/*.hgn >/dev/null 2>&1; then
      echo "halogen-weights: legacy flat weights in $modelsDir and no 'current' symlink." >&2
      echo "halogen-weights: refusing to fetch a second ~118 GiB copy. Pick one:" >&2
      echo "  a) if those files ARE revision $revision:" >&2
      echo "       systemctl stop ${lib.concatMapStringsSep " " (u: u + ".service") roleUnitNames}" >&2
      echo "       mkdir -p '$targetDir'" >&2
      echo "       mv '$modelsDir'/*.hgn '$modelsDir'/tokenizer '$targetDir'/" >&2
      echo "     then re-run this unit; hf re-verifies the moved files." >&2
      echo "  b) or delete them and let this unit fetch a fresh copy." >&2
      exit 1
    fi

    # Free the space BEFORE the fetch: keep only the tree the live server is
    # using, drop every other version. This also clears a half-fetched tree
    # left behind by an aborted run, so a retry never stacks on a partial.
    # Result: at most two versions on disk, the live one plus this fetch.
    for d in "$versionsDir"/*; do
      [ -d "$d" ] || continue
      name="$(basename "$d")"
      if [ "$name" != "$active" ] && [ "$name" != "$revision" ]; then
        echo "halogen-weights: pruning superseded version $d"
        rm -rf "$d"
      fi
    done

    markerFile="$targetDir/.halogen-weights-complete"
    expectedMarker="rev=$revision|excl=$exclusionsStr"
    if [ -d "$targetDir" ]; then
      if [ -f "$markerFile" ]; then
        read -r firstLine < "$markerFile"
        if [ "$firstLine" = "$expectedMarker" ]; then
          echo "halogen-weights: $targetDir complete (rev=$revision, excl=$exclusionsStr), nothing to do"
          trap - EXIT
          write_metric complete
          exit 0
        else
          echo "halogen-weights: $targetDir exists but exclusions/revision changed; will fetch (resumes from existing files)"
        fi
      else
        # Legacy / interrupted tree with no marker: adopt it (write marker)
        # rather than re-fetching a complete tree. A missing file in the tree
        # is handled by hf download (re-verifies); only exclusions that were
        # previously absent can be added now without deleting anything.
        echo "halogen-weights: $targetDir present without marker; adopting as complete (rev=$revision)"
        echo "$expectedMarker" > "$markerFile"
        trap - EXIT
        write_metric complete
        exit 0
      fi
    fi

    write_metric fetching
    echo "halogen-weights: fetching $repo @ $revision into $targetDir"
    "$hf" download "$repo" --revision "$revision" --local-dir "$targetDir" "''${excludeFlags[@]}"

    # Write the completion marker immediately after the fetch succeeds,
    # before the symlink flip. This means a failed/superseded fetch (e.g.
    # disk full, interrupted download with partial dir) never writes the
    # marker, so the next run sees the partial and resumes (re-fetches the
    # missing pieces) rather than trusting an incomplete tree.
    echo "$expectedMarker" > "$markerFile"

    # Atomic swap. `ln -sf` onto an existing symlink-to-a-directory follows
    # the link and creates the new one INSIDE it; rename(2) over the link
    # replaces the link itself, so stage under a temp name and move.
    tmpLink="$currentLink.new.$$"
    ln -s "$targetDir" "$tmpLink"
    mv -T "$tmpLink" "$currentLink"
    echo "halogen-weights: $currentLink -> $targetDir"
    trap - EXIT

    # The new tree is on disk and linked; now it is safe to move the server
    # onto it. try-restart so a host that has the unit masked does not fail
    # the sync.
    if [ -n "$restartUnits" ]; then
      echo "halogen-weights: restarting $restartUnits to load $revision"
      # The bump is only actually deployed once the server runs on the new tree.
      # try-restart exits 0 even for a unit that fails to come back, so the
      # outcome is checked rather than publishing `complete` over a dead server.
      "$systemctl" try-restart $restartUnits || {
        echo "halogen-weights: restart of $restartUnits failed" >&2
        write_metric restart_failed
        exit 1
      }
      for _u in $restartUnits; do
        if ! "$systemctl" is-active --quiet "$_u"; then
          echo "halogen-weights: $_u is not active after the restart" >&2
          write_metric restart_failed
          exit 1
        fi
      done
    fi
    write_metric complete

    # A bump that landed while this fetch was running is not silently dropped.
    # The path unit activates this service with StartUnit, which is a no-op while
    # it is already activating, so without this the newer intent would not be
    # picked up until the next change or a reboot. Exiting non-zero lets the
    # restart policy run the reconciler against the new intent.
    if [ -r "$targetRevisionFile" ]; then
      _now="$(tr -d '[:space:]' < "$targetRevisionFile")"
      if [ -n "$_now" ] && [ "$_now" != "$revision" ]; then
        echo "halogen-weights: intent moved to $_now mid-run; requeueing" >&2
        write_metric superseded
        exit 1
      fi
    fi
  '';

  weightsPreCheck =
    if versionedActive then
      # The sync unit owns the fetch. The role unit only refuses to start on
      # a missing tree — without this podman happily creates an empty bind
      # source and serves a model that is not there.
      "${pkgs.coreutils}/bin/test -d '${currentLink}'"
    else if cfg.download.enable then
      # Unversioned: download straight into modelsDir on every start.
      # First start transfers ~118 GiB (resumes when interrupted); later
      # starts re-verify existing files and only fetch what changed. With
      # `revision` set, hf fetches that exact commit instead of the floating
      # default branch.
      let
        revArg = lib.optionalString (cfg.download.revision != "") " --revision '${cfg.download.revision}'";
      in
      "${pkgs.python3Packages.huggingface-hub}/bin/hf download ${cfg.download.repo}${revArg} --local-dir '${cfg.modelsDir}'"
    else
      "${pkgs.coreutils}/bin/test -d '${cfg.modelsDir}'";

  roleArgs =
    roleName:
    let
      # Do not mirror shipped defaults here — when the image changes, a stale
      # override silently wins (upstream's own words on their compose file).
      extraEnv =
        (lib.optionalAttrs cfg.enableVision {
          # `1` tells the engine to look for the vision sidecar beside the
          # checkpoint inside the container's `/models` mount (i.e. the same
          # mount source that `current` points to). A raw host absolute path
          # (`${mountSource}/...`) does not exist inside the container namespace.
          HALOGEN_VISION_TOWER = "1";
        })
        // cfg.environment;
    in
    [
      "--name"
      "halogen-flash-${roleName}"
      "--rm"
      # Take over a container left by a previous run instead of failing to
      # start. Without this the unit is permanently wedged by its own name:
      # `podman run` exits 125 with "the container name ... is already in use"
      # and Restart=on-failure loops on that forever.
      #
      # Not hypothetical. On 2026-10-19 a deploy restarted the unit; podman
      # exited on the stop signal but the container kept running under conmon
      # (rootless podman falls back to --cgroup-manager=cgroupfs, so the
      # container is outside this unit's cgroup and KillMode cannot reach it).
      # The survivor held the name, every subsequent start failed, and llm01
      # was down ~19 min until the container was removed by hand.
      "--replace"
      # Upstream contract — keep in sync with their docker-compose.yml. The
      # seccomp escape is load-bearing: ROCm's syscall surface (kfd ioctls,
      # large mappings) trips the default profile, and their README ships it
      # on every invocation.
      "--device"
      "/dev/kfd"
      "--device"
      "/dev/dri"
      "--group-add"
      "keep-groups"
      "--security-opt"
      "seccomp=unconfined"
      "--ipc=host"
      "--ulimit"
      "memlock=-1:-1"
      # Holds checkpoint + quality sidecar + tokenizer/; read-only, and every
      # role reads it (the API needs the tokenizer). Under the versioned
      # layout this is the `current` symlink, so the source path never moves
      # across a weights bump.
      "-v"
      "${mountSource}:/models:ro"
      # Upstream's HALOGEN_TOKENIZER default points at /tokenizer — a second
      # mount in their examples. Ours is the same tree; mount it where the
      # image expects it (harmless if the image already looks at
      # /models/tokenizer).
      "-v"
      "${mountSource}/tokenizer:/tokenizer:ro"
    ]
    # All modes run on the host network (upstream's split topology): the
    # engine binds the host's loopback (HALOGEN_BIND default 127.0.0.1,
    # never published) and the API binds 0.0.0.0 on the published port.
    # Host networking also avoids pasta's published-port address selection,
    # which binds -p forwards only on loopback + the pasta interface — a LAN
    # client then gets timeouts even with the firewall port open.
    ++ [ "--network=host" ]
    ++ (lib.optionals (cfg.mode == "split" && roleName == "api") [
      "-e"
      "HALOGEN_ENGINE=127.0.0.1:${toString cfg.enginePort}"
    ])
    ++ lib.concatMap (k: [
      "-e"
      "${k}=${extraEnv.${k}}"
    ]) (lib.attrNames extraEnv)
    # raw pass-through, appended last so it can override anything above
    ++ cfg.extraRunArgs;

  # Quote one argv element for a systemd ExecStart line (systemd splits on
  # unquoted spaces; inside double quotes it honors \\" and \\, and needs %
  # doubled to escape specifier expansion). nixpkgs has no ready-made helper
  # for this, so keep a local one.
  sysdArg =
    a:
    if builtins.match "[A-Za-z0-9_@+=:,./-]*" a != null then
      a
    else
      "\"${lib.replaceStrings [ "\\" "\"" "%" ] [ "\\\\" "\\\"" "%%" ] a}\"";

  # A digest-pinned reference (name:tag@sha256:...) names immutable bytes;
  # a bare tag does not. Split the two so the pull unit can verify local
  # presence against the digest instead of trusting a tag that may have
  # moved since it was reviewed.
  imageParts =
    let
      parts = builtins.match "(.*)@(sha256:[0-9a-f]{64})" cfg.image;
    in
    if parts != null then
      {
        ref = builtins.elemAt parts 0;
        digest = builtins.elemAt parts 1;
      }
    else
      {
        ref = cfg.image;
        digest = "";
      };

  # Shared by the role units and the pull unit. Rootless podman needs $HOME
  # (its storage lives under it) and XDG_RUNTIME_DIR (systemd sets neither
  # for system units with User=); root runs need neither.
  unitEnvironment = [
    "HF_HOME=${cfg.modelsDir}/.cache"
  ]
  ++ lib.optionals (cfg.user != "root") [
    "HOME=${cfg.podmanHome}"
    "XDG_RUNTIME_DIR=/run/user/${toString config.users.users.${cfg.user}.uid}"
  ];

  # Pull the pinned image, but never let a dead registry take the server
  # down. If the pull fails and the exact artifact is already in local
  # storage, those are the same bytes we would have pulled, so succeed
  # anyway. With a digest-pinned `image` that equivalence is provable; with
  # a bare tag it is a guess, which is what the `pull` warning is about.
  #
  # Retries live here rather than in systemd Restart=, which is not
  # meaningful for a Type=oneshot unit.
  pullScript = ''
    set -u
    podman="${podmanPkg}/bin/podman"
    attempts=3
    n=1

    while [ "$n" -le "$attempts" ]; do
      if "$podman" pull --quiet "$HALOGEN_IMAGE"; then
        echo "halogen-flash: pulled $HALOGEN_IMAGE"
        exit 0
      fi
      echo "halogen-flash: pull attempt $n/$attempts failed for $HALOGEN_IMAGE" >&2
      n=$((n + 1))
      if [ "$n" -le "$attempts" ]; then sleep 15; fi
    done

    if [ -n "$HALOGEN_DIGEST" ]; then
      if "$podman" images --no-trunc --format '{{.Id}}' | grep -qxF "$HALOGEN_DIGEST"; then
        echo "halogen-flash: pull failed, pinned digest already in local storage"
        exit 0
      fi
    elif "$podman" image exists "$HALOGEN_IMAGE"; then
      echo "halogen-flash: pull failed, tag already in local storage (mutable tag: not necessarily current)" >&2
      exit 0
    fi

    echo "halogen-flash: pull failed and $HALOGEN_IMAGE is not available locally" >&2
    exit 1
  '';

  mkRoleUnit = roleName: {
    description = "halogen-flash-server (${roleName})";
    wantedBy = [ "multi-user.target" ];
    after =
      # The pull unit is a soft dependency: ordering only. A pull timeout
      # (e.g. when the ~112 GiB weights fetch saturates disk IO) must NOT
      # cascade into a role-unit failure, so this is After= (ordering) not
      # Requires= (hard dependency). It exits 0 when the pinned artifact is
      # already local, so this does not make boot contingent on the registry
      # being reachable.
      (lib.optionals cfg.pull.enable [ "halogen-flash-pull.service" ])
      # No edge on halogen-flash-weights.service: the fetch is a background
      # reconciler now, and ordering here would let a multi-hour download delay
      # a server restart. ExecStartPre's `test -d` is the only guard -- on a
      # fresh host with no weights the unit fails loudly and retries, which is
      # the same contract the pull unit has for a missing image.
      ++ (lib.optionals (cfg.download.enable && !versionedActive) [ "network-online.target" ])
      # split mode: don't race the engine to boot; its weight load takes
      # minutes and an API that starts first crash-loops until it is ready.
      ++ lib.optional (cfg.mode == "split" && roleName == "api") "halogen-flash-engine.service";
    wants =
      (lib.optionals (cfg.download.enable || cfg.pull.enable) [ "network-online.target" ])
      # The pull unit — Wants= (not Requires=): see the `after` comment above.
      # If the pull unit is already done (success or failure) when this unit
      # starts, systemd starts this unit anyway. If the image is missing, the
      # podman ExecStart fails and Restart=on-failure retries until the pull
      # completes and the image lands.
      ++ (lib.optionals cfg.pull.enable [ "halogen-flash-pull.service" ]);
    serviceConfig = {
      User = cfg.user;
      # Keep hub tmp/locks next to weights: predictable, per-host, no HOME
      # dependence (root vs service user diverge otherwise).
      Environment = unitEnvironment;
      ExecStartPre = [ weightsPreCheck ];
      # Generous headroom only while we fetch: the first ever start pulls
      # ~118 GiB of weights. Under the versioned layout the fetch lives in
      # the sync unit, so this only has to cover a weight load (minutes),
      # but keep the long ceiling for the unversioned path.
      # (mkIf rather than optionalString: an empty TimeoutStartSec= is a
      # parse failure systemd only warns about.)
      TimeoutStartSec = lib.mkIf cfg.download.enable "2d";
      # memlock=-1:-1 (upstream contract) needs to RAISE the hard limit — a
      # privileged operation. systemd applies this as root before switching
      # to User=, which is what makes the rootless podman run able to honor
      # it; without it podman exits immediately with EPERM as non-root.
      LimitMEMLOCK = "infinity";
      # Weight reloads take minutes; give repeated load failures real room.
      # No StartLimit* here on purpose: the manager default is 5 starts in 10 s,
      # which RestartSec=30 never reaches, so a failed load keeps retrying until
      # the weights unit flips `current` and restarts it. That unbounded retry is
      # what lets a host that booted before its weights existed recover on its
      # own once the fetch lands.
      Restart = "on-failure";
      RestartSec = "30";
      # Stop path — see the header note. The container is outside this unit's
      # cgroup under rootless podman, so systemd's own kill cannot reach it and
      # these podman-mediated directives are the only thing that does.
      #
      # Both are `-`-prefixed (ignore failure): a cleanup error must not fail the
      # unit, or the comin health gate rolls back a deploy over a container that
      # was already gone. Neither may be `+`-prefixed: rootless podman keeps its
      # state in cfg.user's store, so a root-prefixed cleanup would clean root's
      # store and leave the real container holding the GPU. systemd applies
      # User= and Environment= to Exec*Post too, so HOME/XDG_RUNTIME_DIR are
      # already the values rootless podman needs.
      #
      # ExecStop drains (in-flight requests finish, GTT unmaps cleanly; upstream
      # documents --ignore for exactly this ExecStop-references-a-gone-container
      # case). ExecStopPost is the backstop and, unlike ExecStop, also runs after
      # a FAILED start — that is what reaps a half-created container. `--rm` on
      # ExecStart already removes a container that exits by itself, so on the
      # happy path the rm is a no-op.
      ExecStop = "-${podmanPkg}/bin/podman stop -t 30 --ignore halogen-flash-${roleName}";
      ExecStopPost = "-${podmanPkg}/bin/podman rm -f --ignore halogen-flash-${roleName}";
      # Bounds ExecStop + ExecStopPost together. Explicit rather than inherited
      # so the relationship to the `-t 30` drain above stays visible if anyone
      # raises that timeout.
      TimeoutStopSec = "60";
      # systemd splits ExecStart itself (no shell): flag/value pairs stay
      # separate argv elements, each through sysdArg so paths/env values with
      # spaces survive. (escapeShellArgs was wrong here: it quotes per element
      # for a shell, producing one-argv "--name foo".)
      ExecStart =
        let
          argv = roleArgs roleName ++ [
            cfg.image
            roleName
          ];
        in
        "${podmanPkg}/bin/podman run ${lib.concatMapStringsSep " " sysdArg argv}";
    };
  };

in
{
  options.services.halogenFlash = {
    enable = lib.mkEnableOption "halogen-flash-server, the ROCm inference server for Qwen3.8-Flash-Next on AMD Strix Halo";

    user = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = ''
        User the systemd units (podman + weights ExecStartPre) run as.
        Default root: has CAP_DAC_OVERRIDE for /dev/kfd + /dev/dri and uses
        the system podman store, matching upstream's docker-compose.

        A non-root user means ROOTLESS podman: the container process runs as
        that uid, and the image lives in that user's podman storage
        (podmanHome) — it must be pulled BY that user, a root `podman pull`
        does not help. The user needs render/video group access for /dev/kfd
        + /dev/dri; the module handles linger, subuid/subgid range
        allocation and ownership of modelsDir/podmanHome (tmpfiles).

        The weights sync unit always runs as root regardless of this option,
        because it has to restart the server units once a new tree lands.
        Files it writes are world-readable, so the service user reads them
        fine without owning them. That unit is started by
        `halogen-flash-weights.path` when the declared revision changes, not by
        the switch.
      '';
    };

    podmanHome = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/halogen";
      description = ''
        $HOME for the unit (only used when user != "root"): holds the user's
        podman storage (containers/ — image layers, reserve tens of GiB) and
        stray state files. Put it on a big volume; for a root run it is
        unused.
      '';
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/peonist-ai/halogen-flash-server:0.18.14@sha256:e0c1d1b48e07c8acdd204fbdbafbb421a395a73cf704271845a1846ad1fd767f";
      description = ''
        Full container-image reference for the release build. Both units in
        split mode run this one reference on purpose: an API older than the
        engine silently mis-routes requests (upstream issue #26).

        Prefer the digest-pinned form `name:tag@sha256:<digest>`. It is
        what makes `pull.enable` safe: the running container is then
        provably the artifact that was reviewed, and the pull unit's
        offline fallback ("already in local storage") means the same bytes
        rather than whatever a mutable tag last pointed at. The bump script
        in this repo writes the pinned form for you.

        Without `pull.enable`, the image is used as-is and never fetched:
        bump this option, `podman pull` it as `user`, then restart.
      '';
    };

    pull = lib.mkOption {
      type = lib.types.submodule {
        options.enable = lib.mkEnableOption ''
          a oneshot unit that pulls the image before the server units start
        '';
      };
      default = {
        enable = false;
      };
      description = ''
        When enabled, `halogen-flash-pull.service` runs before the role
        units and pulls `image` as `user` — which matters for rootless
        setups, where a root `podman pull` would land in the wrong store.

        The unit retries three times, and still succeeds if the pull fails
        while the exact artifact is already in local storage, so a reboot
        during a registry outage keeps the server up. If the artifact is
        neither pullable nor present, the unit fails and retries on a
        bounded schedule (`Restart=on-failure`, 10 attempts in 10 minutes).
        The role units order after it (`After=`) but do not `Requires=` it,
        so a pull timeout — e.g. disk IO starved by a concurrent ~112 GiB
        weights fetch — cannot stop a server that is already running. The
        role units' own `Restart=on-failure` keeps retrying until the image
        lands, which is a loud failure the host health gate sees rather than
        a silently stale container.

        Only enable this with a digest-pinned `image`; the module warns
        otherwise.
      '';
    };

    mode = lib.mkOption {
      type = lib.types.enum [
        "all"
        "split"
      ];
      default = "all";
      description = ''
        all: one container running engine + OpenAI front-end (the upstream
        quickstart shape); restarting reloads the ~115 GiB model.

        split: two units on host networking, so an API restart costs no weight
        reload; only the API port is reachable from outside, the engine stays
        bound to loopback.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8731;
      description = "Host port of the OpenAI-compatible endpoint in all mode.";
    };

    enginePort = lib.mkOption {
      type = lib.types.port;
      default = 8730;
      description = "Engine port on host loopback in split mode (never published).";
    };

    modelsDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/halogen/models";
      example = "/opt/llm/halogen/models";
      description = ''
        Base directory for the weights. With `download.toVersionedDir` (the
        default) it holds `versions/<revision>/` plus a `current` symlink,
        and the container mounts `current` as /models — so this path stays
        constant across weight bumps. Needs ~2x the weight size of headroom
        on a big volume during a bump (on llm01 that is /opt/llm).

        With versioning off it is the weight tree itself, exactly as
        `hf download <repo> --local-dir` writes it.
      '';
    };

    download = lib.mkOption {
      type = lib.types.submodule (
        { ... }: rec {
          options.enable = lib.mkEnableOption "fetching the weights with huggingface-hub";
          options.repo = lib.mkOption {
            type = lib.types.str;
            default = defaultRepo;
            description = "HuggingFace repo id: ~115 GiB checkpoint, quality sidecar and tokenizer.";
          };
          options.revision = lib.mkOption {
            type = lib.types.str;
            default = defaultWeightsRevision;
            example = "cd24312f5c5e671659f538ed1f489120c658901f";
            description = ''
              HuggingFace commit sha to pin the weights to. Defaults to
              `defaultWeightsRevision` above so the weights are as immutable as
              the image. Setting it to "" means the repo's default branch,
              which floats: an upstream push would swap the model underneath a
              digest-pinned image with no review and no rollback path, and may
              not even match what that image expects.
            '';
          };
          options.toVersionedDir = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Fetch into `<modelsDir>/versions/<revision>/` and point
              `<modelsDir>/current` at the live revision, instead of pulling
              straight into `modelsDir`.

              Because the units mount `current`, a revision bump no longer
              changes the server units at all. The switch writes the revision to
              /etc/halogen-flash/target-revision and returns in seconds;
              `halogen-flash-weights.path` then starts
              `halogen-flash-weights.service`, which downloads the new tree
              while the old server keeps serving, flips the symlink, and only
              then restarts the server to load it. The deploy never waits on the
              transfer, and the window where the server is down is the weight
              load (minutes), not the ~112 GiB transfer (hours).

              Superseded versions are pruned BEFORE each fetch, so the volume
              only ever needs room for two: the live tree and the one being
              fetched. Roll back by writing the older revision to the intent
              file (or pointing `current` at the older tree) and letting the
              path unit act.

              Set false for the original behaviour (fetch into `modelsDir` in
              the role unit's ExecStartPre, which blocks startup).
            '';
          };
          options.exclude = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            # Default matches `defaultRepo`'s unused checkpoints, so a weights
            # bump fits the ~330 GiB volume without pulling the whole 286 GiB
            # repo. Measured at aec9e43: these skip 173.9 GiB (w4b.hgn 115.5,
            # ht43.hgn 53.7, w4b.overlay 2.4, w4b.overlay-speed 2.3) and keep
            # the 112.1 GiB the engine needs (v2 + ngram + mtp + vision +
            # tokenizer). This is a curated DENYLIST, not a required-only
            # filter: on a weights bump, re-check the repo tree and extend it
            # if the new revision adds another large unused checkpoint. Override
            # per host (or set [ ] to fetch everything) if you want a different
            # set; the patterns are harmless against a non-matching repo.
            default = [
              "qwen38-flash-next-w4b*"
              "qwen38-flash-next-ht43*"
            ];
            description = ''
              Glob patterns passed to `hf download --exclude`, naming files in the
              weights repo that must never be fetched. Patterns apply against file
              paths in the repo (`fnmatch`), not the mounted tree. The module
              records the exclusions in the fetch-completion marker, so changing
              them forces a fresh download of anything previously excluded; nothing
              is deleted.
            '';
          };
        }
      );
      default = {
        enable = false;
        repo = defaultRepo;
        revision = defaultWeightsRevision;
        toVersionedDir = true;
      };
      description = ''
        When enabled, the weights are fetched with `hf download <repo>
        --revision <rev> --local-dir <dir>`: the first time it transfers
        ~118 GiB (it resumes when interrupted), afterwards hf-hub
        re-verifies existing files and only fetches what changed. The
        container therefore never dials out.

        With `toVersionedDir = true` (default) that fetch runs in its own
        `halogen-flash-weights.service` oneshot, triggered by
        `halogen-flash-weights.path` when the declared revision changes rather
        than by the switch. It prunes superseded versions first, then atomically
        flips the `current` symlink and restarts the server units. A revision
        change is therefore a deploy that returns immediately, a background
        download, and one short reload — and a failed download fails only the
        weights unit, never the deploy that requested it.

        With `toVersionedDir = false` the fetch runs in the role unit's
        ExecStartPre, so the deploy that introduces a revision change is
        down for the whole transfer and needs a health-gate warmup window
        that can outlast it (see cominGitOps.healthGate.halogenWarmupSec
        downstream).

        When disabled, provision the directory yourself (`hf download ...
        --local-dir <modelsDir>` by hand) — a plain `test -d` runs instead.
      '';
    };

    metricsTextfileDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/node-exporter/textfiles";
      example = "";
      description = ''
        Directory for the `halogen-weights.prom` node_exporter textfile, or ""
        to disable metric emission. The sync unit records the desired revision,
        the live revision, and its own state there at every transition.

        This exists because a decoupled fetch can fail long after the deploy
        that requested it reported success; without this the failure is
        invisible to monitoring. The directory must be one node_exporter
        actually reads -- enabling the textfile collector is the host's job,
        not this module's.
      '';
    };

    enableVision = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Set HALOGEN_VISION_TOWER to the vision sidecar inside the mounted
        tree so images are accepted on /v1. The engine wants a PATH (it
        names the file it found, e.g. /models/qwen38-flash-next-vision.hgn);
        the sidecar must have been downloaded with the weights. Off by
        default: a text-only server is byte-identical to a build without any
        of it and allocates nothing for it.
      '';
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Extra HALOGEN_* variables passed with -e. See the upstream docs/FLAGS.md
        for what each one costs; do not copy shipped defaults here (a stale
        override silently wins once the image changes).
      '';
    };

    extraRunArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional raw `podman run` arguments, appended last.";
    };
  };

  # Runs podman as a system unit as cfg.user (default root; non-root =
  # rootless podman with the container running as that uid). As root the
  # container process gets CAP_DAC_OVERRIDE for /dev/kfd + /dev/dri;
  # --group-add keep-groups stays to match upstream's invocation (and is what
  # carries render/video GIDs through in rootless mode).
  #
  # GPU memory budget is host-wide: llm01's GTT (~112–120 GiB) is a single
  # pool shared with whatever else the iGPU holds (llama-cpp-server), so this
  # and that are mutually exclusive — run one or the other at a time.
  config = lib.mkMerge ([
    # Explicit unit names (no mapAttrsToList over dynamic keys): keeps the
    # merge plain attrsets, which is what the current NixOS module system
    # handles without trouble.
    (lib.mkIf (cfg.enable && cfg.mode == "all") {
      systemd.services."halogen-flash" = mkRoleUnit "all";
    })
    # The weights sync unit. A background reconciler, not part of the deploy:
    # it runs at boot and whenever halogen-flash-weights.path sees the declared
    # intent change, and exits immediately when nothing changed. Its generated
    # text must not depend on the revision -- see the description below.
    (lib.mkIf (cfg.enable && versionedActive) {
      # The declared intent. Written on every activation; its bytes change only
      # when the pinned revision is bumped, so a no-change deploy fires nothing.
      # environment.etc (not tmpfiles) because it renames into place atomically
      # and always exists after activation, which is what PathChanged needs.
      environment.etc."halogen-flash/target-revision".text = "${targetRevision}\n";
    })
    (lib.mkIf (cfg.enable && versionedActive) {
      systemd.services."halogen-flash-weights" = {
        # Constant on purpose. switch-to-configuration restarts units whose
        # generated text changed, so naming the revision here would stop the
        # fetch unit on every bump and hold the server behind it. The revision
        # is read from /etc/halogen-flash/target-revision at run time instead.
        description = "Sync halogen-flash weights to the declared revision";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          # RemainAfterExit deliberately NOT set: a PathUnit activates this unit
          # with StartUnit, and starting an already-active RemainAfterExit oneshot
          # is a no-op -- the second bump would silently do nothing. Leaving the
          # unit inactive after a run is what makes repeat bumps work. Nothing
          # orders off this unit any more, so nothing needs it to stay active.
          # root, not cfg.user: the unit restarts the server units after
          # flipping the symlink, which a non-root user cannot do.
          User = "root";
          # Same hub cache location the role units use, under the BASE dir
          # so pruning a version never throws away resumable metadata.
          Environment = [ "HF_HOME=${cfg.modelsDir}/.cache" ];
          ExecStart = weightsSyncScript;
          # A revision bump is a fresh ~112 GiB transfer.
          TimeoutStartSec = "2d";
          Restart = "on-failure";
          RestartSec = "60";
        };
        # StartLimit* is a [Unit] directive, not a [Service] one. NixOS renders
        # serviceConfig into [Service], where systemd ignores unknown keys with a
        # warning, so declaring them there silently loses the bound: the manager
        # defaults (5 starts in 10 s) never trip against RestartSec=60 and a
        # permanently failing fetch churns forever instead of settling `failed`.
        unitConfig = {
          # Bounded: the fetch is no longer a deploy, so a permanently failing
          # download must settle in a visible `failed` state rather than churn
          # forever. Five attempts in an hour rides out an HF blip.
          StartLimitBurst = 5;
          StartLimitIntervalSec = 3600;
        };
      };

      # The trigger. The deploy only rewrites the intent file; this notices.
      systemd.paths."halogen-flash-weights" = {
        description = "Watch the declared halogen-flash weights revision";
        wantedBy = [ "multi-user.target" ];
        pathConfig = {
          PathChanged = "/etc/halogen-flash/target-revision";
          Unit = "halogen-flash-weights.service";
        };
      };
    })
    (lib.mkIf (cfg.enable && cfg.pull.enable) {
      systemd.services."halogen-flash-pull" = {
        description = "Pull the halogen-flash-server image";
        wantedBy = [ "multi-user.target" ];
        # Deliberately NO ordering edge on halogen-flash-weights.service: that
        # unit can legitimately run for up to 2 days (~112 GiB fetch), and
        # After= would hold the pull — and so, via the role units' After=, the
        # server — behind the whole transfer. IO contention is handled by the
        # pull's own retry (Restart=on-failure), not by serialising the two.
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          # Same user as the role units: rootless podman stores the image
          # per-user, so pulling as anyone else is useless here.
          User = cfg.user;
          Environment = unitEnvironment ++ [
            "HALOGEN_IMAGE=${cfg.image}"
            "HALOGEN_DIGEST=${imageParts.digest}"
          ];
          ExecStart = "${pkgs.writeShellScript "halogen-flash-pull" pullScript}";
          # The image is the engine + front-end only (a few GiB); the
          # ~118 GiB of weights are a separate volume and untouched
          # here. Generous, but bounded well below the weight-fetch
          # timeout on the sync unit.
          TimeoutStartSec = "30min";
          # Retry on failure so an IO-starved timeout (e.g. the weights
          # fetch saturating disk) recovers instead of leaving the image
          # permanently absent and the role units stuck retrying.
          Restart = "on-failure";
          RestartSec = "60";
        };
        # Bound the retry storm: a persistently unreachable registry or a
        # digest that never resolves would otherwise restart every 60 s
        # forever. Ten attempts in ten minutes rides out a transient blip
        # without churning indefinitely.
        unitConfig = {
          StartLimitBurst = 10;
          StartLimitIntervalSec = 600;
        };
      };
    })
    (lib.mkIf (cfg.enable && cfg.mode == "split") {
      systemd.services."halogen-flash-engine" = mkRoleUnit "engine";
      systemd.services."halogen-flash-api" = mkRoleUnit "api";
    })
    (lib.mkIf (cfg.enable && cfg.pull.enable && imageParts.digest == "") {
      warnings = [
        ''
          services.halogenFlash.pull is enabled but services.halogenFlash.image
          (${cfg.image}) is not digest-pinned. The pull unit fetches a mutable
          tag, so the container that starts is whatever the registry served at
          that moment — not necessarily the release that was reviewed — and the
          "already in local storage" fallback is a guess rather than a proof.
          Pin it as `name:tag@sha256:<digest>` (scripts/bump-image.sh writes
          this form) or disable the pull.''
      ];
    })
    # The published API port (the engine port is loopback-only, and
    # loopback traffic does not traverse the firewall).
    (lib.mkIf cfg.enable { networking.firewall.allowedTCPPorts = [ cfg.port ]; })
    # Rootless mode support: linger keeps /run/user/<uid> alive for podman,
    # subuid/subgid ranges are REQUIRED by rootless podman (auto-allocation
    # only defaults on for isNormalUser — a system user like ollama needs
    # this), and tmpfiles gives the user ownership of its storage and the
    # weights (Z also fixes ownership of a pre-fetched tree).
    (lib.mkIf (cfg.enable && cfg.user != "root") {
      users.users.${cfg.user} = {
        linger = true;
        autoSubUidGidRange = true;
      };
      # Rootless podman with a subuid range execs newuidmap/newgidmap,
      # which only work setuid-root. Define the wrappers here so hosts
      # without virtualisation.podman (or programs.shadow) get them too;
      # identical definitions merge cleanly with those modules'.
      security.wrappers = {
        newuidmap = {
          setuid = true;
          owner = "root";
          group = "root";
          source = "${pkgs.shadow}/bin/newuidmap";
        };
        newgidmap = {
          setuid = true;
          owner = "root";
          group = "root";
          source = "${pkgs.shadow}/bin/newgidmap";
        };
      };
      systemd.tmpfiles.rules = [
        # Guarantee the runtime dir exists before the first start — logind
        # creates it for linger, but can race the unit on a fresh switch.
        "d /run/user/${toString config.users.users.${cfg.user}.uid} 0700 ${cfg.user} ${
          config.users.users.${cfg.user}.group
        } - -"
        "d ${cfg.podmanHome} 0750 ${cfg.user} ${config.users.users.${cfg.user}.group} - -"
        # The base dir has to exist before the sync unit runs as root, and
        # Z keeps a pre-fetched tree readable by the service user.
        "d ${cfg.modelsDir} 0755 ${cfg.user} ${config.users.users.${cfg.user}.group} - -"
        "Z ${cfg.modelsDir} 0755 ${cfg.user} ${config.users.users.${cfg.user}.group} - -"
      ];
    })
  ]);
}
