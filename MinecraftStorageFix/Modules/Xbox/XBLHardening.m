// XBLServiceManager request-signing hardening.
//
// IDA: -[XBLServiceManager getTokenAndSignRequestSynchronously:completion:]
// injects Authorization + Signature headers into the URL request. On slow
// or contended token-fetch paths the original sometimes calls completion
// with the unsigned request — Xbox Live then returns 401. This category
// is installed via method_exchangeImplementations from
// +[MinecraftStorageFix installXBLServiceManagerGuardsOnce] so
// every call goes through here: check headers, retry once if missing.

#import <Foundation/Foundation.h>
#import "MCFIXLog.h"
#import "XBLIdentityCapture.h"

static BOOL mcfix_xblRequestNeedsSignedHeaders(NSURLRequest *req) {
    NSURL *u = req.URL;
    if (!u) return NO;
    NSString *host = u.host.lowercaseString ?: @"";
    NSString *path = u.path.lowercaseString ?: @"";
    if (host.length == 0 && path.length == 0) return NO;
    BOOL hostMatch = ([host rangeOfString:@"xboxlive"].location != NSNotFound) ||
                     ([host rangeOfString:@"xsts"].location != NSNotFound) ||
                     ([host rangeOfString:@"user.auth"].location != NSNotFound) ||
                     ([host rangeOfString:@"title.mgt"].location != NSNotFound) ||
                     ([host rangeOfString:@"minecraft.net"].location != NSNotFound) ||
                     ([host rangeOfString:@"mojang"].location != NSNotFound) ||
                     ([host rangeOfString:@"blob.core.windows.net"].location != NSNotFound);
    BOOL pathMatch = ([path rangeOfString:@"xsts"].location != NSNotFound) ||
                     ([path rangeOfString:@"title"].location != NSNotFound) ||
                     ([path rangeOfString:@"users"].location != NSNotFound);
    return hostMatch || pathMatch;
}

static BOOL mcfix_xblHasAuthHeaders(NSURLRequest *req) {
    NSString *auth = [req valueForHTTPHeaderField:@"Authorization"];
    NSString *sig  = [req valueForHTTPHeaderField:@"Signature"];
    return auth.length > 0 && sig.length > 0;
}

@interface NSObject (XBLHardeningMethods)
- (void)mcfix_xbl_getTokenAndSignRequestSynchronously:(id)request
                                           completion:(void (^)(id signedRequest, NSError *error))completion;
@end

@implementation NSObject (XBLHardeningMethods)

- (void)mcfix_xbl_getTokenAndSignRequestSynchronously:(id)request
                                           completion:(void (^)(id signedRequest, NSError *error))completion {
    if (!request || ![request isKindOfClass:[NSMutableURLRequest class]]) {
        [self mcfix_xbl_getTokenAndSignRequestSynchronously:request completion:completion];
        return;
    }

    NSMutableURLRequest *req = (NSMutableURLRequest *)request;
    MCFIXTryCaptureXUIDFromXboxRequestURL(req.URL);
    __block BOOL completionFired = NO;
    void (^fireCompletionOnce)(id, NSError *) = ^(id signedReq, NSError *err) {
        if (!completion) return;
        @synchronized (req) {
            if (completionFired) return;
            completionFired = YES;
        }
        completion(signedReq, err);
    };

    __weak __typeof(self) weakSelf = self;
    [self mcfix_xbl_getTokenAndSignRequestSynchronously:req completion:^(id signedRequest, NSError *error) {
        BOOL needsHeaders = mcfix_xblRequestNeedsSignedHeaders(req);
        BOOL signedOK = [signedRequest isKindOfClass:[NSURLRequest class]] &&
                        mcfix_xblHasAuthHeaders((NSURLRequest *)signedRequest);
        if (!needsHeaders || signedOK) {
            if (needsHeaders) {
                NSURL *u = req.URL;
                if ([signedRequest isKindOfClass:[NSURLRequest class]]) {
                    MCFIXTryCaptureXUIDFromXboxRequestURL(((NSURLRequest *)signedRequest).URL);
                }
                MCFIXTryCaptureXUIDFromXboxRequestURL(u);
                MCFIXLogRate(MCFIXLogCatXBL, @"xbl_sign_ok", 30.0,
                             @"request signed correctly host=%@ path=%@",
                             u.host ?: @"", u.path ?: @"");
            }
            fireCompletionOnce(signedRequest, error);
            return;
        }

        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            fireCompletionOnce(signedRequest, error);
            return;
        }

        NSMutableURLRequest *retryReq = [req mutableCopy];
        [strongSelf mcfix_xbl_getTokenAndSignRequestSynchronously:retryReq completion:^(id signedRequest2, NSError *error2) {
            BOOL signedOK2 = [signedRequest2 isKindOfClass:[NSURLRequest class]] &&
                             mcfix_xblHasAuthHeaders((NSURLRequest *)signedRequest2);
            if (signedOK2) {
                NSURL *u = req.URL;
                if ([signedRequest2 isKindOfClass:[NSURLRequest class]]) {
                    MCFIXTryCaptureXUIDFromXboxRequestURL(((NSURLRequest *)signedRequest2).URL);
                }
                MCFIXTryCaptureXUIDFromXboxRequestURL(u);
                MCFIXLogOnce(MCFIXLogCatXBL, @"xbl_sign_retry_ok",
                             @"request signed correctly after retry host=%@ path=%@",
                             u.host ?: @"", u.path ?: @"");
                fireCompletionOnce(signedRequest2, error2);
                return;
            }
            NSMutableDictionary *ui = [NSMutableDictionary dictionaryWithObject:
                @"XBL signing failed: missing Authorization/Signature headers"
                forKey:NSLocalizedDescriptionKey];
            NSError *underlying = error2 ?: error;
            if (underlying) ui[NSUnderlyingErrorKey] = underlying;
            NSError *finalErr = [NSError errorWithDomain:@"MinecraftStorageFix.XBL"
                                                     code:1001
                                                 userInfo:ui];
            NSURL *u = req.URL;
            MCFIXLog(MCFIXLogCatError,
                     @"XBL retry failed host=%@ path=%@ error=%@",
                     u.host ?: @"", u.path ?: @"", finalErr);
            fireCompletionOnce(nil, finalErr);
        }];
    }];
}

@end
