//
//  MCFIXLog.h — production-silent logging (no Console, no heap tables)
//
//  MCFIX_PRODUCTION_SILENT=1: all log/diag calls compile to no-ops; format
//  arguments are not evaluated. Rebuild with MCFIX_PRODUCTION_SILENT=0 to debug.
//

#import <Foundation/Foundation.h>

#ifndef MCFIX_PRODUCTION_SILENT
#define MCFIX_PRODUCTION_SILENT 1
#endif

typedef NS_OPTIONS(uint32_t, MCFIXLogCategory) {
    MCFIXLogCatNone      = 0,
    MCFIXLogCatError     = 1u << 0,
    MCFIXLogCatBoot      = 1u << 1,
    MCFIXLogCatVFS       = 1u << 2,
    MCFIXLogCatIcon      = 1u << 3,
    MCFIXLogCatVFSTrace  = 1u << 4,
    MCFIXLogCatFSGuard   = 1u << 5,
    MCFIXLogCatFSMiss    = 1u << 6,
    MCFIXLogCatCK        = 1u << 7,
    MCFIXLogCatXBL       = 1u << 8,
};

#define MCFIX_LOG_DEFAULT_MASK ( \
    MCFIXLogCatError | MCFIXLogCatBoot | MCFIXLogCatVFS | MCFIXLogCatIcon | \
    MCFIXLogCatVFSTrace | MCFIXLogCatFSGuard | MCFIXLogCatFSMiss | \
    MCFIXLogCatCK | MCFIXLogCatXBL)
#define MCFIX_LOG_TRACE_MASK   MCFIXLogCatVFSTrace

#if MCFIX_PRODUCTION_SILENT

#define MCFIXLogEffectiveMask() (0u)
#define MCFIXLogIsEnabled(category) (NO)
#define MCFIXLog(...) ((void)0)
#define MCFIXLogOnce(...) ((void)0)
#define MCFIXLogRate(...) ((void)0)
#define MCFIXLogBump(counterKey) ((void)0)
#define MCFIXLogCounter(counterKey) (0ul)
#define MCFIXLogRedirect(path, redirected) ((void)0)
#define MCFIXLogRedirectMiss(path, home, stdPath) ((void)0)
#define MCFIXLogIconAccess(resolvedPath, accessResult) ((void)0)
#define MCFIXLogEmitBootBanner() ((void)0)
#define MCFIXLogEmitSessionSummary(trigger) ((void)0)

#else

NS_ASSUME_NONNULL_BEGIN

uint32_t MCFIXLogEffectiveMask(void);
BOOL MCFIXLogIsEnabled(MCFIXLogCategory category);

void MCFIXLog(MCFIXLogCategory category, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
void MCFIXLogOnce(MCFIXLogCategory category, NSString *key, NSString *fmt, ...) NS_FORMAT_FUNCTION(3, 4);
void MCFIXLogRate(MCFIXLogCategory category, NSString *key, NSTimeInterval minInterval,
                  NSString *fmt, ...) NS_FORMAT_FUNCTION(4, 5);

void MCFIXLogBump(NSString *counterKey);
NSUInteger MCFIXLogCounter(NSString *counterKey);

void MCFIXLogRedirect(NSString *path, NSString *redirected);
void MCFIXLogRedirectMiss(NSString *path, NSString *home, NSString *stdPath);
void MCFIXLogIconAccess(const char *resolvedPath, int accessResult);

void MCFIXLogEmitBootBanner(void);
void MCFIXLogEmitSessionSummary(NSString *trigger);

NS_ASSUME_NONNULL_END

#endif
