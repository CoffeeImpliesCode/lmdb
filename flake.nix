# SPDX-License-Identifier: OLDAP-2.8
#
# The flake pins its input; devenv resolves its separate input.
{
  description = "LMDB, the Lightning Memory-Mapped Database, built from this repository's pinned upstream C with Zig 0.16";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/c7def046b9a883d46974757852106483d741586f";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems f;

      mk = system: linkage:
        let pkgs = nixpkgs.legacyPackages.${system};
        in pkgs.callPackage ./package.nix { zig = pkgs.zig_0_16; inherit linkage; };
    in
    {
      packages = forAllSystems (
        system:
        let
          # Default to the archive variant.
          staticVariant = mk system "static";
        in
        {
          static = staticVariant;
          shared = mk system "dynamic";
          default = staticVariant;
        }
      );
    };
}