# SPDX-License-Identifier: OLDAP-2.8
#
# Tools only. Entering the shell builds nothing, and the SDK itself is not in
# `packages`. The package is reachable through the lazy `outputs` below and is
# built on request with `devenv build outputs.static` / `outputs.shared`.
{ pkgs, ... }:

let
  mk = linkage: pkgs.callPackage ./package.nix { zig = pkgs.zig_0_16; inherit linkage; };

  # This SDK's own directory, already shell-quoted. `./.` is resolved against
  # the file that writes it, so it names this repository whatever directory the
  # caller was standing in; `builtins.toString` renders the path the evaluation
  # already holds, because the plain `${./.}` form copies the whole SDK into the
  # read-only store first, and every task would then build and check that copy
  # instead of the working tree `UPSTREAM.sha256` describes.
  sdkRootArg = pkgs.lib.escapeShellArg (builtins.toString ./.);

  # First line of every task body, without exception. `|| exit 1`, because a `cd`
  # that failed and was not checked would leave the task running in the very
  # directory this is here to escape: the caller created one file and the
  # scripts then reported their own absence. The paths are resolved relative to
  # the working directory, and nothing here is resolved from `$DEVENV_ROOT`.
  inSdk = ''cd ${sdkRootArg} || exit 1'';

  # The two Zig caches, as a default and never as a choice. A value the caller
  # exported wins and is never overwritten or unset; otherwise the root is
  # `$XDG_CACHE_HOME`, because that is where the Base Directory Specification
  # puts a cache, and `$TMPDIR` after it, because that is the host's own scratch
  # policy. `/tmp` is not a fallback for anything, and neither is this checkout,
  # which is on a shared volume and is the tree whose file set the driver
  # digests before and after a run. A caller that named none of the two is told
  # which are missing and gets no location: this file does not get to invent
  # one.
  #
  # These are the same two names, in the same order and under the same two
  # directory names, that `enterShell` below applies, so a task and the shell
  # agree on where a cache lives. The hook is not relied on: a task reaches this
  # text whether it was entered through the shell or run directly.
  #
  # Written flush left because it is interpolated into a task body verbatim,
  # and its own indentation is then the indentation the generated script
  # carries.
  #
  # The last three lines of that body name the build cache every `zig build` in
  # this file passes as `--cache-dir`, and they run on **every** task rather than
  # only when a cache variable was missing. Without that flag Zig resolves
  # `.zig-cache` from the working directory, and the working directory is this
  # checkout: a shared volume, and the tree whose file set the driver digests
  # before and after a run. So the cache is stated, not left to a default, and
  # it sits under the local cache the caller named or the one filled just above.
  # One directory for the whole SDK: the nested consumer build is a second build
  # root, and it inherits `ZIG_LOCAL_CACHE_DIR` from this environment instead of
  # resolving a cache of its own.
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

  # The install prefix for one delivery variant, for the two tasks that install
  # at all. A bare `zig build` runs this package's install step -- `build.zig`
  # installs the archive, the translated header, the generated `lmdb.pc`, the
  # five tools, the five man pages and the two upstream records
  # (the `b.installArtifact`, `installHeader`, `addInstallFile` and
  # `b.installFile` calls in `build.zig`) -- and its own default prefix is
  # `zig-out` inside the source tree. So these two tasks name a prefix under the
  # caller's local cache instead, one directory per linkage, because a static
  # install and a shared install must not land on one another. `zigCache` has
  # already run and exported the directory this reads.
  #
  # Every other task installs nothing and carries no prefix: `test`,
  # `test-release-safe`, `smoke`, `check`, `check-refused-target`, `interop`
  # and `consumer` are steps, not delivery.
  installPrefix = task: variant: ''
