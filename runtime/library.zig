// SPDX-License-Identifier: OLDAP-2.8
//
//! LMDB loader descriptor for synchronization, symbol routing, and validation.
//! Providers must export translated `mdb_*` symbols and match the selected header's calling convention, widths, layouts, and configuration macros.
//! The provider owns handle allocations; callbacks and context stay caller-owned. `validate` checks `mdb_version`, not ABI compatibility.

const rt = @import("rt");

/// Namespaced sync bindings from `runtime/sync.c`; the prefix must match `graph.zig`.
/// Separate bindings keep SDK instances from sharing loader state.
pub const Sync = struct {
    extern fn lmdb_rt_lock() void;
    extern fn lmdb_rt_unlock() void;
    extern fn lmdb_rt_wait() void;
    extern fn lmdb_rt_broadcast() void;
    // C `unsigned long long` matches `u64` on supported targets.
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

/// Adapt the loader core to this SDK's generated dispatch.
pub fn Config(comptime dispatch: type) type {
    return struct {
        /// Name used in pre-load panic messages.
        pub const library_name = "lmdb";

        /// Table and symbol lists emitted by the selected translation.
        pub const table = dispatch.Table;
        pub const symbols = dispatch.symbols;
        pub const optional_symbols = dispatch.optional_symbols;

        /// Namespaced synchronization binding.
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

        /// Assign one resolved optional symbol to its nullable table field.
        pub inline fn assignOptional(comptime index: usize, dst: *table, address: *const anyopaque) void {
            dispatch.assignOptional(index, dst, address);
        }

        pub inline fn assignMissing(comptime index: usize, dst: *table) void {
            dispatch.assignMissing(index, dst);
        }

        /// Verify `mdb_version` writes all three version fields before publication.
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
