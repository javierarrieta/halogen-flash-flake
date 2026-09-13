{
  description = "NixOS deployment of peonist-ai/halogen-flash-server (AMD Strix Halo)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs = _inputs: let
    # The module is evaluated inside the HOST's module system, so podman and
    # huggingface-hub come from the host's own nixpkgs; nothing here needs a
    # platform (the `nixpkgs` input only pins future package outputs).
    module = import ./nixos/module.nix { };
  in {
    nixosModules.default = module;

    # Convenience alias for `imports` lists.
    defaultNixosModule = module;
  };
}
