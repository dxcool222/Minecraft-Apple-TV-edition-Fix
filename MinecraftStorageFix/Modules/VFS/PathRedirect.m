// Game-storage path redirection.
//
// The Minecraft sideload writes save data to "Library/games" and
// "Documents/games" under NSHomeDirectory(), plus some content roots
// under NSTemporaryDirectory(). Library and Documents are read-only on
// strict tvOS sideload profiles, and tmp/ is purged under storage
// pressure. Every tail listed in MCFIXTailNeedsGameVFSCacheRedirect
// gets remapped into a mirror tree under MCFIXGameDataVFSSandboxRoot()
// (Library/Caches/MinecraftStorageFix/GameData/vfs/<tail>).
//
// The redirection runs from both NSFileManager swizzles (NSURL paths)
// and from the POSIX fishhook layer (C path strings), so it must be
// re-entrant + cheap.
//
// Until gMCFIXBootstrapReady is YES (Phase B migrations finished), redirectable
// tails stay on legacy $HOME paths; POSIX may still re-read via
// MCFIXLegacyPathForRedirectedPath after bootstrap when the VFS mirror misses.
//
// Path normalization handles two quirks:
//   - relative paths from Bedrock's post-chdir code → absolutized via getcwd
//   - kernel-reported /private/var/mobile/... vs NSHomeDirectory's /var/mobile/...
//     (the latter is a symlink to the former on tvOS)

#import "PathRedirect.h"
#import "Bootstrap.h"
#import "MCFIXGameDataVFS.h"
#import "MCFIXLog.h"
#import "MCFIXBypass.h"
#import "../Internal/MCFIXPosixOrigs.h"
#import "../Internal/MCFIXState.h"
#import "../Log/MCFIXCrashTrace.h"
#import <stdatomic.h>
#import "../Marketplace/MCFIXMarketplaceIdentity.h"

#import <limits.h>
#import <sys/stat.h>
#import <unistd.h>

/// FTP (port 2121) and HTTP handlers set MCFIX_BypassHooks on the worker thread so
/// NSFileManager swizzles still reach here; skip .ent rewrite/generation to avoid loops.
static BOOL MCFIXPathRedirectSkipsEntitlementCanonicalize(void) {
    return MCFIXBypassHooksActive();
}

static NSString *gMCFIXCachedHomeStd = nil;
static NSString *gMCFIXCachedHomeMatch = nil;
static NSUInteger gMCFIXCachedHomeMatchLen = 0;
static NSString *gMCFIXCachedVfsRoot = nil;
static char gMCFIXCachedVfsRootUTF8[PATH_MAX];
static dispatch_once_t gMCFIXPathCacheOnce;
static NSArray<NSString *> *gMCFIXCachedWorldsVFSDirs = nil;

void MCFIXWarmPathRedirectCaches(void) {
    dispatch_once(&gMCFIXPathCacheOnce, ^{
        gMCFIXCachedHomeStd = [[NSHomeDirectory() stringByStandardizingPath] copy];
        gMCFIXCachedHomeMatch = gMCFIXCachedHomeStd;
        if ([gMCFIXCachedHomeStd hasPrefix:@"/private/"]) {
            gMCFIXCachedHomeMatch = [gMCFIXCachedHomeStd substringFromIndex:8];
        }
        gMCFIXCachedHomeMatchLen = gMCFIXCachedHomeMatch.length;
        gMCFIXCachedVfsRoot = [MCFIXGameDataVFSSandboxRoot() copy];
        if (![gMCFIXCachedVfsRoot getFileSystemRepresentation:gMCFIXCachedVfsRootUTF8
                                                    maxLength:sizeof(gMCFIXCachedVfsRootUTF8)]) {
            const char *u8 = gMCFIXCachedVfsRoot.UTF8String;
            if (u8) {
                (void)snprintf(gMCFIXCachedVfsRootUTF8, sizeof(gMCFIXCachedVfsRootUTF8), "%s", u8);
            } else {
                gMCFIXCachedVfsRootUTF8[0] = '\0';
            }
        }
        NSArray<NSString *> *tails = @[
            @"Library/games/com.mojang/minecraftWorlds",
            @"Documents/games/com.mojang/minecraftWorlds",
            @"tmp/Temp/games/com.mojang/minecraftWorlds",
            @"tmp/minecraftpe/games/com.mojang/minecraftWorlds",
        ];
        NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:tails.count];
        for (NSString *t in tails) {
            [out addObject:[[gMCFIXCachedVfsRoot stringByAppendingPathComponent:t] stringByStandardizingPath]];
        }
        gMCFIXCachedWorldsVFSDirs = [out copy];
    });
}

