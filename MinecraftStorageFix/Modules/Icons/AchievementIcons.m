// Achievement-icon seeding + bidirectional VFS sync.
//
// Bundle ships UI chrome PNGs under .app/data/resource_packs/.../achievements;
// hashed per-achievement PNGs only ever come from Xbox Live (offline →
// they never arrive). Seeding the chrome into both
// $HOME/tmp/minecraftpe/AchievementIcons and the VFS mirror covers the
// achievements screen placeholder rendering and gives the FTP user a
// consistent view from either side.

#import "AchievementIcons.h"
#import "MCFIXBypass.h"
#import "MCFIXGameDataVFS.h"
#import "MCFIXLog.h"

#import <errno.h>
#import <string.h>

void MCFIXSeedAchievementIconsFromBundle(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static NSString *const kBundleAchievements =
            @"data/resource_packs/vanilla/textures/gui/achievements";
        static NSString *const kRelAchievementIcons = @"tmp/minecraftpe/AchievementIcons";

        NSString *srcRoot = [[[NSBundle mainBundle] bundlePath]
            stringByAppendingPathComponent:kBundleAchievements];
        NSString *dstRoot = [[[NSHomeDirectory() stringByStandardizingPath]
            stringByAppendingPathComponent:kRelAchievementIcons] stringByStandardizingPath];

        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:srcRoot isDirectory:&isDir] || !isDir) {
            MCFIXLogOnce(MCFIXLogCatError, @"ach_bundle_missing",
                         @"achievement bundle missing: %@", kBundleAchievements);
            return;
        }

        BOOL prevBypass = MCFIXBypassHooksActive();
        MCFIXBypassHooksSet(YES);
        [fm createDirectoryAtPath:dstRoot withIntermediateDirectories:YES attributes:nil error:nil];

        NSDirectoryEnumerator *en = [fm enumeratorAtPath:srcRoot];
        NSString *rel = nil;
        NSUInteger copied = 0;
        while ((rel = [en nextObject])) {
            if (rel.length == 0 || [rel containsString:@".."]) continue;
            if ([rel.pathExtension caseInsensitiveCompare:@"png"] != NSOrderedSame) continue;
            NSString *srcFile = [srcRoot stringByAppendingPathComponent:rel];
            BOOL fileIsDir = NO;
            if (![fm fileExistsAtPath:srcFile isDirectory:&fileIsDir] || fileIsDir) continue;
            NSString *baseName = rel.lastPathComponent;
            if (baseName.length == 0) continue;
            NSString *dstFile = [dstRoot stringByAppendingPathComponent:baseName];
            if ([fm fileExistsAtPath:dstFile]) continue;
            if ([fm copyItemAtPath:srcFile toPath:dstFile error:nil]) copied++;
        }
        MCFIXBypassHooksSet(prevBypass);
        if (copied > 0) {
            MCFIXLogOnce(MCFIXLogCatVFS, @"ach_icons_seed",
                         @"seeded %lu achievement UI chrome PNGs -> container %@ (hashed icons need Xbox)",
                         (unsigned long)copied, kRelAchievementIcons);
        }
    });
}

static void MCFIXAchievementDirStats(NSString *dir, BOOL *outExists, NSUInteger *outPngTotal,
                                     NSUInteger *outPngHashed) {
    if (outExists)    *outExists = NO;
    if (outPngTotal)  *outPngTotal = 0;
    if (outPngHashed) *outPngHashed = 0;
    if (dir.length == 0) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) return;
    if (outExists) *outExists = YES;

    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
    NSCharacterSet *inverted = [hex invertedSet];
    for (NSString *name in [fm contentsOfDirectoryAtPath:dir error:nil]) {
        if (![name.pathExtension isEqualToString:@"png"]) continue;
        if (outPngTotal) (*outPngTotal)++;
        NSString *stem = [name stringByDeletingPathExtension];
        if (outPngHashed && stem.length >= 8 &&
            [stem rangeOfCharacterFromSet:inverted].location == NSNotFound) {
            (*outPngHashed)++;
        }
    }
}

static NSArray<NSDictionary<NSString *, NSString *> *> *MCFIXAchievementIconCandidateDirs(void) {
    static NSArray<NSDictionary<NSString *, NSString *> *> *dirs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *home = [NSHomeDirectory() stringByStandardizingPath];
        NSString *vfs  = [MCFIXGameDataVFSSandboxRoot() stringByStandardizingPath];
        NSString *nstd = [NSTemporaryDirectory() stringByStandardizingPath];
        dirs = @[
            @{@"label": @"NSHomeDirectory+tmp/minecraftpe/AchievementIcons",
              @"path": [[home stringByAppendingPathComponent:@"tmp/minecraftpe/AchievementIcons"]
                  stringByStandardizingPath]},
            @{@"label": @"VFS+tmp/minecraftpe/AchievementIcons",
              @"path": [[vfs stringByAppendingPathComponent:@"tmp/minecraftpe/AchievementIcons"]
                  stringByStandardizingPath]},
            @{@"label": @"NSTemporaryDirectory+minecraftpe/AchievementIcons",
              @"path": [[nstd stringByAppendingPathComponent:@"minecraftpe/AchievementIcons"]
                  stringByStandardizingPath]},
            @{@"label": @"NSTemporaryDirectory+tmp/minecraftpe/AchievementIcons",
              @"path": [[nstd stringByAppendingPathComponent:@"tmp/minecraftpe/AchievementIcons"]
                  stringByStandardizingPath]},
        ];
    });
    return dirs;
}

