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
# Disk is capped at TWO versions: the sync unit prunes every version dir that
# is not the live one before it starts a fetch, so a revision bump never needs
# room for three.
{ lib, pkgs, config, ... }:

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
  defaultWeightsRevision = "e053f488b120b99ed2525e6ac99f68c51b3b6179";

  # Rootless runs need the setuid newuidmap/newgidmap: plain pkgs.podman
  # bundles crun/passt/etc. next to its binary, but the uid-mapping helpers
  # must be the system's setuid wrappers. virtualisation.podman.package is
  # exactly that (it bakes /run/wrappers into the helper lookup — same store
  # path as the host's own podman when it is enabled, so no rebuild).
  podmanPkg =
    if cfg.user != "root" then config.virtualisation.podman.package else pkgs.podman;

  # The versioned layout only exists when the module is the one fetching. With
  # downloads off the operator owns modelsDir outright, so mount it directly
  # and keep the pre-versioning behaviour byte-for-byte.
  versionedActive = cfg.download.enable && cfg.download.toVersionedDir;

  versionsDir = "${cfg.modelsDir}/versions";
  currentLink = "${cfg.modelsDir}/current";
  targetRevision = if cfg.download.revision != "" then cfg.download.revision else defaultWeightsRevision;
  targetDir = "${versionsDir}/${targetRevision}";

  # What the container actually mounts as /models. Constant under the
  # versioned layout (that constancy is the whole point); the raw base dir
  # otherwise.
  mountSource = if versionedActive then currentLink else cfg.modelsDir;

  # Units that read the weights tree, and therefore have to be restarted when
  # the symlink flips. Names are spelled out rather than derived from mkRoleUnit
  # so the restart target is obvious in the generated unit.
  roleUnitNames = if cfg.mode == "all" then [ "halogen-flash" ] else [
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
    targetDir=${targetDir}
    repo=${cfg.download.repo}
    revision=${targetRevision}
    hf=${pkgs.python3Packages.huggingface-hub}/bin/hf
    systemctl=${pkgs.systemd}/bin/systemctl
    restartUnits=${lib.escapeShellArg (lib.concatMapStringsSep " " (u: u + ".service") roleUnitNames)}

    mkdir -p "$versionsDir"

    # The symlink is the single source of truth for what is live: the running
    # container has whatever it pointed at bind-mounted, and that binding
    # survives the link being flipped underneath it.
    active=""
    if [ -L "$currentLink" ]; then
      active="$(basename "$(readlink "$currentLink")")"
    fi

    if [ "$active" = "$revision" ] && [ -d "$targetDir" ]; then
      echo "halogen-weights: revision $revision already active, nothing to do"
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

    if [ -d "$targetDir" ]; then
      echo "halogen-weights: $targetDir already on disk, skipping fetch"
    else
      echo "halogen-weights: fetching $repo @ $revision into $targetDir"
      "$hf" download "$repo" --revision "$revision" --local-dir "$targetDir"
    fi

    # Atomic swap. `ln -sf` onto an existing symlink-to-a-directory follows
    # the link and creates the new one INSIDE it; rename(2) over the link
    # replaces the link itself, so stage under a temp name and move.
    tmpLink="$currentLink.new.$$"
    ln -s "$targetDir" "$tmpLink"
    mv -T "$tmpLink" "$currentLink"
    echo "halogen-weights: $currentLink -> $targetDir"

    # The new tree is on disk and linked; now it is safe to move the server
    # onto it. try-restart so a host that has the unit masked does not fail
    # the sync.
    if [ -n "$restartUnits" ]; then
      echo "halogen-weights: restarting $restartUnits to load $revision"
      "$systemctl" try-restart $restartUnits
    fi
  '';

  weightsPreCheck =
    if versionedActive then
      # The sync unit owns the fetch. The role unit only refuses to start on
      # a missing tree — without this podman happily creates an empty bind
      # source and serves a model that is not there.
      "test -d '${currentLink}'"
    else if cfg.download.enable then
      # Unversioned: download straight into modelsDir on every start.
      # First start transfers ~118 GiB (resumes when interrupted); later
      # starts re-verify existing files and only fetch what changed. With
      # `revision` set, hf fetches that exact commit instead of the floating
      # default branch.
      let
        revArg = lib.optionalString (cfg.download.revision != "")
          " --revision '${cfg.download.revision}'";
      in
      "${pkgs.python3Packages.huggingface-hub}/bin/hf download ${cfg.download.repo}${revArg} --local-dir '${cfg.modelsDir}'"
    else
      "test -d '${cfg.modelsDir}'";

  roleArgs = roleName:
    let
      # Do not mirror shipped defaults here — when the image changes, a stale
      # override silently wins (upstream's own words on their compose file).
      extraEnv = (lib.optionalAttrs cfg.enableVision {
        HALOGEN_VISION_TOWER = "${mountSource}/qwen38-flash-next-vision.hgn";
      })
      // cfg.environment;
    in
    [
      "--name"
      "halogen-flash-${roleName}"
      "--rm"
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
    ++ (lib.optionals (cfg.mode == "split" && roleName == "api") [ "-e" "HALOGEN_ENGINE=127.0.0.1:${toString cfg.enginePort}" ])
    ++ lib.concatMap (k: [ "-e" "${k}=${extraEnv.${k}}" ]) (lib.attrNames extraEnv)
    # raw pass-through, appended last so it can override anything above
    ++ cfg.extraRunArgs;

  # Quote one argv element for a systemd ExecStart line (systemd splits on
  # unquoted spaces; inside double quotes it honors \\" and \\, and needs %
  # doubled to escape specifier expansion). nixpkgs has no ready-made helper
  # for this, so keep a local one.
  sysdArg =
    a:
    if builtins.match "[A-Za-z0-9_@+=:,./-]*" a != null then a
    else "\"${lib.replaceStrings [ "\\" "\"" "%" ] [ "\\\\" "\\\"" "%%" ] a}\"";

  # A digest-pinned reference (name:tag@sha256:...) names immutable bytes;
  # a bare tag does not. Split the two so the pull unit can verify local
  # presence against the digest instead of trusting a tag that may have
  # moved since it was reviewed.
  imageParts =
    let
      parts = builtins.match "(.*)@(sha256:[0-9a-f]{64})" cfg.image;
    in
    if parts != null then
      { ref = builtins.elemAt parts 0; digest = builtins.elemAt parts 1; }
    else
      { ref = cfg.image; digest = ""; };

  # Shared by the role units and the pull unit. Rootless podman needs $HOME
  # (its storage lives under it) and XDG_RUNTIME_DIR (systemd sets neither
  # for system units with User=); root runs need neither.
  unitEnvironment =
    [ "HF_HOME=${cfg.modelsDir}/.cache" ]
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
      # The pull unit is a hard dependency: no image, no server. It exits 0
      # when the pinned artifact is already local, so this does not make
      # boot contingent on the registry being reachable.
      (lib.optionals cfg.pull.enable [ "halogen-flash-pull.service" ])
      # On a fresh boot wait for the weights oneshot to finish (a oneshot
      # only reaches "started" once ExecStart exits 0), so the server does
      # not crash-loop against a tree that is still downloading. Deliberately
      # After= only, never Requires=: Requires would propagate a restart of
      # the sync unit into the server every time it merely re-ran.
      ++ (lib.optionals versionedActive [ "halogen-flash-weights.service" ])
      ++ (lib.optionals (cfg.download.enable && !versionedActive) [ "network-online.target" ])
      # split mode: don't race the engine to boot; its weight load takes
      # minutes and an API that starts first crash-loops until it is ready.
      ++ lib.optional (cfg.mode == "split" && roleName == "api") "halogen-flash-engine.service";
    wants = lib.optionals (cfg.download.enable || cfg.pull.enable) [ "network-online.target" ];
    requires = lib.optionals cfg.pull.enable [ "halogen-flash-pull.service" ];
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
      # Weight reloads take minutes; give repeated load failures real room,
      # but keep a crash-loop guard (5 starts in 30 s gives up).
      Restart = "on-failure";
      RestartSec = "30";
      # systemd splits ExecStart itself (no shell): flag/value pairs stay
      # separate argv elements, each through sysdArg so paths/env values with
      # spaces survive. (escapeShellArgs was wrong here: it quotes per element
      # for a shell, producing one-argv "--name foo".)
      ExecStart =
        let
          argv = roleArgs roleName ++ [ cfg.image roleName ];
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
        fine without owning them.
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
      default = "ghcr.io/peonist-ai/halogen-flash-server:0.13.8@sha256:6e626c979d536ab1edb07898e278be6686afd353758ea268817457f801d687dd";
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
      default = { enable = false; };
      description = ''
        When enabled, `halogen-flash-pull.service` runs before the role
        units and pulls `image` as `user` — which matters for rootless
        setups, where a root `podman pull` would land in the wrong store.

        The unit retries three times, and still succeeds if the pull fails
        while the exact artifact is already in local storage, so a reboot
        during a registry outage keeps the server up. If the artifact is
        neither pullable nor present, the unit fails and the role units do
        not start (they `Requires=` it) — a loud failure the host health
        gate sees, rather than a silently stale container.

        Only enable this with a digest-pinned `image`; the module warns
        otherwise.
      '';
    };

    mode = lib.mkOption {
      type = lib.types.enum [ "all" "split" ];
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
      type = lib.types.submodule ({ ... }: rec {
        options.enable = lib.mkEnableOption "fetching the weights with huggingface-hub before each start";
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
            changes the server units at all: `halogen-flash-weights.service`
            downloads the new tree while the old server keeps serving, flips
            the symlink, and only then restarts the server to load it. The
            window where the server is down is the weight load (minutes), not
            the ~118 GiB transfer (hours).

            Superseded versions are pruned BEFORE each fetch, so the volume
            only ever needs room for two: the live tree and the one being
            fetched. Roll back by pointing `current` at the older tree and
            restarting.

            Set false for the original behaviour (fetch into `modelsDir` in
            the role unit's ExecStartPre, which blocks startup).
          '';
        };
      });
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
        `halogen-flash-weights.service` oneshot, which prunes superseded
        versions first, then atomically flips the `current` symlink and
        restarts the server units. A revision change is therefore a
        background download followed by a short reload.

        With `toVersionedDir = false` the fetch runs in the role unit's
        ExecStartPre, so the deploy that introduces a revision change is
        down for the whole transfer and needs a health-gate warmup window
        that can outlast it (see cominGitOps.healthGate.halogenWarmupSec
        downstream).

        When disabled, provision the directory yourself (`hf download ...
        --local-dir <modelsDir>` by hand) — a plain `test -d` runs instead.
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
  config =
    lib.mkMerge ([
      # Explicit unit names (no mapAttrsToList over dynamic keys): keeps the
      # merge plain attrsets, which is what the current NixOS module system
      # handles without trouble.
      (
        lib.mkIf (cfg.enable && cfg.mode == "all") {
          systemd.services."halogen-flash" = mkRoleUnit "all";
        }
      )
      # The weights sync unit. Wanted by multi-user.target and NOT Required by
      # the server units: it runs on boot and on every switch whose revision
      # differs, and exits immediately when nothing changed. Keeping it out of
      # the server's Requires= means re-running it never propagates a restart
      # into a healthy server.
      (
        lib.mkIf (cfg.enable && versionedActive) {
          systemd.services."halogen-flash-weights" = {
            description = "Sync halogen-flash weights to ${targetRevision}";
            wantedBy = [ "multi-user.target" ];
            after = [ "network-online.target" ];
            wants = [ "network-online.target" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              # root, not cfg.user: the unit restarts the server units after
              # flipping the symlink, which a non-root user cannot do.
              User = "root";
              # Same hub cache location the role units use, under the BASE dir
              # so pruning a version never throws away resumable metadata.
              Environment = [ "HF_HOME=${cfg.modelsDir}/.cache" ];
              ExecStart = weightsSyncScript;
              # A revision bump is a fresh ~118 GiB transfer.
              TimeoutStartSec = "2d";
              Restart = "on-failure";
              RestartSec = "60";
            };
          };
        }
      )
      (
        lib.mkIf (cfg.enable && cfg.pull.enable) {
          systemd.services."halogen-flash-pull" = {
            description = "Pull the halogen-flash-server image";
            wantedBy = [ "multi-user.target" ];
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
            };
          };
        }
      )
      (
        lib.mkIf (cfg.enable && cfg.mode == "split") {
          systemd.services."halogen-flash-engine" = mkRoleUnit "engine";
          systemd.services."halogen-flash-api" = mkRoleUnit "api";
        }
      )
      (
        lib.mkIf (cfg.enable && cfg.pull.enable && imageParts.digest == "") {
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
        }
      )
      # The published API port (the engine port is loopback-only, and
      # loopback traffic does not traverse the firewall).
      (lib.mkIf cfg.enable { networking.firewall.allowedTCPPorts = [ cfg.port]; })
      # Rootless mode support: linger keeps /run/user/<uid> alive for podman,
      # subuid/subgid ranges are REQUIRED by rootless podman (auto-allocation
      # only defaults on for isNormalUser — a system user like ollama needs
      # this), and tmpfiles gives the user ownership of its storage and the
      # weights (Z also fixes ownership of a pre-fetched tree).
      (
        lib.mkIf (cfg.enable && cfg.user != "root") {
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
            "d /run/user/${toString config.users.users.${cfg.user}.uid} 0700 ${cfg.user} ${config.users.users.${cfg.user}.group} - -"
            "d ${cfg.podmanHome} 0750 ${cfg.user} ${config.users.users.${cfg.user}.group} - -"
            # The base dir has to exist before the sync unit runs as root, and
            # Z keeps a pre-fetched tree readable by the service user.
            "d ${cfg.modelsDir} 0755 ${cfg.user} ${config.users.users.${cfg.user}.group} - -"
            "Z ${cfg.modelsDir} 0755 ${cfg.user} ${config.users.users.${cfg.user}.group} - -"
          ];
        }
      )
    ]);
}
