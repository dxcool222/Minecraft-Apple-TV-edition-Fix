// World-icon mirroring, JPEG verification, dual-path snapshots, and POSIX
// diagnostic probes. See WorldIcon.h for the public surface.
//
// The engine probes thumbnails through several interfaces — POSIX fopen,
// stat/access, NSFileManager fileExistsAtPath:/contentsAtPath:, plus the
// UI's #world_icon_texture_file binding. Each probe path logs through
// MCFIXWorldIconTraceUI so a runtime trace shows exactly which roots the
// game touches and which return a valid JPEG.

#import "WorldIcon.h"
#import "../Internal/MCFIXPosixOrigs.h"
#import "../VFS/PathRedirect.h"
#import "MCFIXBypass.h"
#import "MCFIXGameDataVFS.h"
#import "MCFIXLog.h"

#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <unistd.h>

static NSArray<NSString *> *MCFIXWorldIconStorageTails(void) {
    static NSArray<NSString *> *tails;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tails = @[
            @"tmp/Temp/games/com.mojang/minecraftWorlds",
            @"Library/games/com.mojang/minecraftWorlds",
            @"Documents/games/com.mojang/minecraftWorlds",
            @"tmp/minecraftpe/games/com.mojang/minecraftWorlds",
        ];
    });
    return tails;
}

NSString *MCFIXWorldIdFromWorldIconPath(NSString *ps) {
    if (ps.length == 0) {
        return nil;
    }
    NSRange worldsRange = [ps rangeOfString:@"/minecraftWorlds/"];
    if (worldsRange.location == NSNotFound) {
        return nil;
    }
    NSString *after = [ps substringFromIndex:worldsRange.location + worldsRange.length];
    NSRange slash = [after rangeOfString:@"/"];
    if (slash.location == NSNotFound) {
        return nil;
    }
    return [after substringToIndex:slash.location];
}

/// IDA canonical write/read root: vfs/tmp/Temp/games/com.mojang/minecraftWorlds/<id>/world_icon.jpeg
NSString *MCFIXWorldIconCanonicalVFSPath(NSString *worldId) {
    if (worldId.length == 0) {
        return nil;
    }
    static NSString *const kTail = @"tmp/Temp/games/com.mojang/minecraftWorlds";
    static NSString *const kIcon = @"world_icon.jpeg";
    NSString *vfs = [MCFIXGameDataVFSSandboxRoot() stringByStandardizingPath];
    return [[[vfs stringByAppendingPathComponent:kTail]
        stringByAppendingPathComponent:worldId] stringByAppendingPathComponent:kIcon];
}

/// Read-only: map any redirected world_icon path to the canonical VFS Temp file (no multi-tail copy).
NSString *MCFIXWorldIconAliasReadPath(NSString *redirectedPath) {
    if (redirectedPath.length == 0 || [redirectedPath rangeOfString:@"world_icon"].location == NSNotFound) {
        return redirectedPath;
    }
    NSString *worldId = MCFIXWorldIdFromWorldIconPath(redirectedPath);
    if (worldId.length == 0) {
        return redirectedPath;
    }
    NSString *canon = [MCFIXWorldIconCanonicalVFSPath(worldId) stringByStandardizingPath];
    if (canon.length == 0 || [canon isEqualToString:[redirectedPath stringByStandardizingPath]]) {
        return redirectedPath;
    }
    static NSMutableSet<NSString *> *sAliasLogged;
    static dispatch_once_t sAliasLoggedOnce;
    dispatch_once(&sAliasLoggedOnce, ^{
        sAliasLogged = [NSMutableSet set];
    });
    @synchronized (sAliasLogged) {
        if (![sAliasLogged containsObject:worldId]) {
            [sAliasLogged addObject:worldId];
            off_t bytes = MCFIXWorldIconFileBytes(canon);
            MCFIXLog(MCFIXLogCatIcon,
                     @"WORLD read alias world_id=%@ from=%@ to=%@ bytes=%lld",
                     worldId, redirectedPath.lastPathComponent, canon.lastPathComponent,
                     (long long)bytes);
        }
    }
    return canon;
}

