#import "Bootstrap.h"

#import <Foundation/Foundation.h>

#import "AchievementIcons.h"
#import "CatalogStub.h"
#import "../Marketplace/MCFIXEntitlementCatalog.h"
#import "../Marketplace/MCFIXMarketplaceIdentity.h"
#import "../Internal/MCFIXState.h"
#import "../Xbox/XBLIdentityCapture.h"
#import "MCFIXBypass.h"
#import "MCFIXGameDataVFS.h"
#import "MCFIXLog.h"
#import "MCFIXPosixOrigs.h"
#import "WorldIcon.h"

#import <os/lock.h>
#import <stdatomic.h>
#import <stdio.h>
#import <sys/stat.h>

NSString *MCFIXGameDataVFSSandboxRoot(void) {
    static NSString *root;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // NSCachesDirectory only — do NOT use NSApplicationSupportDirectory here.
        NSFileManager *fm = [NSFileManager defaultManager];
        NSURL *u = [fm URLForDirectory:NSCachesDirectory
                            inDomain:NSUserDomainMask
                   appropriateForURL:nil
                              create:YES
                               error:nil];
        NSString *caches = u.path;
        if (caches.length == 0) {
            caches = [NSSearchPathForDirectoriesInDomains(
                NSCachesDirectory, NSUserDomainMask, YES) firstObject];
        }
        if (caches.length == 0) {
            caches = [[[NSHomeDirectory() stringByStandardizingPath]
                stringByAppendingPathComponent:@"Library"] stringByAppendingPathComponent:@"Caches"];
        }
        root = [[[[caches stringByAppendingPathComponent:@"MinecraftStorageFix"]
            stringByAppendingPathComponent:@"GameData"] stringByAppendingPathComponent:@"vfs"]
            stringByStandardizingPath];
        const char *gr = root.fileSystemRepresentation;
        if (gr) {
            int mk = mcfix_orig_mkdir_p(gr, (mode_t)0755);
            if (mk != 0 && (mcfix_orig_mkdir == NULL || mcfix_orig_access == NULL)) {
                BOOL prevBypass = MCFIXBypassHooksActive();
                MCFIXBypassHooksSet(YES);
                (void)[fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
                MCFIXBypassHooksSet(prevBypass);
            }
        }
    });
    return root;
}

NSString *MCFIXGameDataVFSSandboxRootStd(void) {
    static NSString *sStdRoot = nil;
    static dispatch_once_t sStdOnce;
    dispatch_once(&sStdOnce, ^{
        sStdRoot = [MCFIXGameDataVFSSandboxRoot() stringByStandardizingPath];
    });
    return sStdRoot ?: @"";
}

/// True for normal POSIX file paths (leading `/`). Does not treat `file://` as absolute; game paths are always filesystem strings here.
/// IDA: world_icon.jpeg under tmp/Temp/games/.../minecraftWorlds/<id>/ — exclude from VFS redirect (logs: vfs write, tmp/Temp read MISS, Library=1).
/// IDA tail: tmp/minecraftpe/AchievementIcons — excluded from VFS redirect (see boot ACH dirs probe).

