# SPDX-License-Identifier: OLDAP-2.8
#
# One derivation, one linkage selector. Both entry points call this file the
# same way:
#
#   pkgs.callPackage ./package.nix { zig = pkgs.zig_0_16; inherit linkage; }
#
# The variants live in the entry points, not here. `linkage` defaults to the
# package's own policy: upstream's archive form, which is what build.zig has
# always produced.
#
# This file installs nothing of its own. build.zig owns the C flags, the source
# list, the header, the tools, the man pages, the pkg-config file and the licence
# material; one writer per path means this file runs the real build once, against
# $out, and then makes the one edit the graph cannot: the installed ELF rpath.
{ lib, stdenv, zig, patchelf, linkage ? "static" }:

assert linkage == "static" || linkage == "dynamic";
# build.zig chooses the shared-lock backend from the target's OS, but this
# derivation neither exercises nor documents a cross build. A remote builder for
# this derivation's own system is unaffected: there host and build agree.
assert stdenv.hostPlatform.system == stdenv.buildPlatform.system ||
  throw "lmdb: build for this stdenv's own system; pkgsCross is not supported";

let
  # patchelf rewrites ELF rpaths and does not read Mach-O, so the rpath
  # normalisation in the install phase is generated for ELF targets only, and
  # the tool is a build input exactly where that code runs. The platform is
  # decided here rather than in the builder, where `[ "$NIX_SYSTEM" != *-darwin ]`
  # is a literal string comparison and not a pattern match, so the test it
  # guarded never excluded anything.
  isElfTarget = !stdenv.hostPlatform.isDarwin;
in

stdenv.mkDerivation {
  pname = "lmdb";
  # build.zig refuses to configure when build.zig.zon .version and the pin it
  # compiles disagree; this string is the same pin and is checked the same way by
  # being compared here.
  version = "1.0.1";

  # Everything a build or a consumer needs, minus VCS state, caches, install
  # output, fetched packages, devenv/direnv state and nix build symlinks.
  src = lib.cleanSourceWith {
    src = ./.;
    filter = path: _type:
      let base = baseNameOf (toString path);
      in !(builtins.elem base [
        ".git"
        ".hg"
        ".svn"
        ".zig-cache"
        "zig-cache"
        "zig-out"
        "zig-pkg"
        ".devenv"
        ".devenv.flake.nix"
        ".devenv.state"
        ".direnv"
        "result"
      ] || lib.hasPrefix "result-" base);
  };

  strictDeps = true;
  dontConfigure = true;
  dontBuild = true;
  dontCheck = true;
  dontUseZigCheck = true;

  nativeBuildInputs = [ zig ] ++ lib.optional isElfTarget patchelf;

  # The Zig caches go under the builder's TMPDIR, never under $sourceRoot.
  installPhase = ''
    runHook preInstall

    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
    mkdir -p "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR"

    zig build -j"''${NIX_BUILD_CORES:-1}" \
      -Dcpu=baseline \
      -Dlinkage=${linkage} \
      -Doptimize=ReleaseSafe \
      --prefix "$out"

    # build.zig adds $ORIGIN/../lib or @loader_path/../lib so the installed
    # programs find this prefix. Zig also leaves an rpath into its own build
    # cache, which does not exist once the program is installed; drop it and
    # leave one entry, pointing at this prefix. build.zig installs the tool set
    # beside the library in both variants, so $out/bin is present either way.
    ${lib.optionalString isElfTarget ''
      for exe in "$out"/bin/*; do
        [ -f "$exe" ] || continue
        patchelf --remove-rpath "$exe"
        patchelf --set-rpath '$ORIGIN/../lib' "$exe"
      done
    ''}

    runHook postInstall
  '';

  passthru = {
    inherit linkage;
    zigVersion = zig.version;
  };

  meta = {
    description = "LMDB, the Lightning Memory-Mapped Database, built from this repository's pinned upstream C with Zig 0.16 — ${linkage} variant";
    homepage = "https://github.com/LMDB/lmdb";
    license = lib.licenses.openldap;
    platforms = lib.platforms.unix;
  };
}