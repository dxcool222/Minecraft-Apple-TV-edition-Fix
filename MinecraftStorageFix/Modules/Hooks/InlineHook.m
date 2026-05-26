// Inline trampoline hook for the Minecraft main binary.
//
// vm_allocate a 64-byte RWX region for the trampoline, copy the first 16
// bytes of the target prologue + an absolute jump back to target+16, then
// patch the target with an absolute jump to the replacement.
//
// On real Apple TV hardware AMFI typically refuses vm_protect on
// __TEXT_EXEC pages — most callers see kr=2 and fall back to vtable
// patches. The code is kept for cases where it does succeed (older iOS,
// certain JB configurations) and for diagnostics on failure.

#import "../Internal/MCFIXInlineHook.h"
#import "MCFIXLog.h"

#import <dlfcn.h>
#import <libkern/OSCacheControl.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <mach/vm_map.h>

static intptr_t gMCFIXCachedSlide = 0;
static uintptr_t gMCFIXCachedImageLo = 0;
static uintptr_t gMCFIXCachedImageHi = 0;
static dispatch_once_t gMCFIXImageBoundsOnce;

void MCFIXCachedImageBounds(intptr_t *outSlide, uintptr_t *outLo, uintptr_t *outHi) {
    dispatch_once(&gMCFIXImageBoundsOnce, ^{
        uint32_t imageCount = _dyld_image_count();
        intptr_t slide = (intptr_t)_dyld_get_image_vmaddr_slide(0);
        const char *imageName = _dyld_get_image_name(0);
        for (uint32_t i = 0; i < imageCount; i++) {
            const char *name = _dyld_get_image_name(i);
            if (name && strstr(name, "minecraftappletv.app/minecraftappletv")) {
                slide = (intptr_t)_dyld_get_image_vmaddr_slide(i);
                imageName = name;
                break;
            }
        }
        gMCFIXCachedSlide = slide;
        gMCFIXCachedImageLo = (uintptr_t)(0x100000000UL + (uintptr_t)slide);
        gMCFIXCachedImageHi = gMCFIXCachedImageLo + 0x03000000UL;
        (void)imageName;
    });
    if (outSlide) {
        *outSlide = gMCFIXCachedSlide;
    }
    if (outLo) {
        *outLo = gMCFIXCachedImageLo;
    }
    if (outHi) {
        *outHi = gMCFIXCachedImageHi;
    }
}

intptr_t MCFIXMainImageSlide(void) {
    MCFIXCachedImageBounds(NULL, NULL, NULL);
    return gMCFIXCachedSlide;
}

uintptr_t MCFIXImageLo(void) {
    MCFIXCachedImageBounds(NULL, NULL, NULL);
    return gMCFIXCachedImageLo;
}

uintptr_t MCFIXImageHi(void) {
    MCFIXCachedImageBounds(NULL, NULL, NULL);
    return gMCFIXCachedImageHi;
}

void MCFIXPerformOnMainThread(void (^block)(void)) {
    if (!block) return;
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

BOOL MCFIXInstallInlineHook(MCFIXInlineHook *h, uintptr_t staticAddr, void *replacement) {
    if (!h || h->installed) return YES;
    intptr_t slide = 0;
    const char *imageName = NULL;
    MCFIXCachedImageBounds(&slide, NULL, NULL);
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "minecraftappletv.app/minecraftappletv")) {
            imageName = name;
            break;
        }
    }
    if (imageName == NULL) {
        imageName = _dyld_get_image_name(0);
    }
    uint8_t *target = (uint8_t *)(staticAddr + (uintptr_t)slide);
    h->target = target;
    h->replacement = replacement;
    MCFIXLogOnce(MCFIXLogCatXBL, [NSString stringWithFormat:@"xbl_prep_0x%llx", staticAddr],
                 @"hook prep static=0x%llx target=%p slide=0x%llx image=%s",
          (unsigned long long)staticAddr, target, (unsigned long long)slide, imageName ?: "(null)");

    vm_address_t trampAddr = 0;
    kern_return_t kr = vm_allocate(mach_task_self(), &trampAddr, 64, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        MCFIXLog(MCFIXLogCatError,
                 @"XBL hook fail static=0x%llx gate=vm_allocate kr=%d",
                 (unsigned long long)staticAddr, kr);
        return NO;
    }
    kr = vm_protect(mach_task_self(), trampAddr, 64, FALSE,
                    VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        MCFIXLog(MCFIXLogCatError,
                 @"XBL hook fail static=0x%llx gate=trampoline_vm_protect kr=%d",
                 (unsigned long long)staticAddr, kr);
        return NO;
    }
    uint8_t *tramp = (uint8_t *)trampAddr;

    memcpy(h->original, target, sizeof(h->original));
    memcpy(tramp, h->original, sizeof(h->original));

    uint32_t *jmpBack = (uint32_t *)(tramp + 16);
    jmpBack[0] = 0x58000050; // ldr x16, #8
    jmpBack[1] = 0xD61F0200; // br x16
    *(uint64_t *)(tramp + 24) = (uint64_t)(target + 16);
    sys_icache_invalidate((void *)tramp, 32);

    uintptr_t page = ((uintptr_t)target) & ~((uintptr_t)vm_page_size - 1);
    kr = vm_protect(mach_task_self(), (vm_address_t)page, (vm_size_t)vm_page_size, FALSE,
                    VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        kr = vm_protect(mach_task_self(), (vm_address_t)page, (vm_size_t)vm_page_size, TRUE,
                        VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
    }
    if (kr != KERN_SUCCESS) {
        MCFIXLog(MCFIXLogCatError,
                 @"XBL hook fail static=0x%llx gate=target_vm_protect kr=%d page=%p",
                 (unsigned long long)staticAddr, kr, (void *)page);
        return NO;
    }
    uint32_t *patch = (uint32_t *)target;
    patch[0] = 0x58000050; // ldr x16, #8
    patch[1] = 0xD61F0200; // br x16
    *(uint64_t *)(target + 8) = (uint64_t)replacement;
    sys_icache_invalidate((void *)target, 16);
    (void)vm_protect(mach_task_self(), (vm_address_t)page, (vm_size_t)vm_page_size, FALSE,
                     VM_PROT_READ | VM_PROT_EXECUTE);

    h->trampoline = tramp;
    h->installed = YES;
    MCFIXLogOnce(MCFIXLogCatXBL, [NSString stringWithFormat:@"xbl_ok_0x%llx", staticAddr],
                 @"hook ok static=0x%llx target=%p tramp=%p",
                 (unsigned long long)staticAddr, target, tramp);
    return YES;
}
