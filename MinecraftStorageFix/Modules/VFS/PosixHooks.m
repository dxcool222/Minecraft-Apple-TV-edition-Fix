// fishhook POSIX path layer.
//
// rebind_symbols() in MinecraftStorageFix.m's +installPOSIXPathRebindings
// patches libc lazy-bind slots in every loaded image. The replacements
// here pass each path string through MCFIXPathByRedirectingGameStorage
// before delegating to the captured mcfix_orig_* via MCFIXPosixOrigs.h.
//
// Apple's 64-bit libc forwards some symbols through suffixed variants
// (stat$INODE64, fopen$DARWIN_EXTSN, opendir$INODE64) — each needs its
// own pair of replacement + orig because fishhook overwrites one slot
// per name.

#import <Foundation/Foundation.h>
#import "PosixHooks.h"
#import "PathRedirect.h"
#import "../Internal/MCFIXState.h"
#import "../Icons/AchievementIcons.h"
#import "../Icons/WorldIcon.h"
#import "../Internal/MCFIXPosixOrigs.h"
#import "../Marketplace/CatalogStub.h"
#import "MCFIXBypass.h"
#import "MCFIXGameDataVFS.h"
#import "MCFIXLog.h"

#import <dirent.h>
#import <errno.h>
#import <fcntl.h>
#import <stdarg.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <time.h>
#import <unistd.h>


static BOOL MCFIXPathNeedsGameStorageFallback(NSString *path) {
    if (path.length == 0) {
        return NO;
    }
    if ([path containsString:@"world_icon"]) {
        return NO;
    }
    return [path containsString:@"skin_packs"] ||
           [path containsString:@"options.txt"] ||
           [path containsString:@"catalog_info"] ||
           [path containsString:@"MarketplaceDurableCatalog"] ||
           [path containsString:@"textures/ui"] ||
           [path containsString:@"resource_pack_download_cache"] ||
           [path containsString:@"resource_packs"] ||
           [path containsString:@"achievement"] ||
           [path containsString:@"premium_cache"] ||
           [path containsString:@"minecraftpe"] ||
           [path containsString:@"clientId"] ||
           [path containsString:@"external_servers"] ||
           [path containsString:@"global_resource_packs"];
}

static FILE *MCFIXFopenTryAlternatePath(const char *primary, const char *original, const char *mode,
                                        FILE *(*orig)(const char *, const char *)) {
    if (primary == NULL || orig == NULL || mode == NULL || mode[0] != 'r') {
        return NULL;
    }
    @autoreleasepool {
        NSString *p = [NSString stringWithUTF8String:primary];
        if ([p rangeOfString:@"world_icon"].location != NSNotFound) {
            return NULL;
        }
        NSString *alt = MCFIXLegacyPathForRedirectedPath(p);
        if (alt.length == 0 && original != NULL) {
            alt = MCFIXPathByRedirectingGameStorage([NSString stringWithUTF8String:original]);
            if ([alt isEqualToString:(original ? [NSString stringWithUTF8String:original] : @"")]) {
                alt = nil;
            }
        }
        if (alt.length == 0) {
            return NULL;
        }
        const char *altc = alt.fileSystemRepresentation;
        if (altc == NULL) {
            return NULL;
        }
        FILE *f = orig(altc, mode);
        if (f) {
            MCFIXLogOnce(MCFIXLogCatFSMiss, [NSString stringWithFormat:@"fopen_fb_%@", p],
                         @"fopen fallback OK %@ (primary miss %@)", alt, p);
        }
        return f;
    }
}

// ---------------------------------------------------------------------------
//  Layer 6b — fishhook: POSIX (C++) path rebinding
//
//  Bedrock often uses C++ fstreams / libc open/mkdir without NSFileManager.
//  rebind_symbols() patches __DATA __la_symbol_ptr / __nl_symbol_ptr in all
//  loaded images.  Same redirect as Layer 6a (MCFIXPathByRedirectingGameStorage).
//
//  Path logic: MCFIXPathByRedirectingGameStorage absolutizes *relative* paths
//  with getcwd(3) before hasPrefix:home, so chdir + open("games/...") works.
//
//  Apple 64-bit libc often uses stat$INODE64, lstat$INODE64, fopen$DARWIN_EXTSN,
//  opendir$INODE64 — each needs its own mcfix_orig_* (fishhook overwrites one
//  slot per name; shared "replaced" pointers would clobber).  readdir/closedir
//  are not rebound (no path argument).
//
//  IDA (MCP list_imports): _open, _mkdir, _access, _fopen, _lstat, _stat,
//  _rename, _unlink, _chmod, _rmdir, _remove, _opendir, _readdir, …;
//  suffixed symbols may not appear in the import list but are still rebound
//  when present in a dylib IAT.
// ---------------------------------------------------------------------------

static const char *MCFIXPOSIXResolvedPathForSyscall(const char *cPath, char fspath[PATH_MAX]) {
    if (cPath == NULL) {
        return NULL;
    }
    // Absolute paths can only match tails containing one of these tokens
    // (see MCFIXTailNeedsGameVFSCacheRedirect). Skip the NSString
    // round-trip for everything else. Relative paths still need the full
    // resolver so getcwd-prepend can match.
    if (cPath[0] == '/') {
        if (!strstr(cPath, "games") &&
            !strstr(cPath, "internal") &&
            !strstr(cPath, "minecraftpe") &&
            !strstr(cPath, "XBLStoage")) {
            return cPath;
        }
    }
    @autoreleasepool {
        NSString *ns = [NSString stringWithUTF8String:cPath];
        if (ns == nil || ns.length == 0) {
            return cPath;
        }
        NSString *res = MCFIXPathByRedirectingGameStorage(ns);
        if (!atomic_load(&gMCFIXBootstrapReady)) {
            if ([res isEqualToString:ns]) {
                return cPath;
            }
            if (![res getFileSystemRepresentation:fspath maxLength:(NSUInteger)PATH_MAX]) {
                return NULL;
            }
            return fspath;
        }
        if ([res isEqualToString:ns]) {
            return cPath;
        }
        if (![res getFileSystemRepresentation:fspath maxLength:(NSUInteger)PATH_MAX]) {
            return NULL;
        }
        return fspath;
    }
}

