#pragma once

#import <Foundation/Foundation.h>

/// Offline entitlement / catalog item+88 identity (16-char XUID, no separators).
FOUNDATION_EXPORT NSString *const MCFIXOfflineMarketplaceIdentity;

/// NSUserDefaults swizzle for profile identity keys (no __TEXT inline hooks).
void MCFIXInstallMarketplaceIdentityBridge(void);
