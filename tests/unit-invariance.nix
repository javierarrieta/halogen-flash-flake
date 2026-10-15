# Test harness: render the generated systemd units for this module as one
# comparable string, so a caller can diff it across two values of
# `services.halogenFlash.download.revision`.
#
# `rev` is fed through the public `download.revision` option rather than by
# editing the module, so the harness tests the same interface a host uses.
#
# Why this exists: switch-to-configuration stops and restarts any unit whose
# generated text changed. If any unit's text embeds the revision, a weights bump
# restarts it, and the inference server loses its weights load for the whole
# ~112 GiB fetch. Byte-identical unit text across revisions is what makes a bump
# a non-event for the running server.
#
# Whole units are dumped rather than a hand-picked attribute list on purpose: a
# check that names only the fields the author thought of cannot catch a leak
# through a field the author did not think of.
{
  rev,
  mode ? "all",
}:
let
  mod = import ../nixos/module.nix;
  ev = import (toString <nixpkgs> + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [
      mod
      {
        services.halogenFlash = {
          enable = true;
          mode = mode;
          download.enable = true;
          download.revision = rev;
        };
      }
    ];
  };

  # Every key of a section, sorted, one `prefix_KEY=value` line each.
  dumpSection =
    prefix: sect:
    builtins.concatStringsSep "\n" (
      map (k: "${prefix}_${k}=${builtins.toString (builtins.getAttr k sect)}") (
        builtins.sort builtins.lessThan (builtins.attrNames sect)
      )
    );

  # Everything that ends up in the unit file, plus the top-level attributes the
  # generator folds into [Unit]/[Service] itself.
  dumpUnit =
    name:
    let
      u = ev.config.systemd.services.${name} or { };
      svcCfg = u.serviceConfig or { };
      unitCfg = u.unitConfig or { };
      p = builtins.replaceStrings [ "-" ] [ "_" ] name;
    in
    ''
      ### UNIT ${name}
      ${p}_description=${u.description or ""}
      ${p}_after=${builtins.toString (u.after or [ ])}
      ${p}_before=${builtins.toString (u.before or [ ])}
      ${p}_requires=${builtins.toString (u.requires or [ ])}
      ${p}_wants=${builtins.toString (u.wants or [ ])}
      ${p}_wantedBy=${builtins.toString (u.wantedBy or [ ])}
      ${p}_partOf=${builtins.toString (u.partOf or [ ])}
      ${p}_restartTriggers=${builtins.toString (u.restartTriggers or [ ])}
      ${dumpSection "${p}_UNIT" unitCfg}
      ${dumpSection "${p}_CFG" svcCfg}
    '';

  # "all" mode runs one combined unit; "split" runs an engine and an api unit.
  # Both mount the weights tree, so both must be revision-independent.
  roleUnitNames =
    if mode == "split" then
      [
        "halogen-flash-engine"
        "halogen-flash-api"
      ]
    else
      [ "halogen-flash" ];

  roleDump = builtins.concatStringsSep "\n" (map dumpUnit roleUnitNames);

  pathUnit = ev.config.systemd.paths."halogen-flash-weights" or { };
  pathCfg = pathUnit.pathConfig or { };
in
''
  ### MODE=${mode}
  ${dumpUnit "halogen-flash-weights"}
  ### PATH halogen-flash-weights
  PATH_description=${pathUnit.description or ""}
  PATH_wantedBy=${builtins.toString (pathUnit.wantedBy or [ ])}
  ${dumpSection "PATH_CFG" pathCfg}
  ${roleDump}
  ### ETC
  ETC_TARGET=${ev.config.environment.etc."halogen-flash/target-revision".text or "<none>"}
''
