// CloudKit sync-entry inline-hook guards.
//
// Even with the vtable replacements in VtablePatches, completion callbacks
// queued before patches take effect can still fire with non-nil errors,
// reaching the sync state machine and dispatching status 5/7/8 → "failed
// to sync world data" UI + local-write disable.
//
// Solution: also inline-hook every CloudKit sync entry / dispatch function
// at its direct address. The completion callbacks tail-call the trampoline
// with NULL in the error slot, forcing them down the success branch.
//
// On real Apple TV hardware __TEXT_EXEC vm_protect is usually denied
// (AMFI/PAC) — these install attempts may report failure and the vtable
// patches in VtablePatches.m carry the fix on their own. The redundancy
// matters on older iOS where vm_protect does succeed.

#import "CompletionShims.h"
#import "VtablePatches.h"
#import "../Internal/MCFIXInlineHook.h"
#import "MCFIXLog.h"

static const uintptr_t kSyncUploadFunc                  = 0x100CA795CUL;
static const uintptr_t kSyncQueryFunc                   = 0x100CA9838UL;
static const uintptr_t kSyncWipeFunc                    = 0x100CA9074UL;
static const uintptr_t kSyncUploadDispatchFunc          = 0x100CA76B4UL;
static const uintptr_t kSyncQueryDispatchFunc           = 0x100CA0E9CUL;
static const uintptr_t kSyncWipeDispatchFunc            = 0x100CA1138UL;
static const uintptr_t kSyncQueryCompletionFunc         = 0x100CA48C4UL;
static const uintptr_t kSyncModifyCompletionFunc        = 0x100CA37F4UL;
static const uintptr_t kSyncModifyRecordsCompletionFunc = 0x100CA52C8UL;
static const uintptr_t kSyncCursorQueryCompletionFunc   = 0x100CA63D8UL;
static const uintptr_t kSyncRemoveAssetsCompletionFunc  = 0x100CA551CUL;
static const uintptr_t kSyncStatusBlockFunc             = 0x100CA27DCUL;

static MCFIXInlineHook gSyncUploadEntryHook              = {0};
static MCFIXInlineHook gSyncQueryEntryHook               = {0};
static MCFIXInlineHook gSyncWipeEntryHook                = {0};
static MCFIXInlineHook gSyncUploadDispatchHook           = {0};
static MCFIXInlineHook gSyncQueryDispatchHook            = {0};
static MCFIXInlineHook gSyncWipeDispatchHook             = {0};
static MCFIXInlineHook gSyncQueryCompletionHook          = {0};
static MCFIXInlineHook gSyncModifyCompletionHook         = {0};
static MCFIXInlineHook gSyncModifyRecordsCompletionHook  = {0};
static MCFIXInlineHook gSyncCursorQueryCompletionHook    = {0};
static MCFIXInlineHook gSyncRemoveAssetsCompletionHook   = {0};
static MCFIXInlineHook gSyncStatusBlockHook              = {0};

typedef void    (*FnSyncCompletion3_t)(int64_t, int64_t, void *);
typedef void    (*FnSyncModifyCompletion_t)(int64_t, void *, void *, void *);
typedef int64_t (*FnSyncStatusBlock_t)(int64_t);

static void mcfix_syncQueryCompletionNoError(int64_t a1, int64_t a2, void *error) {
    (void)error;
    if (gSyncQueryCompletionHook.trampoline) {
        ((FnSyncCompletion3_t)gSyncQueryCompletionHook.trampoline)(a1, a2, NULL);
    }
}

static void mcfix_syncModifyCompletionNoError(int64_t a1, void *saved, void *deleted, void *error) {
    (void)error;
    if (gSyncModifyCompletionHook.trampoline) {
        ((FnSyncModifyCompletion_t)gSyncModifyCompletionHook.trampoline)(a1, saved, deleted, NULL);
    }
}

static void mcfix_syncModifyRecordsCompletionNoError(int64_t a1, int64_t a2, void *error) {
    (void)error;
    if (gSyncModifyRecordsCompletionHook.trampoline) {
        ((FnSyncCompletion3_t)gSyncModifyRecordsCompletionHook.trampoline)(a1, a2, NULL);
    }
}

