// Auto-complete Xbox sign-in (formerly XBLFocusFix.framework).

#import "XBLFocus.h"
#import "MCFIXLog.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static IMP XBLInstallOverride(Class cls, SEL sel, IMP new_imp, const char *fallback_types) {
    Method inherited = class_getInstanceMethod(cls, sel);
    IMP    prev_imp  = inherited ? method_getImplementation(inherited) : NULL;
    const char *types = inherited ? method_getTypeEncoding(inherited) : fallback_types;
    if (class_addMethod(cls, sel, new_imp, types)) return prev_imp;
    return method_setImplementation(class_getInstanceMethod(cls, sel), new_imp);
}

static void XBLAutoCompleteSignIn(void) {
    Class scenarioCls = NSClassFromString(@"XBLIDPScenario");
    if (!scenarioCls) return;
    id scenario = ((id (*)(Class, SEL))objc_msgSend)(scenarioCls, @selector(sharedIDPScenario));
    id delegate = ((id (*)(id, SEL))objc_msgSend)(scenario, @selector(delegate));
    SEL done = NSSelectorFromString(@"userCompletedSignedIn");
    if ([delegate respondsToSelector:done]) {
        ((void (*)(id, SEL))objc_msgSend)(delegate, done);
    }
}

static void (*orig_welcome_showLogInState)(id, SEL);

static void welcome_showLogInState(id self, SEL _cmd) {
    if (orig_welcome_showLogInState) orig_welcome_showLogInState(self, _cmd);
    dispatch_async(dispatch_get_main_queue(), ^{ XBLAutoCompleteSignIn(); });
}

void MCFIXInstallXBLFocusFix(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"XBLTVWelcomePageViewController");
        if (!cls) {
            MCFIXLog(MCFIXLogCatXBL, @"XBLFocusFix: XBLTVWelcomePageViewController not found");
            return;
        }
        orig_welcome_showLogInState = (void (*)(id, SEL))XBLInstallOverride(
            cls, @selector(showLogInState), (IMP)welcome_showLogInState, "v@:");
        MCFIXLog(MCFIXLogCatXBL, @"XBLFocusFix: installed");
    });
}
