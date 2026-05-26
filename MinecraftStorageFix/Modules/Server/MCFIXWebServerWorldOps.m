#import "MCFIXWebServerWorldOps.h"

#import "MCFIXGameDataVFS.h"

#import <sys/file.h>
#import <stdatomic.h>
#import <unistd.h>

static NSString *const kMCFIXSidecarName = @".mcfix_world_meta.plist";
static NSString *const kMCFIXBackupLabelKey = @"backupLabel";
static NSString *const kMCFIXStagedAtKey = @"stagedAt";

static atomic_int gMCFIXWebServerGameWorldSessionActive;

static BOOL MCFIXWorldBackupKeySafe(NSString *worldId) {
    if (worldId.length == 0 || worldId.length > 128) {
        return NO;
    }
    if ([worldId containsString:@"/"] || [worldId containsString:@"\\"]) {
        return NO;
    }
    if ([worldId isEqualToString:@"."] || [worldId isEqualToString:@".."]) {
        return NO;
    }
    return YES;
}

NSString *MCFIXWebServerStagingRoot(void) {
    return [[NSTemporaryDirectory() stringByAppendingPathComponent:@"mcfix_uploads"] stringByStandardizingPath];
}

NSString *MCFIXWebServerBackupsRoot(void) {
    NSString *vfs = MCFIXGameDataVFSSandboxRoot();
    return [[[vfs stringByAppendingPathComponent:@"Library/games/com.mojang"] stringByAppendingPathComponent:@"mcfix_backups"]
        stringByStandardizingPath];
}

NSString *_Nullable MCFIXSanitizedWorldId(NSString *raw) {
    if (raw.length == 0) {
        return nil;
    }
    NSCharacterSet *allowed =
        [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._"];
    NSMutableString *out = [NSMutableString stringWithCapacity:raw.length];
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if ([allowed characterIsMember:c]) {
            [out appendFormat:@"%C", c];
        }
    }
    if (out.length == 0 || out.length > 128) {
        return nil;
    }
    return [out copy];
}

void MCFIXWebServerSetGameWorldSessionActive(BOOL active) {
    atomic_store(&gMCFIXWebServerGameWorldSessionActive, active ? 1 : 0);
}

BOOL MCFIXWebServerGameWorldSessionActive(void) {
    return atomic_load(&gMCFIXWebServerGameWorldSessionActive) != 0;
}

NSArray<NSDictionary *> *MCFIXBackupIndexReadSnapshots(NSString *worldId) {
    if (!MCFIXWorldBackupKeySafe(worldId)) {
        return @[];
    }
    NSString *path = [[[MCFIXWebServerBackupsRoot() stringByAppendingPathComponent:worldId] stringByAppendingPathComponent:@"index.json"]
        stringByStandardizingPath];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length == 0) {
        return @[];
    }
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) {
        return @[];
    }
    id arr = [(NSDictionary *)json objectForKey:@"snapshots"];
    if (![arr isKindOfClass:[NSArray class]]) {
        return @[];
    }
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (id o in (NSArray *)arr) {
        if ([o isKindOfClass:[NSDictionary class]]) {
            [out addObject:o];
        }
    }
    return [out copy];
}

BOOL MCFIXBackupIndexWrite(NSString *worldId, NSArray<NSDictionary *> *snapshots, NSError **error) {
    if (!MCFIXWorldBackupKeySafe(worldId)) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCFIXWorld" code:50 userInfo:nil];
        }
        return NO;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [[MCFIXWebServerBackupsRoot() stringByAppendingPathComponent:worldId] stringByStandardizingPath];
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }
    NSString *path = [dir stringByAppendingPathComponent:@"index.json"];
    NSDictionary *root = @{@"worldId" : worldId, @"snapshots" : snapshots ?: @[]};
    NSData *data = [NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingPrettyPrinted error:error];
    if (!data) {
        return NO;
    }
    return [data writeToURL:[NSURL fileURLWithPath:path] options:NSDataWritingAtomic error:error];
}

