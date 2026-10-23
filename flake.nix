# SPDX-License-Identifier: OLDAP-2.8
#
# The flake pins its input; devenv resolves its separate input.
{
  description = "LMDB, the Lightning Memory-Mapped Database, built from this repository's pinned upstream C with Zig 0.17";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/02c087f3fe673c9e317f206a627cb6b910336dbe";

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
        in pkgs.callPackage ./package.nix { zig = pkgs.zig_0_17; inherit linkage; };
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