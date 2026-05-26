#import "MCFIXBypass.h"

#import <pthread.h>

static pthread_key_t sBypassKey;
static dispatch_once_t sBypassKeyOnce;

void MCFIXBypassEnsureKey(void) {
    dispatch_once(&sBypassKeyOnce, ^{
        (void)pthread_key_create(&sBypassKey, NULL);
    });
}

BOOL MCFIXBypassHooksActive(void) {
    MCFIXBypassEnsureKey();
    void *v = pthread_getspecific(sBypassKey);
    return v != NULL && (uintptr_t)v == 1;
}

void MCFIXBypassHooksSet(BOOL active) {
    MCFIXBypassEnsureKey();
    pthread_setspecific(sBypassKey, active ? (void *)1 : (void *)0);
}