// Verbose world-list thumbnail load tracing (IDA: list build uses access; UI bind uses
// #world_icon_texture_file / sub_10015C718 — often no libc fopen read during scroll).
uint32_t gMCFIXWorldIconUITraceN = 0;
const uint32_t kMCFIXWorldIconUITraceCap = 96;

// Targeted bind-path mirror: canonical VFS icon → home tmp/Temp (IDA +96 / texture load).
uint32_t gMCFIXWorldIconSaveRewriteAllow = 0;
FILE *gMCFIXWorldIconPendingFclose = NULL;
char gMCFIXWorldIconPendingVfsPath[PATH_MAX];

static NSString *MCFIXWorldIconPathTailLabel(NSString *path) {
    NSString *p = [path stringByStandardizingPath];
    if ([p containsString:@"/tmp/Temp/games/"]) {
        return @"tmp_Temp";
    }
    if ([p containsString:@"/Library/games/"]) {
        return @"Library";
    }
    if ([p containsString:@"/Documents/games/"]) {
        return @"Documents";
    }
    if ([p containsString:@"/minecraftpe/"]) {
        return @"minecraftpe";
    }
    return @"other";
}

static BOOL MCFIXWorldIconResolvedIsCanonical(NSString *resolved, NSString *worldId) {
    if (worldId.length == 0 || resolved.length == 0) {
        return NO;
    }
    NSString *canon = [MCFIXWorldIconCanonicalVFSPath(worldId) stringByStandardizingPath];
    return [canon isEqualToString:[resolved stringByStandardizingPath]];
}

void MCFIXWorldIconTraceUI(const char *iface, const char *phase, const char *op,
                                   const char *rawC, const char *resolvedC,
                                   int rc, off_t bytes, int jpegKnown) {
    if (!MCFIXLogIsEnabled(MCFIXLogCatIcon)) {
        return;
    }
    uint32_t n = __atomic_fetch_add(&gMCFIXWorldIconUITraceN, 1, __ATOMIC_RELAXED);
    if (n >= kMCFIXWorldIconUITraceCap) {
        if (n == kMCFIXWorldIconUITraceCap) {
            MCFIXLog(MCFIXLogCatIcon,
                     @"WORLD UI trace cap (%u) — further icon load events suppressed",
                     kMCFIXWorldIconUITraceCap);
        }
        return;
    }
    @autoreleasepool {
        NSString *raw = rawC ? [NSString stringWithUTF8String:rawC] : @"?";
        NSString *res = resolvedC ? [NSString stringWithUTF8String:resolvedC] : @"?";
        NSString *wid = MCFIXWorldIdFromWorldIconPath(res) ?: MCFIXWorldIdFromWorldIconPath(raw);
        BOOL canon = MCFIXWorldIconResolvedIsCanonical(res, wid);
        const char *jpegStr = (jpegKnown < 0) ? "?" : (jpegKnown ? "1" : "0");
        MCFIXLog(MCFIXLogCatIcon,
                 @"WORLD UI [%s] %s %s world=%@ rc=%d sz=%lld canon=%d jpeg=%s raw_tail=%@ res_tail=%@",
                 iface, phase, op, wid ?: @"?", rc, (long long)bytes, canon ? 1 : 0, jpegStr,
                 MCFIXWorldIconPathTailLabel(raw), MCFIXWorldIconPathTailLabel(res));
        if (n < 20) {
            MCFIXLog(MCFIXLogCatIcon, @"WORLD UI path #%u raw=%@ -> resolved=%@", n, raw, res);
        }
    }
}

