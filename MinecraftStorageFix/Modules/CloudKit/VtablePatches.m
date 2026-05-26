// CloudKit / iCloud gate vtable patches.
//
// On sideload (no iCloud entitlement) several C++ vtable methods reach
// sub_10035C938 which surfaces the "Turn on iCloud" modal and stalls the
// boot path. Three "gate" slots and one Permissions dispatcher are
// replaced with bypass functions that drive the success path directly.
//
// Two IO-callback slots crash with a null *(streamObj+104) under a
// streaming race; their replacements null-guard the chain and mark the
// stream object "done" so the poll function doesn't deadlock.
//
// Three LevelDB sync slots are replaced with an unconditional no-op that
// stops -SYNC- backup file creation + the CloudKit upload chain, which
// in turn prevents the "failed to sync world data" path that can delete
// local world files on failure.

#import "VtablePatches.h"
#import "../Internal/MCFIXInlineHook.h"
#import "../Internal/MCFIXState.h"
#import "MCFIXLog.h"

#import <mach-o/dyld.h>

const uintptr_t kVtableSlot1     = 0x1014A4B58UL;
const uintptr_t kVtableSlot1Alt  = 0x1014A4BA0UL;
const uintptr_t kVtableSlot1Alt2 = 0x10149F5B8UL;
const uintptr_t kVtableSlot2     = 0x10149C410UL;
const uintptr_t kVtableSlot3     = 0x1014A5758UL;
const uintptr_t kDispatcherSlot  = 0x1014A5150UL;
const uintptr_t kIoCallbackSlot  = 0x10154A3C8UL;
const uintptr_t kIoCallbackSlot2 = 0x10154A348UL;
const uintptr_t kSyncSlot        = 0x10154C5E0UL;
const uintptr_t kNoQuerySlot     = 0x10154C698UL;
const uintptr_t kNoWipeQueueSlot = 0x10154C5C8UL;

const uintptr_t kSuccessFunc1    = 0x10035A088UL;
const uintptr_t kSuccessFunc2    = 0x10035E93CUL;
const uintptr_t kFnStateUpdate3  = 0x100359EA8UL;
const uintptr_t kFnScreenObj3    = 0x10035F334UL;
const uintptr_t kFnProgression3  = 0x100437624UL;
const uintptr_t kFnKVCleanup3    = 0x100430C98UL;
const uintptr_t kDispatcherSuccess = 0x100359918UL;
const uintptr_t kNotifyChain     = 0x1001562E4UL;

typedef int64_t (*SuccessFn1)(int64_t storageProvider);
typedef void    (*SuccessFn2)(int64_t storageProvider, int64_t flags);
typedef int64_t (*DispatchSuccessFn)(int64_t);
typedef int64_t (*NotifyChainFn)(int64_t);

int64_t mcfix_gateBypass1(int64_t a1) {
    gMCFIXDiag.gate1++;
    if (!a1) return 0;
    int64_t platform = *(int64_t *)(a1 + 8);
    if (!platform) return 0;
    int64_t sp = *(int64_t *)(platform + 632);
    if (!sp) return 0;
    if (!*(int64_t *)(sp + 32)) return 0;

    MCFIXDiagOnce(@"gate1_invoked", @"gate1 → sub_10035A088");
    intptr_t slide = MCFIXMainImageSlide();
    SuccessFn1 fn = (SuccessFn1)(kSuccessFunc1 + (uintptr_t)slide);
    gMCFIXLastStorageProvider = sp;
    return fn(sp);
}

int64_t mcfix_gateBypass2(int64_t a1) {
    gMCFIXDiag.gate2++;
    if (!a1) return 0;
    int64_t platform = *(int64_t *)(a1 + 8);
    if (!platform) return 0;
    int64_t sp = *(int64_t *)(platform + 632);
    if (!sp) return 0;
    if (!*(int64_t *)(sp + 24)) return 0;

    MCFIXDiagOnce(@"gate2_ok", @"gate2 → sub_10035E93C");
    intptr_t slide = MCFIXMainImageSlide();
    SuccessFn2 fn = (SuccessFn2)(kSuccessFunc2 + (uintptr_t)slide);
    fn(sp, 1);
    return 0;
}

