// Diag helpers — compiled only when MCFIX_PRODUCTION_SILENT=0

#import <Foundation/Foundation.h>
#import "../Internal/MCFIXState.h"
#import "MCFIXLog.h"

MCFIXDiagCounters gMCFIXDiag = {0};

#if !MCFIX_PRODUCTION_SILENT

BOOL MCFIXDiagEnabled(void) {
    return MCFIXLogIsEnabled(MCFIXLogCatCK);
}

void MCFIXDiagLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    MCFIXLog(MCFIXLogCatCK, @"%@", body);
}

void MCFIXDiagOnce(NSString *key, NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    MCFIXLogOnce(MCFIXLogCatCK, key, @"%@", body);
}

BOOL MCFIXDiagStateChanged(NSString *key, uint64_t fingerprint) {
    static NSMutableDictionary<NSString *, NSNumber *> *last;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        last = [NSMutableDictionary dictionary];
    });
    @synchronized (last) {
        NSNumber *prev = last[key];
        if (prev && prev.unsignedLongLongValue == fingerprint) {
            return NO;
        }
        last[key] = @(fingerprint);
        return YES;
    }
}

BOOL MCFIXDiagRateAllow(NSString *key, NSTimeInterval minInterval) {
    static NSMutableDictionary<NSString *, NSDate *> *times;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        times = [NSMutableDictionary dictionary];
    });
    NSDate *now = [NSDate date];
    @synchronized (times) {
        NSDate *prev = times[key];
        if (prev && [now timeIntervalSinceDate:prev] < minInterval) {
            return NO;
        }
        times[key] = now;
        return YES;
    }
}

#endif
