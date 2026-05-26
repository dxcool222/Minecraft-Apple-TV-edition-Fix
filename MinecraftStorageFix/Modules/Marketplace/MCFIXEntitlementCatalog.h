#pragma once

#import <stddef.h>

typedef struct {
    const char *productId;
    const char *typeUUID;
    const char *friendlyName;
    /// resource_packs | behavior_packs | skin_packs (IDA sub_1007C6E10 globals)
    const char *packKind;
} MCFIXEntitlementCatalogEntry;

extern const MCFIXEntitlementCatalogEntry kMCFIXProductionEntitlementCatalog[];
extern const size_t kMCFIXProductionEntitlementCatalogCount;
