// SPDX-License-Identifier: OLDAP-2.8
//
//! Builds the runtime-loaded LMDB module from the selected translation.
//! Do not link the C archive into this route; provider ABI requirements are in `library.zig`.

const std = @import("std");

/// Symbol prefix used by both `runtime/sync.c` and the LMDB binding.
/// Change both prefixes to embed a second independent instance.
const sync_prefix = "lmdb_rt";

/// C-library externs that must remain direct instead of resolving from liblmdb.
const libc_noise =
    \\memcpy,memmove,memset,memcmp,memchr,memrchr,
    \\strlen,strcmp,strncmp,strcpy,strncpy,strcasecmp,strncasecmp,strchr,strrchr,
    \\strstr,strdup,strndup,strerror,strtok,strspn,strcspn,strpbrk,strcoll,strxfrm,
    \\malloc,calloc,realloc,reallocarray,free,aligned_alloc,posix_memalign,
    \\abort,exit,_exit,_Exit,atexit,atexit_quick,
    \\snprintf,vsnprintf,sprintf,vsprintf,printf,vprintf,fprintf,vfprintf,
    \\fputs,fputc,putchar,puts,putc,putchar_unlocked,fflush,fclose,fopen,fread,
    \\fwrite,freopen,perror,fseek,ftell,fseeko,ftello,
    \\open,openat,close,read,write,pread,pwrite,preadv,pwritev,lseek,llseek,
    \\ftruncate,fsync,fdatasync,msync,fstat,stat,lstat,fstatat,unlink,rename,
    \\access,chmod,fchmod,mkdir,rmdir,truncate,
    \\mmap,munmap,mprotect,getpagesize,
    \\getenv,setenv,unsetenv,clearenv,putenv,system,
    \\time,clock,gettimeofday,difftime,localtime,gmtime,mktime,strftime,
    \\isprint,isalnum,isalpha,isdigit,isspace,isxdigit,toupper,tolower,
    \\qsort,bsearch,atoi,atol,strtol,strtoul,strtoll,strtoull,strtod,strtof,
    \\abs,labs,div,
    \\signal,raise,sigaction,
    \\dlopen,dlsym,dlclose,dlerror,dlvsym,
    \\pthread_mutex_init,pthread_mutex_lock,pthread_mutex_unlock,pthread_mutex_destroy,
    \\pthread_cond_init,pthread_cond_wait,pthread_cond_signal,pthread_cond_destroy,
    \\pthread_create,pthread_join,pthread_self,pthread_exit,pthread_key_create,
    \\sem_init,sem_wait,sem_post,sem_destroy,sem_open,sem_close,
    \\VirtualAlloc,VirtualFree,CreateFileW,WriteFile,ReadFile,CloseHandle,
    \\CreateMutexW,OpenMutexA,WaitForSingleObject,ReleaseMutex,
    \\LockFileEx,UnlockFileEx,CreateEventW,SetEvent,GetFileSizeEx,
    \\imaxabs,imaxdiv,strtoimax,strtoumax,wcstoimax,wcstoumax,select,pselect,
    \\__darwin_check_fd_set_overflow,__mingw_get_crt_info,__prefetch,
;

/// Optional provider exports; empty for this header configuration.
const provider_optional = "";

/// Provider exports not required by this build; empty for this header configuration.
const provider_excluded = "";

/// Loader core for linked builds; runtime builds use the dispatch's instance.
pub fn createCoreModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("runtime/loader.zig"),
        .target = target,
        .optimize = optimize,
        // Unix dynamic loading requires libc.
        .link_libc = true,
    });
}

/// Create the runtime-loaded `c` module from this target's translation.
pub fn createModule(
    b: *std.Build,
    translate: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const core = createCoreModule(b, target, optimize);

    const library = b.createModule(.{
        .root_source_file = b.path("runtime/library.zig"),
        .target = target,
        .optimize = optimize,
    });
    library.addImport("rt", core);

    return createDispatchModule(b, translate, target, optimize, core, library);
}

/// Generated dispatch and patched translation paths.
const GeneratedSources = struct {
    native: std.Build.LazyPath,
    dispatch: std.Build.LazyPath,
};

fn createDispatchModule(
    b: *std.Build,
    translate: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core: *std.Build.Module,
    library: *std.Build.Module,
) *std.Build.Module {
    const sources = generateDispatch(b, translate, target);

    const dispatch = b.createModule(.{
        .root_source_file = sources.dispatch,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    dispatch.addImport("rt", core);
    dispatch.addImport("library", library);

    // Re-export translated types so the facade and dispatch use identical declarations.
    const native = b.createModule(.{
        .root_source_file = sources.native,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    native.addImport("c_routed", dispatch);
    dispatch.addImport("c_native", native);
    dispatch.addCSourceFiles(.{
        .files = &.{"runtime/sync.c"},
        .flags = &.{b.fmt("-DRT_SYNC_PREFIX={s}", .{sync_prefix})},
        .language = .c,
    });
    return dispatch;
}

/// Generate the dispatch from the translation selected for this target.
fn generateDispatch(
    b: *std.Build,
    translate: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
) GeneratedSources {
    const generator = b.addExecutable(.{
        .name = b.fmt("lmdb-runtime-generate-{s}", .{
            target.result.zigTriple(b.allocator) catch @panic("unspellable target"),
        }),
        .root_module = b.createModule(.{
            .root_source_file = b.path("runtime/generate.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const run = b.addRunArtifact(generator);
    run.addArg("--library");
    run.addArg("lmdb");
    run.addArg("--translate");
    run.addFileArg(translate.getOutput());
    if (libc_noise.len != 0) {
        run.addArg("--noise");
        run.addArg(libc_noise);
    }
    if (provider_optional.len != 0) {
        run.addArg("--optional");
        run.addArg(provider_optional);
    }
    if (provider_excluded.len != 0) {
        run.addArg("--exclude");
        run.addArg(provider_excluded);
    }
    run.addArg("--native-output");
    const native_source = run.addOutputFileArg("native.zig");
    run.addArg("--output");
    const dispatch_source = run.addOutputFileArg("dispatch.zig");
    return .{ .native = native_source, .dispatch = dispatch_source };
}
