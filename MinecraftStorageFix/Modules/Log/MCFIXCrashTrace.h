#pragma once

#import <Foundation/Foundation.h>
#import "MCFIXLog.h"

#if MCFIX_PRODUCTION_SILENT

#define MCFIXCrashTraceInstall() ((void)0)
#define MCFIXCrashTrace(...) ((void)0)
#define MCFIXCrashTraceOnce(key, ...) ((void)0)

static inline NSString *MCFIXCrashTraceLastLine(void) { return @""; }
static inline NSString *MCFIXCrashTraceLogFilePath(void) { return @""; }

#else

/// Always-on crash breadcrumbs: sync file + stderr + os_log_error/fault.
void MCFIXCrashTraceInstall(void);
void MCFIXCrashTrace(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
void MCFIXCrashTraceOnce(NSString *key, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
NSString *MCFIXCrashTraceLastLine(void);
/// Path to tmp/mcfix_boot_trace.log (empty if open failed).
NSString *MCFIXCrashTraceLogFilePath(void);

#endif