static void mcfix_syncCursorQueryCompletionNoError(int64_t a1, int64_t cursor, void *error) {
    (void)error;
    if (gSyncCursorQueryCompletionHook.trampoline) {
        ((FnSyncCompletion3_t)gSyncCursorQueryCompletionHook.trampoline)(a1, cursor, NULL);
    }
}

static void mcfix_syncRemoveAssetsCompletionNoOp(int64_t a1, int a2, void *recordIDs, int64_t error) {
    (void)a1; (void)a2; (void)recordIDs; (void)error;
}

static int64_t mcfix_syncStatusBlockFilter(int64_t block) {
    if (!block) return 0;
    int status = *(int *)(block + 40);
    if (status == 5 || status == 7 || status == 8) return 0;
    if (gSyncStatusBlockHook.trampoline) {
        return ((FnSyncStatusBlock_t)gSyncStatusBlockHook.trampoline)(block);
    }
    return 0;
}

void MCFIXInstallSyncEntryGuards(void) {
    BOOL upload         = MCFIXInstallInlineHook(&gSyncUploadEntryHook,             kSyncUploadFunc,                  (void *)mcfix_syncSystemNoOp);
    BOOL query          = MCFIXInstallInlineHook(&gSyncQueryEntryHook,              kSyncQueryFunc,                   (void *)mcfix_syncSystemNoOp);
    BOOL wipe           = MCFIXInstallInlineHook(&gSyncWipeEntryHook,               kSyncWipeFunc,                    (void *)mcfix_syncSystemNoOp);
    BOOL uploadDisp     = MCFIXInstallInlineHook(&gSyncUploadDispatchHook,          kSyncUploadDispatchFunc,          (void *)mcfix_syncSystemNoOp);
    BOOL queryDisp      = MCFIXInstallInlineHook(&gSyncQueryDispatchHook,           kSyncQueryDispatchFunc,           (void *)mcfix_syncSystemNoOp);
    BOOL wipeDisp       = MCFIXInstallInlineHook(&gSyncWipeDispatchHook,            kSyncWipeDispatchFunc,            (void *)mcfix_syncSystemNoOp);
    BOOL queryComp      = MCFIXInstallInlineHook(&gSyncQueryCompletionHook,         kSyncQueryCompletionFunc,         (void *)mcfix_syncQueryCompletionNoError);
    BOOL modifyComp     = MCFIXInstallInlineHook(&gSyncModifyCompletionHook,        kSyncModifyCompletionFunc,        (void *)mcfix_syncModifyCompletionNoError);
    BOOL modifyRecComp  = MCFIXInstallInlineHook(&gSyncModifyRecordsCompletionHook, kSyncModifyRecordsCompletionFunc, (void *)mcfix_syncModifyRecordsCompletionNoError);
    BOOL cursorComp     = MCFIXInstallInlineHook(&gSyncCursorQueryCompletionHook,   kSyncCursorQueryCompletionFunc,   (void *)mcfix_syncCursorQueryCompletionNoError);
    BOOL removeComp     = MCFIXInstallInlineHook(&gSyncRemoveAssetsCompletionHook,  kSyncRemoveAssetsCompletionFunc,  (void *)mcfix_syncRemoveAssetsCompletionNoOp);
    BOOL statusBlock    = MCFIXInstallInlineHook(&gSyncStatusBlockHook,             kSyncStatusBlockFunc,             (void *)mcfix_syncStatusBlockFilter);

    MCFIXLogOnce(MCFIXLogCatBoot, @"syncguard_entry",
                 @"SyncGuard entry upload=%d query=%d wipe=%d dispatch=%d/%d/%d",
                 upload, query, wipe, uploadDisp, queryDisp, wipeDisp);
    MCFIXLogOnce(MCFIXLogCatBoot, @"syncguard_completion",
                 @"SyncGuard completion query=%d modify=%d records=%d cursor=%d remove=%d status=%d",
                 queryComp, modifyComp, modifyRecComp, cursorComp, removeComp, statusBlock);
}
