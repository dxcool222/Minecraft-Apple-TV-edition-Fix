#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <libkern/OSCacheControl.h>
#import <Security/Security.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <stdarg.h>
#import <stdio.h>
#import <stdlib.h>
#import <dirent.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <unistd.h>
#include <string.h>
#import <os/lock.h>
#import "fishhook.h"
#import "MCFIXBypass.h"
#import "MCFIXGameDataVFS.h"
#import "MCFIXFTPServer.h"
#import "MCFIXLog.h"
#import "MCFIXCrashTrace.h"
#import "MCFIXCityHash64.h"

NSString *MCFIXCityHash64PNGFilename(NSString *string);

static void MCFIXEnsureGameVFSSandboxTree(void);
static void MCFIXSeedEngineOptionsTxtInVFS(void);
static void MCFIXLogWorldIconBootProbe(void);
static void MCFIXLogWorldIconAccessProbe(const char *resolvedPath, int accessRc);
static void MCFIXLogWorldIconStatProbe(const char *resolvedPath, int statRc);
static void MCFIXLogWorldIconFopenProbe(const char *path, const char *mode, FILE *result,
                                        const char *rawPath);
static const char *MCFIXPOSIXResolvedPathForReadSyscall(const char *cPath, char fspath[PATH_MAX]);
int MCFIXIsExitWipeActive(void);
int (*mcfix_orig_stat)(const char *path, struct stat *sb) = NULL;
FILE *(*mcfix_orig_fopen)(const char *path, const char *mode) = NULL;
int (*mcfix_orig_fclose)(FILE *stream) = NULL;
static void MCFIXSeedMinecraftPEConfigFilesInVFS(void);
static void MCFIXInstallVFSSandboxLayers(void);
static void MCFIXSyncBidirectionalSkinAndPrefs(void);
#import "Modules/CloudKit/FakeCKContainer.h"

//  Xbox / MSA keychain (IDA: -[XBLKeychainStorage dictionaryForKeychainQuery:]
//  @ ~0x101099764; literal "com.microsoft.xboxliveservices" is kSecAttrService;
//  kSecAttrAccessGroup is only set if _accessGroup is non-nil.)
//  Sideloads see securityd -34018 when the access group is not entitled.
//
//  Two-layer defence:
//   1. ObjC swizzle on -[XBLKeychainStorage dictionaryForKeychainQuery:] —
//      catches the path the Xbox SDK uses to build queries with an explicit
//      access group. Remap target is built from AppIdentifierPrefix /
//      SecTask application-identifier / UserDefaults override.
//   2. fishhook on SecItemAdd/CopyMatching/Update/Delete — catches every
//      other code path. Discovers the real entitled access group at boot
//      by probing the keychain (per SideloadFix), then rewrites any
//      kSecAttrAccessGroup in incoming queries to that group. fishhook
//      is safe here — it only rebinds lazy imports in this process. The
//      old warning about __interpose does not apply.
// ---------------------------------------------------------------------------

static OSStatus (*mcfix_orig_SecItemAdd)(CFDictionaryRef, CFTypeRef *) = NULL;
static OSStatus (*mcfix_orig_SecItemCopyMatching)(CFDictionaryRef, CFTypeRef *) = NULL;
static OSStatus (*mcfix_orig_SecItemUpdate)(CFDictionaryRef, CFDictionaryRef) = NULL;
static OSStatus (*mcfix_orig_SecItemDelete)(CFDictionaryRef) = NULL;

static CFDictionaryRef MCFIXKeychainQueryStripped(CFDictionaryRef src) {
    if (src == NULL) return NULL;
    if (!CFDictionaryContainsKey(src, kSecAttrAccessGroup)) {
        return (CFDictionaryRef)CFRetain(src);
    }
    CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, src);
    CFDictionaryRemoveValue(m, kSecAttrAccessGroup);
    return m;
}

static OSStatus mcfix_hook_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    if (!mcfix_orig_SecItemAdd) return errSecNotAvailable;
    CFDictionaryRef q = MCFIXKeychainQueryStripped(attributes);
    OSStatus rc = mcfix_orig_SecItemAdd(q, result);
    if (q) CFRelease(q);
    return rc;
}

static OSStatus mcfix_hook_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    if (!mcfix_orig_SecItemCopyMatching) return errSecNotAvailable;
    CFDictionaryRef q = MCFIXKeychainQueryStripped(query);
    OSStatus rc = mcfix_orig_SecItemCopyMatching(q, result);
    if (q) CFRelease(q);
    return rc;
}

static OSStatus mcfix_hook_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    if (!mcfix_orig_SecItemUpdate) return errSecNotAvailable;
    // Strip from both dicts — re-asserting kSecAttrAccessGroup in the
    // updates dict is treated as a move-into-group and fails with -34018
    // when the target group isn't in the app's entitlements.
    CFDictionaryRef q = MCFIXKeychainQueryStripped(query);
    CFDictionaryRef u = MCFIXKeychainQueryStripped(attributesToUpdate);
    OSStatus rc = mcfix_orig_SecItemUpdate(q, u);
    if (q) CFRelease(q);
    if (u) CFRelease(u);
    return rc;
}

static OSStatus mcfix_hook_SecItemDelete(CFDictionaryRef query) {
    if (!mcfix_orig_SecItemDelete) return errSecNotAvailable;
    CFDictionaryRef q = MCFIXKeychainQueryStripped(query);
    OSStatus rc = mcfix_orig_SecItemDelete(q);
    if (q) CFRelease(q);
    return rc;
}
#import "Modules/Xbox/XBLKeychain.h"

#import "Modules/Internal/MCFIXInlineHook.h"
#import "Modules/CloudKit/VtablePatches.h"
#import "Modules/CloudKit/CompletionShims.h"

//  CloudKit fake-success shim
// ---------------------------------------------------------------------------

static char kMCFIXQueryCompletionOriginalKey;
static char kMCFIXModifyCompletionKey;
static void (*gOrigCKQuerySetCompletion)(id, SEL, id) = NULL;
static void (*gOrigCKModifySetCompletion)(id, SEL, id) = NULL;

// IDA: CloudKit query completion invoke targets and queue advance helper.
static const uintptr_t kFnCKQueryCompletion48C4 = 0x100CA48C4UL;
static const uintptr_t kFnCKCursorQueryCompletion63D8 = 0x100CA63D8UL;
static const uintptr_t kFnCKModifyCompletion551C = 0x100CA551CUL;
static const uintptr_t kFnSyncQueueAdvance25AC = 0x100CA25ACUL;
static const uintptr_t kFnSyncStatusOnMain27DC = 0x100CA27DCUL;
static NSString *const kMCFIXFakeUbiquityToken = @"mcfix-sideload-ubiquity-token";
#import "Modules/Internal/MCFIXState.h"
#import "Modules/Internal/MCFIXPosixOrigs.h"
#import "Modules/Lifecycle/PlatformCapture.h"
#import "Modules/Marketplace/CatalogStub.h"
#import "Modules/Marketplace/MCFIXMarketplaceIdentity.h"
#import "Modules/VFS/Bootstrap.h"
#import "Modules/VFS/PathRedirect.h"
#import "Modules/VFS/PosixHooks.h"
#import "Modules/Icons/AchievementIcons.h"
#import "Modules/Icons/WorldIcon.h"
#import "Modules/Sideload/SideloadFix.h"
#import "Modules/Xbox/XBLFocus.h"

int64_t gMCFIXPendingGatePlatform = 0;
void *gOrigCloudKitBootstrap = NULL;
int64_t gMCFIXSyncManager = 0;
// sub_100C9BF38 `a1` — storage/iCloud host object; CloudKit sync queue is at a1+576 only.
int64_t gMCFIXBootstrapHost = 0;
BOOL gMCFIXMenuPresented = NO;
int gMCFIXMenuAttemptGeneration = 0;
int64_t gMCFIXLastStorageProvider = 0;
int64_t gMCFIXDiagPlatform = 0;
// AppPlatform_apple* (vtable off_101489D30) — NOT qword_101656FB8 (different object, IDA 78FC48).
int64_t gMCFIXAppPlatformApple = 0;
_Atomic bool gMCFIXBootstrapReady = false;
_Atomic bool gMCFIXMarketplaceVFSPassThrough = false;

//  MCFIX Diag — CloudKit / boot diagnostics (category MCFIXLogCatCK, off by default)
//  Filter Console: MCFIX CK | MCFIX Boot | MCFIX Icon | MCFIX Err
// ---------------------------------------------------------------------------

static void MCFIXDiagDescribeStorageProvider(int64_t sp, NSMutableString *out);
void MCFIXDiagDescribePlatform(int64_t platform, NSMutableString *out);
static void MCFIXDiagSnapshotGate(NSString *gate, int64_t observer, int64_t platform);
static void MCFIXDiagSnapshotBootstrap(int64_t host, int64_t sync, NSString *tag);
void MCFIXDiagMenuWait(NSString *reason);
static void MCFIXDiagEmitSummary(NSString *trigger);
static void MCFIXDiagStartWatchdog(void);
static void MCFIXScheduleStartupKickstart(void);
static void MCFIXKickstartGameIfStalled(NSString *reason);
#import "Modules/Internal/MCFIXVtablePatch.h"

static void MCFIXDiagInstallLifecycleHooks(void);

uint64_t MCFIXReadU64At(int64_t addr) {
    uintptr_t u = (uintptr_t)addr;
    if (u < 0x10000 || (u & 7)) {
        return 0;
    }
    uint64_t value = 0;
    mach_msg_type_number_t readCount = (mach_msg_type_number_t)sizeof(value);
    if (vm_read_overwrite(mach_task_self(), (vm_address_t)addr, sizeof(value),
                          (vm_address_t)&value, &readCount) != KERN_SUCCESS) {
        return 0;
    }
    return value;
}

BOOL MCFIXPointerLooksLikeGameObject(int64_t ptr) {
    uintptr_t u = (uintptr_t)ptr;
    if (u < 0x10000 || (u & 7)) {
        return NO;
    }
    uintptr_t imageLo = MCFIXImageLo();
    uintptr_t imageHi = MCFIXImageHi();
    return u >= imageLo && u < imageHi;
}

static BOOL MCFIXLooksLikeStorageProvider(int64_t sp) {
    if (!MCFIXPointerLooksLikeGameObject(sp)) {
        return NO;
    }
    int64_t fileInterface = (int64_t)MCFIXReadU64At(sp + 32);
    int64_t inner48 = (int64_t)MCFIXReadU64At(sp + 48);
    return MCFIXPointerLooksLikeGameObject(fileInterface) && MCFIXPointerLooksLikeGameObject(inner48);
}

