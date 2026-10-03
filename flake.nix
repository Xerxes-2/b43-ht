{
  description = "b43 with 5 GHz and 802.11n on the Broadcom BCM4331 (HT-PHY)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      nixosModules.default = ./nix/module.nix;

      # Against nixpkgs' default kernel; the NixOS module builds against
      # whatever boot.kernelPackages is.
      packages.${system} = {
        default = pkgs.linuxPackages.callPackage ./nix/package.nix { };
        debug = pkgs.linuxPackages.callPackage ./nix/package.nix { debug = true; };
      };

      formatter.${system} = pkgs.nixfmt;
    };
}
