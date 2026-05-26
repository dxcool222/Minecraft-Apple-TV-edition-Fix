#pragma once

#import <Foundation/Foundation.h>
#import <stdio.h>
#import <sys/types.h>

// World-icon mirroring + diagnostics.
//
// The game writes world thumbnails to several roots simultaneously
// (Library/games/.../<id>/world_icon.jpeg, tmp/Temp/games/..., etc.).
// We canonicalize *all* reads to a single VFS Temp file so the UI is
// consistent regardless of which path the engine probes. Writes still
// land at the original redirected path; a save-rewrite window then
// mirrors the canonical bytes back out to the other roots after close.

extern uint32_t gMCFIXWorldIconUITraceN;
extern const uint32_t kMCFIXWorldIconUITraceCap;
extern uint32_t gMCFIXWorldIconSaveRewriteAllow;
extern FILE *gMCFIXWorldIconPendingFclose;
extern char gMCFIXWorldIconPendingVfsPath[PATH_MAX];

NSString *MCFIXWorldIdFromWorldIconPath(NSString *ps);
NSString *MCFIXWorldIconCanonicalVFSPath(NSString *worldId);
NSString *MCFIXWorldIconAliasReadPath(NSString *redirectedPath);
NSString *MCFIXWorldIconHomeTempPath(NSString *worldId);

off_t MCFIXWorldIconFileBytes(NSString *path);
BOOL  MCFIXWorldIconMagicLooksJPEG(const unsigned char *hdr, size_t n);
BOOL  MCFIXWorldIconJPEGMagicOK(NSString *path);

void MCFIXWorldIconLogHeaderOnce(NSString *worldId, NSString *path);
void MCFIXWorldIconDualPathSnapshot(const char *phase, NSString *worldId, NSString *bindPathRaw);
void MCFIXWorldIconDeleteTrace(const char *op, const char *raw, const char *resolved, int blocked, int syscallRc);
void MCFIXWorldIconMirrorCanonicalToHome(NSString *worldId);
void MCFIXWorldIconTraceUI(const char *iface, const char *phase, const char *op,
                           const char *rawPath, const char *resolvedPath,
                           int rc, off_t bytes, int jpegFlag);

void MCFIXLogWorldIconBootProbe(void);
void MCFIXLogWorldIconBootInventory(void);
void MCFIXLogWorldIconAccessProbe(const char *resolvedPath, int accessRc);
void MCFIXLogWorldIconStatProbe(const char *resolvedPath, int statRc);
void MCFIXLogWorldIconFopenProbe(const char *path, const char *mode, FILE *result, const char *rawPath);