void MCFIXLogAchievementIconBootProbe(void) {
    NSString *home = [NSHomeDirectory() stringByStandardizingPath];
    NSString *nstd = [NSTemporaryDirectory() stringByStandardizingPath];
    MCFIXLog(MCFIXLogCatIcon, @"ACH boot NSHomeDirectory=%@", home);
    MCFIXLog(MCFIXLogCatIcon, @"ACH boot NSTemporaryDirectory=%@", nstd);
    for (NSDictionary<NSString *, NSString *> *entry in MCFIXAchievementIconCandidateDirs()) {
        NSString *label = entry[@"label"];
        NSString *path  = entry[@"path"];
        BOOL exists = NO;
        NSUInteger pngTotal = 0, pngHashed = 0;
        MCFIXAchievementDirStats(path, &exists, &pngTotal, &pngHashed);
        MCFIXLog(MCFIXLogCatIcon,
                 @"ACH dirs boot label=%@ path=%@ exists=%d png_total=%lu png_hashed=%lu",
                 label, path, exists ? 1 : 0, (unsigned long)pngTotal, (unsigned long)pngHashed);
    }
}

void MCFIXLogAchievementAccessProbe(const char *resolvedPath, int accessRc) {
    if (resolvedPath == NULL) return;
    @autoreleasepool {
        NSString *ps = [NSString stringWithUTF8String:resolvedPath];
        NSString *file = ps.lastPathComponent;
        MCFIXLogOnce(MCFIXLogCatIcon, @"ach_access_miss",
                     @"ACH access MISS game_path=%@ errno=%d rc=%d file=%@",
                     ps, errno, accessRc, file);
        if (file.length == 0) return;
        NSMutableString *probe = [NSMutableString stringWithFormat:@"ACH probe file=%@ ", file];
        for (NSDictionary<NSString *, NSString *> *entry in MCFIXAchievementIconCandidateDirs()) {
            NSString *label = entry[@"label"];
            NSString *candidate = [entry[@"path"] stringByAppendingPathComponent:file];
            BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:candidate];
            [probe appendFormat:@"%@=%d ", label, exists ? 1 : 0];
        }
        MCFIXLogOnce(MCFIXLogCatIcon, [NSString stringWithFormat:@"ach_probe_%@", file], @"%@", probe);
    }
}

void MCFIXLogAchievementFopenProbe(const char *path, const char *mode, FILE *result) {
    if (path == NULL || mode == NULL || strstr(path, "AchievementIcons/") == NULL) return;
    BOOL isWrite = (mode[0] == 'w' || mode[0] == 'a' ||
                    (mode[0] == 'r' && strchr(mode, '+') != NULL));
    if (!isWrite) {
        if (result == NULL) {
            @autoreleasepool {
                NSString *ps = [NSString stringWithUTF8String:path];
                MCFIXLogOnce(MCFIXLogCatIcon,
                             [NSString stringWithFormat:@"ach_fopen_miss_%@", ps.lastPathComponent],
                             @"ACH fopen read MISS path=%s mode=%s errno=%d", path, mode, errno);
            }
        }
        return;
    }
    MCFIXLogOnce(MCFIXLogCatIcon, @"ach_fopen_write",
                 @"ACH fopen write path=%s mode=%s ok=%d errno=%d",
                 path, mode, result != NULL ? 1 : 0, errno);
}

NSUInteger MCFIXSyncAchievementIconsBidirectional(void) {
    static NSString *const kRel = @"tmp/minecraftpe/AchievementIcons";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *home = [NSHomeDirectory() stringByStandardizingPath];
    NSString *vfs  = MCFIXGameDataVFSSandboxRoot();
    NSString *legDir = [[home stringByAppendingPathComponent:kRel] stringByStandardizingPath];
    NSString *vfsDir = [[vfs  stringByAppendingPathComponent:kRel] stringByStandardizingPath];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:legDir isDirectory:&isDir] || !isDir) {
        [fm createDirectoryAtPath:legDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    [fm createDirectoryAtPath:vfsDir withIntermediateDirectories:YES attributes:nil error:nil];

    BOOL prevBypass = MCFIXBypassHooksActive();
    MCFIXBypassHooksSet(YES);
    __block NSUInteger copied = 0;
    void (^copyMissing)(NSString *, NSString *) = ^(NSString *srcDir, NSString *dstDir) {
        for (NSString *name in [fm contentsOfDirectoryAtPath:srcDir error:nil]) {
            if (![name.pathExtension isEqualToString:@"png"]) continue;
            NSString *src = [srcDir stringByAppendingPathComponent:name];
            NSString *dst = [dstDir stringByAppendingPathComponent:name];
            if ([fm fileExistsAtPath:dst]) continue;
            if ([fm copyItemAtPath:src toPath:dst error:nil]) copied++;
        }
    };
    copyMissing(legDir, vfsDir);
    copyMissing(vfsDir, legDir);
    MCFIXBypassHooksSet(prevBypass);
    if (copied > 0) {
        MCFIXLogOnce(MCFIXLogCatVFS, @"ach_icons_bidir",
                     @"ACH sync copied=%lu from=%@ to=%@ (bidirectional)",
                     (unsigned long)copied, legDir, vfsDir);
    }
    return copied;
}