NSString *_Nullable MCFIXBackupSnapshotPath(NSString *worldId, NSString *snapshotId) {
    if (!MCFIXWorldBackupKeySafe(worldId)) {
        return nil;
    }
    NSString *s = MCFIXSanitizedWorldId(snapshotId);
    if (s.length == 0) {
        return nil;
    }
    NSString *backs = [MCFIXWebServerBackupsRoot() stringByStandardizingPath];
    NSString *full =
        [[[[backs stringByAppendingPathComponent:worldId] stringByAppendingPathComponent:@"snapshots"] stringByAppendingPathComponent:s]
            stringByStandardizingPath];
    if ([full hasPrefix:backs] == NO) {
        return nil;
    }
    return full;
}

NSString *_Nullable MCFIXCreateWorldBackupSnapshot(NSString *worldsRoot, NSString *worldId, NSString *_Nullable label,
                                                   NSString *_Nullable proposedSnapshotId, NSError **error) {
    if (worldsRoot.length == 0 || worldId.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCFIXWorld" code:51 userInfo:nil];
        }
        return nil;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *live = [[worldsRoot stringByAppendingPathComponent:worldId] stringByStandardizingPath];
    if ([live hasPrefix:[worldsRoot stringByStandardizingPath]] == NO || ![fm fileExistsAtPath:live]) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCFIXWorld" code:52
                                     userInfo:@{NSLocalizedDescriptionKey : @"world folder not found"}];
        }
        return nil;
    }
    if (!MCFIXWorldBackupKeySafe(worldId)) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCFIXWorld" code:54 userInfo:nil];
        }
        return nil;
    }
    if (MCFIXWorldFolderHasLevelDat(live) == NO && MCFIXDirectoryContainingWorldLevelDat(live) == nil) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCFIXWorld" code:53
                                     userInfo:@{NSLocalizedDescriptionKey : @"not a Bedrock world (no level.dat)"}];
        }
        return nil;
    }

    NSString *worldBack = [[MCFIXWebServerBackupsRoot() stringByAppendingPathComponent:worldId] stringByStandardizingPath];
    NSString *snapRoot = [worldBack stringByAppendingPathComponent:@"snapshots"];
    if (![fm createDirectoryAtPath:snapRoot withIntermediateDirectories:YES attributes:nil error:error]) {
        return nil;
    }

    NSString *snapId = @"";
    if (proposedSnapshotId.length) {
        NSString *s = MCFIXSanitizedWorldId(proposedSnapshotId);
        if (s.length) {
            snapId = s;
        }
    }
    if (snapId.length == 0) {
        snapId = [NSString stringWithFormat:@"%.0f", [NSDate date].timeIntervalSince1970 * 1000.0];
    }

    NSString *dest = [snapRoot stringByAppendingPathComponent:snapId];
    if ([fm fileExistsAtPath:dest]) {
        snapId = [NSString stringWithFormat:@"%@-%@", snapId, [[NSUUID UUID] UUIDString]];
        dest = [snapRoot stringByAppendingPathComponent:snapId];
    }

    if (![fm copyItemAtPath:live toPath:dest error:error]) {
        return nil;
    }
    if (MCFIXWorldFolderHasLevelDat(dest) == NO && MCFIXDirectoryContainingWorldLevelDat(dest) == nil) {
        (void)[fm removeItemAtPath:dest error:nil];
        if (error) {
            *error = [NSError errorWithDomain:@"MCFIXWorld" code:55
                                     userInfo:@{NSLocalizedDescriptionKey : @"snapshot copy missing level.dat"}];
        }
        return nil;
    }

    NSMutableArray *existing = [MCFIXBackupIndexReadSnapshots(worldId) mutableCopy];
    NSDictionary *entry = @{
        @"id" : snapId,
        @"label" : label ?: @"",
        @"created" : @([NSDate date].timeIntervalSince1970),
    };
    [existing addObject:entry];
    if (!MCFIXBackupIndexWrite(worldId, existing, error)) {
        (void)[fm removeItemAtPath:dest error:nil];
        return nil;
    }
    return snapId;
}

