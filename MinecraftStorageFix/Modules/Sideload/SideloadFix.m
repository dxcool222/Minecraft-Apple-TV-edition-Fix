// Sideload runtime fixes (formerly SideloadFix.framework).
//
// 1) NSFileManager -containerURLForSecurityApplicationGroupIdentifier:
//    Sideloaded apps without app-group entitlements get nil from the
//    stock implementation. We point any unresolved query at a per-app
//    fallback dir under Library/SideloadFix/AppGroups so app-group
//    consumers see a stable URL.
//
// 2) LSBundleProxy -entitlements
//    Strip iCloud-related entitlement keys from any returned dict so
//    downstream code that gates on those keys takes the "no iCloud" path
//    cleanly instead of trying to use unavailable services.
//
// 3) StoreKit shim
//    -[SKPaymentQueue canMakePayments] → YES, and
//    -[SKReceiptRefreshRequest start] short-circuits to delegate's
//    requestDidFinish: so the chooser's "Confirm" button doesn't hang
//    when sandbox StoreKit is unreachable.

#import "SideloadFix.h"

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <StoreKit/StoreKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

@interface LSBundleProxy : NSObject
+ (instancetype)bundleProxyForCurrentProcess;
- (NSDictionary *)entitlements;
- (NSDictionary<NSString *, NSURL *> *)groupContainerURLs;
@end

static IMP SLFSwizzle(Class cls, SEL sel, IMP replacement) {
    Method m = class_getInstanceMethod(cls, sel);
    return m ? method_setImplementation(m, replacement) : NULL;
}

#pragma mark - App-group container fallback

static NSURL *gFallbackAppGroupURL;
static NSURL *(*orig_containerURLForSecurityApplicationGroupIdentifier)(id, SEL, NSString *);

static NSURL *slf_containerURLForSecurityApplicationGroupIdentifier(id self, SEL _cmd, NSString *groupId) {
    NSURL *real = orig_containerURLForSecurityApplicationGroupIdentifier(self, _cmd, groupId);
    if (real || !gFallbackAppGroupURL) return real;

    NSURL *scoped = [gFallbackAppGroupURL URLByAppendingPathComponent:groupId ?: @"_default"
                                                          isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:scoped
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    return scoped;
}

static NSURL *SLFResolveFallbackAppGroupURL(void) {
    Class proxyCls = NSClassFromString(@"LSBundleProxy");
    LSBundleProxy *bp = proxyCls ? [proxyCls bundleProxyForCurrentProcess] : nil;
    NSDictionary<NSString *, NSURL *> *groups = [bp groupContainerURLs];
    if ([groups isKindOfClass:[NSDictionary class]] && groups.count > 0) {
        return groups.allValues.firstObject;
    }
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/SideloadFix/AppGroups"];
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return [NSURL fileURLWithPath:path isDirectory:YES];
}

#pragma mark - LSBundleProxy entitlements spoof

static NSString *const kSLFStripEntitlements[] = {
    @"com.apple.developer.icloud-container-environment",
    @"com.apple.developer.icloud-services",
    @"com.apple.developer.icloud-container-identifiers",
    @"com.apple.developer.ubiquity-container-identifiers",
    @"com.apple.developer.ubiquity-kvstore-identifier",
};
static const size_t kSLFStripEntitlementsCount =
    sizeof(kSLFStripEntitlements) / sizeof(kSLFStripEntitlements[0]);

static NSDictionary *(*orig_LSBundleProxy_entitlements)(id, SEL);

static NSDictionary *slf_LSBundleProxy_entitlements(id self, SEL _cmd) {
    NSDictionary *real = orig_LSBundleProxy_entitlements(self, _cmd);
    if (![real isKindOfClass:[NSDictionary class]]) return real;

    NSMutableDictionary *m = nil;
    for (size_t i = 0; i < kSLFStripEntitlementsCount; i++) {
        NSString *key = kSLFStripEntitlements[i];
        if (!real[key]) continue;
        if (!m) m = [real mutableCopy];
        [m removeObjectForKey:key];
    }
    return m ?: real;
}

#pragma mark - StoreKit shim

static BOOL slf_SKPaymentQueue_canMakePayments(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return YES;
}

static void slf_SKReceiptRefreshRequest_start(id self, SEL _cmd) {
    (void)_cmd;
    id delegate = [self performSelector:@selector(delegate)];
    if (delegate && [delegate respondsToSelector:@selector(requestDidFinish:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [delegate performSelector:@selector(requestDidFinish:) withObject:self];
        });
    }
}

#pragma mark - Install

void MCFIXInstallSideloadFixes(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gFallbackAppGroupURL = SLFResolveFallbackAppGroupURL();
        orig_containerURLForSecurityApplicationGroupIdentifier = (void *)SLFSwizzle(
            [NSFileManager class],
            @selector(containerURLForSecurityApplicationGroupIdentifier:),
            (IMP)slf_containerURLForSecurityApplicationGroupIdentifier);

        Class proxyCls = NSClassFromString(@"LSBundleProxy");
        if (proxyCls) {
            orig_LSBundleProxy_entitlements = (void *)SLFSwizzle(
                proxyCls, @selector(entitlements), (IMP)slf_LSBundleProxy_entitlements);
        }

        Class queueCls = NSClassFromString(@"SKPaymentQueue");
        if (queueCls) {
            Method m = class_getClassMethod(queueCls, @selector(canMakePayments));
            if (m) method_setImplementation(m, (IMP)slf_SKPaymentQueue_canMakePayments);
        }

        Class refreshCls = NSClassFromString(@"SKReceiptRefreshRequest");
        if (refreshCls) {
            Method m = class_getInstanceMethod(refreshCls, @selector(start));
            if (m) method_setImplementation(m, (IMP)slf_SKReceiptRefreshRequest_start);
        }
    });
}
