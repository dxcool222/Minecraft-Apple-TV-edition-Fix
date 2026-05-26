#pragma once

#import <Foundation/Foundation.h>

// AppPlatform_apple* capture via ObjC swizzles on the game's renderer
// view controller (-initView, -viewDidLoad, -startAnimation, -drawFrame).
// Each hook reads the platform pointer from the controller's _app ivar
// (or +16 direct slot) and stores it in gMCFIXAppPlatformApple the first
// time it's seen so other layers can correlate state by absolute address.

void MCFIXInstallPlatformCaptureHooks(void);
void MCFIXTryBringUpMainMenu(NSString *reason);
