# SPDX-License-Identifier: OLDAP-2.8
#
# build.zig owns installation content; this derivation adds Nix packaging.
{ lib, stdenv, zig, patchelf, linkage ? "static" }:

assert linkage == "static" || linkage == "dynamic";
assert stdenv.hostPlatform.system == stdenv.buildPlatform.system ||
  throw "lmdb: build for this stdenv's own system; pkgsCross is not supported";

let
  # patchelf is used only for non-Darwin installs.
  isElfTarget = !stdenv.hostPlatform.isDarwin;
in

stdenv.mkDerivation {
  pname = "lmdb";
  # Matches the pinned build version.
  version = "1.0.1";

  # Exclude repository state and build outputs from the source.
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

  # Keep Zig caches outside the read-only source tree.
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

    # Keep only the install-relative rpath, not the build-cache path.
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