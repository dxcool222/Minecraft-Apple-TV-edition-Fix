#pragma once

#import <dirent.h>
#import <stdio.h>
#import <sys/stat.h>
#import <sys/mount.h>
#import <sys/types.h>

// Original POSIX function pointers captured by fishhook rebinding. Set in
// MinecraftStorageFix.m's POSIX install path; read by any module that needs
// to do unhooked I/O (avoid recursion when called from inside a hook body).

extern int   (*mcfix_orig_open)(const char *path, int oflag, ...);
extern int   (*mcfix_orig_openat)(int fd, const char *path, int oflag, ...);
extern int   (*mcfix_orig_access)(const char *path, int amode);
extern int   (*mcfix_orig_stat)(const char *path, struct stat *sb);
extern int   (*mcfix_orig_lstat)(const char *path, struct stat *sb);
extern int   (*mcfix_orig_mkdir)(const char *path, mode_t mode);
extern int   (*mcfix_orig_unlink)(const char *path);
extern int   (*mcfix_orig_rmdir)(const char *path);
extern int   (*mcfix_orig_rename)(const char *oldpath, const char *newpath);
extern int   (*mcfix_orig_chmod)(const char *path, mode_t mode);
extern int   (*mcfix_orig_chown)(const char *path, uid_t owner, gid_t group);
extern int   (*mcfix_orig_remove)(const char *path);
extern int   (*mcfix_orig_statfs)(const char *path, struct statfs *buf);
extern int   (*mcfix_orig_symlink)(const char *name1, const char *name2);
extern int   (*mcfix_orig_readlink)(const char *path, char *buf, size_t bufsiz);
extern int   (*mcfix_orig_stat_inode64)(const char *path, struct stat *sb);
extern int   (*mcfix_orig_lstat_inode64)(const char *path, struct stat *sb);
extern FILE *(*mcfix_orig_fopen)(const char *path, const char *mode);
extern FILE *(*mcfix_orig_fopen_darwin_extsn)(const char *path, const char *mode);
extern int   (*mcfix_orig_fclose)(FILE *stream);
extern DIR  *(*mcfix_orig_opendir)(const char *path);
extern DIR  *(*mcfix_orig_opendir_inode64)(const char *path);
// Convenience: recursive mkdir using the captured open/access/mkdir.
int mcfix_orig_mkdir_p(const char *path, mode_t mode);

// Exit-wipe window — true while a forced quit is propagating and unlink
// guards should be suppressed.
int MCFIXIsExitWipeActive(void);