NSString *MCFIXCachedHomeForPathMatch(void) {
    MCFIXWarmPathRedirectCaches();
    return gMCFIXCachedHomeMatch;
}

NSString *MCFIXCachedHomeStandardized(void) {
    MCFIXWarmPathRedirectCaches();
    return gMCFIXCachedHomeStd;
}

const char *MCFIXCachedVFSRootUTF8(void) {
    MCFIXWarmPathRedirectCaches();
    return gMCFIXCachedVfsRootUTF8[0] ? gMCFIXCachedVfsRootUTF8 : NULL;
}

BOOL MCFIXBootstrapReady(void) {
    return atomic_load(&gMCFIXBootstrapReady);
}

NSString *MCFIXLegacyPathForRedirectedPath(NSString *redirected) {
    if (redirected.length == 0) {
        return nil;
    }
    MCFIXWarmPathRedirectCaches();
    NSString *std = redirected;
    if ([redirected rangeOfString:@"//"].location != NSNotFound || [redirected hasSuffix:@"/"]) {
        std = [redirected stringByStandardizingPath];
    }
    if (![std hasPrefix:gMCFIXCachedVfsRoot]) {
        return nil;
    }
    NSString *tail = [std substringFromIndex:gMCFIXCachedVfsRoot.length];
    if ([tail hasPrefix:@"/"]) {
        tail = [tail substringFromIndex:1];
    }
    if (tail.length == 0) {
        return nil;
    }
    return [[gMCFIXCachedHomeStd stringByAppendingPathComponent:tail] stringByStandardizingPath];
}

NSArray<NSString *> *MCFIXMinecraftWorldsVFSDirectoryPaths(void) {
    MCFIXWarmPathRedirectCaches();
    return gMCFIXCachedWorldsVFSDirs ?: @[];
}

BOOL MCFIXStringIsAbsolutePOSIXPath(NSString *s) {
    if (s.length == 0) return NO;
    return [s hasPrefix:@"/"];
}

BOOL MCFIXTailNeedsGameVFSCacheRedirect(NSString *tail) {
    if (tail.length == 0) return NO;
    static NSArray<NSString *> *prefixes;
    static dispatch_once_t ponce;
    dispatch_once(&ponce, ^{
        prefixes = @[
            @"Library/games",
            @"Documents/games",
            @"tmp/Temp/games",
            @"tmp/Temp/internal",
            @"tmp/minecraftpe",
            @"tmp/XBLStoage.json",
        ];
    });
    for (NSString *pre in prefixes) {
        if ([tail isEqualToString:pre]) return YES;
        if ([tail hasPrefix:pre] && tail.length > pre.length &&
            [tail characterAtIndex:pre.length] == (unichar)'/') {
            return YES;
        }
    }
    return NO;
}

BOOL MCFIXTailIsWorldIconFile(NSString *tail) {
    if (tail.length == 0) return NO;
    return [tail hasSuffix:@"world_icon.jpeg"] ||
           [tail containsString:@"/world_icon.jpeg"];
}

BOOL MCFIXTailIsAchievementIconPath(NSString *tail) {
    if (tail.length == 0) return NO;
    static NSString *const kPrefix = @"tmp/minecraftpe/AchievementIcons";
    if ([tail isEqualToString:kPrefix]) return YES;
    return ([tail hasPrefix:kPrefix] && tail.length > kPrefix.length &&
            [tail characterAtIndex:kPrefix.length] == (unichar)'/');
}

