#pragma once
#include <errno.h>
#include <stdio.h>
#ifdef __linux__
#include <linux/fs.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <fcntl.h>
#endif

// Foundation's replaceItem is not an atomic exchange on all platforms.
static inline int vellum_rename(const char *source, const char *destination, int exchange) {
#ifdef __APPLE__
    int result = renamex_np(source, destination, exchange ? RENAME_SWAP : RENAME_EXCL);
#else
    int result = syscall(SYS_renameat2, AT_FDCWD, source, AT_FDCWD, destination,
                         exchange ? RENAME_EXCHANGE : RENAME_NOREPLACE);
#endif
    return result == 0 ? 0 : errno;
}
