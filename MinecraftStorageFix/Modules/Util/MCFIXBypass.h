#import <Foundation/Foundation.h>
#import <stdbool.h>

/// Thread-local VFS bypass (pthread TLS). Safe across concurrent FTP/HTTP GCD workers.
void MCFIXBypassEnsureKey(void);
BOOL MCFIXBypassHooksActive(void);
void MCFIXBypassHooksSet(BOOL active);