/// IDA list entry +96 / texture bind: NSHomeDirectory + tmp/Temp/.../world_icon.jpeg (not VFS path).
NSString *MCFIXWorldIconHomeTempPath(NSString *worldId) {
    if (worldId.length == 0) {
        return nil;
    }
    NSString *home = [NSHomeDirectory() stringByStandardizingPath];
    return [[[home stringByAppendingPathComponent:@"tmp/Temp/games/com.mojang/minecraftWorlds"]
        stringByAppendingPathComponent:worldId] stringByAppendingPathComponent:@"world_icon.jpeg"];
}

/// Bypass-hook stat of home vs canonical vfs/tmp/Temp icon — detects VFS-only writes (split=1).
void MCFIXWorldIconDualPathSnapshot(const char *phase, NSString *worldId, NSString *bindPathRaw) {
    if (!MCFIXLogIsEnabled(MCFIXLogCatIcon) || worldId.length == 0) {
        return;
    }
    @autoreleasepool {
        NSString *home = [MCFIXWorldIconHomeTempPath(worldId) stringByStandardizingPath];
        NSString *vfs = [MCFIXWorldIconCanonicalVFSPath(worldId) stringByStandardizingPath];
        off_t homeSz = MCFIXWorldIconFileBytes(home);
        off_t vfsSz = MCFIXWorldIconFileBytes(vfs);
        int homeJpeg = (homeSz >= 256) ? (MCFIXWorldIconJPEGMagicOK(home) ? 1 : 0) : -1;
        int vfsJpeg = (vfsSz >= 256) ? (MCFIXWorldIconJPEGMagicOK(vfs) ? 1 : 0) : -1;
        int split = 0;
        if (vfsSz >= 256 && homeSz < 0) {
            split = 1;
        } else if (homeSz >= 256 && vfsSz < 0) {
            split = 2;
        } else if (homeSz >= 256 && vfsSz >= 256 && homeSz != vfsSz) {
            split = 3;
        }
        MCFIXLog(MCFIXLogCatIcon,
                 @"WORLD DUAL %s world=%@ bind_candidate=%@ home=%@ home_sz=%lld home_jpeg=%d vfs=%@ vfs_sz=%lld vfs_jpeg=%d split=%d",
                 phase, worldId, bindPathRaw ?: @"?", home.lastPathComponent, (long long)homeSz, homeJpeg,
                 vfs.lastPathComponent, (long long)vfsSz, vfsJpeg, split);
        if (split == 1) {
            MCFIXLog(MCFIXLogCatIcon,
                     @"WORLD SPLIT vfs_only — texture/bind likely reads home tmp/Temp but bytes only on VFS canonical");
        } else if (split == 2) {
            MCFIXLog(MCFIXLogCatIcon,
                     @"WORLD SPLIT home_only — unexpected (write may have hit home not VFS)");
        }
        if (bindPathRaw.length) {
            NSString *bindStd = [bindPathRaw stringByStandardizingPath];
            BOOL bindIsHome = [bindStd containsString:@"/tmp/Temp/games/"] &&
                [bindStd rangeOfString:@"MinecraftStorageFix/GameData/vfs"].location == NSNotFound;
            BOOL bindIsVfs = [bindStd containsString:@"MinecraftStorageFix/GameData/vfs"];
            MCFIXLog(MCFIXLogCatIcon,
                     @"WORLD BIND path_shape home_tmp_Temp=%d vfs_canonical=%d (IDA+96 uses worldFolder+world_icon.jpeg)",
                     bindIsHome ? 1 : 0, bindIsVfs ? 1 : 0);
        }
    }
}

