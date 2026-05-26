#pragma once

#import <Foundation/Foundation.h>

// VFS sandbox bootstrap.
//
// Sets up the redirect tree under Library/Caches/MinecraftStorageFix/, seeds
// engine config files into it, migrates legacy save state from previous
// install paths, and primes the achievement / world-icon trace logs.
//
// MCFIXInstallVFSSandboxLayers is the one-shot install called from +load.

void MCFIXInstallVFSSandboxLayers(void);
void MCFIXEnsureMinecraftSavesAndMigrateFromTempIfNeeded(void);
void MCFIXMigrateRealGameStorageToVFS(void);
void MCFIXSyncBidirectionalSkinAndPrefs(void);

/// Active profile identity for item+88 / .ent (live capture → validated defaults → offline).
NSString *MCFIXActiveProfileIdentity(void);

/// Receipt `ownerId` written into Inventory items for the given profile (`@""` for `0.ent`).
NSString *MCFIXReceiptOwnerIdForEntitlementProfile(NSString *activeXUID);

/// Drop cached `.ent` owner so the next fopen/stat path regenerates for a new XUID.
void MCFIXInvalidateEntitlementOwnerCache(void);

/// YES while writing `.ent` files (avoids PathRedirect ↔ Ensure re-entrancy).
BOOL MCFIXEntitlementFileMutationInProgress(void);

/// IDA sub_1008A92E0 hash → `{hash}.ent` for the given identity string.
NSString *MCFIXEntitlementStorageFileNameForIdentity(NSString *identity);

/// Basename for current active profile identity.
NSString *MCFIXEntitlementStorageFileName(void);

/// Synthesize production `.ent` (16-SKU Inventory + receipts) with `activeXUID` in every ownerId / OwnerId.
void MCFIXGenerateDefaultProductionEntitlementFile(NSString *targetPath, NSString *activeXUID);

/// YES when on-disk JSON has the full 16-SKU inventory and matching receipt ownerId.
BOOL MCFIXProductionEntitlementFileIsValidAtPath(NSString *entPath, NSString *expectedOwnerId);

/// Create or regenerate `.ent` when missing or stale. Returns YES if a fresh file was written.
BOOL MCFIXEnsureEntitlementFileAtPath(NSString *entPath, NSString *activeXUID);

/// One-shot main-queue sub_1006658CC reload after a successful lazy `.ent` write.
void MCFIXScheduleEntitlementCatalogReload(void);

/// Write `3883282432.ent` (ownerId 0000000000000000) and `0.ent` (ownerId "") under `storageRoot`.
void MCFIXEnsureProductionEntitlementAtStorageRoot(NSString *storageRoot);

/// Synthesize production `.ent` with explicit receipt `ownerId` (may be @"" for 0.ent).
BOOL MCFIXGenerateProductionEntitlementFile(NSString *targetPath, NSString *ownerId);

NSString    *MCFIXMinecraftSavesBasePath(void);
const char  *MCFIXMinecraftSavesBasePathUTF8(void);
