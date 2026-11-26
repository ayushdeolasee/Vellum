#define _GNU_SOURCE
#include "library_io.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/openat2.h>
#include <sys/syscall.h>
#include <unistd.h>

// The kernel checks every component during one fd-relative lookup, including
// concurrent renames. Descendants cannot cross a mount inside the library.
static int open_path(int parent, const char *path, int flags, unsigned long long resolve) {
    struct open_how how = {
        .flags = flags | O_CLOEXEC | O_NOFOLLOW,
        .resolve = resolve | RESOLVE_NO_SYMLINKS,
    };
    return syscall(SYS_openat2, parent, path, &how, sizeof(how));
}

int library_open_root(const char *absolute_path) {
    return open_path(AT_FDCWD, absolute_path, O_RDONLY | O_DIRECTORY, 0);
}

static int open_child(int parent, const char *path, int flags) {
    return open_path(parent, path, flags, RESOLVE_BENEATH | RESOLVE_NO_XDEV);
}

static int close_with_error(int fd, int error) {
    close(fd);
    errno = error;
    return -1;
}

int library_open_file(int root, const char *relative_path, struct stat *info) {
    int fd = open_child(root, relative_path, O_RDONLY | O_NONBLOCK | O_NOCTTY);
    if (fd < 0) return -1;
    if (fstat(fd, info) < 0) return close_with_error(fd, errno);
    if (!S_ISREG(info->st_mode)) return close_with_error(fd, EINVAL);
    return fd;
}

DIR *library_open_directory(int root, const char *relative_path) {
    // A new open description gives every enumeration its own readdir cursor.
    int fd = open_child(root, relative_path, O_RDONLY | O_DIRECTORY);
    if (fd < 0) return NULL;
    DIR *directory = fdopendir(fd);
    if (!directory) close_with_error(fd, errno);
    return directory;
}

const char *library_next_regular(DIR *directory, struct stat *info) {
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(directory);
        if (!entry) return NULL;
        if (entry->d_name[0] == '.') continue;
        int fd = open_child(dirfd(directory), entry->d_name, O_PATH);
        if (fd < 0) {
            if (errno == ENOENT || errno == EXDEV || errno == ELOOP) continue;
            return NULL;
        }
        if (fstat(fd, info) < 0) {
            close_with_error(fd, errno);
            return NULL;
        }
        close(fd);
        if (S_ISREG(info->st_mode)) return entry->d_name;
    }
}
