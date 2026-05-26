// AppPlatform_apple* capture + diag-only main-menu probe.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "PlatformCapture.h"
#import "../Internal/MCFIXObjectInspect.h"
#import "../Internal/MCFIXState.h"

extern void MCFIXDiagMenuWait(NSString *reason);

// ---------------------------------------------------------------------------
//  Proactive menu bring-up (sideload: gates never virtually dispatched)
// ---------------------------------------------------------------------------

// Diag-only: log why menu is not up; never synthesize platform or force sub_10035A088.
void MCFIXTryBringUpMainMenu(NSString *reason) {
    if (gMCFIXMenuPresented) {
        return;
    }
    gMCFIXDiag.menuOpenAttempts++;
    MCFIXDiagMenuWait(reason);
}

static void *gOrigAppPlatformLoadTick = NULL;
static void *gOrigAppPlatformICloudGate = NULL;
static void *gOrigAppPlatformICloudCheck2E8 = NULL;
static uint32_t gMCFIXAdvanceLoadAttempts = 0;

typedef int64_t (*FnAppPlatformLoadTick_t)(int64_t platform);
typedef int64_t (*FnAppPlatformLoadSuccess_t)(int64_t platform);

static void MCFIXTryAdvancePlatformLoad(__unused int64_t platform) {
    MCFIXDiagOnce(@"advance_load_disabled", @"MCFIXTryAdvancePlatformLoad disabled (tweak-1 boot)");
}

// Diag-only: remember platform when game creates it naturally (no synthesis / forced menu).
static void MCFIXOnPlatformCaptured(int64_t platform, NSString *reason) {
    if (!platform || !MCFIXPointerIsAppPlatformApple(platform)) {
        return;
    }
    if (!gMCFIXAppPlatformApple) {
        MCFIXRememberAppPlatformApple(platform);
        MCFIXDiagOnce(@"platform_captured",
                      @"AppPlatform_apple captured (%@) ptr=%llx",
                      reason ?: @"?", (unsigned long long)platform);
        NSMutableString *msg = [NSMutableString stringWithString:@"platform state"];
        MCFIXDiagDescribePlatform(platform, msg);
        MCFIXDiagLog(@"%@", msg);
    }
}

static BOOL (*gOrigMCFIXInitView)(id, SEL) = NULL;
static void (*gOrigMCFIXDrawFrame)(id, SEL) = NULL;
static void (*gOrigMCFIXViewDidLoad)(id, SEL) = NULL;
static void (*gOrigMCFIXStartAnimation)(id, SEL) = NULL;

static BOOL mcfix_initViewCapture(id self, SEL _cmd) {
    MCFIXDiagOnce(@"hook_initview", @"initView hook fired (%@)", NSStringFromClass([self class]));
    BOOL ok = gOrigMCFIXInitView ? gOrigMCFIXInitView(self, _cmd) : YES;
    int64_t platform = MCFIXPlatformFromViewController(self);
    if (!platform) {
        platform = MCFIXPlatformFromAppDelegate();
    }
    if (platform) {
        MCFIXOnPlatformCaptured(platform, @"initView");
    }
    return ok;
}

static void mcfix_viewDidLoadCapture(id self, SEL _cmd) {
    MCFIXDiagOnce(@"hook_viewdidload", @"viewDidLoad hook fired (%@)", NSStringFromClass([self class]));
    if (gOrigMCFIXViewDidLoad) {
        gOrigMCFIXViewDidLoad(self, _cmd);
    }
    if (!gMCFIXAppPlatformApple) {
        int64_t platform = MCFIXPlatformFromViewController(self);
        if (!platform) {
            platform = MCFIXPlatformFromAppDelegate();
        }
        if (platform) {
            MCFIXOnPlatformCaptured(platform, @"viewDidLoad");
        }
    }
}

static void mcfix_startAnimationCapture(id self, SEL _cmd) {
    MCFIXDiagOnce(@"hook_startanim", @"startAnimation hook fired (%@)", NSStringFromClass([self class]));
    if (!gMCFIXAppPlatformApple) {
        int64_t platform = MCFIXPlatformFromViewController(self);
        if (platform) {
            MCFIXOnPlatformCaptured(platform, @"startAnimation");
        }
    }
    if (gOrigMCFIXStartAnimation) {
        gOrigMCFIXStartAnimation(self, _cmd);
    }
}

static void mcfix_drawFrameCapture(id self, SEL _cmd) {
    static uint32_t sDrawFrames = 0;
    sDrawFrames++;
    if (sDrawFrames == 1) {
        MCFIXDiagOnce(@"hook_drawframe", @"drawFrame hook fired (%@)", NSStringFromClass([self class]));
    }
    if (!gMCFIXAppPlatformApple) {
        static uint32_t polls = 0;
        polls++;
        if (polls == 1 || polls == 30 || polls == 120) {
            int64_t platform = MCFIXPlatformFromViewController(self);
            if (!platform) {
                platform = MCFIXPlatformFromAppDelegate();
            }
            if (platform) {
                gMCFIXDiag.loadTickPolls++;
                MCFIXOnPlatformCaptured(platform, @"drawFrame");
            }
        }
    }
    if (gOrigMCFIXDrawFrame) {
        gOrigMCFIXDrawFrame(self, _cmd);
    }
}

