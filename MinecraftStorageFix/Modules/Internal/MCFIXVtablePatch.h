#pragma once

#import <Foundation/Foundation.h>
#import <stdint.h>

BOOL mcfix_patchVtableSlot(uintptr_t staticSlotAddr, void *newFn);
BOOL mcfix_patchVtableSlotCapture(uintptr_t staticSlotAddr, void *newFn, void **oldFnOut);
