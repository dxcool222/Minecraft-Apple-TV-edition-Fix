#pragma once

#import <Foundation/Foundation.h>
#import <stdint.h>

// Object-inspection helpers used by the platform-capture path and the
// diagnostic snapshots. All read the C++ engine's memory by absolute
// addresses recovered from IDA — see callers for the exact offsets.

uint64_t MCFIXReadU64At(int64_t addr);
BOOL     MCFIXPointerLooksLikeGameObject(int64_t ptr);
BOOL     MCFIXPointerIsAppPlatformApple(int64_t ptr);
void     MCFIXRememberAppPlatformApple(int64_t platform);
int64_t  MCFIXGetAppPlatform(void);
int64_t  MCFIXPlatformFromViewController(id vc);
int64_t  MCFIXPlatformFromAppDelegate(void);
void     MCFIXDiagDescribePlatform(int64_t platform, NSMutableString *out);
