// Stand-in CKDatabase / CKContainer.
//
// +[CKContainer defaultContainer] is swizzled to return MCFIXFakeCloudContainer
// (see +[MinecraftStorageFix patchCloudKit]). Every CKQuery / CKModify path
// then runs against this shim — addOperation: just schedules a fake
// completion on the main queue and the operation's callbacks fire with
// (nil, nil) or (@[], @[], nil). The game's CloudKit-driven state machines
// advance to "done" without ever talking to Apple, but the C++ functor at
// op+112 still gets to run on its own stack first.

#import "FakeCKContainer.h"
#import "../Internal/MCFIXState.h"

@interface MCFIXFakeCKDatabase : NSObject
@end

@implementation MCFIXFakeCKDatabase

- (void)addOperation:(id)operation {
    if (!operation) return;
    __weak id weakOp = operation;
    dispatch_async(dispatch_get_main_queue(), ^{
        id op = weakOp;
        if (!op) return;
        gMCFIXDiag.fakeCKOps++;
        if (gMCFIXDiag.fakeCKOps <= 2) {
            MCFIXDiagLog(@"fakeDB addOperation #%u %@", gMCFIXDiag.fakeCKOps,
                         NSStringFromClass([op class]));
        } else if (gMCFIXDiag.fakeCKOps == 3) {
            MCFIXDiagOnce(@"fakeDB_more",
                          @"fakeDB: further addOperation calls suppressed (see SUMMARY fakeCK count)");
        }
        MCFIXCompleteFakeCKOperation(op);
    });
}

@end

@interface MCFIXFakeCKContainer : NSObject
@end

@implementation MCFIXFakeCKContainer

- (id)privateCloudDatabase {
    return MCFIXFakeCloudDatabase();
}

- (void)accountStatusWithCompletionHandler:(void (^)(NSInteger accountStatus, NSError *error))completion {
    if (!completion) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        MCFIXDiagOnce(@"ck_account", @"accountStatus → Available (tweak-1)");
        gMCFIXDiag.bootstrap++;
        completion(1, nil);
    });
}

- (void)fetchUserRecordIDWithCompletionHandler:(void (^)(id recordID, NSError *error))completion {
    if (!completion) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        MCFIXDiagOnce(@"ck_recordid", @"fetchUserRecordID → nil,nil (tweak-1)");
        completion(nil, nil);
    });
}

@end

id MCFIXFakeCloudDatabase(void) {
    static MCFIXFakeCKDatabase *db = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        db = [MCFIXFakeCKDatabase new];
    });
    return db;
}

id MCFIXFakeCloudContainer(void) {
    static MCFIXFakeCKContainer *container = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        container = [MCFIXFakeCKContainer new];
    });
    return container;
}