/// Read-only world_icon: redirect then alias every tail to canonical vfs/tmp/Temp/.../world_icon.jpeg.
static const char *MCFIXPOSIXResolvedPathForReadSyscall(const char *cPath, char fspath[PATH_MAX]) {
    if (cPath == NULL) {
        return NULL;
    }
    @autoreleasepool {
        NSString *ns = [NSString stringWithUTF8String:cPath];
        if (ns == nil || ns.length == 0) {
            return cPath;
        }
        NSString *res = MCFIXPathByRedirectingGameStorage(ns);
        if ([res rangeOfString:@"world_icon"].location != NSNotFound) {
            res = MCFIXWorldIconAliasReadPath(res);
        }
        if (!atomic_load(&gMCFIXBootstrapReady)) {
            if ([res isEqualToString:ns]) {
                return cPath;
            }
            if (![res getFileSystemRepresentation:fspath maxLength:(NSUInteger)PATH_MAX]) {
                return NULL;
            }
            return fspath;
        }
        if ([res isEqualToString:ns]) {
            return cPath;
        }
        if (![res getFileSystemRepresentation:fspath maxLength:(NSUInteger)PATH_MAX]) {
            return NULL;
        }
        return fspath;
    }
}

int (*mcfix_orig_open)(const char *path, int oflag, ...) = NULL;
int (*mcfix_orig_lstat)(const char *path, struct stat *sb) = NULL;
int (*mcfix_orig_unlink)(const char *path) = NULL;
int (*mcfix_orig_rmdir)(const char *path) = NULL;
int (*mcfix_orig_rename)(const char *oldpath, const char *newpath) = NULL;
int (*mcfix_orig_chmod)(const char *path, mode_t mode) = NULL;
int (*mcfix_orig_chown)(const char *path, uid_t owner, gid_t group) = NULL;
int (*mcfix_orig_remove)(const char *path) = NULL;
int (*mcfix_orig_statfs)(const char *path, struct statfs *buf) = NULL;
int (*mcfix_orig_symlink)(const char *name1, const char *name2) = NULL;
int (*mcfix_orig_readlink)(const char *path, char *buf, size_t bufsiz) = NULL;
int (*mcfix_orig_openat)(int fd, const char *path, int oflag, ...) = NULL;
int (*mcfix_orig_stat_inode64)(const char *path, struct stat *sb) = NULL;
int (*mcfix_orig_lstat_inode64)(const char *path, struct stat *sb) = NULL;
FILE *(*mcfix_orig_fopen_darwin_extsn)(const char *path, const char *mode) = NULL;
DIR *(*mcfix_orig_opendir)(const char *path) = NULL;
DIR *(*mcfix_orig_opendir_inode64)(const char *path) = NULL;

/// mkdir -p using only lazily-bound libc symbols (never NSFileManager). Avoids
/// re-entrancy: NSFileManager's createDirectoryAtPath invokes POSIX mkdir, which is
/// fishhooked — calling NSFileManager from inside open/fopen/rename hooks could
/// recurse through our mcfix_posix_mkdir / stack blow or deadlock.
int mcfix_orig_mkdir_p(const char *path, mode_t mode) {
    if (path == NULL || path[0] == '\0') {
        errno = EINVAL;
        return -1;
    }
    if (mcfix_orig_mkdir == NULL || mcfix_orig_access == NULL) {
        errno = ENOSYS;
        return -1;
    }
    char tmp[PATH_MAX];
    strncpy(tmp, path, sizeof(tmp) - 1);
    tmp[sizeof(tmp) - 1] = '\0';
    size_t L = strlen(tmp);
    while (L > 1 && tmp[L - 1] == '/') {
        tmp[--L] = '\0';
    }
    for (char *q = tmp + 1; *q; q++) {
        if (*q != '/') {
            continue;
        }
        *q = '\0';
        if (strlen(tmp) && strcmp(tmp, "/") != 0) {
            if (mcfix_orig_access(tmp, F_OK) != 0) {
                if (mcfix_orig_mkdir(tmp, mode) != 0 && errno != EEXIST) {
                    *q = '/';
                    return -1;
                }
            }
        }
        *q = '/';
    }
    if (strlen(tmp)) {
        if (mcfix_orig_access(tmp, F_OK) != 0) {
            int mk = mcfix_orig_mkdir(tmp, mode);
            if (mk != 0 && errno != EEXIST && errno != EISDIR) {
                return -1;
            }
        }
    }
    return 0;
}

typedef int (*MCFIXPosixPathStatFn)(const char *path, struct stat *sb);

static int mcfix_posix_xstat(const char *path, struct stat *sb, MCFIXPosixPathStatFn orig) {
    if (path == NULL) {
        errno = EINVAL;
        return -1;
    }
    if (sb == NULL) {
        errno = EINVAL;
        return -1;
    }
    if (orig == NULL) {
        errno = ENOSYS;
        return -1;
    }
    if (MCFIXBypassHooksActive()) {
        return orig(path, sb);
    }
    char buf[PATH_MAX];
    const char *p = MCFIXPOSIXResolvedPathForSyscall(path, buf);
    if (p == NULL) {
        errno = EINVAL;
        return -1;
    }
    return orig(p, sb);
}