static void MCFIXHookViewControllerClass(Class vc, BOOL *okInit, BOOL *okDraw, BOOL *okLoad, BOOL *okAnim) {
    if (!vc) {
        return;
    }
    Method mInit = class_getInstanceMethod(vc, @selector(initView));
    if (mInit && !*okInit) {
        gOrigMCFIXInitView = (BOOL (*)(id, SEL))method_getImplementation(mInit);
        method_setImplementation(mInit, (IMP)mcfix_initViewCapture);
        *okInit = YES;
    }
    Method mDraw = class_getInstanceMethod(vc, @selector(drawFrame));
    if (mDraw && !*okDraw) {
        gOrigMCFIXDrawFrame = (void (*)(id, SEL))method_getImplementation(mDraw);
        method_setImplementation(mDraw, (IMP)mcfix_drawFrameCapture);
        *okDraw = YES;
    }
    Method mLoad = class_getInstanceMethod(vc, @selector(viewDidLoad));
    if (mLoad && !*okLoad) {
        gOrigMCFIXViewDidLoad = (void (*)(id, SEL))method_getImplementation(mLoad);
        method_setImplementation(mLoad, (IMP)mcfix_viewDidLoadCapture);
        *okLoad = YES;
    }
    Method mAnim = class_getInstanceMethod(vc, @selector(startAnimation));
    if (mAnim && !*okAnim) {
        gOrigMCFIXStartAnimation = (void (*)(id, SEL))method_getImplementation(mAnim);
        method_setImplementation(mAnim, (IMP)mcfix_startAnimationCapture);
        *okAnim = YES;
    }
}

void MCFIXInstallPlatformCaptureHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        BOOL okInit = NO, okDraw = NO, okLoad = NO, okAnim = NO;
        const char *classNames[] = {"minecraftpeViewControllerBase", "minecraftpeViewController", NULL};
        for (size_t i = 0; classNames[i] != NULL; i++) {
            MCFIXHookViewControllerClass(objc_getClass(classNames[i]), &okInit, &okDraw, &okLoad, &okAnim);
        }
        MCFIXDiagLog(@"Platform diag hooks (tweak-1 boot, no synthesis) initView=%d drawFrame=%d viewDidLoad=%d startAnim=%d",
                     okInit ? 1 : 0, okDraw ? 1 : 0, okLoad ? 1 : 0, okAnim ? 1 : 0);
    });
}

// Load tick early gate: sub_10002E6D0 @ vtable+0x18; TBNZ W0,#0 → skip sub_10013EB6C(perm=3) gray modal.
static int64_t mcfix_appPlatformICloudGateSuccess(int64_t platform) {
    typedef int64_t (*FnICloudGate_t)(int64_t);
    FnICloudGate_t orig = (FnICloudGate_t)gOrigAppPlatformICloudGate;
    if (orig) {
        (void)orig(platform);
    }
    return 1;
}

// Second iCloud branch in load tick (0x100022fa4) — force success so flow reaches sub_100028D68.
static int64_t mcfix_appPlatformICloudCheck2E8Success(int64_t platform, int64_t a2) {
    typedef int64_t (*FnCheck2E8_t)(int64_t, int64_t);
    FnCheck2E8_t orig = (FnCheck2E8_t)gOrigAppPlatformICloudCheck2E8;
    if (orig) {
        (void)orig(platform, a2);
    }
    return 1;
}

static int64_t mcfix_appPlatformLoadTickVtable(int64_t platform) {
    MCFIXRememberAppPlatformApple(platform);
    FnAppPlatformLoadTick_t orig = (FnAppPlatformLoadTick_t)gOrigAppPlatformLoadTick;
    int64_t result = 0;
    if (orig) {
        result = orig(platform);
    }
    static uint32_t sTickMenus = 0;
    sTickMenus++;
    if (!gMCFIXMenuPresented && platform && (sTickMenus <= 12 || (sTickMenus % 60) == 0)) {
        gMCFIXDiag.loadTickPolls++;
        dispatch_async(dispatch_get_main_queue(), ^{
            MCFIXTryBringUpMainMenu(@"load-tick-vtable");
        });
    }
    return result;
}

// AppPlatform iCloud/load-tick vtable patches disabled (tweak-1 boot — caused gray screen).
static void MCFIXInstallAppPlatformMenuVtableFixes(void) {
    MCFIXDiagOnce(@"appplatform_vtable_disabled",
                  @"AppPlatform vtable patches OFF — stock sub_1000206AC load tick");
}
