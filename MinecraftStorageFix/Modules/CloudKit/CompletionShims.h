#pragma once

#import <Foundation/Foundation.h>

// Installs inline trampoline hooks on the CloudKit sync entry / dispatch /
// completion functions. Each replacement is a no-error variant that drops
// the error argument and tail-calls the original via its trampoline, so
// even completion callbacks queued before the vtable no-ops take effect
// drive the success branch instead of the status 5/7/8 dialog path.
void MCFIXInstallSyncEntryGuards(void);
