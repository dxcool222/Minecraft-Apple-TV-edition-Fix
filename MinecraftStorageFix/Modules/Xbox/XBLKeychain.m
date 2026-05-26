// Sideload Xbox Live keychain + MSA login fixes.
//
// XBL: -[XBLKeychainStorage dictionaryForKeychainQuery:] hardcodes the
// keychain access group "com.microsoft.xboxliveservices" (or the Mojang
// team-prefixed form). Sideloaded apps can never be entitled to that
// group; mcfix_xbl_replacement_dictForKeychainQuery rewrites it on the
// fly to <TEAM>.<thisBundleId>, picked up from AppIdentifierPrefix or
// the running app's SecTask entitlements.
//
// MSA: -[XBLMSADeviceClient msaAppID] builds the OAuth client_id from
// CFBundleIdentifier. The sideload bundle id (e.g. sh.local.minecraft)
// is unregistered → device-code flow returns HTTP 400. Force the retail
// id so the OAuth client_id matches an active app registration.

#import "XBLKeychain.h"

#import <CoreFoundation/CoreFoundation.h>
#import <Security/Security.h>
#import <dlfcn.h>

XBL_DictionaryForQuery_t gXBLKeychainStorage_orig_dictForQuery = NULL;

typedef void *MCFIXSecTaskRef;
typedef MCFIXSecTaskRef (*MCFIXSecTaskCreateFromSelf_t)(void *allocator);
typedef CFTypeRef       (*MCFIXSecTaskCopyValueForEntitlement_t)(MCFIXSecTaskRef task,
                                                                CFStringRef key, void *errorOut);

static MCFIXSecTaskCreateFromSelf_t          mcfix_SecTaskCreateFromSelf          = NULL;
static MCFIXSecTaskCopyValueForEntitlement_t mcfix_SecTaskCopyValueForEntitlement = NULL;

static void MCFIXResolveSecTaskIfAvailable(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *sec = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW);
        if (!sec) return;
        mcfix_SecTaskCreateFromSelf =
            (MCFIXSecTaskCreateFromSelf_t)dlsym(sec, "SecTaskCreateFromSelf");
        mcfix_SecTaskCopyValueForEntitlement =
            (MCFIXSecTaskCopyValueForEntitlement_t)dlsym(sec, "SecTaskCopyValueForEntitlement");
    });
}

static NSString *MCFIXMinecraftMainBundleId(void) {
    NSString *b = [NSBundle mainBundle].bundleIdentifier;
    return (b.length > 0) ? b : @"com.mojang.minecraftappletv";
}

static NSString *MCFIXTeamIdFromSecTaskApplicationIdentifier(void) {
    MCFIXResolveSecTaskIfAvailable();
    if (!mcfix_SecTaskCreateFromSelf || !mcfix_SecTaskCopyValueForEntitlement) return nil;
    MCFIXSecTaskRef task = mcfix_SecTaskCreateFromSelf((void *)kCFAllocatorDefault);
    if (!task) return nil;
    CFTypeRef v = mcfix_SecTaskCopyValueForEntitlement(task, CFSTR("application-identifier"), NULL);
    CFRelease((CFTypeRef)task);
    if (!v) return nil;
    if (CFGetTypeID(v) != CFStringGetTypeID()) {
        CFRelease(v);
        return nil;
    }
    NSString *s = (__bridge NSString *)v;
    NSRange d = [s rangeOfString:@"."];
    NSString *out = (d.location > 0) ? [s substringToIndex:d.location] : nil;
    CFRelease(v);
    return out.length > 0 ? out : nil;
}

static NSString *MCFIXRemapXboxKeychainAccessGroup(NSString *accessGroup) {
    if (accessGroup.length == 0) return nil;
    if ([accessGroup rangeOfString:@"com.microsoft.xboxliveservices"].location == NSNotFound) return nil;

    NSString *ov = [[NSUserDefaults standardUserDefaults]
        stringForKey:@"MinecraftStorageFixXboxKeychainGroup"];
    if (ov.length > 0) return ov;

    NSString *team = nil;
    id prefix = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"AppIdentifierPrefix"];
    if ([prefix isKindOfClass:[NSString class]] && [(NSString *)prefix length] > 0) {
        team = [(NSString *)prefix
            stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@". "]];
    }
    if (team.length == 0) team = MCFIXTeamIdFromSecTaskApplicationIdentifier();
    if (team.length > 0) {
        return [NSString stringWithFormat:@"%@.%@", team, MCFIXMinecraftMainBundleId()];
    }
    NSRange r = [accessGroup rangeOfString:@"com.microsoft.xboxliveservices"];
    if (r.location == NSNotFound) return nil;
    return [accessGroup stringByReplacingCharactersInRange:r
                                                withString:MCFIXMinecraftMainBundleId()];
}

id mcfix_xbl_replacement_dictForKeychainQuery(id self, SEL _cmd, id key) {
    if (!gXBLKeychainStorage_orig_dictForQuery) return nil;
    id d = gXBLKeychainStorage_orig_dictForQuery(self, _cmd, key);
    if (!d) return d;
    NSMutableDictionary *m = [d isKindOfClass:[NSMutableDictionary class]] ? d : [d mutableCopy];
    if (![m isKindOfClass:[NSMutableDictionary class]]) return d;
    id ag = m[(id)kSecAttrAccessGroup];
    if (![ag isKindOfClass:[NSString class]]) return m;
    NSString *remapped = MCFIXRemapXboxKeychainAccessGroup((NSString *)ag);
    if (remapped.length > 0) m[(id)kSecAttrAccessGroup] = remapped;
    return m;
}

NSString *mcfix_msaAppID_replacement(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return @"ios-app://com.mojang.minecraftappletv";
}
