# SPDX-License-Identifier: OLDAP-2.8
#
# Pinned entry points, and nothing else. `flake.lock` beside this file is the
# resolution of that one input, at the very commit named below, and it is
# shipped in `build.zig.zon`'s `.paths` so a package fetched through `.paths`
# resolves the pin rather than a branch. The devenv side is a different tree
# with a different pin and has no lock: `devenv.yaml` names its own nixpkgs and
# `devenv.lock` is the driver's to create. Neither file was invented here.
#
# No devShells output. The canonical development environment is devenv, and a dev
# shell that has to build LMDB to be entered is not a fast loop.
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
          # `default` preserves the SDK's native policy: upstream's archive form,
          # which is what build.zig produces with no -Dlinkage.
          staticVariant = mk system "static";
        in
        {
          static = staticVariant;
          # package.nix's `linkage` takes Zig's own spelling; "shared" is the
          # attribute name, not a value it accepts.
          shared = mk system "dynamic";
          default = staticVariant;
        }
      );
    };
}