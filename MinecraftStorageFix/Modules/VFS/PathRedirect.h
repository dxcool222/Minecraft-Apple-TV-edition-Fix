#pragma once

#import <Foundation/Foundation.h>

// Path / URL redirection for the game's "Library/games", "Documents/games",
// "tmp/Temp/games", "tmp/minecraftpe", and "tmp/XBLStoage.json" tails.
// Resolves anything under those tails to a mirror tree under
// MCFIXGameDataVFSSandboxRoot() (Library/Caches/MinecraftStorageFix/GameData/vfs).
//
// World-icon and AchievementIcon tails are explicitly EXCLUDED — handled
// elsewhere — so the icon mirroring layer can manage them independently.

NSString *MCFIXPathByRedirectingGameStorage(NSString *path);
NSURL    *MCFIXFileURLByRedirectingGameStorage(NSURL *url);

BOOL MCFIXTailNeedsGameVFSCacheRedirect(NSString *tail);
BOOL MCFIXTailIsWorldIconFile(NSString *tail);
BOOL MCFIXTailIsAchievementIconPath(NSString *tail);
BOOL MCFIXStringIsAbsolutePOSIXPath(NSString *s);
BOOL MCFIXPathIsContainerGameDataForDiag(NSString *path);

NSArray<NSString *> *MCFIXMinecraftWorldsVFSDirectoryPaths(void);

/// Precomputes home/vfs match strings (call after VFS root exists, e.g. from +load Phase A).
void MCFIXWarmPathRedirectCaches(void);
NSString *MCFIXCachedHomeForPathMatch(void);
NSString *MCFIXCachedHomeStandardized(void);
const char *MCFIXCachedVFSRootUTF8(void);
BOOL MCFIXBootstrapReady(void);

/// Maps a VFS mirror path back to the legacy $HOME container path (inverse of vfs redirect).
NSString *MCFIXLegacyPathForRedirectedPath(NSString *redirected);

/// IDA sub_10066F2DC: `{storageRoot}/{hash(identity)}.ent`. Rewrites non-`0.ent` access to the
/// active profile hash; preserves `0.ent` for blank identity. Skipped when MCFIX_BypassHooks (FTP/HTTP).
NSString *MCFIXCanonicalizeEntitlementStoragePath(NSString *path);

/// Block unlink/remove targeting the active-profile entitlement file on disk.
BOOL MCFIXShouldBlockProductionEntitlementDelete(NSString *path);

/// Synchronous dual `.ent` seed under `tmp/Temp/games/com.mojang` before marketplace scans (POSIX hot path).
void MCFIXHotSeedRuntimeEntitlementsForPOSIXPath(const char *resolvedPath);

/// Marketplace paths that must never be deleted (POSIX + NSFileManager).
BOOL MCFIXIsMarketplaceCleanupPath(NSString *path);