/// Always log world_icon unlink/remove — grey icon root cause tracing.
void MCFIXWorldIconDeleteTrace(const char *op, const char *raw, const char *resolved, int blocked, int syscallRc) {
    if (!MCFIXLogIsEnabled(MCFIXLogCatIcon)) {
        return;
    }
    if (resolved == NULL || strstr(resolved, "world_icon") == NULL) {
        if (raw == NULL || strstr(raw, "world_icon") == NULL) {
            return;
        }
    }
    @autoreleasepool {
        NSString *res = resolved ? [NSString stringWithUTF8String:resolved] : @"?";
        NSString *rawNs = raw ? [NSString stringWithUTF8String:raw] : @"?";
        NSString *wid = MCFIXWorldIdFromWorldIconPath(res) ?: MCFIXWorldIdFromWorldIconPath(rawNs);
        MCFIXLog(MCFIXLogCatIcon,
                 @"WORLD DELETE %s world=%@ blocked=%d exit_wipe=%d syscall_rc=%d errno=%d raw=%@ resolved=%@",
                 op, wid ?: @"?", blocked, MCFIXIsExitWipeActive(), syscallRc, errno, rawNs, res);
        if (wid.length) {
            MCFIXWorldIconDualPathSnapshot(blocked ? "DELETE_BLOCKED" : "DELETE_DONE", wid, rawNs);
        }
    }
}

static void MCFIXWorldIconBeginSaveRewriteWindow(void) {
    __atomic_store_n(&gMCFIXWorldIconSaveRewriteAllow, 1, __ATOMIC_RELAXED);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __atomic_store_n(&gMCFIXWorldIconSaveRewriteAllow, 0, __ATOMIC_RELAXED);
    });
}

/// Copy canonical vfs/tmp/Temp/.../world_icon.jpeg → NSHome tmp/Temp path (texture bind only).
void MCFIXWorldIconMirrorCanonicalToHome(NSString *worldId) {
    if (worldId.length == 0) {
        return;
    }
    @autoreleasepool {
        NSString *canon = [MCFIXWorldIconCanonicalVFSPath(worldId) stringByStandardizingPath];
        NSString *home = [MCFIXWorldIconHomeTempPath(worldId) stringByStandardizingPath];
        if (canon.length == 0 || home.length == 0) {
            return;
        }
        off_t sz = MCFIXWorldIconFileBytes(canon);
        if (sz < 256) {
            MCFIXLog(MCFIXLogCatIcon,
                     @"WORLD MIRROR skip world=%@ — canonical bytes=%lld",
                     worldId, (long long)sz);
            return;
        }
        NSString *parent = [home stringByDeletingLastPathComponent];
        const char *pdir = parent.fileSystemRepresentation;
        if (pdir) {
            (void)mcfix_orig_mkdir_p(pdir, (mode_t)0755);
        }
        const char *src = canon.fileSystemRepresentation;
        const char *dst = home.fileSystemRepresentation;
        if (src == NULL || dst == NULL) {
            return;
        }
        BOOL prevBypass = MCFIXBypassHooksActive();
        MCFIXBypassHooksSet(YES);
        FILE *in = mcfix_orig_fopen ? mcfix_orig_fopen(src, "rb") : fopen(src, "rb");
        if (in == NULL) {
            MCFIXBypassHooksSet(prevBypass);
            MCFIXLog(MCFIXLogCatIcon,
                     @"WORLD MIRROR fail world=%@ — open canonical errno=%d",
                     worldId, errno);
            return;
        }
        FILE *out = mcfix_orig_fopen ? mcfix_orig_fopen(dst, "wb") : fopen(dst, "wb");
        if (out == NULL) {
            (mcfix_orig_fclose ? mcfix_orig_fclose : fclose)(in);
            MCFIXBypassHooksSet(prevBypass);
            MCFIXLog(MCFIXLogCatIcon,
                     @"WORLD MIRROR fail world=%@ — open home errno=%d",
                     worldId, errno);
            return;
        }
        char buf[65536];
        size_t n = 0;
        off_t copied = 0;
        while ((n = fread(buf, 1, sizeof(buf), in)) > 0) {
            if (fwrite(buf, 1, n, out) != n) {
                break;
            }
            copied += (off_t)n;
        }
        (mcfix_orig_fclose ? mcfix_orig_fclose : fclose)(in);
        (mcfix_orig_fclose ? mcfix_orig_fclose : fclose)(out);
        MCFIXBypassHooksSet(prevBypass);
        MCFIXLog(MCFIXLogCatIcon,
                 @"WORLD MIRROR vfs→home world=%@ bytes=%lld home=%@",
                 worldId, (long long)copied, home);
        MCFIXWorldIconDualPathSnapshot("POST_MIRROR", worldId, home);
    }
}