static BOOL MCFIXPathHasEntitlementBasename(NSString *path, NSString **outBasename) {
    if (path.length == 0) {
        return NO;
    }
    NSString *base = path.lastPathComponent;
    if (![base.pathExtension isEqualToString:@"ent"]) {
        return NO;
    }
    if (outBasename) {
        *outBasename = base;
    }
    return YES;
}

NSString *MCFIXCanonicalizeEntitlementStoragePath(NSString *path) {
    return path;
}

BOOL MCFIXIsMarketplaceCleanupPath(NSString *path) {
    if (path.length == 0) {
        return NO;
    }
    if ([path containsString:@"MarketplaceDurableCatalog"] ||
        [path containsString:@"catalog_info.json"]) {
        return YES;
    }
    if ([path containsString:@"/skin_packs"] ||
        [path.lastPathComponent isEqualToString:@"skin_packs"]) {
        return YES;
    }
    return NO;
}

void MCFIXHotSeedRuntimeEntitlementsForPOSIXPath(const char *resolvedPath) {
    (void)resolvedPath;
}

BOOL MCFIXShouldBlockProductionEntitlementDelete(NSString *path) {
    (void)path;
    return NO;
}

BOOL MCFIXPathIsContainerGameDataForDiag(NSString *path) {
    if (path.length == 0) return NO;
    if ([path containsString:@".app/"] || [path containsString:@"Bundle/Application"]) return NO;
    return ([path containsString:@"com.mojang"] ||
            [path containsString:@"minecraftpe/"] ||
            [path containsString:@"minecraftWorlds"] ||
            [path containsString:@"AchievementIcons"] ||
            [path containsString:@"tmp/Temp/games"] ||
            [path containsString:@"level.dat"] ||
            [path containsString:@"catalog_info"] ||
            [path containsString:@"MarketplaceDurableCatalog"]);
}

