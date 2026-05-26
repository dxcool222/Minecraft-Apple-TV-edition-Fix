// Catalog ownership reconciliation — uses the game's own grant path (IDA tvOS 1.1.5).
//
// All store content types (skin_pack, texture_pack, mashup, world_template, adventures)
// funnel through CatalogItem ownership:
//   sub_1006634DC(item)  — IsOwned (+168, +143, +112)
//   sub_1006642A8(item, path) — GrantCatalogOwnership
//
// Installed packs on disk are reconciled by:
//   sub_10064324C(catalogMgr, mode) → sub_100666D3C → sub_100668F94 → sub_1006642A8
//
// sub_1006634DC is never in a vtable (direct BL only). sub_10064410C is virtual at
// off_1014D0320 + 0x40 (slot 0x1014D0360) and ends with sub_10064324C(a1, 0).

#import "PurchaseGrant.h"
#import "../Internal/MCFIXInlineHook.h"
#import "../Internal/MCFIXVtablePatch.h"
#import "../Internal/MCFIXState.h"
#import "MCFIXLog.h"

#import <mach/mach.h>
#import <stdatomic.h>
#import <dispatch/dispatch.h>

// CatalogManager vtable (sub_10063D9EC sets *obj = off_1014D0320).
static const uintptr_t kMCFIXCatalogMgrVtable      = 0x1014D0320UL;
// Virtual sub_10064410C — sync installed paths then sub_10064324C(mgr, 0).
static const uintptr_t kMCFIXCatalogSyncPathsSlot  = 0x1014D0360UL;

static const uintptr_t kMCFIXFnCatalogReconcile    = 0x10064324CUL;
static const uintptr_t kMCFIXFnEntitlementReload   = 0x1006658CCUL;

static void *gMCFIXOrigCatalogSyncPaths = NULL;
static _Atomic(void *) gMCFIXCatalogManager = NULL;
static _Atomic(bool) gMCFIXCatalogReconcileDone = false;

BOOL MCFIXCatalogManagerLooksValid(void *mgr) {
    if (!mgr) return NO;
    intptr_t slide = MCFIXMainImageSlide();
    void *vt = *(void **)mgr;
    void *expected = (void *)(kMCFIXCatalogMgrVtable + (uintptr_t)slide);
    return vt == expected;
}

void MCFIXRegisterCatalogManager(void *mgr) {
    if (MCFIXCatalogManagerLooksValid(mgr)) {
        atomic_store(&gMCFIXCatalogManager, mgr);
    }
}

static void *MCFIXDiscoverCatalogManagerByVtable(void) {
    intptr_t slide = MCFIXMainImageSlide();
    const void *expectedVt = (const void *)(kMCFIXCatalogMgrVtable + (uintptr_t)slide);

    vm_address_t address = 0;
    vm_size_t regionSize = 0;
    while (1) {
        struct vm_region_submap_info_64 info;
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &address, &regionSize, NULL,
                                 (vm_region_info_t)&info, &count) != KERN_SUCCESS) {
            break;
        }
        if ((info.protection & VM_PROT_READ) && (info.protection & VM_PROT_WRITE) &&
            regionSize >= sizeof(void *)) {
            const uint8_t *bytes = (const uint8_t *)address;
            size_t limit = regionSize - sizeof(void *);
            for (size_t off = 0; off < limit; off += sizeof(void *)) {
                void *candidate = *(void **)(bytes + off);
                if (((uintptr_t)candidate & 0x7) != 0) {
                    continue;
                }
                if (*(const void **)candidate != expectedVt) {
                    continue;
                }
                if (MCFIXCatalogManagerLooksValid(candidate)) {
                    atomic_store(&gMCFIXCatalogManager, candidate);
                    return candidate;
                }
            }
        }
        address += regionSize;
    }
    return NULL;
}

static void *MCFIXResolveCatalogManager(void) {
    void *mgr = atomic_load(&gMCFIXCatalogManager);
    if (MCFIXCatalogManagerLooksValid(mgr)) {
        return mgr;
    }
    return MCFIXDiscoverCatalogManagerByVtable();
}

typedef int64_t (*MCFIXCatalogSyncPathsFn)(void *mgr, int64_t *pathList);