// AppPlatform_apple vtable base (sub_10001CD14 sets *a1 = off_101489D30).
static const uintptr_t kAppPlatformAppleVtable = 0x101489D30UL;
static const uintptr_t kAppPlatformGlobalPtr = 0x101656FB8UL; // sub_10078FC48 object — wrong type for +632

BOOL MCFIXPointerIsAppPlatformApple(int64_t ptr) {
    if (!MCFIXPointerLooksLikeGameObject(ptr)) {
        return NO;
    }
    intptr_t slide = MCFIXMainImageSlide();
    int64_t vt = (int64_t)MCFIXReadU64At(ptr);
    return vt == (int64_t)(kAppPlatformAppleVtable + (uintptr_t)slide);
}

void MCFIXRememberAppPlatformApple(int64_t platform) {
    if (!platform || !MCFIXPointerIsAppPlatformApple(platform)) {
        return;
    }
    gMCFIXAppPlatformApple = platform;
    gMCFIXDiagPlatform = platform;
}

int64_t MCFIXGetAppPlatform(void) {
    if (gMCFIXAppPlatformApple && MCFIXPointerIsAppPlatformApple(gMCFIXAppPlatformApple)) {
        return gMCFIXAppPlatformApple;
    }
    intptr_t slide = MCFIXMainImageSlide();
    int64_t global = (int64_t)MCFIXReadU64At((int64_t)(kAppPlatformGlobalPtr + (uintptr_t)slide));
    if (MCFIXPointerIsAppPlatformApple(global)) {
        gMCFIXAppPlatformApple = global;
        gMCFIXDiagPlatform = global;
        return global;
    }
    return 0;
}

// sub_1006F15A0 stores AppPlatform_apple* at *(minecraftpeViewControllerBase+16) before initView.
int64_t MCFIXPlatformFromViewController(id vc) {
    if (!vc) {
        return 0;
    }
    int64_t direct = (int64_t)MCFIXReadU64At((int64_t)(__bridge void *)vc + 16);
    if (MCFIXPointerIsAppPlatformApple(direct)) {
        return direct;
    }
    static Ivar sAppIvar = NULL;
    if (!sAppIvar) {
        Class cls = [vc class];
        if (!cls) {
            cls = objc_getClass("minecraftpeViewControllerBase");
        }
        if (cls) {
            sAppIvar = class_getInstanceVariable(cls, "_app");
        }
    }
    if (sAppIvar) {
        ptrdiff_t off = ivar_getOffset(sAppIvar);
        int64_t app = (int64_t)MCFIXReadU64At((int64_t)(__bridge void *)vc + off);
        if (app) {
            int64_t plat = (int64_t)MCFIXReadU64At(app + 8);
            if (MCFIXPointerIsAppPlatformApple(plat)) {
                return plat;
            }
        }
    }
    return 0;
}

int64_t MCFIXPlatformFromAppDelegate(void) {
    id del = [UIApplication sharedApplication].delegate;
    if (!del) {
        return 0;
    }
    static Ivar sPlatformIvar = NULL;
    if (!sPlatformIvar) {
        static const char *kDelegateClassNames[] = {
            "minecraftpeAppDelegate", "minecraftpeAppDelegateBase", NULL};
        for (size_t i = 0; kDelegateClassNames[i] != NULL; i++) {
            Class cls = objc_getClass(kDelegateClassNames[i]);
            if (cls) {
                sPlatformIvar = class_getInstanceVariable(cls, "_platform");
                if (sPlatformIvar) {
                    break;
                }
            }
        }
        if (!sPlatformIvar) {
            sPlatformIvar = class_getInstanceVariable([del class], "_platform");
        }
    }
    if (!sPlatformIvar) {
        return 0;
    }
    ptrdiff_t off = ivar_getOffset(sPlatformIvar);
    int64_t platform = (int64_t)MCFIXReadU64At((int64_t)(__bridge void *)del + off);
    if (MCFIXPointerIsAppPlatformApple(platform)) {
        return platform;
    }
    return 0;
}

static int64_t MCFIXResolveAppPlatformApple(NSString *reason) {
    int64_t platform = gMCFIXAppPlatformApple;
    if (MCFIXPointerIsAppPlatformApple(platform)) {
        return platform;
    }
    platform = MCFIXPlatformFromAppDelegate();
    if (platform) {
        return platform;
    }
    (void)reason;
    return 0;
}

static const uintptr_t kAppPlatformCtorFunc = 0x10001CD14UL;
static const size_t kAppPlatformAllocSize = 0x448UL;

static UIViewController *MCFIXDescendToMinecraftVC(UIViewController *vc) {
    if (!vc) {
        return nil;
    }
    NSString *cn = NSStringFromClass([vc class]);
    if ([cn rangeOfString:@"minecraftpe" options:NSCaseInsensitiveSearch].length > 0) {
        return vc;
    }
    if (vc.presentedViewController) {
        UIViewController *found = MCFIXDescendToMinecraftVC(vc.presentedViewController);
        if (found) {
            return found;
        }
    }
    for (UIViewController *child in vc.childViewControllers) {
        UIViewController *found = MCFIXDescendToMinecraftVC(child);
        if (found) {
            return found;
        }
    }
    return nil;
}

static id MCFIXFindGameViewController(void) {
    id del = [UIApplication sharedApplication].delegate;
    if (del) {
        static Ivar sViewCIvar = NULL;
        if (!sViewCIvar) {
            sViewCIvar = class_getInstanceVariable([del class], "_viewController");
            if (!sViewCIvar) {
                Class c = objc_getClass("minecraftpeAppDelegate");
                if (c) {
                    sViewCIvar = class_getInstanceVariable(c, "_viewController");
                }
            }
            if (!sViewCIvar) {
                Class c = objc_getClass("minecraftpeAppDelegateBase");
                if (c) {
                    sViewCIvar = class_getInstanceVariable(c, "_viewController");
                }
            }
        }
        if (sViewCIvar) {
            id vc = object_getIvar(del, sViewCIvar);
            if (vc) {
                return vc;
            }
        }
    }
    if (@available(tvOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                UIViewController *found = MCFIXDescendToMinecraftVC(w.rootViewController);
                if (found) {
                    return found;
                }
            }
        }
    }
    UIWindow *key = [UIApplication sharedApplication].keyWindow;
    if (key) {
        return MCFIXDescendToMinecraftVC(key.rootViewController);
    }
    return nil;
}

static void MCFIXWritePlatformToDelegate(int64_t platform) {
    if (!platform) {
        return;
    }
    id del = [UIApplication sharedApplication].delegate;
    if (!del) {
        return;
    }
    static Ivar sPlatformIvar = NULL;
    if (!sPlatformIvar) {
        static const char *kDelegatePlatformClasses[] = {
            "minecraftpeAppDelegate", "minecraftpeAppDelegateBase", NULL};
        for (size_t i = 0; kDelegatePlatformClasses[i] != NULL; i++) {
            Class cls = objc_getClass(kDelegatePlatformClasses[i]);
            if (cls) {
                sPlatformIvar = class_getInstanceVariable(cls, "_platform");
                if (sPlatformIvar) {
                    break;
                }
            }
        }
        if (!sPlatformIvar) {
            sPlatformIvar = class_getInstanceVariable([del class], "_platform");
        }
    }
    if (sPlatformIvar) {
        ptrdiff_t off = ivar_getOffset(sPlatformIvar);
        *(int64_t *)((uint8_t *)(__bridge void *)del + off) = platform;
    }
}

static void MCFIXAttachPlatformToViewController(id vc, int64_t platform) {
    if (!vc || !platform) {
        return;
    }
    *(int64_t *)((uint8_t *)(__bridge void *)vc + 16) = platform;
    MCFIXWritePlatformToDelegate(platform);
}

static int64_t MCFIXSynthesizeAppPlatformApple(void) {
    static void *(*sZnwm)(size_t) = NULL;
    static dispatch_once_t onceZn;
    dispatch_once(&onceZn, ^{
        sZnwm = (void *(*)(size_t))dlsym(RTLD_DEFAULT, "_Znwm");
    });
    if (!sZnwm) {
        return 0;
    }
    void *mem = sZnwm(kAppPlatformAllocSize);
    if (!mem) {
        return 0;
    }
    intptr_t slide = MCFIXMainImageSlide();
    typedef int64_t (*FnAppPlatformCtor_t)(int64_t);
    FnAppPlatformCtor_t ctor = (FnAppPlatformCtor_t)(kAppPlatformCtorFunc + (uintptr_t)slide);
    int64_t platform = ctor((int64_t)mem);
    if (!MCFIXPointerIsAppPlatformApple(platform)) {
        MCFIXDiagLog(@"synthesize AppPlatform failed vtable=%llx (expected %llx)",
                     (unsigned long long)MCFIXReadU64At(platform),
                     (unsigned long long)(kAppPlatformAppleVtable + (uintptr_t)slide));
        return 0;
    }
    MCFIXDiagLog(@"synthesized AppPlatform_apple %llx (sub_10001CD14)", (unsigned long long)platform);
    return platform;
}

// tweak-1 boot profile: kickstart/synthesis disabled (caused gray screen).
static void MCFIXKickstartGameIfStalled(__unused NSString *reason) {
    MCFIXDiagOnce(@"kick_disabled", @"kickstart disabled (tweak-1 boot profile)");
}

static void MCFIXScheduleStartupKickstart(void) {
}

static void MCFIXDiagDescribeStorageProvider(int64_t sp, NSMutableString *out) {
    if (!sp) {
        [out appendString:@" sp=null"];
        return;
    }
    int64_t o24 = (int64_t)MCFIXReadU64At(sp + 24);
    int64_t o32 = (int64_t)MCFIXReadU64At(sp + 32);
    int64_t o48 = (int64_t)MCFIXReadU64At(sp + 48);
    BOOL valid = MCFIXLooksLikeStorageProvider(sp);
    [out appendFormat:@" sp=%llx valid=%d +24=%llx +32=%llx +48=%llx",
     (unsigned long long)sp, valid ? 1 : 0,
     (unsigned long long)o24, (unsigned long long)o32, (unsigned long long)o48];
    if (o32) {
        int64_t innerFromFi = (int64_t)MCFIXReadU64At(o32 + 48);
        int64_t menu584 = innerFromFi ? (int64_t)MCFIXReadU64At(innerFromFi + 584) : 0;
        [out appendFormat:@" fi+48=%llx menu584=%llx",
         (unsigned long long)innerFromFi, (unsigned long long)menu584];
    }
    if (o24 && o24 < 0x10000) {
        [out appendString:@" (+24 looks stub/small)"];
    }
}

