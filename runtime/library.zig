// SPDX-License-Identifier: OLDAP-2.8
//
//! LMDB's side of the runtime loader: the names its synchronization binding
//! has, the external ABI family a provider has to belong to, and the one
//! check that runs after every symbol resolved.
//!
//! Everything else about the runtime route is generic. `runtime/loader.zig` is
//! the state machine and the platform layer; `runtime/generate.zig` builds the
//! dispatch from whatever the translation step actually produced;
//! `runtime/graph.zig` wires them together. This file is what makes them
//! LMDB's, and it is the file another SDK replaces.
//!
//! ## What a provider must be
//!
//! A liblmdb shared object whose dynamic symbol table carries every function
//! `libraries/liblmdb/lmdb.h` declares for this build's configuration. For the
//! bundled header at the default settings that is sixty-nine entry points,
//! `mdb_version` through `mdb_modsetup`:
//!
//!   version and errors   mdb_version, mdb_strerror
//!   environment          mdb_env_create, mdb_env_open, mdb_env_close,
//!                        mdb_env_stat, mdb_env_info, mdb_env_sync,
//!                        mdb_env_set_flags, mdb_env_get_flags,
//!                        mdb_env_get_path, mdb_env_get_fd,
//!                        mdb_env_set_mapsize, mdb_env_set_pagesize,
//!                        mdb_env_set_maxreaders, mdb_env_get_maxreaders,
//!                        mdb_env_set_maxdbs, mdb_env_get_maxkeysize,
//!                        mdb_env_set_userctx, mdb_env_get_userctx,
//!                        mdb_env_set_assert,
//!                        mdb_env_set_encrypt, mdb_env_set_checksum
//!   copy and backup      mdb_env_copy, mdb_env_copyfd, mdb_env_copy2,
//!                        mdb_env_copyfd2, mdb_env_incr_dumpfd,
//!                        mdb_env_incr_dump, mdb_env_incr_loadfd
//!   transactions         mdb_txn_begin, mdb_txn_env, mdb_txn_id, mdb_txn_flags,
//!                        mdb_txn_commit, mdb_txn_prepare, mdb_txn_abort,
//!                        mdb_txn_reset, mdb_txn_renew, mdb_env_rollback
//!   databases            mdb_dbi_open, mdb_dbi_close, mdb_dbi_flags, mdb_stat,
//!                        mdb_drop, mdb_cmp, mdb_dcmp,
//!                        mdb_set_compare, mdb_set_dupsort, mdb_set_relfunc,
//!                        mdb_set_relctx
//!   data                 mdb_get, mdb_put, mdb_del
//!   cursors              mdb_cursor_open, mdb_cursor_close, mdb_cursor_renew,
//!                        mdb_cursor_txn, mdb_cursor_dbi, mdb_cursor_is_db,
//!                        mdb_cursor_get, mdb_cursor_put, mdb_cursor_del,
//!                        mdb_cursor_count
//!   readers              mdb_reader_list, mdb_reader_check
//!   crypto modules       mdb_modload, mdb_modunload, mdb_modsetup
//!
//! `mdb_env_set_encrypt` and `mdb_env_set_checksum` are listed because they are
//! in this build's translation, not because every liblmdb has them: they sit
//! inside `#if MDB_RPAGE_CACHE` (lmdb.h:317, :1096, :1118) and that macro is 1
//! here (lmdb.h:192-195). An older installed header, which is what `-fsys=lmdb`
//! would translate, declares neither, and then neither is routed and this list
//! is wrong by exactly those two — in which case the generated `symbols` array,
//! not this paragraph, is the record. `MDB_open` and `MDB_close` (the lower-case
//! pair) are preprocessor aliases, not declarations, and are not symbols in any
//! build.
//!
//! ## The external ABI family, stated as facts rather than as a version number
//!
//! The boundary is one C shared object reached through the platform loader
//! (`dlopen`/`LoadLibrary` on the backends `runtime/loader.zig` implements), plus
//! the C library both sides already share. What has to match is:
//!
//!   * **The C calling convention and scalar widths.** Every status is an `int`;
//!     `MDB_dbi` is `unsigned int`; `mdb_size_t` is `size_t` here, because
//!     `MDB_VL32` is not defined (lmdb.h:197-203); `mdb_mode_t` is `mode_t` on
//!     the targets this build compiles and `int` under MSVC (lmdb.h:180-184);
//!     `mdb_filehandle_t` is `int` on POSIX and `void *` on Windows
//!     (lmdb.h:221-225). A provider built for a different word size or a
//!     different calling convention is a different ABI family and this header
//!     does not describe it.
//!   * **The two complete struct layouts that cross the boundary.**
//!     `MDB_val` is `{ size_t; void * }` (lmdb.h:293-296) and is the shape of
//!     every key and every datum in every call. `MDB_stat` (lmdb.h:548-556),
//!     `MDB_envinfo` (lmdb.h:559-566) and `MDB_crypto_funcs` (lmdb.h:1873-1880)
//!     are filled in or read by the caller, so their field order is part of the
//!     contract too. `MDB_env`, `MDB_txn` and `MDB_cursor` are opaque
//!     declarations (lmdb.h:267, :274, :280): only the pointers cross, so their
//!     internal layout is not part of this ABI and a provider may allocate them
//!     however it likes.
//!   * **The enum width of `MDB_cursor_op`** (lmdb.h:436-465). A C enum's
//!     underlying type is the target ABI's choice, so it is `c_uint` where the
//!     target gives every enum its full width and narrower where it does not.
//!     `mdb_cursor_get` takes that type by value in the same position in both
//!     builds; a provider compiled for a target whose C ABI narrows enums does
//!     not match one that widens them.
//!   * **The configuration macros that fix behaviour**, all read out of
//!     `build.zig`'s per-target table rather than assumed: `MDB_USE_POSIX_MUTEX`
//!     and `MDB_USE_ROBUST` on Linux, `MDB_USE_POSIX_SEM` on macOS, nothing on
//!     Windows, nothing forced on the BSDs, and nothing at all for `MDB_VL32`,
//!     `MDB_RPAGE_CACHE` or `MDB_ENCRYPT`. Those macros choose between lock
//!     implementations and between whole sets of exported entry points; they do
//!     not change a prototype, but they do change which symbols exist.
//!   * **The allocator.** Every allocation behind an `MDB_env`, an `MDB_txn`
//!     and an `MDB_cursor` belongs to the provider — `mdb_env_create` uses the
//!     C allocator (mdb.c:5028) and `mdb_env_close` releases with it. Zig's
//!     allocator is never handed to the provider and never asked to free
//!     something the provider allocated. The boundary that does carry caller
//!     memory is the callback direction: a comparator, checksum, encryption,
//!     relocation, assert or message callback is the caller's own function, and
//!     the `void *` context it carries is whatever the caller put there.
//!
//! ## What is checked at load time, and what that check is not
//!
//! `validate` asks `mdb_version` to fill three integers. That is the only
//! entry point in the header that needs no environment, no transaction, no map
//! and no allocation, so it is the only one that can be called before a caller
//! has done anything. The check confirms that the symbol is really liblmdb's and
//! that it writes through the three out-pointers.
//!
//! It is **not** an ABI compatibility verdict, and nothing here pretends
//! otherwise: symbol resolution is not ABI proof, and a version triple is not a
//! layout match. The layout and configuration facts above are what a provider
//! has to satisfy; this file states them so the choice is checkable by reading,
//! and the load-time check stays as small as it can be while still refusing a
//! file that is plainly not this library.