/// Copy legacy on-container saves into the Caches VFS mirror so reads/writes stay consistent.
void MCFIXMigrateRealGameStorageToVFS(void) {
    static NSString *const kKey = @"MinecraftStorageFix_migrated_real_games_to_vfs_v1";
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kKey]) {
        return;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *home = [NSHomeDirectory() stringByStandardizingPath];
    NSString *vfs = MCFIXGameDataVFSSandboxRoot();
    NSArray<NSString *> *relRoots = @[
        @"Library/games/com.mojang",
        @"Documents/games/com.mojang",
    ];
    for (NSString *rel in relRoots) {
        NSString *src = [[home stringByAppendingPathComponent:rel] stringByStandardizingPath];
        NSString *dst = [[vfs stringByAppendingPathComponent:rel] stringByStandardizingPath];
        BOOL srcDir = NO;
        if (![fm fileExistsAtPath:src isDirectory:&srcDir] || !srcDir) {
            continue;
        }
        BOOL dstDir = NO;
        if ([fm fileExistsAtPath:dst isDirectory:&dstDir] && dstDir) {
            continue;
        }
        [fm createDirectoryAtPath:[dst stringByDeletingLastPathComponent]
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
        NSError *err = nil;
        if ([fm copyItemAtPath:src toPath:dst error:&err]) {
            MCFIXLogOnce(MCFIXLogCatVFS, [NSString stringWithFormat:@"migrate_%@", src.lastPathComponent],
                         @"migrated %@ -> %@", src, dst);
        } else {
            MCFIXLog(MCFIXLogCatError, @"migrate failed %@ -> %@ err=%@", src, dst, err);
        }
    }
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

/// If `redirected` lives under the Caches VFS root, return the matching legacy $HOME path.
/// Mirror prefs/skins both ways so reads after relaunch hit the same files the game wrote.
void MCFIXSyncBidirectionalSkinAndPrefs(void) {
    static NSString *const kKey = @"MinecraftStorageFix_bidir_skin_prefs_v1";
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if ([[NSUserDefaults standardUserDefaults] boolForKey:kKey]) {
            return;
        }
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *vfsRoot = [[MCFIXGameDataVFSSandboxRoot()
            stringByAppendingPathComponent:@"Library/games/com.mojang"] stringByStandardizingPath];
        NSString *legRoot = [[NSHomeDirectory()
            stringByAppendingPathComponent:@"Library/games/com.mojang"] stringByStandardizingPath];
        NSArray<NSString *> *relNames = @[
            @"options.txt", @"options.txt.bak", @"launcher_profiles.json", @"launcher_settings.json",
        ];
        NSArray<NSString *> *relDirs = @[ @"skin_packs" ];
        void (^copyIfMissing)(NSString *, NSString *) = ^(NSString *src, NSString *dst) {
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:src isDirectory:&isDir]) {
                return;
            }
            if ([fm fileExistsAtPath:dst]) {
                return;
            }
            [fm createDirectoryAtPath:[dst stringByDeletingLastPathComponent]
          withIntermediateDirectories:YES
                           attributes:nil
                                error:nil];
            NSError *e = nil;
            if ([fm copyItemAtPath:src toPath:dst error:&e]) {
                MCFIXLogOnce(MCFIXLogCatVFS, [NSString stringWithFormat:@"bidir_%@", src.lastPathComponent],
                             @"bidir copy %@ -> %@", src.lastPathComponent, dst);
            }
        };
        for (NSString *name in relNames) {
            copyIfMissing([legRoot stringByAppendingPathComponent:name],
                          [vfsRoot stringByAppendingPathComponent:name]);
            copyIfMissing([vfsRoot stringByAppendingPathComponent:name],
                          [legRoot stringByAppendingPathComponent:name]);
        }
        for (NSString *dir in relDirs) {
            copyIfMissing([legRoot stringByAppendingPathComponent:dir],
                          [vfsRoot stringByAppendingPathComponent:dir]);
            copyIfMissing([vfsRoot stringByAppendingPathComponent:dir],
                          [legRoot stringByAppendingPathComponent:dir]);
        }
        NSString *vfsBase = MCFIXGameDataVFSSandboxRoot();
        NSString *legBase = NSHomeDirectory();
        NSArray<NSString *> *extraRelPaths = @[
            @"tmp/Temp/games/com.mojang/minecraftpe/options.txt",
            @"tmp/Temp/games/com.mojang/minecraftpe",
        ];
        for (NSString *rel in extraRelPaths) {
            copyIfMissing([[legBase stringByAppendingPathComponent:rel] stringByStandardizingPath],
                          [[vfsBase stringByAppendingPathComponent:rel] stringByStandardizingPath]);
            copyIfMissing([[vfsBase stringByAppendingPathComponent:rel] stringByStandardizingPath],
                          [[legBase stringByAppendingPathComponent:rel] stringByStandardizingPath]);
        }
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kKey];
    });
}

//  VFS sandbox tree + bundle seeds (Phase 3 storage layers only — no gate/RL hooks)
// ---------------------------------------------------------------------------