void MCFIXDiagDescribePlatform(int64_t platform, NSMutableString *out) {
    if (!platform) {
        [out appendString:@" platform=null"];
        return;
    }
    int64_t sp632 = (int64_t)MCFIXReadU64At(platform + 632);
    int64_t obj704 = (int64_t)MCFIXReadU64At(platform + 704);
    [out appendFormat:@" platform=%llx +632=%llx +704=%llx",
     (unsigned long long)platform, (unsigned long long)sp632, (unsigned long long)obj704];
    MCFIXDiagDescribeStorageProvider(sp632, out);
}

static void MCFIXDiagSnapshotGate(NSString *gate, int64_t observer, int64_t platform) {
    if (!MCFIXDiagEnabled()) {
        return;
    }
    NSMutableString *msg = [NSMutableString stringWithFormat:@"%@ observer=%llx",
                            gate ?: @"?", (unsigned long long)observer];
    MCFIXDiagDescribePlatform(platform, msg);
    MCFIXDiagLog(@"%@", msg);
}

static void MCFIXDiagSnapshotBootstrap(int64_t host, int64_t sync, NSString *tag) {
    if (!MCFIXDiagEnabled()) {
        return;
    }
    uint64_t host272 = host ? MCFIXReadU64At(host + 272) : 0;
    uint64_t host576 = host ? MCFIXReadU64At(host + 576) : 0;
    uint64_t sync72 = sync ? MCFIXReadU64At(sync + 72) : 0;
    uint64_t sync184 = sync ? MCFIXReadU64At(sync + 184) : 0;
    uint64_t sync216 = sync ? MCFIXReadU64At(sync + 216) : 0;
    BOOL hostLooksSP = MCFIXLooksLikeStorageProvider(host);
    NSMutableString *msg = [NSMutableString stringWithFormat:
        @"%@ host=%llx (looksSP=%d) host+272=%llx host+576=%llx | sync=%llx +72=%llu pending=%llu +216=%llx",
        tag ?: @"?",
        (unsigned long long)host, hostLooksSP ? 1 : 0,
        (unsigned long long)host272, (unsigned long long)host576,
        (unsigned long long)sync, sync72, sync184, (unsigned long long)sync216];
    if (gMCFIXDiagPlatform) {
        [msg appendString:@" | tracked platform:"];
        MCFIXDiagDescribePlatform(gMCFIXDiagPlatform, msg);
    } else {
        [msg appendString:@" | tracked platform=(none yet — gate not called)"];
    }
    MCFIXDiagLog(@"%@", msg);
}

void MCFIXDiagMenuWait(NSString *reason) {
    if (!MCFIXDiagEnabled()) {
        return;
    }
    gMCFIXDiag.menuWaitLogs++;
    uint64_t pending = gMCFIXSyncManager ? MCFIXReadU64At(gMCFIXSyncManager + 184) : 0;
    uint64_t fp = (uint64_t)gMCFIXBootstrapHost
        ^ ((uint64_t)gMCFIXLastStorageProvider << 1)
        ^ ((uint64_t)gMCFIXSyncManager << 2)
        ^ (pending << 3)
        ^ (uint64_t)(gMCFIXDiagPlatform & 0xFFFF);
    if (!MCFIXDiagStateChanged(@"menu_wait", fp)) {
        return;
    }
    NSMutableString *msg = [NSMutableString stringWithFormat:
        @"MENU BLOCKED (%@) — need platform+632 StorageProvider with +32 FileInterface",
        reason ?: @"?"];
    MCFIXDiagSnapshotBootstrap(gMCFIXBootstrapHost, gMCFIXSyncManager, @"bootstrap");
    if (gMCFIXDiagPlatform) {
        MCFIXDiagDescribePlatform(gMCFIXDiagPlatform, msg);
    } else {
        [msg appendString:@" | gate1/2/3 never ran (vtable not dispatched)"];
    }
    [msg appendFormat:@" | gateSp=%llx menuPresented=%d gate1hits=%u",
     (unsigned long long)gMCFIXLastStorageProvider, gMCFIXMenuPresented ? 1 : 0, gMCFIXDiag.gate1];
    MCFIXDiagLog(@"%@", msg);
}

static void MCFIXDiagEmitSummary(NSString *trigger) {
    if (!MCFIXDiagEnabled()) {
        return;
    }
    NSMutableString *msg = [NSMutableString stringWithFormat:
        @"SUMMARY (%@) gate1=%u gate2=%u gate3=%u perms=%u modalBlk=%u loadPoll=%u appPlat=%d bootstrap=%u queryDone=%u fakeCK=%u menuWait=%u menuTries=%u presented=%d",
        trigger ?: @"?",
        gMCFIXDiag.gate1, gMCFIXDiag.gate2, gMCFIXDiag.gate3, gMCFIXDiag.perms,
        gMCFIXDiag.modalBlocked, gMCFIXDiag.loadTickPolls,
        gMCFIXAppPlatformApple ? 1 : 0,
        gMCFIXDiag.bootstrap, gMCFIXDiag.queryFinish, gMCFIXDiag.fakeCKOps,
        gMCFIXDiag.menuWaitLogs, gMCFIXDiag.menuOpenAttempts, gMCFIXMenuPresented ? 1 : 0];
    if (gMCFIXDiagPlatform) {
        MCFIXDiagDescribePlatform(gMCFIXDiagPlatform, msg);
    }
    MCFIXDiagLog(@"%@", msg);
}

static void MCFIXDiagStartWatchdog(void) {
#if MCFIX_PRODUCTION_SILENT
    return;
#else
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        MCFIXLogEmitBootBanner();
        dispatch_queue_t utilityQ = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)),
                       utilityQ, ^{
            MCFIXLogEmitSessionSummary(@"T+30s");
        });
        if (!MCFIXDiagEnabled()) {
            return;
        }
        MCFIXDiagOnce(@"banner", @"CK debug ON — filter: MCFIX CK | MCFIX Boot");
        const double delays[] = { 3.0, 10.0, 25.0, 45.0 };
        for (size_t i = 0; i < sizeof(delays) / sizeof(delays[0]); i++) {
            double d = delays[i];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                           utilityQ, ^{
                MCFIXDiagEmitSummary([NSString stringWithFormat:@"T+%.0fs", d]);
            });
        }
        __block int polls = 0;
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, utilityQ);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                                (uint64_t)(2 * NSEC_PER_SEC), (uint64_t)(0.25 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(timer, ^{
            polls++;
            if (polls > 20 || gMCFIXMenuPresented) {
                dispatch_source_cancel(timer);
                return;
            }
            int64_t platform = gMCFIXDiagPlatform;
            if (!platform) {
                platform = MCFIXGetAppPlatform();
            }
            if (!platform) {
                platform = MCFIXResolveAppPlatformApple(@"platform-poll");
            }
            if (!platform) {
                return;
            }
            gMCFIXDiag.loadTickPolls++;
            int64_t sp = (int64_t)MCFIXReadU64At(platform + 632);
            uint64_t fp = (uint64_t)sp ^ ((uint64_t)MCFIXReadU64At(sp + 32) << 8);
            if (MCFIXDiagStateChanged(@"platform_poll", fp)) {
                NSMutableString *msg = [NSMutableString stringWithString:@"platform+632 changed"];
                MCFIXDiagDescribePlatform(platform, msg);
                MCFIXDiagLog(@"%@", msg);
            }
        });
        dispatch_resume(timer);
    });
#endif
}

static void MCFIXDiagInstallLifecycleHooks(void) {
#if MCFIX_PRODUCTION_SILENT
    return;
#else
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *n) {
            MCFIXLogOnce(MCFIXLogCatBoot, @"become_active", @"UIApplicationDidBecomeActive");
            MCFIXLogEmitSessionSummary(@"become-active");
            if (MCFIXDiagEnabled()) {
                MCFIXDiagEmitSummary(@"become-active");
            }
        }];
    });
#endif
}

static void MCFIXRememberSyncManager(int64_t syncObj) {
    if (syncObj) {
        gMCFIXSyncManager = syncObj;
    }
}

static void MCFIXTryPresentMainMenu(NSString *reason) {
    MCFIXTryBringUpMainMenu(reason);
}

static void MCFIXSchedulePresentMainMenu(__unused NSString *reason) {
    MCFIXDiagOnce(@"menu_schedule_disabled",
                  @"MCFIXSchedulePresentMainMenu disabled — wait for natural gate1/load tick");
}

static void *MCFIXBlockInvokeFunction(id block) {
    if (!block) {
        return NULL;
    }
    return *(void **)((uint8_t *)(__bridge void *)block + 16);
}

static BOOL MCFIXRemovePendingCKOpOnMutex(int64_t mutexHolder, uint32_t opNum) {
    if (!mutexHolder) {
        return NO;
    }
    void *mapPtr = *(void **)(mutexHolder + 104);
    id pendingMap = (__bridge id)mapPtr;
    if (![pendingMap isKindOfClass:[NSDictionary class]]) {
        return NO;
    }
    NSNumber *key = @(opNum);
    if (![pendingMap objectForKey:key]) {
        return NO;
    }
    NSMutableDictionary *mutable = [pendingMap isKindOfClass:[NSMutableDictionary class]]
        ? (NSMutableDictionary *)pendingMap
        : [pendingMap mutableCopy];
    [mutable removeObjectForKey:key];
    if (mutable != pendingMap) {
        *(void **)(mutexHolder + 104) = (__bridge void *)mutable;
    }
    return YES;
}

// sub_100CA63D8 prologue: drop pending CKQueryOperation from the mutex map at +104.
static void MCFIXRemovePendingCKQueryOp(uint8_t *blockBytes) {
    if (!blockBytes) {
        return;
    }
    int64_t mutexHolder = *(int64_t *)(blockBytes + 40);
    uint32_t opNum = *(uint32_t *)(blockBytes + 128);
    if (!mutexHolder) {
        return;
    }
    void *mapPtr = *(void **)(mutexHolder + 104);
    id pendingMap = (__bridge id)mapPtr;
    if (![pendingMap isKindOfClass:[NSDictionary class]]) {
        return;
    }
    NSNumber *key = @(opNum);
    if ([pendingMap objectForKey:key]) {
        NSMutableDictionary *mutable = [pendingMap isKindOfClass:[NSMutableDictionary class]]
            ? (NSMutableDictionary *)pendingMap
            : [pendingMap mutableCopy];
        [mutable removeObjectForKey:key];
        if (mutable != pendingMap) {
            *(void **)(mutexHolder + 104) = (__bridge void *)mutable;
        }
    }
}