int64_t mcfix_gateBypass3(int64_t a1) {
    gMCFIXDiag.gate3++;
    if (!a1) return 8;
    int64_t platform = *(int64_t *)(a1 + 8);
    if (!platform) return 8;
    int64_t obj704 = *(int64_t *)(platform + 704);
    if (!obj704) return 8;
    if (!*(int64_t *)(obj704 + 32)) return 8;

    MCFIXDiagOnce(@"gate3_ok", @"gate3 → progression helpers");
    intptr_t slide = MCFIXMainImageSlide();

    typedef int64_t (*FnStateUpdate)(int64_t, int64_t);
    ((FnStateUpdate)(kFnStateUpdate3 + (uintptr_t)slide))(obj704, 0);

    if (*(int64_t *)(obj704 + 24) != 0) {
        typedef int64_t (*FnScreenObj)(int64_t);
        int64_t screenObj = ((FnScreenObj)(kFnScreenObj3 + (uintptr_t)slide))(obj704);
        typedef void (*FnProgression)(int64_t, int64_t);
        ((FnProgression)(kFnProgression3 + (uintptr_t)slide))(screenObj, (int64_t)0xFFFFFFFFLL);
        typedef void (*FnKVCleanup)(void);
        ((FnKVCleanup)(kFnKVCleanup3 + (uintptr_t)slide))();
    }
    return 8;
}

int64_t mcfix_permissionsForceSuccess(int64_t a1) {
    if (!a1) return 0;
    intptr_t slide = MCFIXMainImageSlide();
    gMCFIXDiag.perms++;

    int64_t sp = *(int64_t *)(a1 + 632);
    if (sp) (void)*(int64_t *)(sp + 32);
    if (sp && *(int64_t *)(sp + 32)) {
        ((DispatchSuccessFn)(kDispatcherSuccess + (uintptr_t)slide))(sp);
    }
    return ((NotifyChainFn)(kNotifyChain + (uintptr_t)slide))(a1);
}

int64_t mcfix_safeIoCallback(int64_t a1) {
    if (!a1) return 1;
    int64_t ctx = *(int64_t *)(a1 + 24);
    if (!ctx) return 1;
    int64_t streamObj = *(int64_t *)(ctx + 72);
    if (!streamObj) return 1;
    if (!*(int64_t *)(streamObj + 104)) {
        *(int8_t *)(streamObj + 240) = 1;
        return 1;
    }
    intptr_t slide = MCFIXMainImageSlide();
    typedef int64_t (*IoCallbackFn)(int64_t);
    return ((IoCallbackFn)(0x100C6EAC4UL + (uintptr_t)slide))(a1);
}

int64_t mcfix_safeIoCallback2(int64_t a1) {
    if (!a1) return 1;
    int64_t v2 = *(int64_t *)(a1 + 8);
    if (!v2) return 1;
    int64_t streamObj = *(int64_t *)(v2 + 72);
    if (!streamObj) return 1;
    if (!*(int64_t *)(streamObj + 104)) {
        *(int8_t *)(streamObj + 240) = 1;
        return 1;
    }
    intptr_t slide = MCFIXMainImageSlide();
    typedef int64_t (*IoCallback2Fn)(int64_t);
    return ((IoCallback2Fn)(0x100C6E47CUL + (uintptr_t)slide))(a1);
}

int64_t mcfix_syncSystemNoOp(int64_t a1, unsigned char *a2) {
    (void)a1; (void)a2;
    return 0;
}

BOOL MCFIXVerifyVtableSlot(uintptr_t staticSlotAddr, void *expectedFn, const char *label) {
    intptr_t slide = MCFIXMainImageSlide();
    void **slot = (void **)(staticSlotAddr + (uintptr_t)slide);
    BOOL ok = (*slot == expectedFn);
    MCFIXLogOnce(MCFIXLogCatBoot, [NSString stringWithFormat:@"syncguard_%s", label],
                 @"SyncGuard %s slot=0x%lx installed=%d current=%p expected=%p",
          label ?: "?", staticSlotAddr, ok ? 1 : 0, *slot, expectedFn);
    return ok;
}