static void MCFIXCopyBundleResourceTree(NSString *bundleRel, NSString *vfsRel) {
    if (bundleRel.length == 0 || vfsRel.length == 0) {
        return;
    }
    NSString *src = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:bundleRel];
    NSString *dst = [[MCFIXGameDataVFSSandboxRoot() stringByAppendingPathComponent:vfsRel]
        stringByStandardizingPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:src isDirectory:&isDir] || !isDir) {
        return;
    }
    BOOL prevBypass = MCFIXBypassHooksActive();
    MCFIXBypassHooksSet(YES);
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:src];
    NSString *rel = nil;
    NSUInteger copied = 0;
    while ((rel = [en nextObject])) {
        NSString *srcFile = [src stringByAppendingPathComponent:rel];
        BOOL fileIsDir = NO;
        if (![fm fileExistsAtPath:srcFile isDirectory:&fileIsDir] || fileIsDir) {
            continue;
        }
        NSString *dstFile = [dst stringByAppendingPathComponent:rel];
        if ([fm fileExistsAtPath:dstFile]) {
            continue;
        }
        [fm createDirectoryAtPath:[dstFile stringByDeletingLastPathComponent]
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
        NSError *err = nil;
        if ([fm copyItemAtPath:srcFile toPath:dstFile error:&err]) {
            copied++;
        }
    }
    MCFIXBypassHooksSet(prevBypass);
    if (copied > 0) {
        MCFIXLogOnce(MCFIXLogCatVFS, [NSString stringWithFormat:@"seed_%@", vfsRel],
                     @"seeded %lu files %@ -> %@", (unsigned long)copied, bundleRel, vfsRel);
    }
}

/// IDA: sub_1005F5390 loads tmp/minecraftpe/AchievementIcons/{CityHash64(xboxId)}.png.
/// Bundle only has UI chrome (clock, trophy, …) — not per-achievement art. Those PNGs
/// must come from Xbox (hex filenames). We seed chrome only; CityHash64 is for future
/// materialize when an Xbox id string is known.

static void MCFIXSeedEngineOptionsTxtInVFS(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *vfs = MCFIXGameDataVFSSandboxRoot();
        NSArray<NSString *> *relPaths = @[
            @"tmp/Temp/games/com.mojang/minecraftpe/options.txt",
            @"Library/games/com.mojang/options.txt",
            @"Documents/games/com.mojang/options.txt",
        ];
        static NSString *const kSeed =
            @"mp_username:Player\n"
            @"game_difficulty:1\n"
            @"ctrl_type:0\n";
        BOOL prevBypass = MCFIXBypassHooksActive();
        MCFIXBypassHooksSet(YES);
        for (NSString *rel in relPaths) {
            NSString *dst = [[vfs stringByAppendingPathComponent:rel] stringByStandardizingPath];
            if ([fm fileExistsAtPath:dst]) {
                continue;
            }
            [fm createDirectoryAtPath:[dst stringByDeletingLastPathComponent]
          withIntermediateDirectories:YES
                           attributes:nil
                                error:nil];
            NSError *err = nil;
            if ([kSeed writeToFile:dst atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
                MCFIXLogOnce(MCFIXLogCatVFS, @"options_seed", @"seeded options.txt @ %@", dst);
            }
            NSString *leg = [[NSHomeDirectory() stringByAppendingPathComponent:rel]
                stringByStandardizingPath];
            if (![fm fileExistsAtPath:leg]) {
                [fm createDirectoryAtPath:[leg stringByDeletingLastPathComponent]
              withIntermediateDirectories:YES
                               attributes:nil
                                    error:nil];
                if ([kSeed writeToFile:leg atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
                    MCFIXLogOnce(MCFIXLogCatVFS, @"options_legacy", @"seeded legacy options.txt @ %@", leg);
                }
            }
        }
        MCFIXBypassHooksSet(prevBypass);
    });
}

static void MCFIXEnsureGameVFSSandboxTree(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *vfs = MCFIXGameDataVFSSandboxRoot();
    NSArray<NSString *> *relPaths = @[
        @"Library/games/com.mojang/resource_packs",
        @"Library/games/com.mojang/resource_packs/vanilla",
        @"Library/games/com.mojang/resource_packs/vanilla/textures",
        @"Library/games/com.mojang/resource_packs/vanilla/textures/ui",
        @"Library/games/com.mojang/resource_packs/vanilla/textures/ui/world_icon",
        @"Library/games/com.mojang/resource_packs/vanilla/textures/ui/achievement",
        @"Library/games/com.mojang/skin_packs",
        @"Library/games/com.mojang/minecraftpe",
        @"Library/games/com.mojang/premium_cache",
        @"Library/games/com.mojang/premium_cache/skin_packs",
        @"tmp/Temp/games/com.mojang/minecraftpe",
        @"tmp/Temp/games/com.mojang/skin_packs",
        @"tmp/minecraftpe",
        @"tmp/minecraftpe/AchievementIcons",
        @"tmp/minecraftpe/resource_pack_download_cache",
        @"tmp/minecraftpe/games/com.mojang/minecraftpe",
        @"tmp/minecraftpe/games/com.mojang/resource_packs",
        @"tmp/minecraftpe/games/com.mojang/skin_packs",
    ];
    BOOL prevBypass = MCFIXBypassHooksActive();
    MCFIXBypassHooksSet(YES);
    for (NSString *rel in relPaths) {
        NSString *dst = [[vfs stringByAppendingPathComponent:rel] stringByStandardizingPath];
        [fm createDirectoryAtPath:dst withIntermediateDirectories:YES attributes:nil error:nil];
    }
    MCFIXBypassHooksSet(prevBypass);
}

