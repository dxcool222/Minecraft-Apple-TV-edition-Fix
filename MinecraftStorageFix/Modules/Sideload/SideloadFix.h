#pragma once

#import <Foundation/Foundation.h>

// Sideload runtime fixes formerly shipped as SideloadFix.framework:
// app-group container fallback, LSBundleProxy entitlements strip,
// and StoreKit shim (canMakePayments + SKReceiptRefreshRequest).
//
// Keychain SecItem* hooks are handled separately in MinecraftStorageFix.m
// — those existed before this module was merged in and are still active.

void MCFIXInstallSideloadFixes(void);
