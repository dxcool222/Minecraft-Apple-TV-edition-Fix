#pragma once

#import <Foundation/Foundation.h>
#import <stdatomic.h>
#import <stdint.h>
#import "MCFIXLog.h"

// File-static globals that cross modules. Defined exactly once in MinecraftStorageFix.m.

typedef struct {
    uint32_t gate1;
    uint32_t gate2;
    uint32_t gate3;
    uint32_t perms;
    uint32_t bootstrap;
    uint32_t queryFinish;
    uint32_t fakeCKOps;
    uint32_t menuWaitLogs;
    uint32_t menuOpenAttempts;
    uint32_t modalBlocked;
    uint32_t loadTickPolls;
} MCFIXDiagCounters;

extern MCFIXDiagCounters gMCFIXDiag;

extern int64_t gMCFIXPendingGatePlatform;
extern int64_t gMCFIXSyncManager;
extern int64_t gMCFIXBootstrapHost;
extern int64_t gMCFIXLastStorageProvider;
extern int64_t gMCFIXDiagPlatform;
extern int64_t gMCFIXAppPlatformApple;
extern BOOL    gMCFIXMenuPresented;
extern int     gMCFIXMenuAttemptGeneration;
extern void   *gOrigCloudKitBootstrap;
extern _Atomic bool gMCFIXBootstrapReady;
/// YES during early boot: MarketplaceDurableCatalog / premium_cache stay on $HOME paths.
extern _Atomic bool gMCFIXMarketplaceVFSPassThrough;

#if MCFIX_PRODUCTION_SILENT

#define MCFIXDiagEnabled() (NO)
#define MCFIXDiagLog(...) ((void)0)
#define MCFIXDiagOnce(key, ...) ((void)0)
#define MCFIXDiagStateChanged(key, fingerprint) (NO)
#define MCFIXDiagRateAllow(key, minInterval) (NO)

#else

BOOL MCFIXDiagEnabled(void);
void MCFIXDiagLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
void MCFIXDiagOnce(NSString *key, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
BOOL MCFIXDiagStateChanged(NSString *key, uint64_t fingerprint);
BOOL MCFIXDiagRateAllow(NSString *key, NSTimeInterval minInterval);

#endif