NSDate *_Nullable MCFIXWorldFolderApproximateModificationDate(NSString *worldFolderPath) {
    if (worldFolderPath.length == 0) {
        return nil;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *base = [NSURL fileURLWithPath:worldFolderPath isDirectory:YES];
    NSDate *latest = nil;
    NSArray *children = [fm contentsOfDirectoryAtPath:worldFolderPath error:nil];
    for (NSString *name in children) {
        if ([name isEqualToString:@"."] || [name isEqualToString:@".."]) {
            continue;
        }
        NSURL *u = [base URLByAppendingPathComponent:name];
        NSDate *d = nil;
        (void)[u getResourceValue:&d forKey:NSURLContentModificationDateKey error:nil];
        if (d != nil && (latest == nil || [d compare:latest] == NSOrderedDescending)) {
            latest = d;
        }
    }
    return latest;
}

BOOL MCFIXWorldFolderHasLevelDat(NSString *path) {
    if (path.length == 0) {
        return NO;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    return [fm fileExistsAtPath:[path stringByAppendingPathComponent:@"level.dat"]];
}

NSString *_Nullable MCFIXDirectoryContainingWorldLevelDat(NSString *root) {
    if (!MCFIXWorldFolderHasLevelDat(root)) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *children = [fm contentsOfDirectoryAtPath:root error:nil];
        for (NSString *c in children) {
            if ([c hasPrefix:@"."]) {
                continue;
            }
            if ([c isEqualToString:@"__MACOSX"]) {
                continue;
            }
            NSString *sub = [root stringByAppendingPathComponent:c];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:sub isDirectory:&isDir] || !isDir) {
                continue;
            }
            if (MCFIXWorldFolderHasLevelDat(sub)) {
                return sub;
            }
            NSArray *grand = [fm contentsOfDirectoryAtPath:sub error:nil];
            for (NSString *g in grand) {
                if ([g hasPrefix:@"."]) {
                    continue;
                }
                if ([g isEqualToString:@"__MACOSX"]) {
                    continue;
                }
                NSString *sub2 = [sub stringByAppendingPathComponent:g];
                BOOL isDir2 = NO;
                if (![fm fileExistsAtPath:sub2 isDirectory:&isDir2] || !isDir2) {
                    continue;
                }
                if (MCFIXWorldFolderHasLevelDat(sub2)) {
                    return sub2;
                }
            }
        }
        return nil;
    }
    return root;
}

BOOL MCFIXWorldLevelDbLockIsFree(NSString *worldPath) {
    if (worldPath.length == 0) {
        return YES;
    }
    NSString *lockPath = [[worldPath stringByAppendingPathComponent:@"db"] stringByAppendingPathComponent:@"LOCK"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:lockPath]) {
        return YES;
    }
    int fd = open(lockPath.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) {
        return NO;
    }
    BOOL ok = YES;
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        ok = NO;
    } else {
        (void)flock(fd, LOCK_UN);
    }
    close(fd);
    return ok;
}

BOOL MCFIXWriteStagedWorldSidecar(NSString *worldFolder, NSString *_Nullable backupName, NSError **error) {
    if (worldFolder.length == 0) {
        return NO;
    }
    NSDictionary *dict = @{
        kMCFIXBackupLabelKey : backupName ?: @"",
        kMCFIXStagedAtKey : @([[NSDate date] timeIntervalSince1970]),
    };
    NSString *path = [worldFolder stringByAppendingPathComponent:kMCFIXSidecarName];
    return [dict writeToURL:[NSURL fileURLWithPath:path] error:error];
}