/// IDA: clientId.txt, external_servers.txt, global_resource_packs.json under minecraftpe roots.
static void MCFIXSeedMinecraftPEConfigFilesInVFS(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *vfs = MCFIXGameDataVFSSandboxRoot();
        NSArray<NSString *> *peDirs = @[
            @"Library/games/com.mojang/minecraftpe",
            @"tmp/minecraftpe",
            @"tmp/Temp/games/com.mojang/minecraftpe",
            @"tmp/minecraftpe/games/com.mojang/minecraftpe",
        ];
        NSString *clientId = [[[NSUUID UUID] UUIDString] stringByReplacingOccurrencesOfString:@"-"
                                                                                    withString:@""];
        if (clientId.length == 0) {
            clientId = @"mcfixdefaultclientid00";
        }
        NSString *clientBody = [clientId stringByAppendingString:@"\n"];
        static NSString *const kGlobalPacks = @"[]\n";
        static NSString *const kExternalServers = @"\n";
        BOOL prevBypass = MCFIXBypassHooksActive();
        MCFIXBypassHooksSet(YES);
        for (NSString *dirRel in peDirs) {
            NSString *dir = [[vfs stringByAppendingPathComponent:dirRel] stringByStandardizingPath];
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            NSDictionary<NSString *, NSString *> *files = @{
                @"clientId.txt" : clientBody,
                @"global_resource_packs.json" : kGlobalPacks,
                @"external_servers.txt" : kExternalServers,
            };
            for (NSString *name in files) {
                NSString *dst = [dir stringByAppendingPathComponent:name];
                if ([fm fileExistsAtPath:dst]) {
                    continue;
                }
                NSError *err = nil;
                if ([files[name] writeToFile:dst atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
                    MCFIXLogOnce(MCFIXLogCatVFS, [NSString stringWithFormat:@"cfg_%@_%@", dirRel, name],
                                 @"seeded %@/%@", dirRel, name);
                }
            }
        }
        MCFIXBypassHooksSet(prevBypass);
    });
}

void MCFIXInstallVFSSandboxLayers(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        MCFIXEnsureGameVFSSandboxTree();
        MCFIXSeedEngineOptionsTxtInVFS();
        MCFIXSeedAchievementIconsFromBundle();
        MCFIXLogWorldIconBootProbe();
        MCFIXLogAchievementIconBootProbe();
        MCFIXSeedMinecraftPEConfigFilesInVFS();
        MCFIXLogOnce(MCFIXLogCatVFS, @"sandbox_tree",
                     @"sandbox tree + options + AchievementIcons + minecraftpe config seeds");
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSUInteger synced = MCFIXSyncAchievementIconsBidirectional();
            if (synced > 0) {
                MCFIXLog(MCFIXLogCatVFS, @"ACH sync boot copied=%lu files (vfs<->home)", (unsigned long)synced);
            }
            MCFIXLogAchievementIconBootProbe();
            MCFIXLogWorldIconBootProbe();
        });
    });
}

NSString *MCFIXMinecraftSavesBasePath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *err = nil;
        // tvOS sideload sandbox: NSApplicationSupportDirectory with create:YES can hit
        // kernel deny(... file-write-create .../Library/Application Support) → EPERM
        // Code 513. That mirrors MCFIXGameDataVFSSandboxRoot — use NSCachesDirectory only.
        NSURL *u = [fm URLForDirectory:NSCachesDirectory
                            inDomain:NSUserDomainMask
                   appropriateForURL:nil
                              create:YES
                               error:&err];
        NSString *caches = u.path;
        if (caches.length == 0) {
            caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
        }
        if (caches.length == 0) {
            caches = [[[NSHomeDirectory() stringByStandardizingPath]
                stringByAppendingPathComponent:@"Library"] stringByAppendingPathComponent:@"Caches"];
        }
        path = [[[caches stringByAppendingPathComponent:@"MinecraftStorageFix"]
            stringByAppendingPathComponent:@"MinecraftSaves"] stringByStandardizingPath];
        err = nil;
        const char *psm = path.fileSystemRepresentation;
        if (psm && mcfix_orig_mkdir_p(psm, (mode_t)0755) != 0) {
            if (![fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&err] && err) {
                MCFIXLog(MCFIXLogCatError, @"MinecraftSaves mkdir (Caches fallback): %@", err);
            }
        }
        (void)[[NSURL fileURLWithPath:path isDirectory:YES]
            setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    });
    return path;
}