const rt = @import("rt");

/// The synchronization this loader calls, bound by exact name.
///
/// The names below are `runtime/sync.h` compiled with
/// `RT_SYNC_PREFIX=lmdb_rt`, which is what `runtime/graph.zig` passes. Two
/// spellings of that prefix have to agree: this file names the symbols, and
/// graph.zig defines the macro. A build where they disagree does not link, and
/// that is the whole error report: there is no runtime path that could hide it.
///
/// The core in `runtime/loader.zig` never names a symbol of its own, which is
/// what lets two SDKs, or two configurations of one SDK, hold their own loader
/// state in one process without sharing any of it.
pub const Sync = struct {
    extern fn lmdb_rt_lock() void;
    extern fn lmdb_rt_unlock() void;
    extern fn lmdb_rt_wait() void;
    extern fn lmdb_rt_broadcast() void;
    // `unsigned long long`. Declared as u64, which is the same type in every
    // ABI this SDK targets: 64-bit on x86_64, aarch64, riscv64 and wasm32.
    extern fn lmdb_rt_thread_self() u64;

    pub fn lock() void {
        lmdb_rt_lock();
    }
    pub fn unlock() void {
        lmdb_rt_unlock();
    }
    pub fn wait() void {
        lmdb_rt_wait();
    }
    pub fn broadcast() void {
        lmdb_rt_broadcast();
    }
    pub fn threadSelf() u64 {
        return lmdb_rt_thread_self();
    }
};

/// The loader's configuration for this SDK, given the dispatch that owns the
/// table.
///
/// `dispatch` is the generated module, passed as a type by the dispatch itself
/// so that this file never has to import it. The direction is one-way on
/// purpose: the descriptor knows what the loader needs, the dispatch knows what
/// the header said, and neither imports the other.
pub fn Config(comptime dispatch: type) type {
    return struct {
        /// Named in the pre-load panic, so the message says which library was
        /// reached for before it was loaded.
        pub const library_name = "lmdb";

        /// The table the generated dispatch declares, and the symbols it needs
        /// to fill it. Both come from the translated header, not from this file.
        pub const table = dispatch.Table;
        pub const symbols = dispatch.symbols;
        pub const optional_symbols = dispatch.optional_symbols;

        /// The project's namespaced synchronization binding.
        pub const sync = Sync;

        pub fn tablePtr() *table {
            return dispatch.tablePtr();
        }

        pub fn ready() *rt.Ready {
            return &dispatch.ready;
        }

        pub fn assign(comptime index: usize, dst: *table, address: *const anyopaque) void {
            dispatch.assign(index, dst, address);
        }

        /// One resolved address into one optional table field, and the empty
        /// case beside it. Both index `optional_symbols`, not `symbols`.
        pub inline fn assignOptional(comptime index: usize, dst: *table, address: *const anyopaque) void {
            dispatch.assignOptional(index, dst, address);
        }

        pub inline fn assignMissing(comptime index: usize, dst: *table) void {
            dispatch.assignMissing(index, dst);
        }

        /// The one library-specific check, run after every symbol resolved and
        /// before anything is published.
        ///
        /// `mdb_version` fills each of its three out-parameters only when that
        /// parameter is non-NULL (lmdb.h:570-574), so all three are supplied
        /// and all three are read back. They start below zero so that a
        /// provider which resolved the name and returned without writing is
        /// caught rather than accepted with the caller's own initial values.
        pub fn validate(dst: *const table) ?[]const u8 {
            var major: c_int = -1;
            var minor: c_int = -1;
            var patch: c_int = -1;
            _ = dst.mdb_version(&major, &minor, &patch);
            if (major < 0 or minor < 0 or patch < 0) {
                return "mdb_version() did not fill a version triple, so this " ++
                    "provider is not the library this header describes";
            }
            return null;
        }
    };
}