// sub_100CA27DC: post sync status on main when block+72 is absent (sub_100CA63D8 would throw).
static void MCFIXPostSyncStatusOnMain(int64_t syncObj, int status, intptr_t slide) {
    if (!syncObj) {
        return;
    }
    typedef int64_t (*FnSyncStatusOnMain)(void *);
    FnSyncStatusOnMain fn = (FnSyncStatusOnMain)(kFnSyncStatusOnMain27DC + (uintptr_t)slide);
    struct {
        void *isa;
        int flags;
        int reserved;
        FnSyncStatusOnMain invoke;
        void *desc;
        int64_t sync;
        int statusCode;
    } blk = {
        _NSConcreteStackBlock,
        0x40000000,
        0,
        fn,
        NULL,
        syncObj,
        status,
    };
    fn(&blk);
}

// IDA sub_100CA551C: modify completion may vcall *(block+88)+48. +88 is often std::string
// storage (sub_100CA52C8), not a C++ functor — vcall → execute heap (IPS 151829).
// Only used for CKModifyRecordsOperation fake complete; never on 63D8 block+72 (gray screen).
static BOOL MCFIXIsGameCppCallbackPointer(int64_t ptr, intptr_t slide) {
    (void)slide;
    uintptr_t u = (uintptr_t)ptr;
    if (u < 0x10000 || (u & 7)) {
        return NO;
    }
    uintptr_t imageLo = MCFIXImageLo();
    uintptr_t imageHi = MCFIXImageHi();
    if (u < imageLo || u >= imageHi) {
        return NO;
    }
    int64_t vtable = 0;
    mach_msg_type_number_t readCount = (mach_msg_type_number_t)sizeof(vtable);
    if (vm_read_overwrite(mach_task_self(), (vm_address_t)ptr, sizeof(vtable), (vm_address_t)&vtable,
                          &readCount) != KERN_SUCCESS) {
        return NO;
    }
    if ((uintptr_t)vtable < imageLo || (uintptr_t)vtable >= imageHi) {
        return NO;
    }
    if ((uintptr_t)vtable & 7) {
        return NO;
    }
    int64_t method48 = 0;
    readCount = (mach_msg_type_number_t)sizeof(method48);
    if (vm_read_overwrite(mach_task_self(), (vm_address_t)(vtable + 48), sizeof(method48),
                          (vm_address_t)&method48, &readCount) != KERN_SUCCESS) {
        return NO;
    }
    return (uintptr_t)method48 >= imageLo && (uintptr_t)method48 < imageHi;
}

static void MCFIXInstallFakeUbiquityToken(void) {
    [[NSUserDefaults standardUserDefaults] setObject:kMCFIXFakeUbiquityToken
                                              forKey:@"com.mojang.minecraftappletv.UbiquityIdentityToken"];
}

// tweak-1 CloudKit fake completion — DO NOT replace with custom FinishCK / notify paths.
void MCFIXCompleteFakeCKOperation(id operation) {
    if (!operation) {
        return;
    }
    id originalQuery = objc_getAssociatedObject(operation, &kMCFIXQueryCompletionOriginalKey);
    id modifyCompletion = objc_getAssociatedObject(operation, &kMCFIXModifyCompletionKey);
    intptr_t slide = MCFIXMainImageSlide();
    void *invoke = MCFIXBlockInvokeFunction(originalQuery);

    if (originalQuery && invoke) {
        uint8_t *blockBytes = (uint8_t *)(__bridge void *)originalQuery;
        int64_t syncObj = *(int64_t *)(blockBytes + 32);
        int64_t cppCb = *(int64_t *)(blockBytes + 72);
        MCFIXRemovePendingCKQueryOp(blockBytes);

        if (invoke == (void *)(kFnCKCursorQueryCompletion63D8 + (uintptr_t)slide)) {
            MCFIXDiagOnce(@"ck_complete_63d8", @"CK 63D8 complete (tweak-1: block nil,nil if +72 else 27DC+25AC)");
            if (cppCb) {
                ((void (^)(id, NSError *))originalQuery)(nil, nil);
            } else if (syncObj) {
                MCFIXPostSyncStatusOnMain(syncObj, 0, slide);
                typedef void (*FnSyncQueueAdvance)(int64_t);
                ((FnSyncQueueAdvance)(kFnSyncQueueAdvance25AC + (uintptr_t)slide))(syncObj);
            }
            gMCFIXDiag.queryFinish++;
            MCFIXRememberSyncManager(syncObj);
        } else if (invoke == (void *)(kFnCKQueryCompletion48C4 + (uintptr_t)slide)) {
            MCFIXDiagOnce(@"ck_complete_48c4", @"CK 48C4 complete (tweak-1: block nil,nil)");
            ((void (^)(id, NSError *))originalQuery)(nil, nil);
            gMCFIXDiag.queryFinish++;
        } else {
            MCFIXDiagOnce(@"ck_complete_other", @"CK other complete (tweak-1: block nil,nil)");
            ((void (^)(id, NSError *))originalQuery)(nil, nil);
        }
    }
    if (modifyCompletion) {
        void *modifyInvoke = MCFIXBlockInvokeFunction(modifyCompletion);
        uint8_t *modifyBytes = (uint8_t *)(__bridge void *)modifyCompletion;
        if (modifyInvoke == (void *)(kFnCKModifyCompletion551C + (uintptr_t)slide)) {
            int64_t cpp88 = *(int64_t *)(modifyBytes + 88);
            BOOL cleared88 = NO;
            if (cpp88 && !MCFIXIsGameCppCallbackPointer(cpp88, slide)) {
                MCFIXDiagOnce(@"ck_modify_551c_guard",
                              @"551C: block+88=0x%llx not functor — null +88 for Block_invoke",
                              (unsigned long long)cpp88);
                *(int64_t *)(modifyBytes + 88) = 0;
                cleared88 = YES;
            } else {
                MCFIXDiagOnce(@"ck_modify_551c", @"551C modify complete (tweak-1 Block_invoke nil,@[] nil)");
            }
            ((void (^)(NSArray *savedRecords, NSArray *deletedRecordIDs, NSError *error))modifyCompletion)(
                nil, @[], nil);
            if (cleared88) {
                *(int64_t *)(modifyBytes + 88) = cpp88;
            }
        } else {
            MCFIXDiagOnce(@"ck_modify_other", @"modify complete (tweak-1 @[],@[] nil)");
            ((void (^)(NSArray *savedRecords, NSArray *deletedRecordIDs, NSError *error))modifyCompletion)(
                @[], @[], nil);
        }
    }
}