const char *MCFIXMinecraftSavesBasePathUTF8(void) {
    static char buf[PATH_MAX];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *p = MCFIXMinecraftSavesBasePath();
        if (![p getFileSystemRepresentation:buf maxLength:sizeof(buf)]) {
            const char *u8 = p.UTF8String;
            if (u8) {
                (void)snprintf(buf, sizeof(buf), "%s", u8);
            } else {
                buf[0] = '\0';
            }
        }
    });
    return buf;
}

// IDA: purchaseReceipt @ CatalogItem+120 → sub_100697EA8 vtable+16 → sub_100697B24 (Base64 decode)
// → sub_100663D38 keeps every other byte (UTF-16LE → ASCII) → sub_101069414 (string move)
// → sub_10106A36C (RapidJSON). Outer JSON field is Base64(UTF-16LE(inner UTF-8 JSON)).
//
// sub_100663098: std::string::operator=(item+88, identity) from sub_100661820 before sub_100663D38.
// sub_100663D38: ownerId length must be > 0 (!v13 @ 0x100663F50) and byte-equal to item+88.
// Offline sub_100661820 → "" fails both checks; use static XUID for .ent + receipts + hash path.

static NSString *const kMCFIXMojangCreatorId = @"00000000-0000-0000-0009-000000000000";
static os_unfair_lock gMCFIXEntitlementEnsureLock = OS_UNFAIR_LOCK_INIT;
static NSMutableSet<NSString *> *gMCFIXEnsuredEntitlementPaths = nil;
static _Thread_local BOOL gMCFIXEntitlementFileMutation = NO;

BOOL MCFIXEntitlementFileMutationInProgress(void) {
    return gMCFIXEntitlementFileMutation;
}

static BOOL MCFIXEntitlementFileExistsAtPath(NSString *entPath) {
    if (entPath.length == 0) {
        return NO;
    }
    const char *p = entPath.fileSystemRepresentation;
    if (!p) {
        return NO;
    }
    struct stat st;
    return stat(p, &st) == 0 && S_ISREG(st.st_mode);
}

static NSString *MCFIXDecodePurchaseReceiptJSONString(NSString *encodedReceipt) {
    if (encodedReceipt.length == 0) {
        return nil;
    }
    NSData *data = [[NSData alloc] initWithBase64EncodedString:encodedReceipt options:0];
    if (data.length < 2) {
        return nil;
    }
    NSMutableData *utf8 = [NSMutableData dataWithCapacity:data.length / 2];
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i + 1 < data.length; i += 2) {
        if (bytes[i] == 0 && bytes[i + 1] != 0) {
            break;
        }
        uint8_t ch = bytes[i];
        [utf8 appendBytes:&ch length:1];
    }
    if (utf8.length == 0) {
        return nil;
    }
    return [[NSString alloc] initWithData:utf8 encoding:NSUTF8StringEncoding];
}

static BOOL MCFIXPurchaseReceiptOwnerIdMatches(NSString *encodedReceipt, NSString *expectedOwnerId) {
    NSString *innerJSON = MCFIXDecodePurchaseReceiptJSONString(encodedReceipt);
    if (innerJSON.length == 0) {
        return NO;
    }
    NSData *jsonData = [innerJSON dataUsingEncoding:NSUTF8StringEncoding];
    if (jsonData.length == 0) {
        return NO;
    }
    NSError *err = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&err];
    if (![parsed isKindOfClass:[NSDictionary class]] || err) {
        return NO;
    }
    NSString *ownerId = [(NSDictionary *)parsed objectForKey:@"ownerId"];
    if (![ownerId isKindOfClass:[NSString class]]) {
        return NO;
    }
    return [ownerId isEqualToString:expectedOwnerId ?: @""];
}