NSString *_Nullable MCFIXReadStagedWorldBackupLabel(NSString *worldFolder) {
    NSString *path = [worldFolder stringByAppendingPathComponent:kMCFIXSidecarName];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![d isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    id v = d[kMCFIXBackupLabelKey];
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

BOOL MCFIXNormalizeStagedWorldLayout(NSString *worldRoot, NSError **error) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:worldRoot]) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCFIXWorld" code:10 userInfo:nil];
        }
        return NO;
    }
    if (MCFIXWorldFolderHasLevelDat(worldRoot)) {
        return YES;
    }
    NSString *inner = MCFIXDirectoryContainingWorldLevelDat(worldRoot);
    if (inner.length == 0 || [inner isEqualToString:worldRoot]) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCFIXWorld" code:11
                                    userInfo:@{NSLocalizedDescriptionKey : @"level.dat not found in staging"}];
        }
        return NO;
    }
    if (![inner hasPrefix:worldRoot]) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCFIXWorld" code:12 userInfo:nil];
        }
        return NO;
    }

    NSArray *innerItems = [fm contentsOfDirectoryAtPath:inner error:nil];
    for (NSString *c in innerItems) {
        if ([c isEqualToString:@"."] || [c isEqualToString:@".."]) {
            continue;
        }
        NSString *from = [inner stringByAppendingPathComponent:c];
        NSString *to = [worldRoot stringByAppendingPathComponent:c];
        if ([fm fileExistsAtPath:to]) {
            (void)[fm removeItemAtPath:to error:nil];
        }
        if (![fm moveItemAtPath:from toPath:to error:error]) {
            return NO;
        }
    }
    (void)[fm removeItemAtPath:inner error:nil];
    if (!MCFIXWorldFolderHasLevelDat(worldRoot)) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCFIXWorld" code:13
                                    userInfo:@{NSLocalizedDescriptionKey : @"flatten failed"}];
        }
        return NO;
    }
    return YES;
}

BOOL MCFIXRestoreStagedWorldIntoVFSSlot(NSString *worldsRoot, NSString *targetWorldId, NSString *stagedWorldFolder,
                                       BOOL force, NSError **error) {
    if (worldsRoot.length == 0 || targetWorldId.length == 0 || stagedWorldFolder.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCFIXWorld" code:20 userInfo:nil];
        }
        return NO;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dest = [[worldsRoot stringByAppendingPathComponent:targetWorldId] stringByStandardizingPath];
    if ([dest hasPrefix:worldsRoot] == NO) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCFIXWorld" code:21 userInfo:nil];
        }
        return NO;
    }

    if (!force) {
        NSMutableArray<NSString *> *reasons = [NSMutableArray array];
        if ([fm fileExistsAtPath:dest] && !MCFIXWorldLevelDbLockIsFree(dest)) {
            [reasons addObject:@"LevelDB LOCK held"];
        }
        if (MCFIXWebServerGameWorldSessionActive()) {
            [reasons addObject:@"game world session active"];
        }
        if (reasons.count) {
            if (error) {
                *error = [NSError errorWithDomain:@"MCFIXWorld" code:409
                                        userInfo:@{
                                            NSLocalizedDescriptionKey : [reasons componentsJoinedByString:@"; "]
                                        }];
            }
            return NO;
        }
    }

    if (!MCFIXNormalizeStagedWorldLayout(stagedWorldFolder, error)) {
        return NO;
    }

    NSTimeInterval ts = [NSDate date].timeIntervalSince1970;
    NSString *replacedName = [NSString stringWithFormat:@"%@.replaced.%llu", dest.lastPathComponent, (unsigned long long)(ts * 1000.0)];
    NSString *replaced = [[worldsRoot stringByAppendingPathComponent:replacedName] stringByStandardizingPath];

    BOOL destExisted = [fm fileExistsAtPath:dest];
    if (destExisted) {
        if (![fm moveItemAtPath:dest toPath:replaced error:error]) {
            return NO;
        }
    }

    NSString *pendingName =
        [NSString stringWithFormat:@".mcfix_pending.%@.%@", targetWorldId, [[NSUUID UUID] UUIDString]];
    NSString *pending = [[worldsRoot stringByAppendingPathComponent:pendingName] stringByStandardizingPath];
    if (![pending hasPrefix:worldsRoot]) {
        if (destExisted) {
            (void)[fm moveItemAtPath:replaced toPath:dest error:nil];
        }
        if (error) {
            *error = [NSError errorWithDomain:@"MCFIXWorld" code:21 userInfo:nil];
        }
        return NO;
    }

    (void)[fm removeItemAtPath:pending error:nil];

    NSError *cpyErr = nil;
    if (![fm copyItemAtPath:stagedWorldFolder toPath:pending error:&cpyErr]) {
        if (destExisted) {
            (void)[fm moveItemAtPath:replaced toPath:dest error:nil];
        }
        if (error) {
            *error = cpyErr;
        }
        return NO;
    }

    if (!MCFIXWorldFolderHasLevelDat(pending)) {
        (void)[fm removeItemAtPath:pending error:nil];
        if (destExisted) {
            (void)[fm moveItemAtPath:replaced toPath:dest error:nil];
        }
        if (error) {
            *error = [NSError errorWithDomain:@"MCFIXWorld" code:22
                                    userInfo:@{NSLocalizedDescriptionKey : @"pending copy missing level.dat"}];
        }
        return NO;
    }

    NSError *mvErr = nil;
    // Same volume as worldsRoot: this -[NSFileManager moveItemAtPath:toPath:] is a
    // rename on APFS and is atomic with respect to readers seeing the final folder name.
    // Copy phase above can still be partial on crash; live slot is only swapped in here.
    if (![fm moveItemAtPath:pending toPath:dest error:&mvErr]) {
        (void)[fm removeItemAtPath:pending error:nil];
        if (destExisted) {
            (void)[fm moveItemAtPath:replaced toPath:dest error:nil];
        }
        if (error) {
            *error = mvErr;
        }
        return NO;
    }

    (void)[fm removeItemAtPath:stagedWorldFolder error:nil];
    return YES;
}

