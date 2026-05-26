// Sideload APS / User Notifications stubs.
//
// Sideloaded apps lack the aps-environment entitlement, so
// -[UIApplication registerForRemoteNotifications] hangs (no apsd handshake)
// and UNUserNotificationCenter requestAuthorization can block on system
// permission UI. Both selectors are swizzled in
// +[MinecraftStorageFix patchSideloadPushAndUserNotifications] to point at
// the *_nop_ / *_fast_ stubs below — bootstrap completes without push.

#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/message.h>

@interface UIApplication (MinecraftStorageFixPushStub)
@end

@implementation UIApplication (MinecraftStorageFixPushStub)

- (void)mcfix_nop_registerForRemoteNotifications {
    UIApplication *app = [UIApplication sharedApplication];
    id del = app.delegate;
    SEL failSel = @selector(application:didFailToRegisterForRemoteNotificationsWithError:);
    if (del && [del respondsToSelector:failSel]) {
        NSError *err = [NSError errorWithDomain:NSCocoaErrorDomain code:3000 userInfo:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            void (*msg)(id, SEL, UIApplication *, NSError *) =
                (void (*)(id, SEL, UIApplication *, NSError *))objc_msgSend;
            msg(del, failSel, app, err);
        });
    }
}

@end

@interface UNUserNotificationCenter (MinecraftStorageFixAuthStub)
@end

@implementation UNUserNotificationCenter (MinecraftStorageFixAuthStub)

- (void)mcfix_requestAuthorizationFast:(UNAuthorizationOptions)options
                     completionHandler:(void (^)(BOOL granted, NSError *_Nullable error))completionHandler {
    (void)options;
    if (!completionHandler) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        completionHandler(YES, nil);
    });
}

@end
