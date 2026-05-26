// Live XUID capture for marketplace identity parity (IDA tvOS 1.1.5).
//
// Runtime identity for item+88:
//   sub_1006618E8 → sub_10060B010 → sub_10117A778(xboxUser+40) → 16-digit XUID std::string
// Persistence to options (`last_xuid`) is async via sub_1004259F4 in sub_10041FE78 — too late
// for POSIX fopen hot paths. We mirror the runtime string at capture time instead.

#import "XBLIdentityCapture.h"
#import "../Marketplace/MCFIXMarketplaceIdentity.h"
#import "../VFS/Bootstrap.h"
#import "MCFIXLog.h"

#import <os/lock.h>

static NSString *gMCFIXActiveLiveXUID = nil;
static os_unfair_lock gMCFIXLiveXUIDLock = OS_UNFAIR_LOCK_INIT;

BOOL MCFIXProfileIdentityIsValidNumericXUID(NSString *identity) {
    if (identity.length != 16) {
        return NO;
    }
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    return [identity rangeOfCharacterFromSet:nonDigits].location == NSNotFound;
}

NSString *MCFIXSanitizedProfileIdentityOrOffline(NSString *candidate) {
    if (MCFIXProfileIdentityIsValidNumericXUID(candidate)) {
        return candidate;
    }
    return MCFIXOfflineMarketplaceIdentity;
}

void MCFIXCaptureActiveLiveXUID(NSString *candidate) {
    if (!MCFIXProfileIdentityIsValidNumericXUID(candidate)) {
        return;
    }
    os_unfair_lock_lock(&gMCFIXLiveXUIDLock);
    if ([gMCFIXActiveLiveXUID isEqualToString:candidate]) {
        os_unfair_lock_unlock(&gMCFIXLiveXUIDLock);
        return;
    }
    gMCFIXActiveLiveXUID = [candidate copy];
    os_unfair_lock_unlock(&gMCFIXLiveXUIDLock);
    MCFIXInvalidateEntitlementOwnerCache();
    MCFIXLogOnce(MCFIXLogCatXBL, @"xuid_capture",
                 @"captured live XUID=%@ (VFS/.ent hot path)", candidate);
}

NSString *MCFIXCopyActiveLiveXUID(void) {
    os_unfair_lock_lock(&gMCFIXLiveXUIDLock);
    NSString *copy = gMCFIXActiveLiveXUID ? [gMCFIXActiveLiveXUID copy] : nil;
    os_unfair_lock_unlock(&gMCFIXLiveXUIDLock);
    return copy;
}

void MCFIXClearActiveLiveXUID(void) {
    os_unfair_lock_lock(&gMCFIXLiveXUIDLock);
    gMCFIXActiveLiveXUID = nil;
    os_unfair_lock_unlock(&gMCFIXLiveXUIDLock);
    MCFIXInvalidateEntitlementOwnerCache();
}

void MCFIXTryCaptureXUIDFromXboxRequestURL(NSURL *url) {
    if (url.absoluteString.length == 0) {
        return;
    }
    static NSRegularExpression *re = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"(?i)xuid\\((\\d{16})\\)"
                                                       options:0
                                                         error:nil];
    });
    if (!re) {
        return;
    }
    NSString *s = url.absoluteString;
    NSTextCheckingResult *m = [re firstMatchInString:s
                                             options:0
                                               range:NSMakeRange(0, s.length)];
    if (m.numberOfRanges < 2) {
        return;
    }
    NSString *xuid = [s substringWithRange:[m rangeAtIndex:1]];
    MCFIXCaptureActiveLiveXUID(xuid);
}
