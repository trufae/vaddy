#ifndef VADDY_FILES_H
#define VADDY_FILES_H
#include <stdint.h>
#include <sys/stat.h>
#ifdef _WIN32
#include <windows.h>
#include <io.h>
#endif

struct vaddy_file_info { int64_t size, modified; };
// Inspect the opened file, not its name: metadata and bytes must describe the
// same inode if the publisher atomically replaces a file during a request.
static int vaddy_file_info(int fd, struct vaddy_file_info *out) {
#ifdef _WIN32
    BY_HANDLE_FILE_INFORMATION info;
    HANDLE handle = (HANDLE)_get_osfhandle(fd);
    if (GetFileType(handle) != FILE_TYPE_DISK || !GetFileInformationByHandle(handle, &info) ||
        (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) return -1;
    out->size = ((int64_t)info.nFileSizeHigh << 32) | info.nFileSizeLow;
    uint64_t ticks = ((uint64_t)info.ftLastWriteTime.dwHighDateTime << 32) | info.ftLastWriteTime.dwLowDateTime;
    out->modified = (int64_t)(ticks - 116444736000000000ULL) * 100;
#else
    struct stat info;
    if (fstat(fd, &info) || !S_ISREG(info.st_mode)) return -1;
    out->size = info.st_size;
#ifdef __APPLE__
    out->modified = (int64_t)info.st_mtimespec.tv_sec * 1000000000 + info.st_mtimespec.tv_nsec;
#else
    out->modified = (int64_t)info.st_mtim.tv_sec * 1000000000 + info.st_mtim.tv_nsec;
#endif
#endif
    return out->size >= 0 ? 0 : -1;
}
#endif
