# SPDX-License-Identifier: OLDAP-2.8
#
# Development shell tools are separate from lazy package outputs.
{ pkgs, ... }:

let
  mk = linkage: pkgs.callPackage ./package.nix { zig = pkgs.zig_0_17; inherit linkage; };

  # Use the working-tree root for tasks instead of copying the SDK into the store.
  sdkRootArg = pkgs.lib.escapeShellArg (builtins.toString ./.);

  # Tasks must enter the SDK root; fail if the directory change fails.
  inSdk = ''cd ${sdkRootArg} || exit 1'';

  # Respect exported cache paths; otherwise use XDG_CACHE_HOME, then TMPDIR.
  # Fail if neither is set; never place Zig caches in the checkout.
  # Match enterShell's policy and share one local cache with nested builds.
  zigCache = task: ''
if [ -z "''${ZIG_GLOBAL_CACHE_DIR:-}" ] || [ -z "''${ZIG_LOCAL_CACHE_DIR:-}" ]; then
  if [ -n "''${XDG_CACHE_HOME:-}" ]; then
    lmdb_cache_root="$XDG_CACHE_HOME"
  elif [ -n "''${TMPDIR:-}" ]; then
    lmdb_cache_root="$TMPDIR"
  else
    echo "${task}: XDG_CACHE_HOME and TMPDIR are both unset, so no Zig cache" >&2
    echo "location is named here. Export ZIG_GLOBAL_CACHE_DIR and" >&2
    echo "ZIG_LOCAL_CACHE_DIR at an approved mount." >&2
    exit 1
  fi
  : "''${ZIG_GLOBAL_CACHE_DIR:=$lmdb_cache_root/zig-global-cache}"
  : "''${ZIG_LOCAL_CACHE_DIR:=$lmdb_cache_root/zig-local-cache}"
  export ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR
  mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
  unset lmdb_cache_root
fi
lmdb_build_cache="$ZIG_LOCAL_CACHE_DIR/lmdb/build"
mkdir -p "$lmdb_build_cache"
echo "${task}: build cache $lmdb_build_cache" >&2
'';

  # Install variants under separate local-cache directories; other tasks do not install.
  installPrefix = task: variant: ''
lmdb_prefix="$ZIG_LOCAL_CACHE_DIR/lmdb/${variant}"
mkdir -p "$lmdb_prefix"
echo "${task}: install prefix $lmdb_prefix" >&2
'';

  # Keep cache, job-width, and summary flags consistent across build tasks.
  zigFlags = ''--cache-dir "$lmdb_build_cache" -j8 --summary all'';