/// Hook-safe stat: never re-enter fishhooked POSIX (prevents recursion / extra fd pressure during save).
off_t MCFIXWorldIconFileBytes(NSString *path) {
    if (path.length == 0) {
        return -1;
    }
    const char *pc = path.fileSystemRepresentation;
    if (pc == NULL) {
        return -1;
    }
    struct stat st;
    BOOL prevBypass = MCFIXBypassHooksActive();
    MCFIXBypassHooksSet(YES);
    int (*statfn)(const char *, struct stat *) = mcfix_orig_stat ? mcfix_orig_stat : stat;
    int r = statfn(pc, &st);
    MCFIXBypassHooksSet(prevBypass);
    return (r == 0) ? (off_t)st.st_size : -1;
}

BOOL MCFIXWorldIconMagicLooksJPEG(const unsigned char *hdr, size_t n) {
    return (n >= 3 && hdr[0] == 0xFF && hdr[1] == 0xD8 && hdr[2] == 0xFF);
}

BOOL MCFIXWorldIconJPEGMagicOK(NSString *path) {
    if (path.length == 0) {
        return NO;
    }
    const char *pc = path.fileSystemRepresentation;
    if (pc == NULL) {
        return NO;
    }
    BOOL prevBypass = MCFIXBypassHooksActive();
    MCFIXBypassHooksSet(YES);
    FILE *(*fopenfn)(const char *, const char *) = mcfix_orig_fopen ? mcfix_orig_fopen : fopen;
    int (*fclosefn)(FILE *) = mcfix_orig_fclose ? mcfix_orig_fclose : fclose;
    FILE *f = fopenfn(pc, "rb");
    if (f == NULL) {
        MCFIXBypassHooksSet(prevBypass);
        return NO;
    }
    unsigned char hdr[3] = {0, 0, 0};
    size_t n = fread(hdr, 1, 3, f);
    fclosefn(f);
    MCFIXBypassHooksSet(prevBypass);
    return MCFIXWorldIconMagicLooksJPEG(hdr, n);
}

void MCFIXWorldIconLogHeaderOnce(NSString *worldId, NSString *path) {
    if (worldId.length == 0 || path.length == 0) {
        return;
    }
    off_t bytes = MCFIXWorldIconFileBytes(path);
    if (bytes < 256) {
        return;
    }
    const char *pc = path.fileSystemRepresentation;
    if (pc == NULL) {
        return;
    }
    BOOL prevBypass = MCFIXBypassHooksActive();
    MCFIXBypassHooksSet(YES);
    FILE *(*fopenfn)(const char *, const char *) = mcfix_orig_fopen ? mcfix_orig_fopen : fopen;
    int (*fclosefn)(FILE *) = mcfix_orig_fclose ? mcfix_orig_fclose : fclose;
    FILE *f = fopenfn(pc, "rb");
    if (f == NULL) {
        MCFIXBypassHooksSet(prevBypass);
        return;
    }
    unsigned char hdr[8] = {0};
    size_t n = fread(hdr, 1, sizeof(hdr), f);
    fclosefn(f);
    MCFIXBypassHooksSet(prevBypass);
    BOOL jpeg = MCFIXWorldIconMagicLooksJPEG(hdr, n);
    MCFIXLogOnce(MCFIXLogCatIcon, [NSString stringWithFormat:@"world_icon_hdr_%@", worldId],
                 @"WORLD icon header world_id=%@ path=%@ bytes=%lld magic=%02x%02x%02x%02x jpeg=%d",
                 worldId, path.lastPathComponent, (long long)bytes,
                 n > 0 ? hdr[0] : 0, n > 1 ? hdr[1] : 0, n > 2 ? hdr[2] : 0, n > 3 ? hdr[3] : 0,
                 jpeg ? 1 : 0);
    if (jpeg) {
        MCFIXLogBump(@"world_jpeg_valid");
    }
}