static void MCFIXCKQuerySetCompletion(id self, SEL _cmd, id block) {
    if (block) {
        objc_setAssociatedObject(self, &kMCFIXQueryCompletionOriginalKey, [block copy],
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
    } else {
        objc_setAssociatedObject(self, &kMCFIXQueryCompletionOriginalKey, nil,
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    id wrapped = nil;
    if (block) {
        wrapped = [^(id cursor, NSError *error) {
            ((void (^)(id cursor, NSError *error))block)(cursor, nil);
        } copy];
    }
    if (gOrigCKQuerySetCompletion) {
        gOrigCKQuerySetCompletion(self, _cmd, wrapped);
    }
}

static void MCFIXCKModifySetCompletion(id self, SEL _cmd, id block) {
    if (block) {
        objc_setAssociatedObject(self, &kMCFIXModifyCompletionKey, [block copy],
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
    } else {
        objc_setAssociatedObject(self, &kMCFIXModifyCompletionKey, nil,
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    id wrapped = nil;
    if (block) {
        wrapped = [^(NSArray *savedRecords, NSArray *deletedRecordIDs, NSError *error) {
            ((void (^)(NSArray *savedRecords, NSArray *deletedRecordIDs, NSError *error))block)(
                savedRecords ?: @[], deletedRecordIDs ?: @[], nil);
        } copy];
    }
    if (gOrigCKModifySetCompletion) {
        gOrigCKModifySetCompletion(self, _cmd, wrapped);
    }
}

//  Sideload gameplay — skins / catalog (framework inline hooks only; IDA MCP)
//  DO NOT hook sub_100AE9228 — always-true with null storage caused world-load SIGSEGV.
// ---------------------------------------------------------------------------

static const uintptr_t kMCFIXCatalogOwnedFunc     = 0x1006634DCUL; // sub_1006634DC
static const uintptr_t kMCFIXSkinLockUIFunc       = 0x100369B34UL; // sub_100369B34
static const uintptr_t kMCFIXFreeSkinTypeFunc     = 0x1007A9FC0UL; // sub_1007A9FC0

typedef BOOL (*MCFIXCatalogOwnedFn_t)(int64_t a1);
typedef BOOL (*MCFIXSkinLockUIFn_t)(int64_t a1, int64_t a2);
typedef BOOL (*MCFIXFreeSkinTypeFn_t)(int64_t a1);

static MCFIXInlineHook gGameplayCatalogOwnedHook = {0};
static MCFIXInlineHook gGameplaySkinLockUIHook = {0};
static MCFIXInlineHook gGameplayFreeSkinTypeHook = {0};

static BOOL MCFIXHookGameplayCatalogOwned(int64_t a1) {
    (void)a1;
    return YES;
}

static BOOL MCFIXHookGameplaySkinLockUI(int64_t a1, int64_t a2) {
    (void)a1;
    (void)a2;
    return NO;
}

static BOOL MCFIXHookGameplayFreeSkinType(int64_t a1) {
    (void)a1;
    return YES;
}

static void MCFIXInstallSideloadGameplayHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        BOOL owned = MCFIXInstallInlineHook(&gGameplayCatalogOwnedHook, kMCFIXCatalogOwnedFunc,
                                            (void *)MCFIXHookGameplayCatalogOwned);
        BOOL lockUI = MCFIXInstallInlineHook(&gGameplaySkinLockUIHook, kMCFIXSkinLockUIFunc,
                                             (void *)MCFIXHookGameplaySkinLockUI);
        BOOL freeType = MCFIXInstallInlineHook(&gGameplayFreeSkinTypeHook, kMCFIXFreeSkinTypeFunc,
                                               (void *)MCFIXHookGameplayFreeSkinType);
        NSInteger ok = (NSInteger)(owned + lockUI + freeType);
        if (ok == 3) {
            MCFIXLogOnce(MCFIXLogCatBoot, @"gameplay_unlock", @"gameplay unlock inline hooks 3/3");
        } else {
            MCFIXLog(MCFIXLogCatBoot, @"gameplay unlock inline hooks %ld/3 — owned=%d lockUI=%d freeType=%d "
                  @"(purchased content may stay locked if hooks failed)",
                  (long)ok, owned, lockUI, freeType);
        }
    });
}

//  Game storage VFS — tvOS sideload sandbox (NSFileManager paths only)
//
//  Observed kernel denials on device (minecraftappletv):
//    deny(1) file-write-create .../Library/Application Support
//    deny(1) file-write-create .../Documents/games
//  The previous build used NSApplicationSupportDirectory for the redirect root,
//  which calls into the system to *create* "Application Support" — that hits
//  the first denial.  "Documents/games" was never redirected, so ensureGameData
//  and the engine still touched the real Documents tree.
//
//  Fix: never touch Application Support for this layer.  Re-home paths under
//  $HOME/Library/Caches/MinecraftStorageFix/GameData/vfs/<tail> where <tail>
//  is the substring after $HOME/ for:
//    • Library/games/...   (IDA: "games/com.mojang/" @0x1013bec96,
//                           "/games/com.mojang/" @0x1013c4849,
//                           "/games/com.mojang/minecraftStructures/" @0x1013d7dc5)
//    • Documents/games/...
//  So on disk we mirror e.g. .../vfs/Library/games/com.mojang/... under Caches.
//  Caches is writable in strict profiles where App Support / Documents/games
//  are not (we already use Caches for app-group + iCloud sim shims).
//
//  vtable / CloudKit / XBL: unchanged.  Pure POSIX I/O is still not redirected.
//
//  -------------------------------------------------------------------------
//  IDA Pro trace (Minecraft Apple TV, preferred base 0x100000000) — MCP
//  The binary does *not* store a full absolute "Library/.../com.mojang" path;
//  it stores *relative* fragments and joins them in C++ to the container root.
//
//  • InitFunc_2083 @0x100794ef0 — static init: qword_101656F80 = std::string
//    "/games/com.mojang/" (literal in __text @0x1013c4849, length 0x12).
//  • sub_1006E64E0 @0x1006E64E0 (large ctor) — after copying storage root a3
//    onto (a1+456), builds a path: base + *global* qword_101656F80 via
//    std::string::append @ ~0x1006E6860-0x1006E687C, result → (a1+528).  So
//    the in-game "com mojang" root is: <root> + "/games/com.mojang/".
//  • InitFunc_1752 @0x100692528 — qword_1016549F8 = "games/com.mojang/" (0x11),
//    plus "minecraftWorlds/", "worlds/", etc. (sibling std::string globals).
//  • sub_10069216C @0x10069216C — if (!(a1+144)): concatenates *a1 base +
//    qword_1016549F8 + qword_101654A10 ("minecraftWorlds/") @0x1006921E8+.
//  The platform layer supplies <root> ending in .../Library/ or .../Documents/,
//  so the resolved path is always under $HOME/Library/games/... *or*
//  $HOME/Documents/games/... — exactly the two tail prefixes the swizzle
//  remaps to .../Library/Caches/.../GameData/vfs/...
//  -------------------------------------------------------------------------

int mcfix_orig_mkdir_p(const char *path, mode_t mode);

int (*mcfix_orig_mkdir)(const char *path, mode_t mode) = NULL;
int (*mcfix_orig_access)(const char *path, int amode) = NULL;


//  Binary offsets (preferred load address 0x100000000)
// ---------------------------------------------------------------------------

// CloudKit bootstrap entry (vtable 0x10154BF08) — sub_100C9BF38; a1+576 = sync manager.
static const uintptr_t kBootstrapVtableSlot = 0x10154BF08UL;
static const uintptr_t kBootstrapFunc       = 0x100C9BF38UL;

// Gate 1: sub_100240C60 — success handler sub_10035A088
//   a1+8=platform, platform+632=storageProvider

// AppPlatform_apple vtable — load tick + iCloud gate (IDA sub_1000206AC @ 0x100022f20..f60).
static const uintptr_t kAppPlatformLoadTickVtableSlot = 0x101489DF8UL;
static const uintptr_t kAppPlatformICloudGateVtableSlot = 0x101489D48UL; // sub_10002E6D0 — TBNZ→success @ 0x100022f2c
static const uintptr_t kAppPlatformICloudCheck2E8Slot = 0x10148A018UL;   // sub_1000320C4 — post-modal branch @ 0x100022fa4
// Load-tick success path (sub_1000206AC @ 0x100023034) — advances startup without gate1 dispatch.
static const uintptr_t kAppPlatformLoadSuccessFunc = 0x100028D68UL;

// Gate 2: sub_1001D083C — success handler sub_10035E93C
//   a1+8=platform, platform+632=storageProvider

// Gate 3: sub_10024FA94 — triggers "Turn on iCloud" dialog; vtable 0x1014A5758
//   a1+8=platform, platform+704=loadObj (DIFFERENT field from gates 1&2)
//   Failure: sub_10035C938(loadObj, cb, 0) → Permissions=3 → in-game dialog
//   Success path helpers:
//     sub_100359EA8(loadObj, 0)   — state update (called in BOTH paths)
//     sub_10035F334(loadObj)      — get screen object (= sub_10001F838(*(loadObj+24)))
//     sub_100437624(screenObj, n) — screen progression (ignores args, reads globals)
//     sub_100430C98()             — iCloud KV sync cleanup (reads globals, no args)

//  NOT PATCHED (IDA): sub_100793354 vtable slot 0x10154BF18, and CloudKit query
//  dispatch slots 0x10154C4B0 / 0x10154C570 / 0x10154C578.
//
//  Baseline dylib (MinecraftStorageFix_works) reaches the menu with none of these
//  patched; patching them produced a white screen after become-active (logs
//  stillwhitescreen.txt: GL + ViewController + become-active OK, then stall).
//
//  IDA: sub_100CA5D10 (pointer in slot 0x10154C4B0) ends with `return v16()` after
//  setQueryCompletionBlock / addOperation — i.e. it must invoke a completion functor.
//  Replacing it with mcfix_syncSystemNoOp skipped that path, so sync/bootstrap never
//  advanced. sub_100CA718C / sub_100CA73B0 (0x10154C570 / 0x10154C578) likewise
//  call completion thunks (v12/v13 and v26/v27) that must run.
//
//  Gates already use mcfix_gateBypass1/2/3 and never consult sub_100793354; leaving
//  0x10154BF18 stock matches the working dylib and avoids extra divergence.
// ---------------------------------------------------------------------------

//  C++ bypass stubs (called from the patched vtable slots)
// ---------------------------------------------------------------------------

// Replaces sub_100240C60 — tweak-1 logic (diag counters only).

// Replaces sub_1001D083C.  Calls sub_10035E93C(sp, 1) which forwards to
// sub_1000204A8(*(sp+24), 1) — guard the iCloud-specific sub-object at sp+24.

// Replaces sub_10024FA94 — the third and final caller of sub_10035C938.
// This gate uses platform+704 (a loader/world-progress object), NOT the
// StorageProvider at +632.  When iCloud is unavailable the original function
// sets v5=1 and calls sub_10035C938 → "Turn on iCloud" dialog.
// Our bypass calls the same state-update helper that both paths call, then
// drives the success-path screen/progression helpers, and returns 8.
//
// sub_100359EA8 is IDA-confirmed called in BOTH the failure AND success paths,
// so it is always safe to call here.  sub_100437624 / sub_100430C98 read only
// game globals (qword_101651CD0, qword_101651CC8) — IDA shows them taking no
// parameters; any values we pass in registers are ignored by the callee.

// Replaces CloudKit query/sync vtable slots (Layers 11, 13a, 13b).
// No-ops the entire chain so the sync state machine stays in idle state and
// never triggers the error dialog or cloud-write mode.
// WARNING: do NOT add NSLog or dispatch_once here. This function is called
// from C++ CloudKit init callbacks on threads that are part of the game's
// critical startup chain. Any lock acquisition (including os_log internals
// and dispatch_once spinlocks) can cause a startup deadlock / white screen.

// Replaces sub_100244B60 (Permissions observer dispatcher).
// Forces every Permissions value to the success path instead of showing a dialog.
//
// IDA CONFIRMED call sequence in the original (every switch case):
//   1. handler(a1) — dialog OR success depending on *(a1+698)
//   2. sub_1001562E4(a1) — observer notification chain (MANDATORY)
//
// The notification chain iterates subscribers at (a1+392..400) and notifies each.
// If we skip it, those subscribers are never woken, the observer object may be
// freed from another path while still referenced, causing a use-after-free SIGABRT
// during world generation (~24 s into runtime, right after XBL auth completes).
//
// sub_100359918(sp) call chain (IDA-traced):
//   sub_10000EFD8(*(sp+32)) → sub_10002BD58(*(ptr+48)) → *(ptr+584)
//   sub_10012C040(v1, 1)    → sub_10002BD44(*v1)       → sub_10016BBC8(*(v1+176))
//   sub_10016BBC8 body:      *(result+48) += 1          // counter increment only
// Calling it multiple times is safe — it only increments a permissions-granted counter.

// Replaces sub_100C6EAC4 (IO streaming completion callback, vtable slot 0x10154A3C8).
// Guards all pointer dereferences before the call to sub_100C70D50 so that the
// game's streaming race condition does not crash the process.
// When any pointer is null we return 1 (success/done) — the IO queue keeps draining
// and the game will reload the missing resource naturally.

// Replaces sub_100C6E47C (IO batch callback, vtable slot 0x10154A348).
// Called during the world quit/save path.  The pointer chain here is
//   a1 → +8 → v2 → +72 → streamObj → +104 → sub-interface (null = crash).
// Guards all four pointers; if any is null returns 1 (done) so the IO
// queue drains safely.  When all guards pass, calls the original directly.

// Replaces sub_100CA795C (LevelDB sync vtable slot 0x10154C5E0).
// The real function creates "-SYNC-N" backup copies of DB files then dispatches
// a CloudKit modifyFileBatch operation via sub_100CA76B4→sub_100CA0948.
// Even with a live `+[CKContainer defaultContainer]`, this upload path can fail
// on sideloads and the failure cleanup can delete local world data. This no-op stops
// the entire chain at its source: no backups, no upload, no cleanup.
// LevelDB continues writing to the primary files in NSCachesDirectory normally.

// Saved-world load can still receive CloudKit completion callbacks that were
// queued before the vtable/direct no-ops take effect. Force those callbacks
// through their success/local branch instead of dispatching status 5/7/8.

//  Vtable patcher (makes one __DATA_CONST pointer writable, swaps it, locks)
// ---------------------------------------------------------------------------

BOOL mcfix_patchVtableSlotCapture(uintptr_t staticSlotAddr, void *newFn, void **oldFnOut) {
    intptr_t  slide   = MCFIXMainImageSlide();
    void    **slot    = (void **)(staticSlotAddr + (uintptr_t)slide);
    uintptr_t pageBase = (uintptr_t)slot & ~((uintptr_t)vm_page_size - 1);

    kern_return_t kr = vm_protect(mach_task_self(),
                                  (vm_address_t)pageBase,
                                  (vm_size_t)vm_page_size,
                                  FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        // Log which patches succeed or fail so we know which regions are writable.
        MCFIXLog(MCFIXLogCatError,
                 @"VTABLE FAIL slot=0x%lx fn=%p kr=0x%x (%s)",
                 staticSlotAddr, newFn, kr,
                 kr == KERN_PROTECTION_FAILURE ? "KERN_PROTECTION_FAILURE" :
                 kr == KERN_INVALID_ADDRESS    ? "KERN_INVALID_ADDRESS"    :
                 kr == KERN_NO_ACCESS          ? "KERN_NO_ACCESS"          : "other");
        return NO;
    }

    if (oldFnOut) {
        *oldFnOut = *slot;
    }
    *slot = newFn;

    vm_protect(mach_task_self(),
               (vm_address_t)pageBase,
               (vm_size_t)vm_page_size,
               FALSE,
               VM_PROT_READ);
    MCFIXLogOnce(MCFIXLogCatBoot, [NSString stringWithFormat:@"vtable_ok_0x%lx", staticSlotAddr],
                 @"VTABLE OK slot=0x%lx fn=%p", staticSlotAddr, newFn);
    return YES;
}

BOOL mcfix_patchVtableSlot(uintptr_t staticSlotAddr, void *newFn) {
    return mcfix_patchVtableSlotCapture(staticSlotAddr, newFn, NULL);
}


@interface MinecraftStorageFix : NSObject
+ (BOOL)installXBLServiceManagerGuardsOnce;
+ (BOOL)installXBLKeychainAccessGroupFixOnce;
+ (void)ensureGameDataDirectories;
@end

@implementation MinecraftStorageFix

// fishhook: rebinds libc lazy-bound imports. This is the primary save-path
// redirect layer — all game POSIX I/O (fopen, rename, remove, open, mkdir…)
// is intercepted here. No inline hooking or ElleKit is used.
+ (void)installPOSIXPathRebindings {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        MCFIXLogOnce(MCFIXLogCatIcon, @"world_ui_trace_armed",
                     @"WORLD icon trace armed — filter: WORLD DUAL | WORLD DELETE | WORLD BIND | WORLD UI",
                     kMCFIXWorldIconUITraceCap);
        struct rebinding rebs[] = {
            {"mkdir",   (void *)mcfix_posix_mkdir,   (void **)&mcfix_orig_mkdir},
            {"open",    (void *)mcfix_posix_open,    (void **)&mcfix_orig_open},
            {"fopen",   (void *)mcfix_posix_fopen,   (void **)&mcfix_orig_fopen},
            {"fopen$DARWIN_EXTSN", (void *)mcfix_posix_fopen_darwin_extsn, (void **)&mcfix_orig_fopen_darwin_extsn},
            {"fclose",  (void *)mcfix_posix_fclose,  (void **)&mcfix_orig_fclose},
            {"access",  (void *)mcfix_posix_access,  (void **)&mcfix_orig_access},
            {"stat",    (void *)mcfix_posix_stat,    (void **)&mcfix_orig_stat},
            {"stat$INODE64", (void *)mcfix_posix_stat_inode64, (void **)&mcfix_orig_stat_inode64},
            {"lstat",   (void *)mcfix_posix_lstat,   (void **)&mcfix_orig_lstat},
            {"lstat$INODE64", (void *)mcfix_posix_lstat_inode64, (void **)&mcfix_orig_lstat_inode64},
            {"opendir", (void *)mcfix_posix_opendir,  (void **)&mcfix_orig_opendir},
            {"opendir$INODE64", (void *)mcfix_posix_opendir_inode64, (void **)&mcfix_orig_opendir_inode64},
            {"unlink",  (void *)mcfix_posix_unlink,  (void **)&mcfix_orig_unlink},
            {"rmdir",   (void *)mcfix_posix_rmdir,   (void **)&mcfix_orig_rmdir},
            {"rename",  (void *)mcfix_posix_rename,  (void **)&mcfix_orig_rename},
            {"chmod",   (void *)mcfix_posix_chmod,   (void **)&mcfix_orig_chmod},
            {"chown",   (void *)mcfix_posix_chown,   (void **)&mcfix_orig_chown},
            {"remove",  (void *)mcfix_posix_remove,  (void **)&mcfix_orig_remove},
            {"statfs",  (void *)mcfix_posix_statfs,  (void **)&mcfix_orig_statfs},
            {"symlink", (void *)mcfix_posix_symlink, (void **)&mcfix_orig_symlink},
            {"readlink", (void *)mcfix_posix_readlink, (void **)&mcfix_orig_readlink},
            {"openat",  (void *)mcfix_posix_openat,  (void **)&mcfix_orig_openat},
            // Keychain access-group remap so sideloaded Xbox sign-in tokens
            // land under the entitled group instead of "com.microsoft.xboxliveservices".
            {"SecItemAdd",          (void *)mcfix_hook_SecItemAdd,          (void **)&mcfix_orig_SecItemAdd},
            {"SecItemCopyMatching", (void *)mcfix_hook_SecItemCopyMatching, (void **)&mcfix_orig_SecItemCopyMatching},
            {"SecItemUpdate",       (void *)mcfix_hook_SecItemUpdate,       (void **)&mcfix_orig_SecItemUpdate},
            {"SecItemDelete",       (void *)mcfix_hook_SecItemDelete,       (void **)&mcfix_orig_SecItemDelete},
        };
        (void)rebind_symbols(rebs, sizeof(rebs) / sizeof(rebs[0]));
    });
}

+ (void)patchSideloadPushAndUserNotifications {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class appCls = [UIApplication class];
        Method mReg = class_getInstanceMethod(appCls, @selector(registerForRemoteNotifications));
        Method mNop = class_getInstanceMethod(appCls, @selector(mcfix_nop_registerForRemoteNotifications));
        if (mReg && mNop) {
            method_exchangeImplementations(mReg, mNop);
        }
        Class unc = [UNUserNotificationCenter class];
        if (!unc) {
            return;
        }
        Method mAuth = class_getInstanceMethod(unc, @selector(requestAuthorizationWithOptions:completionHandler:));
        Method mFast = class_getInstanceMethod(
            unc, @selector(mcfix_requestAuthorizationFast:completionHandler:));
        if (mAuth && mFast) {
            method_exchangeImplementations(mAuth, mFast);
        }
    });
}

