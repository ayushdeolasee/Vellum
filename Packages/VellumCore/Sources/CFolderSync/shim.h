#pragma once
#include <errno.h>
#include <stdio.h>
#ifdef __linux__
#include <linux/fs.h>
#include <linux/openat2.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <fcntl.h>

static inline int vellum_open_beneath(int parent, const char *name, int flags) {
    struct open_how how = { .flags = (unsigned int)flags | O_CLOEXEC,
        .resolve = RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_XDEV };
    return syscall(SYS_openat2, parent, name, &how, sizeof(how));
}
static inline int vellum_rename_at(int src, const char *source, int dst, const char *destination, int exchange) {
    int result = syscall(SYS_renameat2, src, source, dst, destination,
                         exchange ? RENAME_EXCHANGE : RENAME_NOREPLACE);
    return result == 0 ? 0 : errno;
}
#endif

// Foundation's replaceItem is not an atomic exchange on all platforms.
static inline int vellum_rename(const char *source, const char *destination, int exchange) {
#ifdef __APPLE__
    int result = renamex_np(source, destination, exchange ? RENAME_SWAP : RENAME_EXCL);
    return result == 0 ? 0 : errno;
#else
    return vellum_rename_at(AT_FDCWD, source, AT_FDCWD, destination, exchange);
#endif
}