/// Every path we can stat on disk — logged at boot; no assumption about which one the game uses.
/// On access miss: log game path + whether this filename exists in each candidate dir.
/// One-time boot: merge vfs FTP copies into container (and mirror back). Never call from access/fopen.
static void MCFIXWorldIconRootStats(NSString *root, BOOL *outExists, NSUInteger *outWorldDirs,
                                    NSUInteger *outIconFiles) {
    if (outExists) {
        *outExists = NO;
    }
    if (outWorldDirs) {
        *outWorldDirs = 0;
    }
    if (outIconFiles) {
        *outIconFiles = 0;
    }
    if (root.length == 0) {
        return;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:root isDirectory:&isDir] || !isDir) {
        return;
    }
    if (outExists) {
        *outExists = YES;
    }
    static NSString *const kIconName = @"world_icon.jpeg";
    for (NSString *worldId in [fm contentsOfDirectoryAtPath:root error:nil]) {
        if (worldId.length == 0 || [worldId hasPrefix:@"."]) {
            continue;
        }
        NSString *worldDir = [root stringByAppendingPathComponent:worldId];
        BOOL worldIsDir = NO;
        if (![fm fileExistsAtPath:worldDir isDirectory:&worldIsDir] || !worldIsDir) {
            continue;
        }
        if (outWorldDirs) {
            (*outWorldDirs)++;
        }
        if ([fm fileExistsAtPath:[worldDir stringByAppendingPathComponent:kIconName]]) {
            if (outIconFiles) {
                (*outIconFiles)++;
            }
        }
    }
}

void MCFIXLogWorldIconBootProbe(void) {
    NSString *home = [NSHomeDirectory() stringByStandardizingPath];
    NSString *vfs = [MCFIXGameDataVFSSandboxRoot() stringByStandardizingPath];
    MCFIXLog(MCFIXLogCatIcon, @"WORLD boot NSHomeDirectory=%@", home);
    MCFIXLog(MCFIXLogCatIcon, @"WORLD boot VFS root=%@", vfs);
    for (NSString *tail in MCFIXWorldIconStorageTails()) {
        NSString *vfsRoot = [[vfs stringByAppendingPathComponent:tail] stringByStandardizingPath];
        NSString *homeRoot = [[home stringByAppendingPathComponent:tail] stringByStandardizingPath];
        BOOL vfsExists = NO, homeExists = NO;
        NSUInteger vfsWorlds = 0, vfsIcons = 0, homeWorlds = 0, homeIcons = 0;
        MCFIXWorldIconRootStats(vfsRoot, &vfsExists, &vfsWorlds, &vfsIcons);
        MCFIXWorldIconRootStats(homeRoot, &homeExists, &homeWorlds, &homeIcons);
        MCFIXLog(MCFIXLogCatIcon,
                 @"WORLD dirs boot label=VFS+%@ path=%@ exists=%d world_dirs=%lu icon_files=%lu",
                 tail, vfsRoot, vfsExists ? 1 : 0, (unsigned long)vfsWorlds, (unsigned long)vfsIcons);
        MCFIXLog(MCFIXLogCatIcon,
                 @"WORLD dirs boot label=NSHomeDirectory+%@ path=%@ exists=%d world_dirs=%lu icon_files=%lu",
                 tail, homeRoot, homeExists ? 1 : 0, (unsigned long)homeWorlds, (unsigned long)homeIcons);
    }
    MCFIXLogWorldIconBootInventory();
}

