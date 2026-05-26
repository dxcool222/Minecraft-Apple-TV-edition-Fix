//
//  MCFIXLog.m — compiled only when MCFIX_PRODUCTION_SILENT=0
//

#import "MCFIXLog.h"

#if !MCFIX_PRODUCTION_SILENT

#import <os/lock.h>
#import <stdarg.h>
#import <string.h>

static const char *MCFIXLogTagForCategory(MCFIXLogCategory category) {
    if (category & MCFIXLogCatError) {
        return "Err";
    }
    if (category & MCFIXLogCatBoot) {
        return "Boot";
    }
    if (category & MCFIXLogCatVFS) {
        return "VFS";
    }
    if (category & MCFIXLogCatIcon) {
        return "Icon";
    }
    if (category & MCFIXLogCatVFSTrace) {
        return "Trace";
    }
    if (category & MCFIXLogCatFSGuard) {
        return "Guard";
    }
    if (category & MCFIXLogCatFSMiss) {
        return "Miss";
    }
    if (category & MCFIXLogCatCK) {
        return "CK";
    }
    if (category & MCFIXLogCatXBL) {
        return "XBL";
    }
    return "Log";
}

static uint32_t gMCFIXLogMask;
static dispatch_once_t gMCFIXLogMaskOnce;
static os_unfair_lock gMCFIXLogLock = OS_UNFAIR_LOCK_INIT;
static NSMutableSet<NSString *> *gMCFIXLogOnceKeys;
static NSMutableDictionary<NSString *, NSDate *> *gMCFIXLogRateTimes;
static NSMutableDictionary<NSString *, NSNumber *> *gMCFIXLogCounters;

static void MCFIXLogInitTables(void) {
    dispatch_once(&gMCFIXLogMaskOnce, ^{
        gMCFIXLogOnceKeys = [NSMutableSet set];
        gMCFIXLogRateTimes = [NSMutableDictionary dictionary];
        gMCFIXLogCounters = [NSMutableDictionary dictionary];
        uint32_t mask = MCFIX_LOG_DEFAULT_MASK;
        NSNumber *maskNum = [NSUserDefaults.standardUserDefaults objectForKey:@"MCFIXLogMask"];
        if (maskNum != nil) {
            mask = maskNum.unsignedIntValue;
        }
        gMCFIXLogMask = mask;
    });
}

uint32_t MCFIXLogEffectiveMask(void) {
    MCFIXLogInitTables();
    return gMCFIXLogMask;
}

BOOL MCFIXLogIsEnabled(MCFIXLogCategory category) {
    if (category == MCFIXLogCatNone) {
        return NO;
    }
    return (MCFIXLogEffectiveMask() & category) != 0;
}

static void MCFIXLogEmit(MCFIXLogCategory category, NSString *body) {
    NSLog(@"[MCFIX %s] %@", MCFIXLogTagForCategory(category), body);
}

void MCFIXLog(MCFIXLogCategory category, NSString *fmt, ...) {
    if (!MCFIXLogIsEnabled(category)) {
        return;
    }
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    MCFIXLogEmit(category, body);
}

void MCFIXLogOnce(MCFIXLogCategory category, NSString *key, NSString *fmt, ...) {
    if (!MCFIXLogIsEnabled(category) || key.length == 0) {
        return;
    }
    MCFIXLogInitTables();
    NSString *compound = [NSString stringWithFormat:@"%u:%@", (unsigned)category, key];
    os_unfair_lock_lock(&gMCFIXLogLock);
    if ([gMCFIXLogOnceKeys containsObject:compound]) {
        os_unfair_lock_unlock(&gMCFIXLogLock);
        return;
    }
    [gMCFIXLogOnceKeys addObject:compound];
    os_unfair_lock_unlock(&gMCFIXLogLock);

    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    MCFIXLogEmit(category, body);
}

void MCFIXLogRate(MCFIXLogCategory category, NSString *key, NSTimeInterval minInterval, NSString *fmt, ...) {
    if (!MCFIXLogIsEnabled(category) || key.length == 0) {
        return;
    }
    MCFIXLogInitTables();
    NSDate *now = [NSDate date];
    os_unfair_lock_lock(&gMCFIXLogLock);
    NSDate *prev = gMCFIXLogRateTimes[key];
    if (prev && [now timeIntervalSinceDate:prev] < minInterval) {
        os_unfair_lock_unlock(&gMCFIXLogLock);
        return;
    }
    gMCFIXLogRateTimes[key] = now;
    os_unfair_lock_unlock(&gMCFIXLogLock);

    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    MCFIXLogEmit(category, body);
}

void MCFIXLogBump(NSString *counterKey) {
    if (counterKey.length == 0) {
        return;
    }
    MCFIXLogInitTables();
    os_unfair_lock_lock(&gMCFIXLogLock);
    NSUInteger n = gMCFIXLogCounters[counterKey].unsignedIntegerValue + 1;
    gMCFIXLogCounters[counterKey] = @(n);
    os_unfair_lock_unlock(&gMCFIXLogLock);
}

NSUInteger MCFIXLogCounter(NSString *counterKey) {
    MCFIXLogInitTables();
    os_unfair_lock_lock(&gMCFIXLogLock);
    NSUInteger n = gMCFIXLogCounters[counterKey].unsignedIntegerValue;
    os_unfair_lock_unlock(&gMCFIXLogLock);
    return n;
}