lmdb_prefix="$ZIG_LOCAL_CACHE_DIR/lmdb/${variant}"
mkdir -p "$lmdb_prefix"
echo "${task}: install prefix $lmdb_prefix" >&2
'';

  # The flags every `zig build` below carries, in one string so no body can
  # spell them differently: an explicit external `--cache-dir` (see
  # `zigCache`), `-j8`, and `--summary all`. Placement is after the step and
  # the options a task owns, which is where a caller-supplied flag of its own
  # would still be able to follow and override. No body forwards `"$@"`: no
  # task here did before this file gained these flags, and `devenv tasks run`
  # takes task names only, so there is nothing for a forwarded argument to
  # override here.
  zigFlags = ''--cache-dir "$lmdb_build_cache" -j8 --summary all'';
in
{
  packages = [
    pkgs.zig_0_16
    pkgs.pkg-config
    pkgs.bash
  ];

  outputs = {
    static = mk "static";
    # package.nix's `linkage` takes Zig's own spelling; "shared" is the
    # attribute name, not a value it accepts.
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
      # The consumer program refuses to invent a database location: it takes
      # `--scratch <dir>` or `LMDB_TEST_SCRATCH` and consults neither `TMPDIR`,
      # nor `/tmp`, nor the source tree, so a bare `zig build consumer` exits
      # non-zero naming what is missing (consumer/src/main.zig:236-261).
      # `zig build` forwards the value only when it was given (the conditional
      # `run.addArg` calls in `runConsumer`), so the task has to be the one that
      # names it.
      #
      # A value the caller exported always wins. Otherwise the location is a
      # fresh `mktemp -d` **inside the TMPDIR the caller exported**: never
      # `/tmp`, never the checkout, never an invented default. Scratch
      # placement is the host's policy and this file does not get to have one.
      #
      # Nothing is cleaned up here. The program creates one randomly named
      # child inside the directory and deletes only that child
      # (consumer/src/main.zig:167-205); the `mktemp` directory is left in
      # place and its path printed, rather than swept by a trap that could
      # reach anything this task does not own.
      #
      # No provider is named and none is invented. This is the linked build,
      # which reads no provider. A runtime-loaded consumer needs
      # `LMDB_TEST_PROVIDER` or `-Dprovider=<absolute path>` from the caller,
      # and one it cannot load fails the run; there is no fallback to a linked
      # copy. `lmdb:build-dynamic` is the shared *linked* build and is a
      # different question.
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

  # Defaults for the two Zig caches when the caller has not supplied them; an
  # exported value always wins and is never overwritten or unset here.
  #
  # The location is read out of the environment when the shell is entered rather
  # than interpolated, and the `devenv` module argument is gone from the header
  # for the reason: devenv passes every module the flake *inputs* as arguments,
  # so `devenv` here was the pinned `?dir=src/modules` input that `devenv.lock`
  # names, not an option namespace. `devenv.stateDir` is not an attribute of it,
  # and evaluating it failed with `error: attribute 'stateDir' missing`. The
  # state directory is the option `devenv.state`, which devenv exports to the
  # shell as `$DEVENV_STATE`; it is `<devenv root>/.devenv/state`, which is this
  # checkout for a shell entered here, so it is not where a Zig cache belongs.
  #
  # `$XDG_CACHE_HOME` is where a cache belongs by the Base Directory
  # Specification, `$TMPDIR` is the host's scratch policy, and a caller that set
  # neither is told so rather than given a location this file does not get to
  # invent.
  #
  # The same rule, in the same order, is applied again by `zigCache` above,
  # because a task body has to stand on its own: it is reached through
  # `devenv tasks run`, from a working directory this hook never saw. This
  # hook stays a default and never a requirement, and the two cannot drift
  # because they name the same two variables and the same two roots.
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

    # `tasks run` / `tasks list`, singular forms do not exist: the pinned devenv
    # declares `Commands::Tasks { command: TasksCommand }` with `Run` and `List`
    # beneath it (devenv `src/cli.rs`), and the acceptance driver invoked
    # `devenv tasks run lmdb:consumer` and `devenv tasks list --json`.
    cat <<'EOF'
    lmdb 1.0.1 — development shell
      tools    zig 0.16.0, pkg-config, bash
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