void MCFIXLogWorldIconBootInventory(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *vfs = [MCFIXGameDataVFSSandboxRoot() stringByStandardizingPath];
    NSString *home = [NSHomeDirectory() stringByStandardizingPath];
    NSString *tail = @"tmp/Temp/games/com.mojang/minecraftWorlds";
    NSMutableSet<NSString *> *worldIds = [NSMutableSet set];
    for (NSString *base in @[vfs, home]) {
        NSString *root = [[base stringByAppendingPathComponent:tail] stringByStandardizingPath];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:root isDirectory:&isDir] || !isDir) {
            continue;
        }
        for (NSString *wid in [fm contentsOfDirectoryAtPath:root error:nil]) {
            if (wid.length && ![wid hasPrefix:@"."]) {
                [worldIds addObject:wid];
            }
        }
    }
    if (worldIds.count == 0) {
        MCFIXLog(MCFIXLogCatIcon, @"WORLD inventory (no worlds under tmp/Temp yet)");
        return;
    }
    for (NSString *wid in worldIds) {
        NSString *canon = MCFIXWorldIconCanonicalVFSPath(wid);
        off_t bytes = canon.length ? MCFIXWorldIconFileBytes(canon) : -1;
        BOOL jpeg = (bytes >= 256 && MCFIXWorldIconJPEGMagicOK(canon));
        MCFIXLog(MCFIXLogCatIcon,
                 @"WORLD inventory world_id=%@ canonical=%@ bytes=%lld jpeg=%d",
                 wid, canon, (long long)bytes, jpeg ? 1 : 0);
    }
    NSArray<NSString *> *profilePaths = @[
        [home stringByAppendingPathComponent:@"Library/games/com.mojang/minecraftpe/launcher_profiles.json"],
        [[vfs stringByAppendingPathComponent:@"Library/games/com.mojang/minecraftpe"]
            stringByAppendingPathComponent:@"launcher_profiles.json"],
        [[vfs stringByAppendingPathComponent:@"Library/games/com.mojang/resource_packs/vanilla/textures/ui"]
            stringByStandardizingPath],
    ];
    for (NSString *pp in profilePaths) {
        BOOL exists = [fm fileExistsAtPath:pp isDirectory:NULL];
        off_t bytes = exists ? MCFIXWorldIconFileBytes(pp) : -1;
        MCFIXLog(MCFIXLogCatIcon, @"PROFILE boot path=%@ exists=%d bytes=%lld",
                 pp, exists ? 1 : 0, (long long)bytes);
    }
}

void MCFIXLogWorldIconAccessProbe(const char *resolvedPath, int accessRc) {
    if (resolvedPath == NULL) {
        return;
    }
    @autoreleasepool {
        NSString *ps = [NSString stringWithUTF8String:resolvedPath];
        NSString *worldId = MCFIXWorldIdFromWorldIconPath(ps);
        MCFIXLogOnce(MCFIXLogCatIcon, [NSString stringWithFormat:@"world_access_miss_%@", worldId ?: @"?"],
                     @"WORLD access MISS game_path=%@ errno=%d rc=%d world_id=%@",
                     ps, errno, accessRc, worldId ?: @"?");
        if (worldId.length) {
            NSString *canon = MCFIXWorldIconCanonicalVFSPath(worldId);
            off_t bytes = canon.length ? MCFIXWorldIconFileBytes(canon) : -1;
            MCFIXLogOnce(MCFIXLogCatIcon,
                         [NSString stringWithFormat:@"world_access_probe_%@", worldId],
                         @"WORLD access probe world_id=%@ canonical_bytes=%lld path=%@",
                         worldId, (long long)bytes, canon);
        }
    }
}