BOOL MCFIXProductionEntitlementFileIsValidAtPath(NSString *entPath, NSString *expectedOwnerId) {
    if (entPath.length == 0) {
        return NO;
    }
    const char *pathC = entPath.fileSystemRepresentation;
    if (!pathC) {
        return NO;
    }
    struct stat st;
    if (stat(pathC, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size < 128) {
        return NO;
    }

    NSError *readErr = nil;
    NSData *jsonData = [NSData dataWithContentsOfFile:entPath options:0 error:&readErr];
    if (jsonData.length == 0 || readErr) {
        return NO;
    }

    NSError *parseErr = nil;
    id rootObj = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&parseErr];
    if (![rootObj isKindOfClass:[NSDictionary class]] || parseErr) {
        return NO;
    }
    NSDictionary *root = (NSDictionary *)rootObj;

    id inventory = root[@"Inventory"];
    if (![inventory isKindOfClass:[NSDictionary class]]) {
        return NO;
    }
    id items = [(NSDictionary *)inventory objectForKey:@"items"];
    if (![items isKindOfClass:[NSArray class]]) {
        return NO;
    }
    if ([(NSArray *)items count] < (NSInteger)kMCFIXProductionEntitlementCatalogCount) {
        return NO;
    }

    NSDictionary *firstItem = [(NSArray *)items firstObject];
    if (![firstItem isKindOfClass:[NSDictionary class]]) {
        return NO;
    }
    NSString *purchaseReceipt = firstItem[@"purchaseReceipt"];
    if (![purchaseReceipt isKindOfClass:[NSString class]] || purchaseReceipt.length == 0) {
        return NO;
    }
    if (!MCFIXPurchaseReceiptOwnerIdMatches(purchaseReceipt, expectedOwnerId)) {
        return NO;
    }

    NSString *outerReceipt = root[@"EntitlementReceipt"];
    if (![outerReceipt isKindOfClass:[NSString class]] || outerReceipt.length == 0) {
        return NO;
    }
    return MCFIXPurchaseReceiptOwnerIdMatches(outerReceipt, expectedOwnerId);
}

void MCFIXScheduleEntitlementCatalogReload(void) {
}

void MCFIXInvalidateEntitlementOwnerCache(void) {
    os_unfair_lock_lock(&gMCFIXEntitlementEnsureLock);
    [gMCFIXEnsuredEntitlementPaths removeAllObjects];
    os_unfair_lock_unlock(&gMCFIXEntitlementEnsureLock);
}

NSString *MCFIXReceiptOwnerIdForEntitlementProfile(NSString *activeXUID) {
    if (activeXUID == nil) {
        return MCFIXActiveProfileIdentity();
    }
    if (activeXUID.length == 0) {
        return @"";
    }
    return MCFIXSanitizedProfileIdentityOrOffline(activeXUID);
}

static NSString *MCFIXOwnerIdForEntitlementEnsure(NSString *activeXUID) {
    return MCFIXReceiptOwnerIdForEntitlementProfile(activeXUID);
}

NSString *MCFIXActiveProfileIdentity(void) {
    NSString *live = MCFIXCopyActiveLiveXUID();
    if (MCFIXProfileIdentityIsValidNumericXUID(live)) {
        return live;
    }
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    for (NSString *key in @[ @"last_xuid", @"MCFIX_XboxIdentity", @"MCFIX_MarketplaceIdentity" ]) {
        NSString *identity = [defs stringForKey:key];
        if (MCFIXProfileIdentityIsValidNumericXUID(identity)) {
            return identity;
        }
    }
    return MCFIXOfflineMarketplaceIdentity;
}

static NSUInteger MCFIXEntitlementIdentityHash(NSString *identity) {
    if (identity.length == 0) {
        return 0;
    }
    uint32_t hash = 0;
    for (NSUInteger i = 0; i < identity.length; i++) {
        unsigned char c = (unsigned char)[identity characterAtIndex:i];
        hash = (uint32_t)c + 31u * hash;
    }
    return (NSUInteger)hash;
}

NSString *MCFIXEntitlementStorageFileNameForIdentity(NSString *identity) {
    if (identity.length == 0) {
        return @"0.ent";
    }
    NSUInteger hash = MCFIXEntitlementIdentityHash(identity);
    return [NSString stringWithFormat:@"%lu.ent", (unsigned long)hash];
}