NSString *MCFIXPathByRedirectingGameStorage(NSString *path) {
    if (path.length == 0) return path;

    MCFIXWarmPathRedirectCaches();

    NSString *std = path;
    BOOL needsStandardize = ([path rangeOfString:@"//"].location != NSNotFound ||
                             [path hasSuffix:@"/"] ||
                             ![path hasPrefix:@"/"]);
    if (needsStandardize) {
        std = [path stringByStandardizingPath];
    }
    if (!MCFIXStringIsAbsolutePOSIXPath(std)) {
        char cwd[PATH_MAX];
        if (getcwd(cwd, sizeof(cwd)) != NULL) {
            NSString *cwdStr = [NSString stringWithUTF8String:cwd];
            if (cwdStr != nil) {
                std = [[cwdStr stringByAppendingPathComponent:std] stringByStandardizingPath];
            }
        }
    }

    NSString *homeForMatch = gMCFIXCachedHomeMatch;
    if (gMCFIXCachedHomeMatchLen == 0) {
        return MCFIXCanonicalizeEntitlementStoragePath(path);
    }

    if ([std hasPrefix:@"/private/"] && ![gMCFIXCachedHomeStd hasPrefix:@"/private/"]) {
        homeForMatch = [@"/private" stringByAppendingString:gMCFIXCachedHomeStd];
    } else if (![std hasPrefix:@"/private/"] && [gMCFIXCachedHomeStd hasPrefix:@"/private/"]) {
        homeForMatch = gMCFIXCachedHomeMatch;
    }

    NSUInteger homeLen = homeForMatch.length;
    if (homeLen == 0 || std.length < homeLen) {
        if (MCFIXPathIsContainerGameDataForDiag(path)) {
            MCFIXLogRedirectMiss(path, gMCFIXCachedHomeStd, std);
        }
        return MCFIXCanonicalizeEntitlementStoragePath(path);
    }

    NSString *tail = nil;
    if ([std isEqualToString:homeForMatch]) {
        tail = @"";
    } else if (std.length == homeLen + 1) {
        unichar c = [std characterAtIndex:homeLen];
        if (c == (unichar)'/') {
            tail = [std substringFromIndex:homeLen + 1];
        } else {
            return MCFIXCanonicalizeEntitlementStoragePath(path);
        }
    } else if ([std hasPrefix:homeForMatch] && std.length > homeLen &&
               [std characterAtIndex:homeLen] == (unichar)'/') {
        tail = [std substringFromIndex:homeLen + 1];
    } else {
        if (MCFIXPathIsContainerGameDataForDiag(path)) {
            MCFIXLogRedirectMiss(path, gMCFIXCachedHomeStd, std);
        }
        return MCFIXCanonicalizeEntitlementStoragePath(path);
    }

    if (!MCFIXTailNeedsGameVFSCacheRedirect(tail)) {
        if (!MCFIXStringIsAbsolutePOSIXPath(path)) {
            return MCFIXCanonicalizeEntitlementStoragePath(std);
        }
        return MCFIXCanonicalizeEntitlementStoragePath(path);
    }
    if (MCFIXTailIsAchievementIconPath(tail)) {
        MCFIXLogOnce(MCFIXLogCatVFS, @"ach_redirect_skip",
                     @"ACH redirect=skip in=%@ out=%@ tail=%@",
                     std, std, tail);
        if (!MCFIXStringIsAbsolutePOSIXPath(path)) return std;
        return MCFIXCanonicalizeEntitlementStoragePath(path);
    }

    // Phase B still running: keep I/O on legacy $HOME until migrations finish.
    if (!atomic_load(&gMCFIXBootstrapReady)) {
        NSString *preBootstrap = MCFIXStringIsAbsolutePOSIXPath(path) ? std : path;
        return MCFIXCanonicalizeEntitlementStoragePath(preBootstrap);
    }

    // tmp/Temp/games/com.mojang (MarketplaceDurableCatalog, premium_cache, manifests):
    // always redirect into GameData/vfs so stat/open/fopen share one tree (IDA sub_100797F30
    // uses POSIX stat+opendir; sub_1008546E8 reads via C++ stream sized from entry+24).

    NSString *redirected = [[gMCFIXCachedVfsRoot stringByAppendingPathComponent:tail]
        stringByStandardizingPath];

    const char *pUTF8 = path.UTF8String;
    const char *tUTF8 = tail.UTF8String;
    if (pUTF8 && tUTF8 && (
            strstr(tUTF8, "tmp/Temp/games") ||
            strstr(pUTF8, "minecraftWorlds") ||
            strstr(pUTF8, "level.dat") ||
            strstr(pUTF8, "MANIFEST") ||
            strstr(pUTF8, "CURRENT") ||
            strstr(pUTF8, "world_icon") ||
            strstr(pUTF8, "catalog_info") ||
            strstr(pUTF8, "skin_packs") ||
            strstr(pUTF8, "options.txt") ||
            strstr(pUTF8, "MarketplaceDurableCatalog") ||
            strstr(pUTF8, ".ent"))) {
        MCFIXLogRedirect(path, redirected);
    }
    if ([tail containsString:@"MarketplaceDurableCatalog"] ||
        [tail containsString:@"premium_cache"] ||
        [tail containsString:@"catalog_info.json"]) {
        MCFIXCrashTrace(@"path vfs_redirect marketplace in=%@ out=%@", path, redirected);
    }
    return MCFIXCanonicalizeEntitlementStoragePath(redirected);
}

NSURL *MCFIXFileURLByRedirectingGameStorage(NSURL *url) {
    if (![url isFileURL]) return url;
    NSString *p = MCFIXPathByRedirectingGameStorage(url.path);
    if ([p isEqualToString:url.path] || p.length == 0) return url;
    return [NSURL fileURLWithPath:p];
}