static int64_t mcfix_catalogSyncPathsCapture(void *mgr, int64_t *pathList) {
    if (pathList == NULL) {
        MCFIXLogOnce(MCFIXLogCatBoot, @"catalog_sync_null_paths",
                     @"catalog sync skipped (pathList=NULL)");
        return 0;
    }
    if (MCFIXCatalogManagerLooksValid(mgr)) {
        atomic_store(&gMCFIXCatalogManager, mgr);
    }
    MCFIXCatalogSyncPathsFn orig = (MCFIXCatalogSyncPathsFn)gMCFIXOrigCatalogSyncPaths;
    if (!orig) {
        return 0;
    }
    return orig(mgr, pathList);
}

void MCFIXInstallCatalogOwnershipHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        BOOL ok = mcfix_patchVtableSlotCapture(
            kMCFIXCatalogSyncPathsSlot,
            (void *)mcfix_catalogSyncPathsCapture,
            &gMCFIXOrigCatalogSyncPaths);
        MCFIXLogOnce(MCFIXLogCatBoot, @"catalog_vtable",
                     @"catalog ownership vtable slot 0x%lx ok=%d",
                     (unsigned long)kMCFIXCatalogSyncPathsSlot, ok ? 1 : 0);
    });
}

void MCFIXTriggerCatalogOwnershipReconcile(int reconcileMode) {
    if (!atomic_load(&gMCFIXBootstrapReady)) return;

    void *mgr = atomic_load(&gMCFIXCatalogManager);
    if (!MCFIXCatalogManagerLooksValid(mgr)) return;

    intptr_t slide = MCFIXMainImageSlide();
    typedef void (*MCFIXCatalogReconcileFn)(void *catalogMgr, int64_t mode);
    MCFIXCatalogReconcileFn fn =
        (MCFIXCatalogReconcileFn)(kMCFIXFnCatalogReconcile + (uintptr_t)slide);
    fn(mgr, reconcileMode);

    MCFIXLogOnce(MCFIXLogCatBoot, @"catalog_reconcile",
                 @"catalog reconcile mode=%d mgr=%p",
                 reconcileMode, mgr);
}

BOOL MCFIXTriggerEntitlementInventoryReload(void) {
    if (!atomic_load(&gMCFIXBootstrapReady)) {
        return NO;
    }

    void *mgr = MCFIXResolveCatalogManager();
    if (!MCFIXCatalogManagerLooksValid(mgr)) {
        MCFIXLogOnce(MCFIXLogCatVFS, @"ent_reload_no_mgr",
                     @"entitlement inventory reload skipped (CatalogManager not found)");
        return NO;
    }

    intptr_t slide = MCFIXMainImageSlide();
    typedef void (*MCFIXEntitlementReloadFn)(int64_t *catalogMgr);
    MCFIXEntitlementReloadFn fn =
        (MCFIXEntitlementReloadFn)(kMCFIXFnEntitlementReload + (uintptr_t)slide);
    fn((int64_t *)mgr);

    MCFIXLogOnce(MCFIXLogCatVFS, @"ent_reload_ok",
                 @"sub_1006658CC entitlement reload mgr=%p", mgr);
    return YES;
}

void MCFIXStartCatalogOwnershipReconcileTimer(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
        dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        __block int attempts = 0;
        dispatch_source_set_timer(src,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                                  (uint64_t)(1.0 * NSEC_PER_SEC),
                                  (uint64_t)(100 * NSEC_PER_MSEC));
        dispatch_source_set_event_handler(src, ^{
            attempts++;
            if (!atomic_load(&gMCFIXBootstrapReady)) return;

            void *mgr = atomic_load(&gMCFIXCatalogManager);
            if (MCFIXCatalogManagerLooksValid(mgr)) {
                if (!atomic_load(&gMCFIXCatalogReconcileDone)) {
                    // Constructor path uses mode 1 (sub_1006404AC); virtual sync uses 0.
                    MCFIXTriggerCatalogOwnershipReconcile(1);
                    MCFIXTriggerCatalogOwnershipReconcile(0);
                    atomic_store(&gMCFIXCatalogReconcileDone, true);
                }
                if (attempts >= 8) {
                    dispatch_source_cancel(src);
                }
                return;
            }

            if (attempts >= 90) {
                dispatch_source_cancel(src);
            }
        });
        dispatch_resume(src);
    });
}