NSString *MCFIXWebServerMinecraftWorldsParentForWorldId(NSString *worldId, NSArray<NSString *> *worldsRoots) {
    if (worldsRoots.count == 0) {
        return nil;
    }
    NSString *first = [worldsRoots.firstObject stringByStandardizingPath];
    if (worldId.length == 0 || !MCFIXWorldBackupKeySafe(worldId)) {
        return first;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *root in worldsRoots) {
        NSString *r = [root stringByStandardizingPath];
        if (r.length == 0) {
            continue;
        }
        NSString *full = [[r stringByAppendingPathComponent:worldId] stringByStandardizingPath];
        if ([full hasPrefix:r] && [fm fileExistsAtPath:full]) {
            return r;
        }
    }
    return first;
}

// Anchor class so `bundleForClass:` resolves to MinecraftStorageFix.framework
// without depending on the private MinecraftStorageFix class in another .m.
@interface MCFIXWebServerBundleAnchor : NSObject
@end
@implementation MCFIXWebServerBundleAnchor
@end

NSData *MCFIXWebServerBundleResource(NSString *name, NSString *ext) {
    static NSMutableDictionary<NSString *, NSData *> *cache;
    static dispatch_once_t cacheOnce = 0;
    dispatch_once(&cacheOnce, ^{ cache = [NSMutableDictionary dictionary]; });

    NSString *key = [NSString stringWithFormat:@"%@.%@", name ?: @"", ext ?: @""];
    @synchronized (cache) {
        NSData *hit = cache[key];
        if (hit) return hit;
        NSBundle *bundle = [NSBundle bundleForClass:[MCFIXWebServerBundleAnchor class]];
        NSURL *url = [bundle URLForResource:name withExtension:ext];
        NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
        if (data) cache[key] = data;
        return data;
    }
}

NSString *MCFIXWebServerFileExplorerHTML(void) {
    static NSString *sHTML = nil;
    static dispatch_once_t sOnce = 0;
    dispatch_once(&sOnce, ^{
        NSData *data = MCFIXWebServerBundleResource(@"explorer", @"html");
        if (data) {
            sHTML = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        }
    });
    return sHTML;
}
