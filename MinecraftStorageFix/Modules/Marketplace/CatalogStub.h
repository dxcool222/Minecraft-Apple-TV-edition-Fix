#pragma once

#import <Foundation/Foundation.h>

BOOL MCFIXPathMentionsCatalog(NSString *path);
BOOL MCFIXWriteBinaryCatalogStubInDirectory(NSString *dir);
void MCFIXSeedMarketplaceCatalogStubs(void);
void MCFIXSeedPremiumCacheDirectories(void);
void MCFIXMirrorMarketplaceTreeToContainer(void);
void MCFIXEnsureCatalogStubForPOSIXPath(const char *resolvedPath);
