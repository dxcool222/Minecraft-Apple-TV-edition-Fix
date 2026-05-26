#import <Foundation/Foundation.h>

/// Persistent Caches VFS root used by the fishhook layer (`.../GameData/vfs`).
FOUNDATION_EXPORT NSString *MCFIXGameDataVFSSandboxRoot(void);

/// Standardized VFS root path, computed once at first use (FTP/HTTP/browse hot path).
FOUNDATION_EXPORT NSString *MCFIXGameDataVFSSandboxRootStd(void);

/// Every `minecraftWorlds` directory under the Caches VFS that matches `MCFIXPathByRedirectingGameStorage`
/// (same tail layout as `MCFIXTailNeedsGameVFSCacheRedirect` + `…/minecraftWorlds`).
/// Order: Library, Documents, tmp/Temp/games, tmp/minecraftpe — first entry is default restore parent for new ids.
FOUNDATION_EXPORT NSArray<NSString *> *MCFIXMinecraftWorldsVFSDirectoryPaths(void);
