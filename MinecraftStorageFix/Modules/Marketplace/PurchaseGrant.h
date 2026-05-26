#pragma once

#import <Foundation/Foundation.h>
#import <stdbool.h>

/// Installs __DATA_CONST vtable capture on the catalog manager's path-sync virtual
/// (sub_10064410C @ slot 0x1014D0360). No __TEXT inline hooks.
void MCFIXInstallCatalogOwnershipHooks(void);

/// Calls the game's sub_10064324C(catalogMgr, mode) when the manager pointer is known.
void MCFIXTriggerCatalogOwnershipReconcile(int reconcileMode);

/// Periodic reconcile after bootstrap (waits for catalog manager construction).
void MCFIXStartCatalogOwnershipReconcileTimer(void);

/// Register a CatalogManager* discovered elsewhere (vtable must match off_1014D0320).
void MCFIXRegisterCatalogManager(void *mgr);

/// IDA sub_1006658CC — reload Inventory from `{storage}/{hash}.ent` on the main thread.
/// Returns YES when the native reload ran with a valid manager pointer.
BOOL MCFIXTriggerEntitlementInventoryReload(void);
