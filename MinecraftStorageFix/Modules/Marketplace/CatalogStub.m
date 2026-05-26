// Minimal binary catalog stub — byte layout must match working tweak-1-1.3_works.
// IDA sub_100854430 @ 0x100854560: 256 bytes, byte[0]==0, magic @ offset 4 == 0x9BCFBADF,
// version length byte[1], version C-string @ byte[2..] (must NOT overlap offset 4).
// Working stub: byte[1]=0 (empty version), magic intact, byte[16..17] auxiliary (ignored offline).

#import "CatalogStub.h"
#import "MCFIXGameDataVFS.h"
#import "MCFIXLog.h"
#import "../Util/MCFIXBypass.h"
#import "../VFS/Bootstrap.h"

BOOL MCFIXPathMentionsCatalog(NSString *path) {
    if (path.length == 0) {
        return NO;
    }
    return [path containsString:@"catalog_info.json"] ||
           [path containsString:@"MarketplaceDurableCatalog"];
}

static BOOL MCFIXCatalogStubBytesValidWorkingLayout(const unsigned char *b, size_t len) {
    if (b == NULL || len != 256) {
        return NO;
    }
    if (b[0] != 0 || b[1] != 0) {
        return NO;
    }
    if (*(const uint32_t *)(b + 4) != (uint32_t)0x9BCFBADF) {
        return NO;
    }
    return YES;
}

BOOL MCFIXWriteBinaryCatalogStubInDirectory(NSString *dir) {
    if (dir.length == 0) {
        return NO;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"catalog_info.json"];
    NSData *existing = [fm fileExistsAtPath:path] ? [NSData dataWithContentsOfFile:path] : nil;
    if (MCFIXCatalogStubBytesValidWorkingLayout(existing.bytes, existing.length)) {
        return YES;
    }
    if (existing.length > 0) {
        [fm removeItemAtPath:path error:nil];
        MCFIXLogOnce(MCFIXLogCatVFS, [NSString stringWithFormat:@"catalog_repair_%@", path],
                     @"removed invalid catalog_info.json (IDA sub_100854430 layout) @ %@", path);
    }

    unsigned char buf[256] = {0};
    *(uint32_t *)(buf + 4) = (uint32_t)0x9BCFBADF;
    buf[16] = 1;
    buf[17] = '1';

    NSData *data = [NSData dataWithBytes:buf length:sizeof(buf)];
    BOOL ok = [fm createFileAtPath:path contents:data attributes:nil];
    if (ok) {
        MCFIXLogOnce(MCFIXLogCatVFS, [NSString stringWithFormat:@"catalog_%@", path],
                     @"wrote catalog stub %@", path);
    }
    return ok;
}

static void MCFIXRemoveMisplacedCatalogInfoAtMojangRoot(NSString *mojangRoot, NSFileManager *fm) {
    if (mojangRoot.length == 0) {
        return;
    }
    NSString *wrong =
        [[mojangRoot stringByAppendingPathComponent:@"catalog_info.json"] stringByStandardizingPath];
    if ([fm fileExistsAtPath:wrong]) {
        [fm removeItemAtPath:wrong error:nil];
        MCFIXLogOnce(MCFIXLogCatVFS, @"catalog_remove_misplaced",
                     @"removed misplaced catalog_info.json @ %@", wrong);
    }
}

void MCFIXSeedMarketplaceCatalogStubs(void) {
    NSString *vfs = MCFIXGameDataVFSSandboxRoot();
    NSArray<NSString *> *relDirs = @[
        @"Library/games/com.mojang",
        @"Library/games/com.mojang/MarketplaceDurableCatalog_V1.1",
        @"Documents/games/com.mojang",
        @"Documents/games/com.mojang/MarketplaceDurableCatalog_V1.1",
        @"tmp/Temp/games/com.mojang",
        @"tmp/Temp/games/com.mojang/MarketplaceDurableCatalog_V1.1",
        @"tmp/minecraftpe/games/com.mojang",
        @"tmp/minecraftpe/games/com.mojang/MarketplaceDurableCatalog_V1.1",
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *rel in relDirs) {
        NSString *dir = [[vfs stringByAppendingPathComponent:rel] stringByStandardizingPath];
        NSString *parent = [dir stringByDeletingLastPathComponent];
        if ([dir.lastPathComponent isEqualToString:@"MarketplaceDurableCatalog_V1.1"]) {
            MCFIXRemoveMisplacedCatalogInfoAtMojangRoot(parent, fm);
        }
        MCFIXWriteBinaryCatalogStubInDirectory(dir);
    }
    MCFIXLogOnce(MCFIXLogCatVFS, @"catalog_layout_seed",
                 @"marketplace catalog stubs (working 256-byte layout, 8 mirrors)");
}

void MCFIXSeedPremiumCacheDirectories(void) {
    NSString *vfs = MCFIXGameDataVFSSandboxRoot();
    NSArray<NSString *> *relDirs = @[
        @"Library/games/com.mojang/premium_cache",
        @"Library/games/com.mojang/premium_cache/skin_packs",
        @"tmp/Temp/games/com.mojang/premium_cache",
        @"tmp/Temp/games/com.mojang/premium_cache/skin_packs",
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *rel in relDirs) {
        NSString *dir = [[vfs stringByAppendingPathComponent:rel] stringByStandardizingPath];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    MCFIXLogOnce(MCFIXLogCatVFS, @"premium_cache_seed", @"premium_cache dirs seeded on VFS");
}

void MCFIXMirrorMarketplaceTreeToContainer(void) {
    BOOL prevBypass = MCFIXBypassHooksActive();
    MCFIXBypassHooksSet(YES);
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *vfs = MCFIXGameDataVFSSandboxRoot();
        NSString *home = NSHomeDirectory();
        NSString *mojangRoot =
            [[home stringByAppendingPathComponent:@"tmp/Temp/games/com.mojang"]
                stringByStandardizingPath];
        NSString *catalog =
            [mojangRoot stringByAppendingPathComponent:@"MarketplaceDurableCatalog_V1.1"];

        [fm createDirectoryAtPath:mojangRoot withIntermediateDirectories:YES attributes:nil error:nil];
        MCFIXRemoveMisplacedCatalogInfoAtMojangRoot(mojangRoot, fm);
        [fm createDirectoryAtPath:catalog withIntermediateDirectories:YES attributes:nil error:nil];
        MCFIXWriteBinaryCatalogStubInDirectory(catalog);

    }
    MCFIXBypassHooksSet(prevBypass);
    MCFIXLogOnce(MCFIXLogCatBoot, @"marketplace_mirror",
                 @"container working catalog stub");
}

void MCFIXEnsureCatalogStubForPOSIXPath(const char *resolvedPath) {
    if (resolvedPath == NULL || !strstr(resolvedPath, "catalog_info.json")) {
        return;
    }
    @autoreleasepool {
        NSString *ps = [NSString stringWithUTF8String:resolvedPath];
        if (ps.length == 0) {
            return;
        }
        MCFIXWriteBinaryCatalogStubInDirectory([ps stringByDeletingLastPathComponent]);
    }
}