static void MCFIXRunBootstrapPhaseB(void) {
    // Match working tweak-1-1.3_works Phase B: catalog stubs only at boot.
    // Production .ent / premium_cache / container mirror are created lazily via
    // PathRedirect (MCFIXCanonicalizeEntitlementStoragePath) on first access — eager
    // boot seeding blocked CloudKit (device: queryDone=0 fakeCK=0 white screen).
    MCFIXEnsureMinecraftSavesAndMigrateFromTempIfNeeded();
    MCFIXMigrateRealGameStorageToVFS();
    MCFIXSyncBidirectionalSkinAndPrefs();
    MCFIXSeedMarketplaceCatalogStubs();
    [MinecraftStorageFix ensureGameDataDirectories];
    MCFIXInstallVFSSandboxLayers();
    atomic_store(&gMCFIXBootstrapReady, true);
    MCFIXLogOnce(MCFIXLogCatBoot, @"bootstrap_ready", @"Phase B bootstrap complete (gMCFIXBootstrapReady=YES)");
    MCFIXCrashTrace(@"Phase B complete bootstrap_ready=1 (working-minimal Phase B)");
}

static void MCFIXStartXBLLateBindTimer(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static _Atomic bool sKeychainHooked = false;
        static _Atomic bool sServiceHooked = false;
        static _Atomic bool sMsaHooked = false;
        dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
        dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        __block int attempts = 0;
        dispatch_source_set_timer(src,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                                  (uint64_t)(0.25 * NSEC_PER_SEC),
                                  (uint64_t)(50 * NSEC_PER_MSEC));
        dispatch_source_set_event_handler(src, ^{
            attempts++;
            if (!atomic_load(&sKeychainHooked)) {
                if ([MinecraftStorageFix installXBLKeychainAccessGroupFixOnce]) {
                    atomic_store(&sKeychainHooked, true);
                }
            }
            if (!atomic_load(&sServiceHooked)) {
                if ([MinecraftStorageFix installXBLServiceManagerGuardsOnce]) {
                    atomic_store(&sServiceHooked, true);
                }
            }
            if (!atomic_load(&sMsaHooked)) {
                [MinecraftStorageFix patchXboxLoginClientID];
                Class clientClass = objc_getClass("XBLMSADeviceClient");
                if (clientClass) {
                    Method m = class_getInstanceMethod(clientClass, @selector(msaAppID));
                    if (m && method_getImplementation(m) == (IMP)mcfix_msaAppID_replacement) {
                        atomic_store(&sMsaHooked, true);
                    }
                }
            }
            if ((atomic_load(&sKeychainHooked) && atomic_load(&sServiceHooked) && atomic_load(&sMsaHooked)) ||
                attempts >= 24) {
                dispatch_source_cancel(src);
            }
        });
        dispatch_resume(src);
    });
}

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        MCFIXCrashTraceInstall();
        MCFIXCrashTrace(@"+load begin build=20260523");
        // Phase A: fishhook first (POSIX hooks must exist before any mkdir/VFS I/O).
        [self installPOSIXPathRebindings];

        // NSUserDefaults profile keys → offline XUID (VFS clientId.txt seeded in Phase B).
        MCFIXInstallMarketplaceIdentityBridge();

        // Phase B (sync, before NSFileManager swizzles): migrations must finish before
        // redirect swizzles are active — async Phase B caused early-start races/crashes.
        MCFIXRunBootstrapPhaseB();

        [self patchNSFileManagerLibraryGamesPathRedirect];
        [self patchNSFileManagerWorldIconUITrace];
        [self patchNSFileManagerStorage];
        [self patchNSFileManagerUbiquity];
        MCFIXWarmPathRedirectCaches();

        [self patchCloudKit];
        [self patchICloudNotificationListener];
        [self installUbiquityNotificationGuard];

        [self patchICloudGate];
        MCFIXDiagInstallLifecycleHooks();
        MCFIXDiagStartWatchdog();

        MCFIXInstallSideloadFixes();
        MCFIXInstallXBLFocusFix();
        [self patchSideloadPushAndUserNotifications];

        MCFIXStartXBLLateBindTimer();

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [MCFIXFTPServer start];
        });
    });
}