void MCFIXLogWorldIconStatProbe(const char *resolvedPath, int statRc) {
    if (resolvedPath == NULL) {
        return;
    }
    @autoreleasepool {
        NSString *ps = [NSString stringWithUTF8String:resolvedPath];
        NSString *worldId = MCFIXWorldIdFromWorldIconPath(ps);
        MCFIXLogOnce(MCFIXLogCatIcon, [NSString stringWithFormat:@"world_stat_miss_%@", worldId ?: @"?"],
                     @"WORLD stat MISS game_path=%@ errno=%d rc=%d world_id=%@",
                     ps, errno, statRc, worldId ?: @"?");
        if (worldId.length) {
            NSString *canon = MCFIXWorldIconCanonicalVFSPath(worldId);
            off_t bytes = canon.length ? MCFIXWorldIconFileBytes(canon) : -1;
            MCFIXLogOnce(MCFIXLogCatIcon,
                         [NSString stringWithFormat:@"world_stat_probe_%@", worldId],
                         @"WORLD stat probe world_id=%@ canonical_bytes=%lld path=%@",
                         worldId, (long long)bytes, canon);
        }
    }
}

void MCFIXLogWorldIconFopenProbe(const char *path, const char *mode, FILE *result,
                                        const char *rawPath) {
    if (path == NULL || mode == NULL || strstr(path, "world_icon") == NULL) {
        return;
    }
    const char *raw = (rawPath != NULL) ? rawPath : path;
    BOOL isWrite = (mode[0] == 'w' || mode[0] == 'a' ||
                    (mode[0] == 'r' && strchr(mode, '+') != NULL));
    if (isWrite) {
        @autoreleasepool {
            NSString *ps = [NSString stringWithUTF8String:path];
            NSString *wid = MCFIXWorldIdFromWorldIconPath(ps);
            off_t bytes = (result != NULL) ? MCFIXWorldIconFileBytes(ps) : -1;
            MCFIXWorldIconTraceUI("posix", "write", "fopen", raw, path,
                                  result != NULL ? 0 : -1, bytes, -1);
            if (result != NULL && wid.length) {
                NSString *bindRaw = [NSString stringWithUTF8String:raw];
                MCFIXWorldIconDualPathSnapshot("SAVE_WRITE", wid, bindRaw);
                MCFIXWorldIconBeginSaveRewriteWindow();
                gMCFIXWorldIconPendingFclose = result;
                strlcpy(gMCFIXWorldIconPendingVfsPath, path, sizeof(gMCFIXWorldIconPendingVfsPath));
            }
        }
        return;
    }
    if (errno == EMFILE || errno == ENFILE) {
        MCFIXLogOnce(MCFIXLogCatIcon, @"world_fopen_emfile",
                     @"WORLD fopen EMFILE errno=%d — no extra icon probes (save may be fd-heavy)",
                     errno);
        return;
    }
    if (result != NULL && mode[0] == 'r') {
        @autoreleasepool {
            NSString *ps = [NSString stringWithUTF8String:path];
            off_t bytes = MCFIXWorldIconFileBytes(ps);
            int jpeg = (bytes >= 256 && gMCFIXWorldIconUITraceN <= 24)
                ? (MCFIXWorldIconJPEGMagicOK(ps) ? 1 : 0)
                : -1;
            MCFIXWorldIconTraceUI("posix", "read", "fopen", raw, path, 0, bytes, jpeg);
            NSString *wid = MCFIXWorldIdFromWorldIconPath(ps);
            if (bytes >= 256) {
                MCFIXLogBump(@"world_icon_ok");
                if (wid.length) {
                    MCFIXWorldIconLogHeaderOnce(wid, ps);
                }
            } else if (bytes == 0) {
                MCFIXLogBump(@"world_jpeg_empty");
            }
        }
        return;
    }
    MCFIXWorldIconTraceUI("posix", "read_miss", "fopen", raw, path, -1, -1, -1);
}
