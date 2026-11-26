#pragma once

#include <dirent.h>
#include <sys/stat.h>

// Owned read-only descriptors. Failures return -1 (or NULL) and set errno.
int library_open_root(const char *absolute_path);
int library_open_file(int root, const char *relative_path, struct stat *info);
DIR *library_open_directory(int root, const char *relative_path);

// Borrowed name, valid until the next call on this stream. NULL with errno == 0 is EOF.
const char *library_next_regular(DIR *directory, struct stat *info);