static NSString *MCFIXLogRedirectTailKey(NSString *path) {
    if (path.length == 0) {
        return @"?";
    }
    static NSArray<NSString *> *kMarkers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kMarkers = @[
            @"AchievementIcons/",
            @"world_icon",
            @"minecraftWorlds/",
            @"level.dat",
            @"catalog_info",
            @"MarketplaceDurableCatalog",
            @"tmp/Temp/games",
            @"tmp/minecraftpe",
        ];
    });
    for (NSString *m in kMarkers) {
        NSRange r = [path rangeOfString:m];
        if (r.location != NSNotFound) {
            return m;
        }
    }
    return @"other";
}

void MCFIXLogRedirect(NSString *path, NSString *redirected) {
    MCFIXLogBump(@"redirect_total");
    NSString *tailKey = MCFIXLogRedirectTailKey(path ?: @"");
    if ([tailKey isEqualToString:@"world_icon"] ||
        [tailKey isEqualToString:@"AchievementIcons/"]) {
        NSString *redKey = [NSString stringWithFormat:@"icon_redir_%@_%@", tailKey, redirected ?: @"?"];
        MCFIXLogRate(MCFIXLogCatIcon, redKey, 2.0,
                     @"ICON redirect [%@] in=%@ out=%@", tailKey, path, redirected);
    }
    if (!MCFIXLogIsEnabled(MCFIXLogCatVFSTrace)) {
        return;
    }
    MCFIXLogOnce(MCFIXLogCatVFSTrace,
                 [NSString stringWithFormat:@"redir_%@", tailKey],
                 @"redirect [%@] %@ -> %@",
                 tailKey, path, redirected);
}

void MCFIXLogRedirectMiss(NSString *path, NSString *home, NSString *stdPath) {
    MCFIXLogBump(@"redirect_miss");
    NSString *key = stdPath.length ? stdPath : (path ?: @"?");
    MCFIXLogCategory cat = MCFIXLogCatFSMiss;
    if ([path containsString:@"level.dat"] || [path containsString:@"minecraftWorlds"]) {
        cat = MCFIXLogCatError;
    }
    MCFIXLogOnce(cat, [NSString stringWithFormat:@"redir_miss_%@", key],
                 @"REDIRECT MISS path=%@ home=%@ std=%@", path, home, stdPath);
}

void MCFIXLogIconAccess(const char *resolvedPath, int accessResult) {
    if (resolvedPath == NULL) {
        return;
    }
    BOOL isWorld = (strstr(resolvedPath, "world_icon") != NULL);
    BOOL isAch = (strstr(resolvedPath, "AchievementIcons") != NULL);
    if (!isWorld && !isAch) {
        return;
    }
    if (accessResult == 0) {
        MCFIXLogBump(isWorld ? @"world_icon_ok" : @"ach_icon_ok");
        return;
    }
    MCFIXLogBump(isWorld ? @"world_icon_miss" : @"ach_icon_miss");
    if (!MCFIXLogIsEnabled(MCFIXLogCatIcon)) {
        return;
    }
    NSString *key = [NSString stringWithUTF8String:resolvedPath];
    NSString *tag = isWorld ? @"world_icon" : @"achievement";
    MCFIXLogOnce(MCFIXLogCatIcon, [NSString stringWithFormat:@"%@_miss_%@", tag, key],
                 @"%@ access MISS path=%s errno=%d", tag, resolvedPath, errno);
}

void MCFIXLogEmitBootBanner(void) {
    BOOL trace = (MCFIXLogEffectiveMask() & MCFIX_LOG_TRACE_MASK) != 0;
    MCFIXLogOnce(MCFIXLogCatBoot, @"banner",
                 @"logging always on (mask=0x%x) — Console filter: MCFIX | "
                 @"WORLD icon only (inventory/restore/jpeg); redirects=%@",
                 MCFIXLogEffectiveMask(),
                 trace ? @"per-path Trace ON (noisy)" : @"counted in SUMMARY only");
}

void MCFIXLogEmitSessionSummary(NSString *trigger) {
    if (!MCFIXLogIsEnabled(MCFIXLogCatBoot) && !MCFIXLogIsEnabled(MCFIXLogCatCK)) {
        return;
    }
    NSString *body = [NSString stringWithFormat:
        @"SUMMARY (%@) redirects=%lu redirect_miss=%lu fopen_miss=%lu "
        @"world ok=%lu miss=%lu jpeg_valid=%lu jpeg_empty=%lu | achievement ok=%lu miss=%lu",
        trigger ?: @"?",
        (unsigned long)MCFIXLogCounter(@"redirect_total"),
        (unsigned long)MCFIXLogCounter(@"redirect_miss"),
        (unsigned long)MCFIXLogCounter(@"fopen_miss"),
        (unsigned long)MCFIXLogCounter(@"world_icon_ok"),
        (unsigned long)MCFIXLogCounter(@"world_icon_miss"),
        (unsigned long)MCFIXLogCounter(@"world_jpeg_valid"),
        (unsigned long)MCFIXLogCounter(@"world_jpeg_empty"),
        (unsigned long)MCFIXLogCounter(@"ach_icon_ok"),
        (unsigned long)MCFIXLogCounter(@"ach_icon_miss")];
    if (MCFIXLogIsEnabled(MCFIXLogCatCK)) {
        MCFIXLog(MCFIXLogCatCK, @"%@", body);
    } else {
        MCFIXLog(MCFIXLogCatBoot, @"%@", body);
    }
}

#endif