int mcfix_posix_stat(const char *path, struct stat *sb) {
    return mcfix_posix_xstat(path, sb, mcfix_orig_stat);
}

int mcfix_posix_stat_inode64(const char *path, struct stat *sb) {
    return mcfix_posix_xstat(path, sb, mcfix_orig_stat_inode64);
}

int mcfix_posix_lstat(const char *path, struct stat *sb) {
    return mcfix_posix_xstat(path, sb, mcfix_orig_lstat);
}

int mcfix_posix_lstat_inode64(const char *path, struct stat *sb) {
    return mcfix_posix_xstat(path, sb, mcfix_orig_lstat_inode64);
}

int mcfix_posix_mkdir(const char *path, mode_t mode) {
    if (path == NULL) {
        errno = EINVAL;
        return -1;
    }
    if (mcfix_orig_mkdir == NULL) {
        errno = ENOSYS;
        return -1;
    }
    if (MCFIXBypassHooksActive()) {
        return mcfix_orig_mkdir(path, mode);
    }
    char buf[PATH_MAX];
    const char *p = MCFIXPOSIXResolvedPathForSyscall(path, buf);
    if (p == NULL) {
        errno = EINVAL;
        return -1;
    }
    return mcfix_orig_mkdir(p, mode);
}

int mcfix_posix_open(const char *path, int oflag, ...) {
    mode_t cmode = 0;
    if (oflag & O_CREAT) {
        va_list ap;
        va_start(ap, oflag);
        cmode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    if (path == NULL) {
        errno = EINVAL;
        return -1;
    }
    if (mcfix_orig_open == NULL) {
        errno = ENOSYS;
        return -1;
    }
    if (MCFIXBypassHooksActive()) {
        if (oflag & O_CREAT) {
            return mcfix_orig_open(path, oflag, cmode);
        }
        return mcfix_orig_open(path, oflag);
    }
    char buf[PATH_MAX];
    BOOL worldIconRead = (strstr(path, "world_icon") != NULL &&
                          (oflag & O_ACCMODE) == O_RDONLY);
    const char *p = worldIconRead
        ? MCFIXPOSIXResolvedPathForReadSyscall(path, buf)
        : MCFIXPOSIXResolvedPathForSyscall(path, buf);
    if (p == NULL) {
        errno = EINVAL;
        return -1;
    }
    if (strstr(p, "AchievementIcons/") != NULL && (oflag & (O_WRONLY | O_RDWR))) {
        MCFIXLogOnce(MCFIXLogCatIcon, @"ach_open_write",
                     @"ACH open write path=%s oflag=0x%x", p, oflag);
    }
    if (strstr(p, "world_icon") != NULL && (oflag & (O_WRONLY | O_RDWR))) {
        MCFIXLogOnce(MCFIXLogCatIcon, @"world_open_write",
                     @"WORLD open write path=%s oflag=0x%x", p, oflag);
    }
    if (oflag & O_CREAT) {
        int fd = mcfix_orig_open(p, oflag, cmode);
        if (fd == -1 && errno == ENOENT && (oflag & O_WRONLY || oflag & O_RDWR)) {
            NSString *ps = [NSString stringWithUTF8String:p];
            NSString *parent = [ps stringByDeletingLastPathComponent];
            const char *pdir = parent.fileSystemRepresentation;
            if (pdir && mcfix_orig_mkdir_p(pdir, (mode_t)0755) == 0) {
                fd = mcfix_orig_open(p, oflag, cmode);
            }
        }
        return fd;
    }
    int fd = mcfix_orig_open(p, oflag);
    if (strstr(p, "catalog_info.json") != NULL || strstr(p, "MarketplaceDurableCatalog") != NULL) {
        MCFIXLogOnce(MCFIXLogCatVFS, [NSString stringWithFormat:@"catalog_open_%s", p],
                     @"catalog I/O open path=%s fd=%d errno=%d", p, fd, fd >= 0 ? 0 : errno);
    }
    if (worldIconRead) {
        off_t bytes = (fd >= 0) ? MCFIXWorldIconFileBytes([NSString stringWithUTF8String:p]) : -1;
        int jpeg = (fd >= 0 && bytes >= 256 && gMCFIXWorldIconUITraceN <= 16)
            ? (MCFIXWorldIconJPEGMagicOK([NSString stringWithUTF8String:p]) ? 1 : 0)
            : -1;
        MCFIXWorldIconTraceUI("posix", fd >= 0 ? "read" : "read_miss", "open",
                              path, p, fd >= 0 ? 0 : -1, bytes, jpeg);
    }
    return fd;
}

static FILE *mcfix_fopen_impl(const char *path, const char *mode,
                              FILE *(*orig)(const char *, const char *)) {
    if (path == NULL || mode == NULL) {
        errno = EINVAL;
        return NULL;
    }
    if (orig == NULL) {
        errno = ENOSYS;
        return NULL;
    }
    if (MCFIXBypassHooksActive()) {
        return orig(path, mode);
    }
    char buf[PATH_MAX];
    BOOL isWriteMode = (mode[0] == 'w' || mode[0] == 'a' ||
                        (mode[0] == 'r' && strchr(mode, '+') != NULL));
    BOOL worldIconRead = (strstr(path, "world_icon") != NULL && mode[0] == 'r' && !isWriteMode);
    const char *p = worldIconRead
        ? MCFIXPOSIXResolvedPathForReadSyscall(path, buf)
        : MCFIXPOSIXResolvedPathForSyscall(path, buf);
    if (p == NULL) {
        errno = EINVAL;
        return NULL;
    }
    FILE *result = orig(p, mode);
    if (strstr(p, "catalog_info.json") != NULL || strstr(p, "MarketplaceDurableCatalog") != NULL) {
        MCFIXLogOnce(MCFIXLogCatVFS, [NSString stringWithFormat:@"catalog_io_%s", p],
                     @"catalog I/O fopen mode=%s path=%s ok=%d errno=%d",
                     mode, p, result ? 1 : 0, result ? 0 : errno);
    }
    if (strstr(p, "AchievementIcons/") != NULL) {
        MCFIXLogAchievementFopenProbe(p, mode, result);
    }
    if (strstr(p, "world_icon") != NULL) {
        MCFIXLogWorldIconFopenProbe(p, mode, result, path);
    }
    // If opening for write/append failed with ENOENT the parent directory is missing
    // in the Caches VFS tree — create it and retry. This handles world folders that
    // were not yet created via our mkdir hook (e.g. race during first-time world creation).
    if (result == NULL && errno == ENOENT &&
        (mode[0] == 'w' || mode[0] == 'a' || (mode[0] == 'r' && strchr(mode, '+')))) {
        NSString *ps = [NSString stringWithUTF8String:p];
        NSString *parent = [ps stringByDeletingLastPathComponent];
        const char *pdir = parent.fileSystemRepresentation;
        if (pdir && mcfix_orig_mkdir_p(pdir, (mode_t)0755) == 0) {
            result = orig(p, mode);
        }
    }
    if (result == NULL && mode[0] == 'r') {
        @autoreleasepool {
            NSString *ps = [NSString stringWithUTF8String:p];
            if (result == NULL && MCFIXPathNeedsGameStorageFallback(ps)) {
                result = MCFIXFopenTryAlternatePath(p, path, mode, orig);
            }
        }
    }
    if (result == NULL && mode[0] == 'r') {
        @autoreleasepool {
            NSString *ps = [NSString stringWithUTF8String:p];
            if (result == NULL &&
                ([ps containsString:@"world_icon"] || [ps containsString:@"AchievementIcons"] ||
                 [ps containsString:@"options.txt"])) {
                MCFIXLogBump(@"fopen_miss");
                MCFIXLogOnce(MCFIXLogCatFSMiss,
                             [NSString stringWithFormat:@"fopen_%s", p],
                             @"fopen MISS mode=%s path=%s resolved=%s errno=%d",
                             mode, path, p, errno);
            }
        }
    }
    return result;
}

FILE *mcfix_posix_fopen(const char *path, const char *mode) {
    return mcfix_fopen_impl(path, mode, mcfix_orig_fopen);
}

FILE *mcfix_posix_fopen_darwin_extsn(const char *path, const char *mode) {
    return mcfix_fopen_impl(path, mode, mcfix_orig_fopen_darwin_extsn);
}

int mcfix_posix_fclose(FILE *stream) {
    if (stream == NULL) {
        errno = EINVAL;
        return EOF;
    }
    if (mcfix_orig_fclose == NULL) {
        errno = ENOSYS;
        return EOF;
    }
    if (stream == gMCFIXWorldIconPendingFclose && gMCFIXWorldIconPendingVfsPath[0] != '\0') {
        @autoreleasepool {
            NSString *vfsPath = [NSString stringWithUTF8String:gMCFIXWorldIconPendingVfsPath];
            NSString *wid = MCFIXWorldIdFromWorldIconPath(vfsPath);
            if (wid.length) {
                MCFIXWorldIconMirrorCanonicalToHome(wid);
            }
        }
        gMCFIXWorldIconPendingFclose = NULL;
        gMCFIXWorldIconPendingVfsPath[0] = '\0';
    }
    return mcfix_orig_fclose(stream);
}

int mcfix_posix_access(const char *path, int amode) {
    if (path == NULL) {
        errno = EINVAL;
        return -1;
    }
    if (mcfix_orig_access == NULL) {
        errno = ENOSYS;
        return -1;
    }
    if (MCFIXBypassHooksActive()) {
        return mcfix_orig_access(path, amode);
    }
    char buf[PATH_MAX];
    const char *p = MCFIXPOSIXResolvedPathForSyscall(path, buf);
    if (p == NULL) {
        errno = EINVAL;
        return -1;
    }
    return mcfix_orig_access(p, amode);
}

static DIR *mcfix_opendir_impl(const char *path, DIR *(*orig)(const char *)) {
    if (path == NULL) {
        errno = EINVAL;
        return NULL;
    }
    if (orig == NULL) {
        errno = ENOSYS;
        return NULL;
    }
    if (MCFIXBypassHooksActive()) {
        return orig(path);
    }
    char buf[PATH_MAX];
    const char *p = MCFIXPOSIXResolvedPathForSyscall(path, buf);
    if (p == NULL) {
        errno = EINVAL;
        return NULL;
    }
    return orig(p);
}

DIR *mcfix_posix_opendir(const char *path) {
    return mcfix_opendir_impl(path, mcfix_orig_opendir);
}

DIR *mcfix_posix_opendir_inode64(const char *path) {
    return mcfix_opendir_impl(path, mcfix_orig_opendir_inode64);
}

// ---------------------------------------------------------------------------
//  Anti-wipe (root tweak) — block cloud-sync init from deleting options.txt /
//  minecraftpe / skin_packs. NO.txt: game RMDIR'd minecraftpe right after seed.
//  Marketplace paths: intercept delete, errno=0, return 0 (fake success).
// ---------------------------------------------------------------------------

#include <stdatomic.h>

static _Atomic uint64_t gMCFIXExitWipeUntilNs = 0;

static uint64_t MCFIXMonotonicNs(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return 0;
    }
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static void MCFIXMarkExitWipe(void) {
    atomic_store(&gMCFIXExitWipeUntilNs, MCFIXMonotonicNs() + 2000000000ull);
}

int MCFIXIsExitWipeActive(void) {
    uint64_t until = atomic_load(&gMCFIXExitWipeUntilNs);
    return until != 0 && MCFIXMonotonicNs() < until;
}

static int MCFIXIsEphemeralMinecraftPEPath(const char *p) {
    if (!p) {
        return 0;
    }
    return strstr(p, "_lock") != NULL ||
           strstr(p, "Perf_Log") != NULL ||
           strstr(p, "valid_known_packs") != NULL ||
           strstr(p, "invalid_known_packs") != NULL ||
           strstr(p, "clientId.txt") != NULL ||
           strstr(p, "TempImportPacks") != NULL;
}

static int MCFIXIsProtectedPersistPath(const char *p) {
    if (!p) {
        return 0;
    }
    if (MCFIXIsEphemeralMinecraftPEPath(p)) {
        return 0;
    }
    if (strstr(p, "options.txt")) {
        return 1;
    }
    if (strstr(p, "MarketplaceDurableCatalog") || strstr(p, "catalog_info.json")) {
        return 1;
    }
    const char *slash = strrchr(p, '/');
    const char *fn = slash ? slash + 1 : p;
    if (strcmp(fn, "minecraftpe") == 0 || strcmp(fn, "skin_packs") == 0) {
        return 1;
    }
    return 0;
}

static int MCFIXIsInsideWorldLevelDB(const char *p) {
    return p && strstr(p, "/db/") != NULL;
}

static int MCFIXPathEndsWithMinecraftWorldsDir(const char *p) {
    if (!p) {
        return 0;
    }
    static const char kSuffix[] = "/minecraftWorlds";
    size_t len = strlen(p);
    size_t slen = sizeof(kSuffix) - 1;
    return len >= slen && strcmp(p + len - slen, kSuffix) == 0;
}

static int MCFIXIsLevelDatSaveRotationCleanup(const char *p) {
    if (!p) {
        return 0;
    }
    const char *slash = strrchr(p, '/');
    const char *fn    = slash ? slash + 1 : p;
    if (strcmp(fn, "level.dat") != 0) {
        return 0;
    }
    char dir[PATH_MAX];
    size_t dirLen = slash ? (size_t)(slash - p) : 0;
    if (dirLen == 0 || dirLen >= sizeof(dir)) {
        return 0;
    }
    memcpy(dir, p, dirLen);
    dir[dirLen] = '\0';
    char sibling[PATH_MAX];
    snprintf(sibling, sizeof(sibling), "%s/level.dat_old", dir);
    struct stat st;
    if (stat(sibling, &st) == 0) {
        return 1;
    }
    snprintf(sibling, sizeof(sibling), "%s/level.dat_new", dir);
    if (stat(sibling, &st) == 0) {
        return 1;
    }
    return 0;
}

static int MCFIXShouldBlockRemove(const char *p) {
    if (MCFIXIsProtectedPersistPath(p)) {
        return 1;
    }
    if (!p || !strstr(p, "minecraftWorlds")) {
        return 0;
    }
    const char *slash = strrchr(p, '/');
    const char *fn    = slash ? slash + 1 : p;
    if (MCFIXIsInsideWorldLevelDB(p)) {
        // Normal play: LevelDB must delete old MANIFEST/.ldb. Exit wipe (NO!.txt
        // 13:50:28) does the same after blocked level.dat — gate on that flag.
        if (MCFIXIsExitWipeActive()) {
            return 1;
        }
        if (strcmp(fn, "LOCK") == 0) {
            return 0;
        }
        if (strstr(fn, ".dbtmp")) {
            return 0;
        }
        return 0;
    }
    if (strcmp(fn, "LOCK") == 0) {
        return 0;
    }
    if (strcmp(fn, "level.dat_new") == 0 || strcmp(fn, "level.dat_old") == 0) {
        return 0;
    }
    if (strstr(fn, ".dbtmp")) {
        return 0;
    }
    if (strcmp(fn, "level.dat") == 0) {
        if (MCFIXIsLevelDatSaveRotationCleanup(p)) {
            return 0;
        }
        MCFIXMarkExitWipe();
        return 1;
    }
    if (strstr(fn, "world_icon")) {
        if (MCFIXIsExitWipeActive()) {
            return 1;
        }
        // IDA: may unlink before fopen(wb); allow only during active save rewrite window.
        if (__atomic_load_n(&gMCFIXWorldIconSaveRewriteAllow, __ATOMIC_RELAXED) != 0) {
            return 0;
        }
        // Relaunch/list teardown: block remove when canonical icon exists (logs: grey icon).
        @autoreleasepool {
            NSString *wid = MCFIXWorldIdFromWorldIconPath([NSString stringWithUTF8String:p]);
            if (wid.length) {
                off_t canonBytes = MCFIXWorldIconFileBytes(MCFIXWorldIconCanonicalVFSPath(wid));
                if (canonBytes >= 256) {
                    return 1;
                }
            }
        }
        return 0;
    }
    if (strcmp(fn, "levelname.txt") == 0) {
        MCFIXMarkExitWipe();
        return 1;
    }
    if (strstr(fn, "world_behavior_packs")) {
        return 1;
    }
    return 0;
}

static int MCFIXShouldBlockRmdir(const char *p) {
    if (!p) {
        return 0;
    }
    if (MCFIXIsEphemeralMinecraftPEPath(p)) {
        return 0;
    }
    if (MCFIXIsProtectedPersistPath(p)) {
        return 1;
    }
    if (strstr(p, "minecraftWorlds")) {
        if (MCFIXPathEndsWithMinecraftWorldsDir(p)) {
            return 1;
        }
        if (MCFIXIsInsideWorldLevelDB(p)) {
            return 0;
        }
        if (strstr(p, "/minecraftWorlds/") != NULL) {
            return 1;
        }
    }
    return 0;
}

int mcfix_posix_unlink(const char *path) {
    if (path == NULL) {
        errno = EINVAL;
        return -1;
    }
    if (mcfix_orig_unlink == NULL) {
        errno = ENOSYS;
        return -1;
    }
    if (MCFIXBypassHooksActive()) {
        return mcfix_orig_unlink(path);
    }
    char buf[PATH_MAX];
    const char *p = MCFIXPOSIXResolvedPathForSyscall(path, buf);
    if (p == NULL) {
        errno = EINVAL;
        return -1;
    }
    // Apply the same anti-wipe protection as mcfix_posix_remove — the game
    // may call unlink() directly rather than remove() for the same files.
    if (strstr(path, "world_icon") != NULL || strstr(p, "world_icon") != NULL) {
        int blocked = MCFIXShouldBlockRemove(p);
        if (blocked) {
            MCFIXWorldIconDeleteTrace("unlink", path, p, 1, 0);
            MCFIXLogOnce(MCFIXLogCatFSGuard, [NSString stringWithFormat:@"unlink_blk_%s", p],
                         @"UNLINK BLOCKED %s", p);
            errno = 0;
            return 0;
        }
        int rc = mcfix_orig_unlink(p);
        MCFIXWorldIconDeleteTrace("unlink", path, p, 0, rc);
        return rc;
    }
    if (MCFIXShouldBlockRemove(p)) {
        MCFIXLogOnce(MCFIXLogCatFSGuard, [NSString stringWithFormat:@"unlink_blk_%s", p],
                     @"UNLINK BLOCKED %s", p);
        errno = 0;
        return 0;
    }
    if (strstr(p, "minecraftWorlds") || strstr(p, "level.dat") ||
        strstr(p, "MANIFEST") || strstr(p, "CURRENT") ||
        strstr(p, ".ldb") || strstr(p, "LOCK")) {
        MCFIXLogRate(MCFIXLogCatFSGuard, @"unlink_sample", 10.0, @"UNLINK %s", p);
    }
    return mcfix_orig_unlink(p);
}

int mcfix_posix_rmdir(const char *path) {
    if (path == NULL) {
        errno = EINVAL;
        return -1;
    }
    if (mcfix_orig_rmdir == NULL) {
        errno = ENOSYS;
        return -1;
    }
    if (MCFIXBypassHooksActive()) {
        return mcfix_orig_rmdir(path);
    }
    char buf[PATH_MAX];
    const char *p = MCFIXPOSIXResolvedPathForSyscall(path, buf);
    if (p == NULL) {
        errno = EINVAL;
        return -1;
    }
    if (MCFIXShouldBlockRmdir(p)) {
        MCFIXLogOnce(MCFIXLogCatFSGuard, [NSString stringWithFormat:@"rmdir_blk_%s", p],
                     @"RMDIR BLOCKED %s", p);
        errno = 0;
        return 0;
    }
    if (strstr(p, "com.mojang")) {
        MCFIXLogRate(MCFIXLogCatFSGuard, @"rmdir_sample", 10.0, @"RMDIR %s", p);
    }
    return mcfix_orig_rmdir(p);
}

int mcfix_posix_rename(const char *oldpath, const char *newpath) {
    if (oldpath == NULL || newpath == NULL) {
        errno = EINVAL;
        return -1;
    }
    if (mcfix_orig_rename == NULL) {
        errno = ENOSYS;
        return -1;
    }
    if (MCFIXBypassHooksActive()) {
        return mcfix_orig_rename(oldpath, newpath);
    }
    char bo[PATH_MAX];
    char bn[PATH_MAX];
    const char *po = MCFIXPOSIXResolvedPathForSyscall(oldpath, bo);
    const char *pn = MCFIXPOSIXResolvedPathForSyscall(newpath, bn);
    if (po == NULL || pn == NULL) {
        errno = EINVAL;
        return -1;
    }

    if (strstr(po, "world_icon") != NULL || strstr(pn, "world_icon") != NULL) {
        MCFIXLog(MCFIXLogCatIcon, @"WORLD rename raw %s -> %s | redir %s -> %s",
                 oldpath, newpath, po, pn);
    }
    // Verbose logging for save-critical renames so we can trace the exact paths.
    BOOL isSavePath = (strstr(oldpath, "level.dat") || strstr(newpath, "level.dat") ||
                       strstr(oldpath, "levelname") || strstr(newpath, "levelname") ||
                       strstr(oldpath, "MANIFEST") || strstr(newpath, "MANIFEST") ||
                       strstr(oldpath, "CURRENT") || strstr(newpath, "CURRENT") ||
                       strstr(oldpath, "minecraftWorlds") || strstr(newpath, "minecraftWorlds"));
    if (isSavePath) {
        MCFIXLogOnce(MCFIXLogCatFSMiss,
                     [NSString stringWithFormat:@"rename_%s_%s", po, pn],
                     @"RENAME raw: %s -> %s | redirected: %s -> %s",
                     oldpath, newpath, po, pn);
    }

    int result = mcfix_orig_rename(po, pn);

    if (isSavePath) {
        if (result != 0) {
            MCFIXLogOnce(MCFIXLogCatFSMiss,
                         [NSString stringWithFormat:@"rename_fail_%s_%s", po, pn],
                         @"RENAME RESULT %d errno=%d for %s -> %s",
                         result, errno, po, pn);
        }
    }

    if (result != 0) {
        @autoreleasepool {
            NSString *vfs = MCFIXGameDataVFSSandboxRoot();
            NSString *poStr = [NSString stringWithUTF8String:po];
            NSString *pnStr = [NSString stringWithUTF8String:pn];
            BOOL poIsInCaches = [poStr hasPrefix:vfs];
            BOOL pnIsInCaches = [pnStr hasPrefix:vfs];

            if (poIsInCaches && !pnIsInCaches) {
                // po is already in the Caches VFS root (e.g. LevelDB resolved its db dir
                // internally) but pn is still the original tmp/Temp/... path.
                // Derive the correct Caches destination two ways and try both:
                //   1. MCFIXPathByRedirectingGameStorage on the raw newpath (now works
                //      correctly after the /private/var fix).
                //   2. Same-directory derivation: replace po's filename with pn's filename.
                NSString *rawNew = [NSString stringWithUTF8String:newpath];
                NSString *correctDest = MCFIXPathByRedirectingGameStorage(rawNew);
                if ([correctDest isEqualToString:rawNew]) {
                    // Redirect still failed for newpath — use same-directory derivation.
                    NSString *poDir = [poStr stringByDeletingLastPathComponent];
                    NSString *pnName = [pnStr lastPathComponent];
                    correctDest = [poDir stringByAppendingPathComponent:pnName];
                    MCFIXLogOnce(MCFIXLogCatFSMiss, @"rename_fb_samedir", @"RENAME FALLBACK SAMEDIR dest: %@", correctDest);
                }
                NSString *correctParent = [correctDest stringByDeletingLastPathComponent];
                const char *pdir = correctParent.fileSystemRepresentation;
                if (pdir) {
                    (void)mcfix_orig_mkdir_p(pdir, (mode_t)0755);
                }
                const char *correctC = [correctDest fileSystemRepresentation];
                if (correctC) {
                    result = mcfix_orig_rename(po, correctC);
                    MCFIXLogOnce(MCFIXLogCatFSMiss, @"rename_fb",
                                 @"RENAME FALLBACK %s -> %s result=%d errno=%d",
                                 po, correctC, result, result == 0 ? 0 : errno);
                }

            } else if (!poIsInCaches && po != oldpath) {
                // po was redirected by MCFIX (po != oldpath) but pn was not redirected to
                // Caches. Try redirecting newpath explicitly.
                NSString *rawNew = [NSString stringWithUTF8String:newpath];
                NSString *correctDest = MCFIXPathByRedirectingGameStorage(rawNew);
                if ([correctDest isEqualToString:rawNew]) {
                    // Still no redirect — fall back to same-directory derivation.
                    NSString *poDir = [NSString stringWithUTF8String:po];
                    poDir = [poDir stringByDeletingLastPathComponent];
                    NSString *pnName = [[NSString stringWithUTF8String:newpath] lastPathComponent];
                    correctDest = [poDir stringByAppendingPathComponent:pnName];
                    MCFIXLogOnce(MCFIXLogCatFSMiss, @"rename_fb2_samedir", @"RENAME FALLBACK2 SAMEDIR dest: %@", correctDest);
                }
                NSString *correctParent = [correctDest stringByDeletingLastPathComponent];
                const char *pdir2 = correctParent.fileSystemRepresentation;
                if (pdir2) {
                    (void)mcfix_orig_mkdir_p(pdir2, (mode_t)0755);
                }
                const char *correctC = [correctDest fileSystemRepresentation];
                if (correctC) {
                    result = mcfix_orig_rename(po, correctC);
                    MCFIXLogOnce(MCFIXLogCatFSMiss, @"rename_fb2",
                                 @"RENAME FALLBACK2 %s -> %s result=%d errno=%d",
                                 po, correctC, result, result == 0 ? 0 : errno);
                }
            }
        }
    }

    // If rename succeeded but pn is outside Caches while po was in Caches,
    // copy the result back to the correct Caches location (achievement icons etc
    // are harmless, but world files must land in Caches).
    if (result == 0 && isSavePath) {
        @autoreleasepool {
            NSString *vfs = MCFIXGameDataVFSSandboxRoot();
            NSString *pnStr = [NSString stringWithUTF8String:pn];
            if (![pnStr hasPrefix:vfs]) {
                NSString *rawNew = [NSString stringWithUTF8String:newpath];
                NSString *correctDest = MCFIXPathByRedirectingGameStorage(rawNew);
                if (![correctDest isEqualToString:rawNew]) {
                    NSString *correctParent = [correctDest stringByDeletingLastPathComponent];
                    NSFileManager *fm = [NSFileManager defaultManager];
                    const char *repairDir = correctParent.fileSystemRepresentation;
                    if (repairDir) {
                        (void)mcfix_orig_mkdir_p(repairDir, (mode_t)0755);
                    }
                    NSError *copyErr = nil;
                    [fm copyItemAtPath:pnStr toPath:correctDest error:&copyErr];
                    if (!copyErr) {
                        MCFIXLogOnce(MCFIXLogCatFSMiss, @"rename_repair",
                                     @"RENAME REPAIR copied %@ -> %@", pnStr, correctDest);
                    } else {
                        MCFIXLog(MCFIXLogCatError, @"RENAME REPAIR FAIL %@ -> %@: %@",
                                 pnStr, correctDest, copyErr.localizedDescription);
                    }
                }
            }
        }
    }

    return result;
}

int mcfix_posix_chmod(const char *path, mode_t mode) {
    if (path == NULL) {
        errno = EINVAL;
        return -1;
    }
    if (mcfix_orig_chmod == NULL) {
        errno = ENOSYS;
        return -1;
    }
    if (MCFIXBypassHooksActive()) {
        return mcfix_orig_chmod(path, mode);
    }
    char buf[PATH_MAX];
    const char *p = MCFIXPOSIXResolvedPathForSyscall(path, buf);
    if (p == NULL) {
        errno = EINVAL;
        return -1;
    }
    return mcfix_orig_chmod(p, mode);
}

int mcfix_posix_chown(const char *path, uid_t owner, gid_t group) {
    if (path == NULL) {
        errno = EINVAL;
        return -1;
    }
    if (mcfix_orig_chown == NULL) {
        errno = ENOSYS;
        return -1;
    }
    if (MCFIXBypassHooksActive()) {
        return mcfix_orig_chown(path, owner, group);
    }
    char buf[PATH_MAX];
    const char *p = MCFIXPOSIXResolvedPathForSyscall(path, buf);
    if (p == NULL) {
        errno = EINVAL;
        return -1;
    }
    return mcfix_orig_chown(p, owner, group);
}

int mcfix_posix_remove(const char *path) {
    if (path == NULL) {
        errno = EINVAL;
        return -1;
    }
    if (mcfix_orig_remove == NULL) {
        errno = ENOSYS;
        return -1;
    }
    if (MCFIXBypassHooksActive()) {
        return mcfix_orig_remove(path);
    }
    char buf[PATH_MAX];
    const char *p = MCFIXPOSIXResolvedPathForSyscall(path, buf);
    if (p == NULL) {
        errno = EINVAL;
        return -1;
    }
    if (strstr(path, "world_icon") != NULL || strstr(p, "world_icon") != NULL) {
        int blocked = MCFIXShouldBlockRemove(p);
        if (blocked) {
            MCFIXWorldIconDeleteTrace("remove", path, p, 1, 0);
            MCFIXLogOnce(MCFIXLogCatFSGuard, [NSString stringWithFormat:@"remove_blk_%s", p],
                         @"REMOVE BLOCKED %s", p);
            errno = 0;
            return 0;
        }
        int rc = mcfix_orig_remove(p);
        MCFIXWorldIconDeleteTrace("remove", path, p, 0, rc);
        return rc;
    }
    if (MCFIXShouldBlockRemove(p)) {
        MCFIXLogOnce(MCFIXLogCatFSGuard, [NSString stringWithFormat:@"remove_blk_%s", p],
                     @"REMOVE BLOCKED %s", p);
        errno = 0;
        return 0;
    }
    if (strstr(p, "minecraftWorlds") || strstr(p, "level.dat") ||
        strstr(p, "MANIFEST") || strstr(p, "CURRENT") ||
        strstr(p, ".ldb") || strstr(p, "LOCK")) {
        MCFIXLogRate(MCFIXLogCatFSGuard, @"remove_sample", 10.0, @"REMOVE %s", p);
    }
    return mcfix_orig_remove(p);
}

int mcfix_posix_statfs(const char *path, struct statfs *buf) {
    if (path == NULL) {
        errno = EINVAL;
        return -1;
    }
    if (mcfix_orig_statfs == NULL) {
        errno = ENOSYS;
        return -1;
    }
    if (MCFIXBypassHooksActive()) {
        return mcfix_orig_statfs(path, buf);
    }
    char fspath[PATH_MAX];
    const char *p = MCFIXPOSIXResolvedPathForSyscall(path, fspath);
    if (p == NULL) {
        errno = EINVAL;
        return -1;
    }
    return mcfix_orig_statfs(p, buf);
}

int mcfix_posix_symlink(const char *name1, const char *name2) {
    if (name1 == NULL || name2 == NULL) {
        errno = EINVAL;
        return -1;
    }
    if (mcfix_orig_symlink == NULL) {
        errno = ENOSYS;
        return -1;
    }
    if (MCFIXBypassHooksActive()) {
        return mcfix_orig_symlink(name1, name2);
    }
    char b2[PATH_MAX];
    const char *p2 = MCFIXPOSIXResolvedPathForSyscall(name2, b2);
    if (p2 == NULL) {
        errno = EINVAL;
        return -1;
    }
    return mcfix_orig_symlink(name1, p2);
}

int mcfix_posix_readlink(const char *path, char *buf, size_t bufsiz) {
    if (path == NULL) {
        errno = EINVAL;
        return -1;
    }
    if (mcfix_orig_readlink == NULL) {
        errno = ENOSYS;
        return -1;
    }
    if (MCFIXBypassHooksActive()) {
        return mcfix_orig_readlink(path, buf, bufsiz);
    }
    char fspath[PATH_MAX];
    const char *p = MCFIXPOSIXResolvedPathForSyscall(path, fspath);
    if (p == NULL) {
        errno = EINVAL;
        return -1;
    }
    return mcfix_orig_readlink(p, buf, bufsiz);
}

int mcfix_posix_openat(int fd, const char *path, int oflag, ...) {
    mode_t cmode = 0;
    if (oflag & O_CREAT) {
        va_list ap;
        va_start(ap, oflag);
        cmode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    if (path == NULL) {
        errno = EINVAL;
        return -1;
    }
    if (mcfix_orig_openat == NULL) {
        errno = ENOSYS;
        return -1;
    }
    if (MCFIXBypassHooksActive()) {
        if (oflag & O_CREAT) {
            return mcfix_orig_openat(fd, path, oflag, cmode);
        }
        return mcfix_orig_openat(fd, path, oflag);
    }
    char buf[PATH_MAX];
    const char *p = MCFIXPOSIXResolvedPathForSyscall(path, buf);
    if (p == NULL) {
        errno = EINVAL;
        return -1;
    }
    if (oflag & O_CREAT) {
        int outfd = mcfix_orig_openat(fd, p, oflag, cmode);
        if (outfd == -1 && errno == ENOENT && (oflag & O_WRONLY || oflag & O_RDWR)) {
            NSString *ps = [NSString stringWithUTF8String:p];
            NSString *parent = [ps stringByDeletingLastPathComponent];
            const char *pdir = parent.fileSystemRepresentation;
            if (pdir && mcfix_orig_mkdir_p(pdir, (mode_t)0755) == 0) {
                outfd = mcfix_orig_openat(fd, p, oflag, cmode);
            }
        }
        return outfd;
    }
    return mcfix_orig_openat(fd, p, oflag);
}