NSString *MCFIXEntitlementStorageFileName(void) {
    return MCFIXEntitlementStorageFileNameForIdentity(MCFIXActiveProfileIdentity());
}

BOOL MCFIXEnsureEntitlementFileAtPath(NSString *entPath, NSString *activeXUID) {
    (void)entPath;
    (void)activeXUID;
    return NO;
}

void MCFIXEnsureProductionEntitlementAtStorageRoot(NSString *storageRoot) {
    (void)storageRoot;
}

/// Inner receipt JSON: itemType + creatorId (must match outer Inventory creatorId) + ownerId (matches item+88).
static NSString *MCFIXBuildPurchaseReceiptInnerPayload(NSString *itemTypeUUID, NSString *ownerId) {
    return [NSString stringWithFormat:
        @"{\"itemType\":\"%@\",\"creatorId\":\"%@\",\"ownerId\":\"%@\"}",
        itemTypeUUID, kMCFIXMojangCreatorId, ownerId ?: @""];
}

static NSString *MCFIXEncodePurchaseReceiptInnerJSON(NSString *innerJSON) {
    if (innerJSON.length == 0) {
        return @"";
    }
    NSData *utf8 = [innerJSON dataUsingEncoding:NSUTF8StringEncoding];
    if (utf8.length == 0) {
        return @"";
    }
    NSMutableData *utf16le = [NSMutableData dataWithCapacity:utf8.length * 2];
    const unsigned char *bytes = utf8.bytes;
    for (NSUInteger i = 0; i < utf8.length; i++) {
        uint8_t pair[2] = { bytes[i], 0 };
        [utf16le appendBytes:pair length:2];
    }
    return [utf16le base64EncodedStringWithOptions:0] ?: @"";
}

static NSDictionary *MCFIXEntitlementInventoryItem(NSString *productId,
                                                   NSString *typeUUID,
                                                   NSString *friendlyName,
                                                   NSString *ownerId) {
    NSString *inner = MCFIXBuildPurchaseReceiptInnerPayload(typeUUID, ownerId);
    return @{
        @"type" : typeUUID,
        @"quantity" : @1,
        @"productId" : productId,
        @"friendlyName" : friendlyName,
        @"creatorId" : kMCFIXMojangCreatorId,
        @"purchaseReceipt" : MCFIXEncodePurchaseReceiptInnerJSON(inner),
    };
}

BOOL MCFIXGenerateProductionEntitlementFile(NSString *targetPath, NSString *ownerId) {
    if (targetPath.length == 0) {
        return NO;
    }
    NSString *receiptOwner = ownerId ?: @"";
    NSMutableArray<NSDictionary *> *items =
        [NSMutableArray arrayWithCapacity:kMCFIXProductionEntitlementCatalogCount];
    for (size_t i = 0; i < kMCFIXProductionEntitlementCatalogCount; i++) {
        const MCFIXEntitlementCatalogEntry *e = &kMCFIXProductionEntitlementCatalog[i];
        [items addObject:MCFIXEntitlementInventoryItem(@(e->productId), @(e->typeUUID),
                                                         @(e->friendlyName), receiptOwner)];
    }

    NSString *entitlementReceiptInner = [NSString stringWithFormat:
        @"{\"OwnerId\":\"%@\",\"DeviceId\":\"\"}", receiptOwner];
    NSDictionary *root = @{
        @"Balance" : @0,
        @"EntitlementReceipt" : MCFIXEncodePurchaseReceiptInnerJSON(entitlementReceiptInner),
        @"Inventory" : @{ @"items" : items },
    };

    NSError *err = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:root options:0 error:&err];
    if (!json || err) {
        MCFIXLog(MCFIXLogCatError, @"0.ent JSON build failed: %@", err);
        return NO;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [targetPath stringByDeletingLastPathComponent];
    BOOL prevBypass = MCFIXBypassHooksActive();
    MCFIXBypassHooksSet(YES);
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    BOOL ok = [json writeToFile:targetPath options:NSDataWritingAtomic error:&err];
    if (ok) {
        MCFIXLogOnce(MCFIXLogCatVFS, [NSString stringWithFormat:@"ent_seed_%@", targetPath.lastPathComponent],
                     @"wrote production entitlement (%lu items, ownerId='%@') @ %@",
                     (unsigned long)items.count, receiptOwner, targetPath);
    } else {
        MCFIXLog(MCFIXLogCatError, @"0.ent write failed %@: %@", targetPath, err);
    }
    MCFIXBypassHooksSet(prevBypass);
    return ok;
}

