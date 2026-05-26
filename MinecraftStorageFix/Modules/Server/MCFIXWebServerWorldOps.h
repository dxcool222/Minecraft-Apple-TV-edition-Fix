#import <Foundation/Foundation.h>

/// Staging root: `NSTemporaryDirectory()/mcfix_uploads`.
FOUNDATION_EXPORT NSString *MCFIXWebServerStagingRoot(void);

/// Per-world backup snapshots under GameData VFS: `.../Library/games/com.mojang/mcfix_backups/<worldId>/`.
/// Each world folder has `index.json` plus `snapshots/<snapshotId>/` (full folder copy).
FOUNDATION_EXPORT NSString *MCFIXWebServerBackupsRoot(void);

/// Ordered snapshot records from `index.json` (`id`, `label`, `created`). Empty if none.
FOUNDATION_EXPORT NSArray<NSDictionary *> *MCFIXBackupIndexReadSnapshots(NSString *worldId);

FOUNDATION_EXPORT BOOL MCFIXBackupIndexWrite(NSString *worldId, NSArray<NSDictionary *> *snapshots, NSError **error);

/// Resolved snapshot directory, or nil if `worldId` / `snapshotId` fail sanitization or path escapes backups root.
FOUNDATION_EXPORT NSString *_Nullable MCFIXBackupSnapshotPath(NSString *worldId, NSString *snapshotId);

/// Copies `worldsRoot/worldId` into a new snapshot folder and appends metadata to `index.json`.
/// `proposedSnapshotId` is optional; if absent, a millisecond timestamp is used. Returns the snapshot id.
FOUNDATION_EXPORT NSString *_Nullable MCFIXCreateWorldBackupSnapshot(NSString *worldsRoot, NSString *worldId,
                                                                    NSString *_Nullable label,
                                                                    NSString *_Nullable proposedSnapshotId,
                                                                    NSError **error);

/// Best-effort “newest child entry” mtime under `worldFolderPath` for UI (non-recursive listing).
FOUNDATION_EXPORT NSDate *_Nullable MCFIXWorldFolderApproximateModificationDate(NSString *worldFolderPath);

/// Sanitizes a proposed folder name; returns nil if unusable.
FOUNDATION_EXPORT NSString *_Nullable MCFIXSanitizedWorldId(NSString *raw);

/// Optional integration: set YES while Bedrock has a world session active.
/// When YES, `/restore` returns HTTP 409 unless `force` is used.
FOUNDATION_EXPORT void MCFIXWebServerSetGameWorldSessionActive(BOOL active);
FOUNDATION_EXPORT BOOL MCFIXWebServerGameWorldSessionActive(void);

/// Restore safety (when `force` is NO): **both** must allow restore — LevelDB
/// `db/LOCK` (if destination exists) **and** the session flag. Neither overrides
/// the other; if either blocks, restore fails. Messages may list multiple reasons.
/// `force` bypasses **both** gates (use only when you accept corruption risk).

FOUNDATION_EXPORT BOOL MCFIXWorldFolderHasLevelDat(NSString *path);

/// Returns the directory that directly contains `level.dat` under `root` (max depth 2).
FOUNDATION_EXPORT NSString *_Nullable MCFIXDirectoryContainingWorldLevelDat(NSString *root);

/// Uses a non-blocking `flock(LOCK_EX|LOCK_NB)` on `<worldPath>/db/LOCK` when present.
FOUNDATION_EXPORT BOOL MCFIXWorldLevelDbLockIsFree(NSString *worldPath);

FOUNDATION_EXPORT BOOL MCFIXWriteStagedWorldSidecar(NSString *worldFolder, NSString *_Nullable backupName,
                                                   NSError **error);
FOUNDATION_EXPORT NSString *_Nullable MCFIXReadStagedWorldBackupLabel(NSString *worldFolder);

/// Flattens `root/SingleSubdir/...` into `root/...` when exactly one subdirectory holds `level.dat`.
FOUNDATION_EXPORT BOOL MCFIXNormalizeStagedWorldLayout(NSString *worldRoot, NSError **error);

/// Copies a staged folder into the active VFS slot without overwriting in place:
/// existing destination is renamed to `<worldId>.replaced.<timestamp>` first.
/// Caller must set `MCFIX_BypassHooks` around file operations if needed.
FOUNDATION_EXPORT BOOL MCFIXRestoreStagedWorldIntoVFSSlot(NSString *worldsRoot, NSString *targetWorldId,
                                                         NSString *stagedWorldFolder, BOOL force,
                                                         NSError **error);

/// `.../minecraftWorlds` parent that contains `worldId`, or `worldsRoots.firstObject` if missing (restore target default).
FOUNDATION_EXPORT NSString *MCFIXWebServerMinecraftWorldsParentForWorldId(NSString *worldId, NSArray<NSString *> *worldsRoots);

/// File explorer UI (browse GameData VFS from LAN). Replaces the old world-backup cards UI.
FOUNDATION_EXPORT NSString *MCFIXWebServerFileExplorerHTML(void);

/// Returns bundled framework resource bytes (cached). nil if the resource
/// wasn't packaged into MinecraftStorageFix.framework.
FOUNDATION_EXPORT NSData *_Nullable MCFIXWebServerBundleResource(NSString *name, NSString *ext);
