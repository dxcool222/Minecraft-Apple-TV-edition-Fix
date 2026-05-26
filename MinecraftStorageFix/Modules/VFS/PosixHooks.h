#pragma once

#import <dirent.h>
#import <stdio.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <sys/types.h>

// POSIX fishhook replacements. Each pairs 1:1 with a mcfix_orig_* function
// pointer in MCFIXPosixOrigs.h. Bodies route C path arguments through
// MCFIXPathByRedirectingGameStorage so libc-level I/O lands in the same
// VFS tree as the NSFileManager swizzles.

int   mcfix_posix_stat(const char *path, struct stat *sb);
int   mcfix_posix_stat_inode64(const char *path, struct stat *sb);
int   mcfix_posix_lstat(const char *path, struct stat *sb);
int   mcfix_posix_lstat_inode64(const char *path, struct stat *sb);
int   mcfix_posix_mkdir(const char *path, mode_t mode);
int   mcfix_posix_open(const char *path, int oflag, ...);
int   mcfix_posix_openat(int fd, const char *path, int oflag, ...);
int   mcfix_posix_access(const char *path, int amode);
int   mcfix_posix_unlink(const char *path);
int   mcfix_posix_rmdir(const char *path);
int   mcfix_posix_rename(const char *oldpath, const char *newpath);
int   mcfix_posix_chmod(const char *path, mode_t mode);
int   mcfix_posix_chown(const char *path, uid_t owner, gid_t group);
int   mcfix_posix_remove(const char *path);
int   mcfix_posix_statfs(const char *path, struct statfs *buf);
int   mcfix_posix_symlink(const char *name1, const char *name2);
int   mcfix_posix_readlink(const char *path, char *buf, size_t bufsiz);
FILE *mcfix_posix_fopen(const char *path, const char *mode);
FILE *mcfix_posix_fopen_darwin_extsn(const char *path, const char *mode);
int   mcfix_posix_fclose(FILE *stream);
DIR  *mcfix_posix_opendir(const char *path);
DIR  *mcfix_posix_opendir_inode64(const char *path);