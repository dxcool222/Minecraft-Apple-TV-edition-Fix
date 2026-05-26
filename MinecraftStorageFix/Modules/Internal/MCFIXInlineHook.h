#pragma once

#import <Foundation/Foundation.h>
#import <stdint.h>

typedef struct {
    void *target;
    void *replacement;
    void *trampoline;
    uint8_t original[16];
    BOOL installed;
} MCFIXInlineHook;

intptr_t MCFIXMainImageSlide(void);
uintptr_t MCFIXImageLo(void);
uintptr_t MCFIXImageHi(void);
void MCFIXCachedImageBounds(intptr_t *outSlide, uintptr_t *outLo, uintptr_t *outHi);
void MCFIXPerformOnMainThread(void (^block)(void));
BOOL MCFIXInstallInlineHook(MCFIXInlineHook *h, uintptr_t staticAddr, void *replacement);
