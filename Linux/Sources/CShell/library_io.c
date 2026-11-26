#define _GNU_SOURCE
#include "library_io.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/openat2.h>
#include <sys/syscall.h>
#include <unistd.h>

int library_open_root(const char *absolute_path) {
    // Ancestors may be aliases (e.g. /home -> /var/home). Pin the selected
    // directory itself without following a final symlink.
    return open(absolute_path, O_DIRECTORY | O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
}

static int open_child(int parent, const char *path, int flags) {
    struct open_how how = {
        .flags = flags | O_CLOEXEC | O_NOFOLLOW,
        .resolve = RESOLVE_BENEATH | RESOLVE_NO_XDEV | RESOLVE_NO_SYMLINKS,
    };
    return syscall(SYS_openat2, parent, path, &how, sizeof(how));
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

const char *library_next_name(DIR *directory) {
    errno = 0;
    struct dirent *entry = readdir(directory);
    return entry ? entry->d_name : NULL;
}

int library_entry_info(DIR *directory, const char *name, struct stat *info) {
    int fd = open_child(dirfd(directory), name, O_PATH);
    if (fd < 0) {
        if (errno == ENOENT || errno == EXDEV || errno == ELOOP) return 0;
        return -1;
    }
    if (fstat(fd, info) < 0) return close_with_error(fd, errno);
    close(fd);
    return S_ISREG(info->st_mode) || S_ISDIR(info->st_mode);
}