+ (void)patchXboxLoginClientID {
    Class clientClass = objc_getClass("XBLMSADeviceClient");
    if (!clientClass) {
        return;
    }
    SEL sel = @selector(msaAppID);
    Method m = class_getInstanceMethod(clientClass, sel);
    if (m) {
        const char *enc = method_getTypeEncoding(m);
        if (enc == NULL) {
            enc = "@@:"; // - (id)msaAppID
        }
        class_replaceMethod(clientClass, sel, (IMP)mcfix_msaAppID_replacement, enc);
        MCFIXDiagOnce(@"xbl_msa", @"Xbox: XBLMSADeviceClient.msaAppID hook installed (login unchanged)");
    }
}

/// Late-bind timer: install once when XBLServiceManager is registered.
+ (BOOL)installXBLServiceManagerGuardsOnce {
    Class svc = objc_getClass("XBLServiceManager");
    if (!svc) {
        return NO;
    }
    static dispatch_once_t once;
    static BOOL sInstalled = NO;
    dispatch_once(&once, ^{
        Method origSign = class_getInstanceMethod(
            svc, @selector(getTokenAndSignRequestSynchronously:completion:));
        Method replSign = class_getInstanceMethod(
            self, @selector(mcfix_xbl_getTokenAndSignRequestSynchronously:completion:));
        if (origSign && replSign) {
            method_exchangeImplementations(origSign, replSign);
            sInstalled = YES;
        }
        MCFIXDiagOnce(@"xbl_svc", @"Xbox: XBLServiceManager sign swizzle OK (per-request logs under XBLHardening)");
    });
    return sInstalled;
}

/// Late-bind timer: install once when XBLKeychainStorage is registered.
+ (BOOL)installXBLKeychainAccessGroupFixOnce {
    Class xbl = objc_getClass("XBLKeychainStorage");
    if (!xbl) {
        return NO;
    }
    static dispatch_once_t once;
    static BOOL sInstalled = NO;
    dispatch_once(&once, ^{
        SEL sel = @selector(dictionaryForKeychainQuery:);
        Method m = class_getInstanceMethod(xbl, sel);
        if (!m) {
            return;
        }
        const char *enc = method_getTypeEncoding(m);
        if (enc == NULL) {
            enc = "@@:@@";
        }
        IMP repl = (IMP)mcfix_xbl_replacement_dictForKeychainQuery;
        IMP willRun = class_getMethodImplementation(xbl, sel);
        if (willRun == NULL || willRun == repl) {
            return;
        }
        // MUST assign before class_replaceMethod: the new IMP is visible to other
        // threads immediately; if gXBL... is still NULL, we would return nil from the
        // replacement and break XBL/SecItem call sites that expect a dictionary.
        gXBLKeychainStorage_orig_dictForQuery = (XBL_DictionaryForQuery_t)willRun;
        (void)class_replaceMethod(xbl, sel, repl, enc);
        sInstalled = YES;
        MCFIXDiagOnce(@"xbl_kc", @"Xbox: XBLKeychainStorage access-group remap OK");
    });
    return sInstalled;
}

#pragma mark - Layers 5 & 7 — C++ iCloud Gate Vtable Bypass + Dispatcher Patch

+ (void)patchICloudGate {
    MCFIXLogOnce(MCFIXLogCatBoot, @"patch_icloud",
                 @"sideload: iCloud gate + dispatcher vtable patches (tweak-1 logic)");
    MCFIXInstallSyncEntryGuards();
    // Gates 1–3: prevent sub_10035C938 from ever being called.
    BOOL ok1 = mcfix_patchVtableSlot(kVtableSlot1, (void *)mcfix_gateBypass1);
    BOOL ok2 = mcfix_patchVtableSlot(kVtableSlot2, (void *)mcfix_gateBypass2);
    BOOL ok3 = mcfix_patchVtableSlot(kVtableSlot3, (void *)mcfix_gateBypass3);

    BOOL ok7 = mcfix_patchVtableSlot(kDispatcherSlot, (void *)mcfix_permissionsForceSuccess);

    BOOL ok8 = mcfix_patchVtableSlot(kIoCallbackSlot, (void *)mcfix_safeIoCallback);

    BOOL ok9 = mcfix_patchVtableSlot(kIoCallbackSlot2, (void *)mcfix_safeIoCallback2);

    BOOL ok11 = mcfix_patchVtableSlot(kSyncSlot, (void *)mcfix_syncSystemNoOp);

    BOOL ok13a = mcfix_patchVtableSlot(kNoQuerySlot, (void *)mcfix_syncSystemNoOp);

    BOOL ok13b = mcfix_patchVtableSlot(kNoWipeQueueSlot, (void *)mcfix_syncSystemNoOp);

    MCFIXVerifyVtableSlot(kSyncSlot, (void *)mcfix_syncSystemNoOp, "upload");
    MCFIXVerifyVtableSlot(kNoQuerySlot, (void *)mcfix_syncSystemNoOp, "query");
    MCFIXVerifyVtableSlot(kNoWipeQueueSlot, (void *)mcfix_syncSystemNoOp, "wipe");

    MCFIXDiagLog(@"vtable patches gate1=%d gate2=%d gate3=%d perms=%d io=%d/%d sync=%d/%d/%d",
                 ok1 ? 1 : 0, ok2 ? 1 : 0, ok3 ? 1 : 0, ok7 ? 1 : 0,
                 ok8 ? 1 : 0, ok9 ? 1 : 0, ok11 ? 1 : 0, ok13a ? 1 : 0, ok13b ? 1 : 0);
    (void)ok1;
    (void)ok2;
    (void)ok3;
    (void)ok7;
    (void)ok8;
    (void)ok9;
    (void)ok11;
    (void)ok13a;
    (void)ok13b;
}

#pragma mark - Layer 6a — Library/games + Documents/games → Caches/.../GameData/vfs

+ (void)patchNSFileManagerLibraryGamesPathRedirect {
    Class c = [NSFileManager class];
    void (^swap)(SEL, SEL) = ^(SEL a, SEL b) {
        Method o = class_getInstanceMethod(c, a);
        Method t = class_getInstanceMethod(c, b);
        if (o && t) {
            method_exchangeImplementations(o, t);
        }
    };
    swap(@selector(createDirectoryAtPath:withIntermediateDirectories:attributes:error:), @selector(mcfix_games_createDirectoryAtPath:withIntermediateDirectories:attributes:error:));
    swap(@selector(createDirectoryAtURL:withIntermediateDirectories:attributes:error:), @selector(mcfix_games_createDirectoryAtURL:withIntermediateDirectories:attributes:error:));
    swap(@selector(fileExistsAtPath:), @selector(mcfix_games_fileExistsAtPath:));
    swap(@selector(fileExistsAtPath:isDirectory:), @selector(mcfix_games_fileExistsAtPath:isDirectory:));
    swap(@selector(copyItemAtPath:toPath:error:), @selector(mcfix_games_copyItemAtPath:toPath:error:));
    swap(@selector(moveItemAtPath:toPath:error:), @selector(mcfix_games_moveItemAtPath:toPath:error:));
    swap(@selector(removeItemAtPath:error:), @selector(mcfix_games_removeItemAtPath:error:));
    swap(@selector(contentsOfDirectoryAtPath:error:), @selector(mcfix_games_contentsOfDirectoryAtPath:error:));
    swap(@selector(subpathsOfDirectoryAtPath:error:), @selector(mcfix_games_subpathsOfDirectoryAtPath:error:));
    swap(@selector(attributesOfItemAtPath:error:), @selector(mcfix_games_attributesOfItemAtPath:error:));
    swap(@selector(createFileAtPath:contents:attributes:), @selector(mcfix_games_createFileAtPath:contents:attributes:));
    swap(@selector(enumeratorAtPath:), @selector(mcfix_games_enumeratorAtPath:));
    swap(@selector(isReadableFileAtPath:), @selector(mcfix_games_isReadableFileAtPath:));
    swap(@selector(isWritableFileAtPath:), @selector(mcfix_games_isWritableFileAtPath:));
    swap(@selector(copyItemAtURL:toURL:error:), @selector(mcfix_games_copyItemAtURL:toURL:error:));
    swap(@selector(moveItemAtURL:toURL:error:), @selector(mcfix_games_moveItemAtURL:toURL:error:));
    swap(@selector(removeItemAtURL:error:), @selector(mcfix_games_removeItemAtURL:error:));
    // Belt-and-suspenders: URL-based directory listing may bypass opendir hook on some
    // NSFileManager codepaths. Swizzle both variants so world discovery always sees Caches.
    swap(@selector(contentsOfDirectoryAtURL:includingPropertiesForKeys:options:error:),
         @selector(mcfix_games_contentsOfDirectoryAtURL:includingPropertiesForKeys:options:error:));
    swap(@selector(enumeratorAtURL:includingPropertiesForKeys:options:errorHandler:),
         @selector(mcfix_games_enumeratorAtURL:includingPropertiesForKeys:options:errorHandler:));
}

/// Trace-only: NSData/Foundation reads of world_icon (Bedrock may bypass libc fopen for thumbnails).
+ (void)patchNSFileManagerWorldIconUITrace {
    Class c = [NSFileManager class];
    void (^swap)(SEL, SEL) = ^(SEL a, SEL b) {
        Method o = class_getInstanceMethod(c, a);
        Method t = class_getInstanceMethod([MinecraftStorageFix class], b);
        if (o && t) {
            method_exchangeImplementations(o, t);
        }
    };
    swap(@selector(contentsAtPath:), @selector(mcfix_worldIcon_contentsAtPath:));
    swap(@selector(dataWithContentsOfFile:options:error:),
         @selector(mcfix_worldIcon_dataWithContentsOfFile:options:error:));
}

#pragma mark - Layer 6 — NSFileManager URLForUbiquityContainerIdentifier:

+ (void)patchNSFileManagerStorage {
    // Patch containerURLForSecurityApplicationGroupIdentifier:
    Method orig = class_getInstanceMethod([NSFileManager class],
        @selector(containerURLForSecurityApplicationGroupIdentifier:));
    Method swiz = class_getInstanceMethod(self,
        @selector(mcfix_containerURLForSecurityApplicationGroupIdentifier:));
    if (orig && swiz) {
        method_exchangeImplementations(orig, swiz);
    }

    // Patch URLForUbiquityContainerIdentifier: — prevents tvOS system
    // "Sign in to iCloud" sheet when the game requests an iCloud container.
    Method origUbiq = class_getInstanceMethod([NSFileManager class],
        @selector(URLForUbiquityContainerIdentifier:));
    Method swizUbiq = class_getInstanceMethod(self,
        @selector(mcfix_URLForUbiquityContainerIdentifier:));
    if (origUbiq && swizUbiq) {
        method_exchangeImplementations(origUbiq, swizUbiq);
    }
}

// Redirects app-group containers to a writable Caches path; avoids EPERM on
// physical Apple TV hardware where the real shared container is entitlement-gated.
- (NSURL *)mcfix_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    if (!groupIdentifier.length) {
        groupIdentifier = @"unknown";
    }

    NSString *home     = NSHomeDirectory();
    NSString *basePath = [home stringByAppendingPathComponent:
                          @"Library/Caches/AppGroupContainers"];
    NSURL *containerURL = [[NSURL fileURLWithPath:basePath isDirectory:YES]
                            URLByAppendingPathComponent:groupIdentifier];

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:containerURL.path]) {
        for (NSString *sub in @[@"Library", @"Library/Application Support",
                                @"Library/Caches", @"Library/Preferences",
                                @"Documents", @"tmp"]) {
            [fm createDirectoryAtURL:[containerURL URLByAppendingPathComponent:sub]
         withIntermediateDirectories:YES
                          attributes:nil
                               error:nil];
        }
        [containerURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    }

    return containerURL;
}

// Returns a local directory URL instead of a real iCloud container URL.
// Prevents the OS-level "Sign in to iCloud" sheet on tvOS when the game
// (or a linked framework) requests a ubiquity container.
- (NSURL *)mcfix_URLForUbiquityContainerIdentifier:(NSString *)containerIdentifier {
    NSString *home = NSHomeDirectory();
    NSString *base = [home stringByAppendingPathComponent:
                      @"Library/Caches/iCloudContainerSim"];

    if (containerIdentifier.length) {
        NSString *sanitized = [containerIdentifier
                               stringByReplacingOccurrencesOfString:@"." withString:@"_"];
        base = [base stringByAppendingPathComponent:sanitized];
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:base]) {
        [fm createDirectoryAtPath:base
     withIntermediateDirectories:YES
                      attributes:nil
                           error:nil];
    }

    return [NSURL fileURLWithPath:base isDirectory:YES];
}

#pragma mark - NSFileManager — Ubiquity Token (Layer 1)

+ (void)patchNSFileManagerUbiquity {
    Method origToken = class_getInstanceMethod([NSFileManager class],
        @selector(ubiquityIdentityToken));
    Method swizToken = class_getInstanceMethod(self,
        @selector(mcfix_ubiquityIdentityToken));
    if (origToken && swizToken) {
        method_exchangeImplementations(origToken, swizToken);
    }
}

// Return a stable fake token so bootstrap does not wait on a missing ubiquity identity.
// sub_100CA2FBC also writes this key when fetchUserRecordID succeeds.
- (id)mcfix_ubiquityIdentityToken {
    MCFIXInstallFakeUbiquityToken();
    return kMCFIXFakeUbiquityToken;
}

#pragma mark - CloudKit — defaultContainer wrapper (Layer 3)

+ (void)patchCloudKit {
    MCFIXInstallFakeUbiquityToken();
    Class ckClass = objc_getClass("CKContainer");
    if (ckClass) {
        Method origDefault = class_getClassMethod(ckClass, @selector(defaultContainer));
        Method swizDefault = class_getClassMethod(self, @selector(mcfix_defaultContainer));
        if (origDefault && swizDefault) {
            method_exchangeImplementations(origDefault, swizDefault);
        }
        Method origIdent = class_getClassMethod(ckClass, @selector(containerWithIdentifier:));
        Method swizIdent = class_getClassMethod(self, @selector(mcfix_containerWithIdentifier:));
        if (origIdent && swizIdent) {
            method_exchangeImplementations(origIdent, swizIdent);
        }
    }

    Class queryOpClass = objc_getClass("CKQueryOperation");
    Method queryOrig = class_getInstanceMethod(queryOpClass, @selector(setQueryCompletionBlock:));
    static BOOL queryPatched = NO;
    if (queryOrig && !queryPatched) {
        gOrigCKQuerySetCompletion = (void (*)(id, SEL, id))method_getImplementation(queryOrig);
        method_setImplementation(queryOrig, (IMP)MCFIXCKQuerySetCompletion);
        queryPatched = YES;
    }

    Class modifyOpClass = objc_getClass("CKModifyRecordsOperation");
    Method modifyOrig = class_getInstanceMethod(modifyOpClass, @selector(setModifyRecordsCompletionBlock:));
    static BOOL modifyPatched = NO;
    if (modifyOrig && !modifyPatched) {
        gOrigCKModifySetCompletion = (void (*)(id, SEL, id))method_getImplementation(modifyOrig);
        method_setImplementation(modifyOrig, (IMP)MCFIXCKModifySetCompletion);
        modifyPatched = YES;
    }

    MCFIXLogOnce(MCFIXLogCatBoot, @"cloudkit_shim",
                 @"CloudKitShim default=%d query=%d modify=%d fakeDB=1",
          (ckClass != Nil) ? 1 : 0,
          queryOrig ? 1 : 0,
          modifyOrig ? 1 : 0);
}

+ (id)mcfix_defaultContainer {
    return MCFIXFakeCloudContainer();
}

+ (id)mcfix_containerWithIdentifier:(NSString *)containerIdentifier {
    (void)containerIdentifier;
    return MCFIXFakeCloudContainer();
}

#pragma mark - iCloudNotificationListener — surgical no-op (Layer 2)

// iCloudAccountAvailabilityChanged: (0x100c9ed90) is registered for BOTH:
//   • NSUbiquityIdentityDidChangeNotification
//   • CKAccountChangedNotification
// Both fire on sideloaded builds immediately after launch; the implementation
// calls [CKContainer defaultContainer] → fetchUserRecordIDWithCompletionHandler:
// whose block dereferences the null iCloudStorage::Impl* → crash.
// Replacing the method with a no-op blocks both notification paths.
+ (void)patchICloudNotificationListener {
    Class listenerClass = objc_getClass("iCloudNotificationListener");
    if (!listenerClass) return;

    Method orig = class_getInstanceMethod(listenerClass,
        @selector(iCloudAccountAvailabilityChanged:));
    Method swiz = class_getInstanceMethod(self,
        @selector(mcfix_iCloudAccountAvailabilityChanged:));
    if (orig && swiz) {
        method_exchangeImplementations(orig, swiz);
    }
}

- (void)mcfix_iCloudAccountAvailabilityChanged:(id)notification {
    // Intentional no-op.
}

#pragma mark - Game Data Directories (Layer 4)

+ (void)ensureGameDataDirectories {
    NSFileManager *fm   = [NSFileManager defaultManager];
    NSString      *home = NSHomeDirectory();

    NSArray<NSString *> *paths = @[
        [home stringByAppendingPathComponent:@"Library/games/com.mojang"],
        [home stringByAppendingPathComponent:@"Library/games/com.mojang/minecraftWorlds"],
        [home stringByAppendingPathComponent:@"Library/games/com.mojang/minecraftStructures"],
        [home stringByAppendingPathComponent:@"Library/games/com.mojang/resource_packs"],
        [home stringByAppendingPathComponent:@"Library/games/com.mojang/behavior_packs"],
        [home stringByAppendingPathComponent:@"Library/games/com.mojang/skin_packs"],
        [home stringByAppendingPathComponent:@"Library/games/com.mojang/screenshots"],
        [home stringByAppendingPathComponent:@"Documents/games/com.mojang"],
        [home stringByAppendingPathComponent:@"Documents/games/com.mojang/minecraftWorlds"],
        // Framework-only roots: game writes here when sub_1006E64E0 is not hooked.
        // The swizzle redirects these to the persistent Caches vfs tree.
        [home stringByAppendingPathComponent:@"tmp/Temp/games/com.mojang"],
        [home stringByAppendingPathComponent:@"tmp/Temp/games/com.mojang/minecraftWorlds"],
        [home stringByAppendingPathComponent:@"tmp/Temp/internal"],
        // Secondary content root (IDA: sub_100792D10, a1+312 = NSTemporaryDirectory()+"/minecraftpe").
        // Uses raw NSTemporaryDirectory() (no /Temp), tail = "tmp/minecraftpe".
        // Stores packs, screenshots, and secondary game content.
        [home stringByAppendingPathComponent:@"tmp/minecraftpe"],
        [home stringByAppendingPathComponent:@"tmp/minecraftpe/games/com.mojang"],
        [home stringByAppendingPathComponent:@"tmp/minecraftpe/games/com.mojang/minecraftWorlds"],
    ];

    for (NSString *path in paths) {
        if (![fm fileExistsAtPath:path]) {
            [fm createDirectoryAtPath:path
          withIntermediateDirectories:YES
                           attributes:nil
                                error:nil];
        }
        NSString *markPath = MCFIXPathByRedirectingGameStorage(path);
        if (markPath.length) {
            [[NSURL fileURLWithPath:markPath] setResourceValue:@YES
                                                        forKey:NSURLIsExcludedFromBackupKey
                                                         error:nil];
        }
    }
}

#pragma mark - Ubiquity Notification Guard (Layer 1 supplement)

// Sideload fires NSUbiquityIdentityDidChangeNotification at launch. Re-assert the fake
// token (sub_100CA2FBC / bootstrap read NSUserDefaults) — do NOT remove the key.
+ (void)installUbiquityNotificationGuard {
    [[NSNotificationCenter defaultCenter]
        addObserverForName:@"NSUbiquityIdentityDidChangeNotification"
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        (void)note;
        MCFIXInstallFakeUbiquityToken();
        MCFIXLogOnce(MCFIXLogCatCK, @"ubiquity_token", @"ubiquity notification → fake token restored");
    }];
}

@end

