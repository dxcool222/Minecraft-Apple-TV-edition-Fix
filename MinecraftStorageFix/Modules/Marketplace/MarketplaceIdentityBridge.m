// Offline marketplace identity bridge — NSUserDefaults swizzle only (no __TEXT hooks).
//
// IDA tvOS 1.1.5: offline sub_100661820 falls back to storage profile config (e.g.
// clientId.txt under minecraftpe roots). VFS seeds that file in Bootstrap.m; this module
// aligns NSUserDefaults keys used by receipt/.ent generation with the same XUID.
//
// Live identity: sub_10117A778 reads the Xbox user object — not the plist cache. We
// capture `last_xuid` / MCFIX_* at setObject time into gMCFIXActiveLiveXUID so VFS
// fopen/stat hooks never wait on NSUserDefaults synchronization.
//
// ZERO-INLINE-HOOK policy: no vm_protect / sub_100661820 patches on device.

#import "MCFIXMarketplaceIdentity.h"
#import "../Xbox/XBLIdentityCapture.h"
#import "MCFIXLog.h"

#import <objc/runtime.h>

NSString *const MCFIXOfflineMarketplaceIdentity = @"0000000000000000";

static NSString *(*gOrigNSStringForKey)(id, SEL, NSString *) = NULL;
static id (*gOrigObjectForKey)(id, SEL, NSString *) = NULL;
static void (*gOrigSetObjectForKey)(id, SEL, id, NSString *) = NULL;

static BOOL mcfix_is_marketplace_profile_defaults_key(NSString *key) {
    if (key.length == 0) return NO;
    static NSSet<NSString *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = [NSSet setWithArray:@[
            @"MCFIX_MarketplaceIdentity",
            @"MCFIX_XboxIdentity",
            @"last_xuid",
        ]];
    });
    return [keys containsObject:key];
}

static NSString *mcfix_offline_profile_identity_string(void) {
    return MCFIXOfflineMarketplaceIdentity;
}

static NSString *mcfix_profile_identity_for_read(NSString *key, NSString *defaultsValue) {
    if (mcfix_is_marketplace_profile_defaults_key(key)) {
        NSString *live = MCFIXCopyActiveLiveXUID();
        if (MCFIXProfileIdentityIsValidNumericXUID(live)) {
            return live;
        }
        if (MCFIXProfileIdentityIsValidNumericXUID(defaultsValue)) {
            return defaultsValue;
        }
        return mcfix_offline_profile_identity_string();
    }
    return defaultsValue;
}

static NSString *mcfix_stringForKey_profile_bridge(id self, SEL _cmd, NSString *key) {
    NSString *value = gOrigNSStringForKey ? gOrigNSStringForKey(self, _cmd, key) : nil;
    if (!mcfix_is_marketplace_profile_defaults_key(key)) {
        return value;
    }
    return mcfix_profile_identity_for_read(key, value);
}

static id mcfix_objectForKey_profile_bridge(id self, SEL _cmd, NSString *key) {
    id value = gOrigObjectForKey ? gOrigObjectForKey(self, _cmd, key) : nil;
    if (!mcfix_is_marketplace_profile_defaults_key(key)) {
        return value;
    }
    if ([value isKindOfClass:[NSString class]]) {
        return mcfix_profile_identity_for_read(key, (NSString *)value);
    }
    return mcfix_profile_identity_for_read(key, nil);
}

static void mcfix_setObject_forKey_profile_bridge(id self, SEL _cmd, id obj, NSString *key) {
    if (mcfix_is_marketplace_profile_defaults_key(key) && [obj isKindOfClass:[NSString class]]) {
        MCFIXCaptureActiveLiveXUID((NSString *)obj);
    }
    if (gOrigSetObjectForKey) {
        gOrigSetObjectForKey(self, _cmd, obj, key);
    }
}

void MCFIXInstallMarketplaceIdentityBridge(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = [NSUserDefaults class];
        Method mStr = class_getInstanceMethod(cls, @selector(stringForKey:));
        Method mObj = class_getInstanceMethod(cls, @selector(objectForKey:));
        Method mSet = class_getInstanceMethod(cls, @selector(setObject:forKey:));
        if (mStr) {
            gOrigNSStringForKey = (NSString *(*)(id, SEL, NSString *))method_getImplementation(mStr);
            method_setImplementation(mStr, (IMP)mcfix_stringForKey_profile_bridge);
        }
        if (mObj) {
            gOrigObjectForKey = (id (*)(id, SEL, NSString *))method_getImplementation(mObj);
            method_setImplementation(mObj, (IMP)mcfix_objectForKey_profile_bridge);
        }
        if (mSet) {
            gOrigSetObjectForKey = (void (*)(id, SEL, id, NSString *))method_getImplementation(mSet);
            method_setImplementation(mSet, (IMP)mcfix_setObject_forKey_profile_bridge);
        }
        MCFIXLogOnce(MCFIXLogCatBoot, @"identity_defaults_swizzle",
                     @"NSUserDefaults profile keys: live capture + offline fallback "
                     @"(string=%d object=%d setObject=%d)",
                     mStr ? 1 : 0, mObj ? 1 : 0, mSet ? 1 : 0);
    });
}
