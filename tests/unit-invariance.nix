# Test harness: render the parts of the generated systemd units that must NOT
# depend on the pinned weights revision, as one comparable string.
#
# `rev` is fed through the public `download.revision` option rather than by
# editing the module, so the harness tests the same interface a host uses.
#
# Why this exists: switch-to-configuration stops and restarts any unit whose
# generated text changed. If the weights unit's text embeds the revision, a
# weights bump restarts it, and the server (ordered behind it) waits for the
# whole ~112 GiB fetch. Byte-identical unit text across revisions is what makes
# a bump a non-event for the running server.
{ rev }:
let
  mod = import ../nixos/module.nix;
  ev = import (toString <nixpkgs> + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [
      mod
      {
        services.halogenFlash = {
          enable = true;
          download.enable = true;
          download.revision = rev;
        };
      }
    ];
  };
  svc = ev.config.systemd.services."halogen-flash-weights";
  path = ev.config.systemd.paths."halogen-flash-weights" or { };
  role = ev.config.systemd.services."halogen-flash" or { };
  svcCfg = svc.serviceConfig or { };
  pathCfg = path.pathConfig or { };
  keys = builtins.attrNames svcCfg;
in
''
WEIGHTS_DESCRIPTION=${svc.description}
WEIGHTS_AFTER=${toString (svc.after or [ ])}
WEIGHTS_WANTS=${toString (svc.wants or [ ])}
WEIGHTS_WANTEDBY=${toString (svc.wantedBy or [ ])}
WEIGHTS_EXECSTART=${toString (svcCfg.ExecStart or "<none>")}
${builtins.concatStringsSep "\n"
  (map (k: "WEIGHTS_CFG_${k}=${toString svcCfg.${k}}") (builtins.sort builtins.lessThan keys))}
PATH_DESCRIPTION=${path.description or "<none>"}
PATH_UNIT=${toString (pathCfg.Unit or "<none>")}
PATH_CHANGED=${toString (pathCfg.PathChanged or "<none>")}
PATH_WANTEDBY=${toString (path.wantedBy or [ ])}
ROLE_AFTER=${toString (role.after or [ ])}
ROLE_EXECSTARTPRE=${toString (role.serviceConfig.ExecStartPre or [ ])}
ETC_TARGET=${ev.config.environment.etc."halogen-flash/target-revision".text or "<none>"}
''