void MCFIXGenerateDefaultProductionEntitlementFile(NSString *targetPath, NSString *activeXUID) {
    NSString *ownerId = MCFIXOwnerIdForEntitlementEnsure(activeXUID);
    MCFIXGenerateProductionEntitlementFile(targetPath, ownerId);
}

void MCFIXEnsureMinecraftSavesAndMigrateFromTempIfNeeded(void) {
    (void)MCFIXMinecraftSavesBasePath();
    // v2: base path moved Application Support → Caches (tvOS sideload EPERM on mkdir App Support).
    static NSString *const kMigratedTempKey = @"MinecraftStorageFix_6E64_migrated_games_com_mojang_v2";
    static NSString *const kMigratedLegacyASKey =
        @"MinecraftStorageFix_legacy_ApplicationSupport_MinecraftSaves_v2";

    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *newBase = MCFIXMinecraftSavesBasePath();
    NSString *newGames =
        [[[newBase stringByAppendingPathComponent:@"games"] stringByAppendingPathComponent:@"com.mojang"]
            stringByStandardizingPath];

    // 1) tmp/Temp/games/com.mojang → …/Caches/…/MinecraftSaves/games/com.mojang
    if (![defs boolForKey:kMigratedTempKey]) {
        NSString *tempRoot =
            [[NSTemporaryDirectory() stringByAppendingPathComponent:@"Temp"] stringByStandardizingPath];
        NSString *oldGames = [[[tempRoot stringByAppendingPathComponent:@"games"]
            stringByAppendingPathComponent:@"com.mojang"] stringByStandardizingPath];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:oldGames isDirectory:&isDir] && isDir &&
            !([fm fileExistsAtPath:newGames isDirectory:&isDir] && isDir)) {
            NSError *e = nil;
            if (![fm createDirectoryAtPath:newGames.stringByDeletingLastPathComponent
                     withIntermediateDirectories:YES
                                      attributes:nil
                                           error:&e]) {
                MCFIXLog(MCFIXLogCatError, @"mkdir parent for migrate: %@", e);
            }
            e = nil;
            if (![fm moveItemAtPath:oldGames toPath:newGames error:&e]) {
                MCFIXLog(MCFIXLogCatError, @"migrate games/com.mojang: %@", e);
            } else {
                MCFIXLogOnce(MCFIXLogCatVFS, @"migrate_games", @"migrated %@ -> %@", oldGames, newGames);
            }
        }
        [defs setBool:YES forKey:kMigratedTempKey];
        [defs synchronize];
    }

    // 2) Older builds used Library/Application Support/MinecraftSaves — move once if present.
    if (![defs boolForKey:kMigratedLegacyASKey]) {
        BOOL destDir = NO;
        if ([fm fileExistsAtPath:newGames isDirectory:&destDir] && destDir) {
            [defs setBool:YES forKey:kMigratedLegacyASKey];
            [defs synchronize];
        } else {
            NSURL *asu = [fm URLForDirectory:NSApplicationSupportDirectory
                                     inDomain:NSUserDomainMask
                            appropriateForURL:nil
                                       create:NO
                                        error:nil];
            NSString *legacyGames = nil;
            if (asu.path.length > 0) {
                legacyGames =
                    [[[[asu.path stringByAppendingPathComponent:@"MinecraftSaves"]
                        stringByAppendingPathComponent:@"games"]
                        stringByAppendingPathComponent:@"com.mojang"] stringByStandardizingPath];
            }
            BOOL legDir = NO;
            if (legacyGames.length &&
                [fm fileExistsAtPath:legacyGames isDirectory:&legDir] && legDir) {
                NSError *e = nil;
                if ([fm createDirectoryAtPath:newGames.stringByDeletingLastPathComponent
                         withIntermediateDirectories:YES
                                          attributes:nil
                                               error:&e]) {
                    e = nil;
                    if ([fm moveItemAtPath:legacyGames toPath:newGames error:&e]) {
                        MCFIXLogOnce(MCFIXLogCatVFS, @"migrate_legacy", @"migrated legacy %@", legacyGames);
                    } else {
                        MCFIXLog(MCFIXLogCatError, @"legacy App Support move: %@", e);
                    }
                }
            }
            [defs setBool:YES forKey:kMigratedLegacyASKey];
            [defs synchronize];
        }
    }
}
