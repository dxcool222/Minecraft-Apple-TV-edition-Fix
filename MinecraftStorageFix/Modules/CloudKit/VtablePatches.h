#pragma once

#import <Foundation/Foundation.h>
#import <stdint.h>

// __DATA_CONST vtable slot addresses (static VA in the unpatched main image).
extern const uintptr_t kVtableSlot1;
extern const uintptr_t kVtableSlot1Alt;
extern const uintptr_t kVtableSlot1Alt2;
extern const uintptr_t kVtableSlot2;
extern const uintptr_t kVtableSlot3;
extern const uintptr_t kDispatcherSlot;
extern const uintptr_t kIoCallbackSlot;
extern const uintptr_t kIoCallbackSlot2;
extern const uintptr_t kSyncSlot;
extern const uintptr_t kNoQuerySlot;
extern const uintptr_t kNoWipeQueueSlot;

// Function-address constants used by the replacement bodies (called by VA + slide).
extern const uintptr_t kSuccessFunc1;
extern const uintptr_t kSuccessFunc2;
extern const uintptr_t kFnStateUpdate3;
extern const uintptr_t kFnScreenObj3;
extern const uintptr_t kFnProgression3;
extern const uintptr_t kFnKVCleanup3;
extern const uintptr_t kDispatcherSuccess;
extern const uintptr_t kNotifyChain;

// Vtable slot replacements.
int64_t mcfix_gateBypass1(int64_t a1);
int64_t mcfix_gateBypass2(int64_t a1);
int64_t mcfix_gateBypass3(int64_t a1);
int64_t mcfix_permissionsForceSuccess(int64_t a1);
int64_t mcfix_safeIoCallback(int64_t a1);
int64_t mcfix_safeIoCallback2(int64_t a1);
int64_t mcfix_syncSystemNoOp(int64_t a1, unsigned char *a2);

BOOL MCFIXVerifyVtableSlot(uintptr_t staticSlotAddr, void *expectedFn, const char *label);
