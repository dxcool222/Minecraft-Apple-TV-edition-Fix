#pragma once

#import <Foundation/Foundation.h>

/// IDA sub_10060B010 / sub_10117A778: live XUID is a 16-digit decimal string on the Xbox user object.
/// Captured synchronously from XBL sign + NSUserDefaults setObject — not read from plist in hot paths.
BOOL MCFIXProfileIdentityIsValidNumericXUID(NSString *identity);
NSString *MCFIXSanitizedProfileIdentityOrOffline(NSString *candidate);

/// Thread-safe live cache (zero NSUserDefaults plist latency).
void MCFIXCaptureActiveLiveXUID(NSString *candidate);
NSString *MCFIXCopyActiveLiveXUID(void);
void MCFIXClearActiveLiveXUID(void);

/// Try to parse `xuid(##############)` from an Xbox Live request URL.
void MCFIXTryCaptureXUIDFromXboxRequestURL(NSURL *url);