in
{
  packages = [
    pkgs.zig_0_17
    pkgs.pkg-config
    pkgs.bash
  ];

  outputs = {
    static = mk "static";
    # Nix output names map to Zig's linkage values.
    shared = mk "dynamic";
    default = mk "static";
  };

  tasks = {
    "lmdb:build" = {
      description = "Compile the three-unit C core, translate lmdb.h and install";
      exec = ''
        ${inSdk}
        ${zigCache "lmdb:build"}
        ${installPrefix "lmdb:build" "static"}
        zig build --prefix "$lmdb_prefix" ${zigFlags}
      '';
    };

    "lmdb:build-dynamic" = {
      description = "The same install, with -Dlinkage=dynamic";
      exec = ''
        ${inSdk}
        ${zigCache "lmdb:build-dynamic"}
        ${installPrefix "lmdb:build-dynamic" "dynamic"}
        zig build -Dlinkage=dynamic --prefix "$lmdb_prefix" ${zigFlags}
      '';
    };

    "lmdb:test" = {
      description = "Run the behavioural tests in $ZIG_OPTIMIZE, Debug by default";
      exec = ''
        ${inSdk}
        ${zigCache "lmdb:test"}
        zig build test -Doptimize="''${ZIG_OPTIMIZE:-Debug}" ${zigFlags}
      '';
    };

    "lmdb:test-release-safe" = {
      description = "Run the behavioural tests in ReleaseSafe";
      exec = ''
        ${inSdk}
        ${zigCache "lmdb:test-release-safe"}
        zig build test -Doptimize=ReleaseSafe ${zigFlags}
      '';
    };

    "lmdb:smoke" = {
      description = "Run the deterministic smoke program";
      exec = ''
        ${inSdk}
        ${zigCache "lmdb:smoke"}
        zig build smoke ${zigFlags}
      '';
    };

    "lmdb:check" = {
      description = "Compile every supported target without running any of them";
      exec = ''
        ${inSdk}
        ${zigCache "lmdb:check"}
        zig build check ${zigFlags}
      '';
    };

    "lmdb:check-refused-target" = {
      description = "Ask for wasm32-wasi by name; failure with the reason is the result";
      exec = ''
        ${inSdk}
        ${zigCache "lmdb:check-refused-target"}
        zig build check -Dtarget=wasm32-wasi ${zigFlags}
      '';
    };

    "lmdb:interop" = {
      description = "Build upstream mdb_dump and compare its -p body with the fixture";
      exec = ''
        ${inSdk}
        ${zigCache "lmdb:interop"}
        zig build interop ${zigFlags}
      '';
    };

    "lmdb:consumer" = {
      description = "Run the separate package in consumer/ against dep.module(\"lmdb\")";
      # The consumer requires caller-named scratch; it never defaults to /tmp or the checkout.
      # Runtime-loaded runs also need an explicit provider; there is no fallback.
      # The program removes only its database child; the scratch directory remains.
      exec = ''
        ${inSdk}
        ${zigCache "lmdb:consumer"}
        if [ -n "''${LMDB_TEST_SCRATCH:-}" ]; then
          scratch="$LMDB_TEST_SCRATCH"
        elif [ -n "''${TMPDIR:-}" ]; then
          scratch="$(mktemp -d "$TMPDIR/lmdb-consumer.XXXXXXXX")"
        else
          echo "lmdb:consumer: no scratch location was named." >&2
          echo "The consumer program will not invent one: it takes --scratch or" >&2
          echo "LMDB_TEST_SCRATCH and never reads TMPDIR, /tmp or the source" >&2
          echo "tree. Export LMDB_TEST_SCRATCH, or TMPDIR at an approved mount." >&2
          exit 1
        fi
        echo "lmdb:consumer: scratch $scratch" >&2
        LMDB_TEST_SCRATCH="$scratch" zig build consumer ${zigFlags}
      '';
    };

    "lmdb:integrity" = {
      description = "Check all 43 SHA-256 records in UPSTREAM.sha256";
      exec = ''
        ${inSdk}
        sha256sum -c UPSTREAM.sha256
      '';
    };
  };

  # Respect exported cache paths; otherwise use XDG_CACHE_HOME, then TMPDIR.
  # Fail without either path rather than inventing a cache location.
  # Keep shell-entry defaults aligned with task cache selection.
  enterShell = ''
    if [ -z "''${ZIG_GLOBAL_CACHE_DIR:-}" ] || [ -z "''${ZIG_LOCAL_CACHE_DIR:-}" ]; then
      if [ -n "''${XDG_CACHE_HOME:-}" ]; then
        lmdb_cache_root="$XDG_CACHE_HOME"
      elif [ -n "''${TMPDIR:-}" ]; then
        lmdb_cache_root="$TMPDIR"
      else
        lmdb_cache_root=
      fi

      if [ -n "$lmdb_cache_root" ]; then
        : "''${ZIG_GLOBAL_CACHE_DIR:=$lmdb_cache_root/zig-global-cache}"
        : "''${ZIG_LOCAL_CACHE_DIR:=$lmdb_cache_root/zig-local-cache}"
        export ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR
        mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
      else
        echo "lmdb devenv: XDG_CACHE_HOME and TMPDIR are both unset, so no Zig" >&2
        echo "cache location is chosen here. Export ZIG_GLOBAL_CACHE_DIR and" >&2
        echo "ZIG_LOCAL_CACHE_DIR at an approved mount." >&2
      fi
      unset lmdb_cache_root
    fi

    # Use devenv's plural `tasks run` and `tasks list` commands.
    cat <<'EOF'
    lmdb 1.0.1 — development shell
      tools    zig 0.17.0, pkg-config, bash
      gates    devenv tasks run
                 lmdb:build | lmdb:test | lmdb:test-release-safe | lmdb:smoke
                 | lmdb:check | lmdb:interop | lmdb:consumer | lmdb:integrity
               # consumer names its own scratch under your $TMPDIR, or under
               # $LMDB_TEST_SCRATCH if you exported one
               #
               # every task runs in this SDK's own directory, whichever one you
               # are standing in; the two build tasks install under your
               # $ZIG_LOCAL_CACHE_DIR, never into this checkout
      refusal  devenv tasks run lmdb:check-refused-target   must fail, with the reason
      variants devenv tasks run lmdb:build-dynamic
      nix      devenv build outputs.static | outputs.shared
    EOF
  '';
}