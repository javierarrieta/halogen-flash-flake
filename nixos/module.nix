# NixOS deployment for peonist-ai/halogen-flash-server.
#
# Runs the release image (engine + OpenAI front-end, one tag) under Podman,
# following upstream's own container contract (see their docker-compose.yml):
#   --device /dev/kfd --device /dev/dri  ROCm access to the iGPU (GTT memory)
#   --group-add keep-groups              podman extension: pass GID memberships through
#   --ipc=host                           load-bearing; no shm_size substitutes for it
#   --ulimit memlock=-1:-1
# The weights are NOT fetched from inside the container: this module either
# uses a pre-provisioned directory or runs `hf download` as ExecStartPre (the
# hf-hub CLI is idempotent and resumes/re-verifies), so the models volume can
# be read-only and a deployed server makes no outbound connections.
{ lib, pkgs, config, ... }:

let
  cfg = config.services.halogenFlash;

  defaultRepo = "peonist-ai/halogen-qwen3.8-flash-next";

  weightsPreCheck =
    if cfg.download.enable
    # First start transfers ~118 GiB (resumes when interrupted); later starts
    # re-verify existing files and only fetch what changed.
    then "${pkgs.python3Packages.huggingface-hub}/bin/hf download ${cfg.download.repo} --local-dir '${cfg.modelsDir}'"
    else "test -d '${cfg.modelsDir}'";

  roleArgs = roleName:
    let
      # Do not mirror shipped defaults here — when the image changes, a stale
      # override silently wins (upstream's own words on their compose file).
      extraEnv = (lib.optionalAttrs cfg.enableVision { HALOGEN_VISION_TOWER = "1"; })
      // cfg.environment;
    in
    [
      "--name halogen-flash-${roleName}"
      "--rm"
      # Upstream contract — keep in sync with their docker-compose.yml.
      "--device /dev/kfd"
      "--device /dev/dri"
      "--group-add keep-groups"
      "--ipc=host"
      "--ulimit memlock=-1:-1"
      # Holds checkpoint + quality sidecar + tokenizer/; read-only, and every
      # role reads it (the API needs the tokenizer).
      "-v '${cfg.modelsDir}':/models:ro"
    ]
    ++ (lib.optionals (cfg.mode == "split") [ "--network=host" ])
    # In all mode only the API port leaves the container (the engine there
    # binds loopback INSIDE its own netns). In split mode both containers
    # share the host netns: the engine keeps its 127.0.0.1 default bind and is
    # never published, the API reaches it on the same loopback.
    ++ (lib.optionals ((roleName == "all" || roleName == "api") && cfg.mode != "split") [ "-p ${toString cfg.port}:8731" ])
    ++ (lib.optionals (cfg.mode == "split" && roleName == "api") [ "-e HALOGEN_ENGINE=127.0.0.1:${toString cfg.enginePort}" ])
    ++ builtins.map (k: "-e ${k}=${extraEnv.${k}}") (lib.attrNames extraEnv)
    # raw pass-through, appended last so it can override anything above
    ++ cfg.extraRunArgs;

  mkRoleUnit = roleName: {
    description = "halogen-flash-server (${roleName})";
    wantedBy = [ "multi-user.target" ];
    after =
      (lib.optionals cfg.download.enable [ "network-online.target" ])
      # split mode: don't race the engine to boot; its weight load takes
      # minutes and an API that starts first crash-loops until it is ready.
      ++ lib.optional (cfg.mode == "split" && roleName == "api") "halogen-flash-engine.service";
    wants = lib.optionals cfg.download.enable [ "network-online.target" ];
    serviceConfig = {
      User = cfg.user;
      # Keep hub tmp/locks next to weights: predictable, per-host, no HOME
      # dependence (root vs service user diverge otherwise).
      Environment =
        [ "HF_HOME=${cfg.modelsDir}/.cache" ]
        # Rootless podman needs $HOME (its storage lives under it) and
        # XDG_RUNTIME_DIR (systemd does not set it for system units with
        # User=); root runs don't need either.
        ++ lib.optionals (cfg.user != "root") [
          "HOME=${cfg.podmanHome}"
          "XDG_RUNTIME_DIR=/run/user/${toString config.users.users.${cfg.user}.uid}"
        ];
      ExecStartPre = [ weightsPreCheck ];
      # Generous headroom only while we fetch: the first ever start pulls
      # ~118 GiB of weights.
      TimeoutStartSec = lib.optionalString (cfg.download.enable) "2d";
      # Weight reloads take minutes; give repeated load failures real room,
      # but keep a crash-loop guard (5 starts in 30 s gives up).
      Restart = "on-failure";
      RestartSec = "30";
      ExecStart = "${pkgs.podman}/bin/podman run ${lib.escapeShellArgs (roleArgs roleName)} ${lib.escapeShellArg cfg.image} ${lib.escapeShellArg roleName}";
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
      default = "ghcr.io/peonist-ai/halogen-flash-server:0.6.3";
      description = ''
        Full container-image reference for the release build. Both units in
        split mode run this one tag on purpose: an API older than the engine
        silently mis-routes requests (upstream issue #26).

        The image is used as-is and never pulled automatically; bump this
        option to a new release, `podman pull` it, then restart the units.
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
        Directory holding the checkpoint, quality sidecar and tokenizer/ — the
        same directory `hf download <repo> --local-dir` writes. Needs ~130 GiB
        of headroom on a big volume (on llm01 that is /opt/llm).
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
      });
      default = { enable = false; repo = defaultRepo; };
      description = ''
        When enabled, ExecStartPre runs `hf download <repo> --local-dir
        modelsDir` on every start: the first time it transfers ~118 GiB (it
        resumes when interrupted), afterwards hf-hub re-verifies existing files
        and only fetches what changed. The container therefore never dials out.

        When disabled, provision the directory yourself (`hf download ...
        --local-dir <modelsDir>` by hand) — a plain `test -d` runs instead.
      '';
    };

    enableVision = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Set HALOGEN_VISION_TOWER=1 so images are accepted on /v1 (the vision
        sidecar lives beside the checkpoint in modelsDir). Off by default: a
        text-only server is byte-identical to a build without any of it and
        allocates nothing for it.
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
      (
        lib.mkIf (cfg.enable && cfg.mode == "split") {
          systemd.services."halogen-flash-engine" = mkRoleUnit "engine";
          systemd.services."halogen-flash-api" = mkRoleUnit "api";
        }
      )
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
          systemd.tmpfiles.rules = [
            "d ${cfg.podmanHome} 0750 ${cfg.user} ${config.users.users.${cfg.user}.group} - -"
            "Z ${cfg.modelsDir} 0750 ${cfg.user} ${config.users.users.${cfg.user}.group} - -"
          ];
        }
      )
    ]);
}
