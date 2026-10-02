/*
 * translate.h — the single C translation unit this package has the Zig C
 * translator read.
 *
 * In the default mode `zig cc` preprocesses this file for the target being
 * built and the translator reads the result (build.zig, `preprocessedHeader`),
 * so the declarations it translates are the ones the bundled core is compiled
 * against. In `-fsys=lmdb` mode this file is read as it stands, because
 * `<lmdb.h>` there has to resolve through the target's own system include
 * path.
 *
 * It is this file, not `lmdb.h`, that decides which LMDB header the Zig facade
 * is generated from, and it is the one place in the build where that choice is
 * written down. The bare name at the bottom resolves two ways:
 *
 *   default          `-I libraries/liblmdb`, which build.zig puts on the
 *                    preprocessing line in bundled mode, so <lmdb.h> is the
 *                    1.0.1 header in this repository.
 *
 *   -fsys=lmdb       no in-tree include path at all. <lmdb.h> then resolves
 *                    through the target's own system include path, next to the
 *                    installed liblmdb that build.zig links in `-fsys=lmdb`
 *                    mode. Translating this repository's header against a
 *                    differently-versioned installed library would bind an ABI
 *                    the library does not have, so the system mode deliberately
 *                    never sees the bundled header.
 *
 * Do not copy LMDB declarations here. The two guarded typedefs below only
 * restate Clang's builtin integer types: its preprocessor emits NetBSD
 * __ALIGNBYTES macros that name __int128_t without emitting that implicit
 * declaration. The compiler's capability macro keeps the bridge target-correct.
 */
#ifndef LMDB_TRANSLATE_H
#define LMDB_TRANSLATE_H

/* Keep compiler-provided types visible in the preprocessed translation unit,
 * as in the PCRE2 aggregate. This does not alter LMDB's declarations or ABI. */
#if defined(__SIZEOF_INT128__)
typedef __int128 __int128_t;
typedef unsigned __int128 __uint128_t;
#endif

/* Angle brackets, not quotes: a quoted include also searches the directory of
 * this file, which would let a stray lmdb.h next to the package root win over
 * the one build.zig put on the preprocessing line. */
#include <lmdb.h>

#endif /* LMDB_TRANSLATE_H */