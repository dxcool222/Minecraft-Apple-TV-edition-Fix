#import "MCFIXWebServerManager.h"

// MARK: Bypass / threading
//
// MCFIXBypassHooksSet is toggled ONLY inside HTTP handler blocks in this file so
// POSIX hooks keep redirecting normal Minecraft I/O. Never set it globally or
// persist it across requests.
//
// GCDWebServer serves each connection on libdispatch worker threads; multiple
// handlers can run concurrently under load. That is OK: game threads still use
// hooked paths; server handlers briefly flip bypass for explicit filesystem work.

// Multipart note: GCDWebServer writes each part to NSHome/tmp (tail `tmp/<UUID>`).
// That tail is NOT in MCFIXTailNeedsGameVFSCacheRedirect's prefix list (only
// tmp/Temp/games, tmp/minecraftpe, etc.), so fishhook does not remap upload temps
// into GameData/vfs — uploads cannot spill into minecraftWorlds via VFS rules.

#import "MCFIXBypass.h"
#import "MCFIXLog.h"
#import "MCFIXFTPServer.h"
#import "MCFIXGameDataVFS.h"
#import "MCFIXUnzip.h"
#import "MCFIXWebServerWorldOps.h"

#import "GCDWebServer.h"
#import "GCDWebServerDataRequest.h"
#import "GCDWebServerDataResponse.h"
#import "GCDWebServerErrorResponse.h"
#import "GCDWebServerFileResponse.h"
#import "GCDWebServerHTTPStatusCodes.h"
#import "GCDWebServerMultiPartFormRequest.h"
#import "GCDWebServerRequest.h"

@implementation MCFIXWebServerManager

static NSString *_Nullable MCFIXHeaderValue(NSDictionary *headers, NSString *name) {
    for (NSString *k in headers) {
        if ([k caseInsensitiveCompare:name] == NSOrderedSame) {
            return headers[k];
        }
    }
    return nil;
}

static NSString *_Nullable MCFIXWorldIdFromRequest(GCDWebServerRequest *request) {
    NSString *q = request.query[@"worldId"];
    if (q.length) {
        return MCFIXSanitizedWorldId(q);
    }
    return nil;
}

static BOOL MCFIXMultipartPathComponentSafe(NSString *rel) {
    if (rel.length == 0) {
        return NO;
    }
    if ([rel hasPrefix:@"/"] || [rel isAbsolutePath]) {
        return NO;
    }
    NSArray *parts = [rel pathComponents];
    for (NSString *p in parts) {
        if ([p isEqualToString:@".."]) {
            return NO;
        }
    }
    return YES;
}

/// Prefer the form field named `file` (matches browser FormData from the UI), then any other parts — stable order for .mcworld uploads.
static NSArray<GCDWebServerMultiPartFile *> *MCFIXOrderedMultipartFiles(GCDWebServerMultiPartFormRequest *mp) {
    NSMutableArray<GCDWebServerMultiPartFile *> *out = [NSMutableArray array];
    GCDWebServerMultiPartFile *primary = [mp firstFileForControlName:@"file"];
    if (primary != nil) {
        [out addObject:primary];
    }
    for (GCDWebServerMultiPartFile *f in mp.files) {
        if (f != primary) {
            [out addObject:f];
        }
    }
    return out;
}

static BOOL MCFIXHandleZipDataUpload(NSData *data, NSString *stagingWorldDir, NSError **error) {
    NSString *tmpZip =
        [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    if (![data writeToFile:tmpZip atomically:YES]) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCFIXHTTP" code:30 userInfo:nil];
        }
        return NO;
    }
    BOOL ok = MCFIXUnzipFileAtPath(tmpZip, stagingWorldDir, error);
    (void)[[NSFileManager defaultManager] removeItemAtPath:tmpZip error:nil];
    return ok;
}

static BOOL MCFIXHandleMultipartUpload(GCDWebServerMultiPartFormRequest *mpReq, NSString *stagingWorldDir,
                                       NSString *_Nullable backupLabel, NSError **error) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm createDirectoryAtPath:stagingWorldDir withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }

    for (GCDWebServerMultiPartArgument *arg in mpReq.arguments) {
        if ([arg.controlName isEqualToString:@"backupName"] && arg.string.length) {
            backupLabel = arg.string;
        }
    }

    if (mpReq.files.count == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCFIXHTTP" code:32
                                    userInfo:@{NSLocalizedDescriptionKey : @"no files in multipart body"}];
        }
        return NO;
    }

    for (GCDWebServerMultiPartFile *f in MCFIXOrderedMultipartFiles(mpReq)) {
        NSString *rel = f.fileName ?: @"";
        NSString *ext = [[rel pathExtension] lowercaseString];
        NSString *mime = [f.mimeType isKindOfClass:[NSString class]] ? [f.mimeType lowercaseString] : @"";
        BOOL mimeLooksZip = [mime containsString:@"zip"];
        BOOL sniffZip = MCFIXFileLooksLikeZipAtPath(f.temporaryPath);

        // Browsers often send application/octet-stream or an empty name; still a .mcworld PKZIP.
        if ([ext isEqualToString:@"mcworld"] || [ext isEqualToString:@"zip"] || mimeLooksZip || sniffZip) {
            MCFIXLogOnce(MCFIXLogCatBoot, @"upload_zip_part",
                         @"zip/mcworld part name=%@ ext=%@ mime=%@ sniff=%@ temp=%@", rel, ext, f.mimeType,
                  sniffZip ? @"YES" : @"NO", f.temporaryPath ?: @"");
            if (!MCFIXFileLooksLikeZipAtPath(f.temporaryPath)) {
                if (error) {
                    *error = [NSError errorWithDomain:@"MCFIXHTTP" code:34
                                           userInfo:@{NSLocalizedDescriptionKey : @"not a ZIP archive (expected .mcworld)"}];
                }
                return NO;
            }
            BOOL ok = MCFIXUnzipFileAtPath(f.temporaryPath, stagingWorldDir, error);
            MCFIXLogOnce(MCFIXLogCatBoot, @"upload_unzip", @"unzip from multipart temp ok=%@", ok ? @"YES" : @"NO");
            if (ok && backupLabel.length) {
                (void)MCFIXWriteStagedWorldSidecar(stagingWorldDir, backupLabel, nil);
            }
            return ok;
        }

        if (!MCFIXMultipartPathComponentSafe(rel)) {
            if (error) {
                *error = [NSError errorWithDomain:@"MCFIXHTTP" code:31
                                        userInfo:@{NSLocalizedDescriptionKey : @"unsafe file path"}];
            }
            return NO;
        }
        NSString *dest = [stagingWorldDir stringByAppendingPathComponent:rel];
        NSString *parent = [dest stringByDeletingLastPathComponent];
        if (![fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:error]) {
            return NO;
        }
        if ([fm fileExistsAtPath:dest]) {
            (void)[fm removeItemAtPath:dest error:nil];
        }
        if (![fm copyItemAtPath:f.temporaryPath toPath:dest error:error]) {
            return NO;
        }
    }

    if (backupLabel.length) {
        (void)MCFIXWriteStagedWorldSidecar(stagingWorldDir, backupLabel, nil);
    }

    return YES;
}

static GCDWebServerResponse *MCFIXJSONResponse(NSDictionary *obj, NSInteger code) {
    GCDWebServerDataResponse *r = [GCDWebServerDataResponse responseWithJSONObject:obj];
    r.statusCode = code;
    return r;
}

static GCDWebServerResponse *MCFIXAPIErrorJSON(NSString *msg, NSInteger code) {
    GCDWebServerDataResponse *r = [GCDWebServerDataResponse responseWithJSONObject:@{@"ok" : @NO, @"error" : msg ?: @""}];
    r.statusCode = code;
    return r;
}

static NSString *MCFIXBrowseVFSSandboxStd(void) {
    return MCFIXGameDataVFSSandboxRootStd();
}

static BOOL MCFIXBrowseIsStrictSubpath(NSString *path, NSString *root) {
    NSString *r = [root stringByStandardizingPath];
    NSString *p = [path stringByStandardizingPath];
    if (r.length == 0 || p.length == 0) {
        return NO;
    }
    if ([p isEqualToString:r]) {
        return YES;
    }
    NSString *prefix = [r hasSuffix:@"/"] ? r : [r stringByAppendingString:@"/"];
    return [p hasPrefix:prefix];
}

/// `rel` is path relative to GameData VFS root (e.g. `Library/games/com.mojang/minecraftWorlds`). Empty = root.
static NSString *_Nullable MCFIXBrowseResolveRel(NSString *rel, NSError **error) {
    NSString *vfs = MCFIXBrowseVFSSandboxStd();
    if (vfs.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCFIXBrowse" code:1
                                    userInfo:@{NSLocalizedDescriptionKey : @"VFS root unavailable"}];
        }
        return nil;
    }
    NSString *s = rel.length ? rel : @"";
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    NSString *combined = s.length ? [vfs stringByAppendingPathComponent:s] : vfs;
    NSString *std = [combined stringByStandardizingPath];
    if (!MCFIXBrowseIsStrictSubpath(std, vfs)) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCFIXBrowse" code:2
                                    userInfo:@{NSLocalizedDescriptionKey : @"path escapes VFS root"}];
        }
        return nil;
    }
    return std;
}

/// Single path segment only; used for /api/upload destination file names.
static BOOL MCFIXBrowseUploadFileNameSafe(NSString *name) {
    if (name.length == 0 || name.length > 255) {
        return NO;
    }
    if ([name isEqualToString:@"."] || [name isEqualToString:@".."]) {
        return NO;
    }
    if ([name rangeOfString:@"/"].location != NSNotFound || [name rangeOfString:@"\\"].location != NSNotFound) {
        return NO;
    }
    return YES;
}

static BOOL MCFIXWorldBackupKeySafeHTTP(NSString *worldId) {
    if (worldId.length == 0 || worldId.length > 128) {
        return NO;
    }
    if ([worldId containsString:@"/"] || [worldId containsString:@"\\"]) {
        return NO;
    }
    if ([worldId isEqualToString:@"."] || [worldId isEqualToString:@".."]) {
        return NO;
    }
    return YES;
}

static NSString *_Nullable MCFIXStageSnapshotCopyForRestore(NSString *stagingRoot, NSString *worldId, NSString *snapshotId,
                                                            NSError **error) {
    NSString *snapPath = MCFIXBackupSnapshotPath(worldId, snapshotId);
    if (snapPath.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCFIXHTTP" code:60 userInfo:nil];
        }
        return nil;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:snapPath]) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCFIXHTTP" code:61
                                     userInfo:@{NSLocalizedDescriptionKey : @"snapshot not found"}];
        }
        return nil;
    }
    NSString *stagingId = [NSString stringWithFormat:@"snap_%@", [[NSUUID UUID] UUIDString]];
    NSString *dest = [stagingRoot stringByAppendingPathComponent:stagingId];
    if (![fm copyItemAtPath:snapPath toPath:dest error:error]) {
        return nil;
    }
    return stagingId;
}

+ (void)start {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<NSString *> *worldsRoots = MCFIXMinecraftWorldsVFSDirectoryPaths();
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *r in worldsRoots) {
            if (![fm fileExistsAtPath:r]) {
                [fm createDirectoryAtPath:r withIntermediateDirectories:YES attributes:nil error:nil];
            }
        }

        NSString *stagingRoot = MCFIXWebServerStagingRoot();

        GCDWebServer *server = [[GCDWebServer alloc] init];

        [server addHandlerForMethod:@"GET"
                               path:@"/"
                       requestClass:[GCDWebServerRequest class]
                       processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
            (void)request;
            MCFIXBypassHooksSet(YES);
            @try {
                NSString *html = MCFIXWebServerFileExplorerHTML();
                if (!html) {
                    return [GCDWebServerResponse responseWithStatusCode:500];
                }
                return [GCDWebServerDataResponse responseWithHTML:html];
            } @finally {
                MCFIXBypassHooksSet(NO);
            }
        }];

        NSArray<NSDictionary<NSString *, NSString *> *> *staticAssets = @[
            @{ @"path": @"/explorer.css", @"name": @"explorer", @"ext": @"css", @"mime": @"text/css; charset=utf-8" },
            @{ @"path": @"/explorer.js",  @"name": @"explorer", @"ext": @"js",  @"mime": @"application/javascript; charset=utf-8" },
        ];
        for (NSDictionary<NSString *, NSString *> *asset in staticAssets) {
            NSString *path = asset[@"path"];
            NSString *name = asset[@"name"];
            NSString *ext  = asset[@"ext"];
            NSString *mime = asset[@"mime"];
            [server addHandlerForMethod:@"GET"
                                   path:path
                           requestClass:[GCDWebServerRequest class]
                           processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
                (void)request;
                NSData *data = MCFIXWebServerBundleResource(name, ext);
                if (!data) {
                    return [GCDWebServerResponse responseWithStatusCode:404];
                }
                return [GCDWebServerDataResponse responseWithData:data contentType:mime];
            }];
        }

        [server addHandlerWithMatchBlock:^GCDWebServerRequest *(
                                         NSString *method, NSURL *url, NSDictionary<NSString *, NSString *> *headers,
                                         NSString *urlPath, NSDictionary<NSString *, NSString *> *query) {
            (void)query;
            if (![method isEqualToString:@"POST"]) {
                return nil;
            }
            if ([urlPath caseInsensitiveCompare:@"/upload"] != NSOrderedSame) {
                return nil;
            }
            NSString *ct = MCFIXHeaderValue(headers, @"Content-Type") ?: @"";
            if ([ct rangeOfString:@"multipart/form-data" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                return [(GCDWebServerRequest *)[GCDWebServerMultiPartFormRequest alloc] initWithMethod:method
                                                                                                    url:url
                                                                                                headers:headers
                                                                                                   path:urlPath
                                                                                                  query:query];
            }
            return [(GCDWebServerRequest *)[GCDWebServerDataRequest alloc] initWithMethod:method
                                                                                     url:url
                                                                                 headers:headers
                                                                                    path:urlPath
                                                                                   query:query];
        }
            processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
                MCFIXBypassHooksSet(YES);
                GCDWebServerResponse *out = nil;
                @try {
                    NSString *stagingBase = stagingRoot;
                    [fm createDirectoryAtPath:stagingBase withIntermediateDirectories:YES attributes:nil error:nil];

                    MCFIXLogOnce(MCFIXLogCatBoot, @"upload_handler",
                                 @"/upload invoked query=%@ content-type=%@",
                                 request.query, MCFIXHeaderValue(request.headers, @"Content-Type"));

                    NSString *worldId = MCFIXWorldIdFromRequest(request);
                    NSString *backupLabel = request.query[@"backupName"];

                    NSError *err = nil;

                    if ([request isKindOfClass:[GCDWebServerMultiPartFormRequest class]]) {
                        GCDWebServerMultiPartFormRequest *mp = (GCDWebServerMultiPartFormRequest *)request;
                        MCFIXLogOnce(MCFIXLogCatBoot, @"upload_multipart",
                                     @"multipart upload: %lu files, %lu args",
                                     (unsigned long)mp.files.count, (unsigned long)mp.arguments.count);
                        GCDWebServerMultiPartArgument *wArg = [mp firstArgumentForControlName:@"worldId"];
                        if (wArg != nil && wArg.string.length) {
                            worldId = MCFIXSanitizedWorldId(wArg.string);
                        }
                        GCDWebServerMultiPartArgument *bArg = [mp firstArgumentForControlName:@"backupName"];
                        if (bArg != nil && bArg.string.length) {
                            backupLabel = bArg.string;
                        }
                        if (worldId.length == 0) {
                            for (GCDWebServerMultiPartFile *f in MCFIXOrderedMultipartFiles(mp)) {
                                MCFIXLogOnce(MCFIXLogCatBoot,
                                             [NSString stringWithFormat:@"mp_%@", f.fileName ?: @"?"],
                                             @"multipart part control=%@ name=%@ mime=%@",
                                             f.controlName ?: @"", f.fileName ?: @"", f.mimeType ?: @"");
                                if (f.fileName.length == 0) {
                                    continue;
                                }
                                NSString *base = [f.fileName stringByDeletingPathExtension];
                                worldId = MCFIXSanitizedWorldId(base);
                                if (worldId.length) {
                                    break;
                                }
                            }
                        }
                    }

                    if (worldId.length == 0) {
                        worldId = [NSString stringWithFormat:@"import-%@", [[NSUUID UUID] UUIDString]];
                    }

                    NSString *stagingWorld = [stagingBase stringByAppendingPathComponent:worldId];
                    if ([fm fileExistsAtPath:stagingWorld]) {
                        (void)[fm removeItemAtPath:stagingWorld error:nil];
                    }

                    BOOL ok = NO;
                    if ([request isKindOfClass:[GCDWebServerMultiPartFormRequest class]]) {
                        ok = MCFIXHandleMultipartUpload((GCDWebServerMultiPartFormRequest *)request, stagingWorld,
                                                       backupLabel, &err);
                    } else if ([request isKindOfClass:[GCDWebServerDataRequest class]]) {
                        NSData *data = [(GCDWebServerDataRequest *)request data];
                        if (!MCFIXDataLooksLikeZip(data)) {
                            out = [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_BadRequest
                                                                             message:@"expected application/zip body"];
                            return out;
                        }
                        if (![fm createDirectoryAtPath:stagingWorld withIntermediateDirectories:YES attributes:nil
                                                 error:&err]) {
                            ok = NO;
                        } else {
                            ok = MCFIXHandleZipDataUpload(data, stagingWorld, &err);
                        }
                        if (ok && backupLabel.length) {
                            (void)MCFIXWriteStagedWorldSidecar(stagingWorld, backupLabel, nil);
                        }
                    } else {
                        out = [GCDWebServerErrorResponse responseWithServerError:kGCDWebServerHTTPStatusCode_InternalServerError
                                                                         message:@"unsupported upload"];
                        return out;
                    }

                    if (!ok) {
                        (void)[fm removeItemAtPath:stagingWorld error:nil];
                        out = [GCDWebServerErrorResponse responseWithServerError:kGCDWebServerHTTPStatusCode_InternalServerError
                                                                         message:@"%@",
                     err.localizedDescription ?: @"upload failed"];
                        MCFIXLog(MCFIXLogCatError, @"upload failed: %@", err.localizedDescription ?: @"upload failed");
                        return out;
                    }

                    NSError *normErr = nil;
                    if (!MCFIXNormalizeStagedWorldLayout(stagingWorld, &normErr) ||
                        !MCFIXWorldFolderHasLevelDat(stagingWorld)) {
                        (void)[fm removeItemAtPath:stagingWorld error:nil];
                        out = [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_BadRequest
                                                                         message:normErr.localizedDescription
                                                                                  ?: @"level.dat missing after upload"];
                        return out;
                    }

                    MCFIXLogOnce(MCFIXLogCatBoot, [NSString stringWithFormat:@"upload_ok_%@", worldId],
                                 @"upload staged worldId=%@ path=%@", worldId, stagingWorld);
                    out = MCFIXJSONResponse(
                        @{
                            @"ok" : @YES,
                            @"worldId" : worldId,
                            @"stagedPath" : stagingWorld,
                            @"message" : @"staged; call POST /restore to promote",
                        },
                        200);
                } @finally {
                    MCFIXBypassHooksSet(NO);
                }
                return out;
            }];

        [server addHandlerWithMatchBlock:^GCDWebServerRequest *(
                                         NSString *method, NSURL *url, NSDictionary<NSString *, NSString *> *headers,
                                         NSString *urlPath, NSDictionary<NSString *, NSString *> *query) {
            (void)query;
            if (![method isEqualToString:@"POST"]) {
                return nil;
            }
            if ([urlPath caseInsensitiveCompare:@"/api/upload"] != NSOrderedSame) {
                return nil;
            }
            NSString *ct = MCFIXHeaderValue(headers, @"Content-Type") ?: @"";
            if ([ct rangeOfString:@"multipart/form-data" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                return [(GCDWebServerRequest *)[GCDWebServerMultiPartFormRequest alloc] initWithMethod:method
                                                                                                    url:url
                                                                                                headers:headers
                                                                                                   path:urlPath
                                                                                                  query:query];
            }
            return nil;
        }
            processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
                MCFIXBypassHooksSet(YES);
                GCDWebServerResponse *out = nil;
                @try {
                    if (![request isKindOfClass:[GCDWebServerMultiPartFormRequest class]]) {
                        out = MCFIXAPIErrorJSON(@"multipart form required (use field name file)", 400);
                        return out;
                    }
                    GCDWebServerMultiPartFormRequest *mp = (GCDWebServerMultiPartFormRequest *)request;
                    if (mp.files.count == 0) {
                        out = MCFIXAPIErrorJSON(@"no file in request", 400);
                        return out;
                    }
                    NSString *parentRel = request.query[@"p"] ?: @"";
                    NSError *err = nil;
                    NSString *parentAbs = MCFIXBrowseResolveRel(parentRel, &err);
                    if (!parentAbs) {
                        out = MCFIXAPIErrorJSON(err.localizedDescription, 400);
                        return out;
                    }
                    BOOL isDir = NO;
                    if (![fm fileExistsAtPath:parentAbs isDirectory:&isDir]) {
                        out = MCFIXAPIErrorJSON(@"parent path not found", 404);
                        return out;
                    }
                    if (!isDir) {
                        out = MCFIXAPIErrorJSON(@"not a directory", 400);
                        return out;
                    }
                    NSString *vfs = MCFIXBrowseVFSSandboxStd();
                    NSMutableArray<NSDictionary *> *written = [NSMutableArray array];
                    NSMutableArray<NSDictionary *> *failures = [NSMutableArray array];

                    for (GCDWebServerMultiPartFile *f in MCFIXOrderedMultipartFiles(mp)) {
                        NSString *origName = f.fileName ?: @"";
                        NSString *base = origName.length ? [origName lastPathComponent] : @"";
                        if (base.length == 0) {
                            base = [NSString stringWithFormat:@"upload-%@.bin", [[NSUUID UUID] UUIDString]];
                        } else if (!MCFIXBrowseUploadFileNameSafe(base)) {
                            [failures addObject:@{@"name" : origName ?: @"", @"error" : @"invalid or unsafe file name"}];
                            continue;
                        }
                        NSString *dest = [[parentAbs stringByAppendingPathComponent:base] stringByStandardizingPath];
                        if (!MCFIXBrowseIsStrictSubpath(dest, vfs)) {
                            [failures addObject:@{@"name" : base, @"error" : @"path escapes VFS root"}];
                            continue;
                        }
                        BOOL destDir = NO;
                        if ([fm fileExistsAtPath:dest isDirectory:&destDir] && destDir) {
                            [failures addObject:@{@"name" : base, @"error" : @"destination is a directory"}];
                            continue;
                        }
                        if ([fm fileExistsAtPath:dest]) {
                            if (![fm removeItemAtPath:dest error:&err]) {
                                [failures addObject:@{@"name" : base, @"error" : err.localizedDescription ?: @"remove failed"}];
                                continue;
                            }
                        }
                        if (![fm copyItemAtPath:f.temporaryPath toPath:dest error:&err]) {
                            [failures addObject:@{@"name" : base, @"error" : err.localizedDescription ?: @"write failed"}];
                            continue;
                        }
                        NSString *relOut = @"";
                        if (![dest isEqualToString:vfs]) {
                            NSString *prefix = [vfs hasSuffix:@"/"] ? vfs : [vfs stringByAppendingString:@"/"];
                            if ([dest hasPrefix:prefix]) {
                                relOut = [dest substringFromIndex:prefix.length];
                            }
                        }
                        [written addObject:@{@"name" : base, @"path" : relOut}];
                    }

                    if (written.count == 0) {
                        out = MCFIXJSONResponse(
                            @{@"ok" : @NO, @"error" : @"no files written", @"errors" : [failures copy]}, 400);
                        return out;
                    }
                    out = MCFIXJSONResponse(
                        @{@"ok" : @YES, @"written" : [written copy], @"errors" : [failures copy]}, 200);
                } @finally {
                    MCFIXBypassHooksSet(NO);
                }
                return out;
            }];

        [server addHandlerForMethod:@"POST"
                               path:@"/restore"
                       requestClass:[GCDWebServerDataRequest class]
                       processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
            MCFIXBypassHooksSet(YES);
            GCDWebServerResponse *out = nil;
            @try {
                GCDWebServerDataRequest *dr = (GCDWebServerDataRequest *)request;
                BOOL force = [request.query[@"force"] isEqualToString:@"1"] ||
                             [[request.query[@"force"] lowercaseString] isEqualToString:@"true"];

                NSString *targetId = request.query[@"worldId"];
                NSString *stagedId = request.query[@"stagedId"];
                NSString *snapshotId = request.query[@"snapshotId"];

                NSData *body = dr.data;
                if (body.length) {
                    NSError *jerr = nil;
                    id json = [NSJSONSerialization JSONObjectWithData:body options:0 error:&jerr];
                    if ([json isKindOfClass:[NSDictionary class]]) {
                        NSDictionary *d = (NSDictionary *)json;
                        id w = d[@"worldId"];
                        id s = d[@"stagedId"];
                        id f = d[@"force"];
                        id snap = d[@"snapshotId"];
                        if ([w isKindOfClass:[NSString class]] && [(NSString *)w length]) {
                            targetId = w;
                        } else if ([w isKindOfClass:[NSNumber class]]) {
                            targetId = [(NSNumber *)w stringValue];
                        }
                        if ([s isKindOfClass:[NSString class]] && [(NSString *)s length]) {
                            stagedId = s;
                        } else if ([s isKindOfClass:[NSNumber class]]) {
                            stagedId = [(NSNumber *)s stringValue];
                        }
                        if ([snap isKindOfClass:[NSString class]] && [(NSString *)snap length]) {
                            snapshotId = snap;
                        } else if ([snap isKindOfClass:[NSNumber class]]) {
                            snapshotId = [(NSNumber *)snap stringValue];
                        }
                        if ([f isKindOfClass:[NSNumber class]]) {
                            force = [(NSNumber *)f boolValue];
                        } else if ([f isKindOfClass:[NSString class]]) {
                            NSString *fs = (NSString *)f;
                            force = [[fs lowercaseString] isEqualToString:@"true"] || [fs isEqualToString:@"1"];
                        }
                    }
                }

                targetId = MCFIXSanitizedWorldId(targetId) ?: @"";
                stagedId = MCFIXSanitizedWorldId(stagedId) ?: @"";
                snapshotId = MCFIXSanitizedWorldId(snapshotId) ?: @"";

                if (!MCFIXWorldBackupKeySafeHTTP(targetId)) {
                    out = [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_BadRequest
                                                                     message:@"worldId required or invalid"];
                    return out;
                }

                BOOL stagedFromSnapshot = NO;

                if (snapshotId.length) {
                    NSError *serr = nil;
                    NSString *scratchId = MCFIXStageSnapshotCopyForRestore(stagingRoot, targetId, snapshotId, &serr);
                    if (scratchId.length == 0) {
                        out = [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_BadRequest
                                                                         message:@"%@",
                                                      serr.localizedDescription ?: @"snapshot restore prep failed"];
                        return out;
                    }
                    stagedId = scratchId;
                    stagedFromSnapshot = YES;
                }

                if (stagedId.length == 0) {
                    stagedId = targetId;
                }

                if (stagedId.length && !MCFIXWorldBackupKeySafeHTTP(stagedId)) {
                    out = [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_BadRequest
                                                                     message:@"stagedId invalid"];
                    return out;
                }

                NSString *stagedFolder = [[stagingRoot stringByAppendingPathComponent:stagedId] stringByStandardizingPath];
                if ([stagedFolder hasPrefix:[stagingRoot stringByStandardizingPath]] == NO) {
                    out = [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_BadRequest
                                                                     message:@"invalid staged path"];
                    return out;
                }

                if (![fm fileExistsAtPath:stagedFolder]) {
                    out = [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_BadRequest
                                                                     message:@"staged world not found"];
                    return out;
                }

                NSString *destParent = MCFIXWebServerMinecraftWorldsParentForWorldId(targetId, worldsRoots);
                NSError *rerr = nil;
                if (!MCFIXRestoreStagedWorldIntoVFSSlot(destParent, targetId, stagedFolder, force, &rerr)) {
                    if (stagedFromSnapshot) {
                        (void)[fm removeItemAtPath:stagedFolder error:nil];
                    }
                    if (rerr.code == 409) {
                        out = [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_Conflict
                                                                         message:@"%@",
                                                  rerr.localizedDescription ?: @"conflict"];
                    } else {
                        out = [GCDWebServerErrorResponse responseWithServerError:kGCDWebServerHTTPStatusCode_InternalServerError
                                                                         message:@"%@",
                                                  rerr.localizedDescription ?: @"restore failed"];
                    }
                    return out;
                }

                NSMutableDictionary *payload =
                    [NSMutableDictionary dictionaryWithDictionary:@{
                        @"ok" : @YES,
                        @"worldId" : targetId,
                        @"restoredFromStagedId" : stagedId,
                    }];
                if (snapshotId.length) {
                    payload[@"restoredFromSnapshotId"] = snapshotId;
                }
                out = MCFIXJSONResponse([payload copy], 200);
            } @finally {
                MCFIXBypassHooksSet(NO);
            }
            return out;
        }];

        [server addHandlerForMethod:@"POST"
                               path:@"/backup"
                       requestClass:[GCDWebServerDataRequest class]
                       processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
            MCFIXBypassHooksSet(YES);
            GCDWebServerResponse *out = nil;
            @try {
                GCDWebServerDataRequest *dr = (GCDWebServerDataRequest *)request;
                NSString *worldId = request.query[@"worldId"];
                NSString *label = request.query[@"label"];
                NSString *proposedSnapshotId = request.query[@"snapshotId"];

                NSData *body = dr.data;
                if (body.length) {
                    id json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
                    if ([json isKindOfClass:[NSDictionary class]]) {
                        NSDictionary *d = (NSDictionary *)json;
                        id w = d[@"worldId"];
                        id lab = d[@"label"];
                        id sid = d[@"snapshotId"];
                        if ([w isKindOfClass:[NSString class]] && [(NSString *)w length]) {
                            worldId = w;
                        } else if ([w isKindOfClass:[NSNumber class]]) {
                            worldId = [(NSNumber *)w stringValue];
                        }
                        if ([lab isKindOfClass:[NSString class]]) {
                            label = lab;
                        }
                        if ([sid isKindOfClass:[NSString class]] && [(NSString *)sid length]) {
                            proposedSnapshotId = sid;
                        } else if ([sid isKindOfClass:[NSNumber class]]) {
                            proposedSnapshotId = [(NSNumber *)sid stringValue];
                        }
                    }
                }

                worldId = MCFIXSanitizedWorldId(worldId) ?: @"";
                proposedSnapshotId = proposedSnapshotId.length ? (MCFIXSanitizedWorldId(proposedSnapshotId) ?: @"") : @"";

                if (!MCFIXWorldBackupKeySafeHTTP(worldId)) {
                    out = [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_BadRequest
                                                                     message:@"worldId required or invalid"];
                    return out;
                }

                NSString *liveParent = MCFIXWebServerMinecraftWorldsParentForWorldId(worldId, worldsRoots);
                NSError *berr = nil;
                NSString *createdId =
                    MCFIXCreateWorldBackupSnapshot(liveParent, worldId, label, proposedSnapshotId, &berr);
                if (createdId.length == 0) {
                    out = [GCDWebServerErrorResponse responseWithServerError:kGCDWebServerHTTPStatusCode_InternalServerError
                                                                     message:@"%@",
                                                  berr.localizedDescription ?: @"backup failed"];
                    return out;
                }

                out = MCFIXJSONResponse(
                    @{@"ok" : @YES, @"worldId" : worldId, @"snapshotId" : createdId, @"label" : label ?: @""}, 200);
            } @finally {
                MCFIXBypassHooksSet(NO);
            }
            return out;
        }];

        [server addHandlerForMethod:@"GET"
                          pathRegex:@"^/export/([^/]+)\\.mcworld$"
                       requestClass:[GCDWebServerRequest class]
                       processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
            MCFIXBypassHooksSet(YES);
            GCDWebServerResponse *out = nil;
            @try {
                NSArray *caps = [request attributeForKey:GCDWebServerRequestAttribute_RegexCaptures];
                if (caps.count < 1) {
                    out = [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_NotFound message:@"not found"];
                    return out;
                }
                NSString *wid = MCFIXSanitizedWorldId(caps[0]) ?: @"";
                if (!MCFIXWorldBackupKeySafeHTTP(wid)) {
                    out = [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_BadRequest
                                                                     message:@"invalid world id"];
                    return out;
                }
                NSString *liveParent = MCFIXWebServerMinecraftWorldsParentForWorldId(wid, worldsRoots);
                NSString *src = [[liveParent stringByAppendingPathComponent:wid] stringByStandardizingPath];
                if ([src hasPrefix:[liveParent stringByStandardizingPath]] == NO || ![fm fileExistsAtPath:src]) {
                    out = [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_NotFound message:@"world not found"];
                    return out;
                }
                NSString *zipPath = [NSTemporaryDirectory()
                    stringByAppendingPathComponent:[NSString stringWithFormat:@"mcfix_export_%@.mcworld", [[NSUUID UUID] UUIDString]]];
                NSError *zerr = nil;
                if (!MCFIXZipDirectoryToFile(src, zipPath, &zerr)) {
                    out = [GCDWebServerErrorResponse responseWithServerError:kGCDWebServerHTTPStatusCode_InternalServerError
                                                                     message:@"%@", zerr.localizedDescription ?: @"zip failed"];
                    return out;
                }
                GCDWebServerFileResponse *fr = [GCDWebServerFileResponse responseWithFile:zipPath isAttachment:YES];
                fr.contentType = @"application/zip";
                NSString *keep = zipPath;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_SEC)),
                               dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                                   (void)[fm removeItemAtPath:keep error:nil];
                               });
                out = fr;
            } @finally {
                MCFIXBypassHooksSet(NO);
            }
            return out;
        }];

        [server addHandlerForMethod:@"GET"
                          pathRegex:@"^/export/([^/]+)/([^/]+)\\.mcworld$"
                       requestClass:[GCDWebServerRequest class]
                       processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
            MCFIXBypassHooksSet(YES);
            GCDWebServerResponse *out = nil;
            @try {
                NSArray *caps = [request attributeForKey:GCDWebServerRequestAttribute_RegexCaptures];
                if (caps.count < 2) {
                    out = [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_NotFound message:@"not found"];
                    return out;
                }
                NSString *wid = MCFIXSanitizedWorldId(caps[0]) ?: @"";
                NSString *snap = MCFIXSanitizedWorldId(caps[1]) ?: @"";
                if (!MCFIXWorldBackupKeySafeHTTP(wid) || snap.length == 0) {
                    out = [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_BadRequest
                                                                     message:@"invalid id"];
                    return out;
                }
                NSString *snapDir = MCFIXBackupSnapshotPath(wid, snap);
                if (snapDir.length == 0 || ![fm fileExistsAtPath:snapDir]) {
                    out = [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_NotFound
                                                                     message:@"snapshot not found"];
                    return out;
                }
                NSString *zipPath = [NSTemporaryDirectory()
                    stringByAppendingPathComponent:[NSString stringWithFormat:@"mcfix_export_%@_%@.mcworld", wid, [[NSUUID UUID] UUIDString]]];
                NSError *zerr = nil;
                if (!MCFIXZipDirectoryToFile(snapDir, zipPath, &zerr)) {
                    out = [GCDWebServerErrorResponse responseWithServerError:kGCDWebServerHTTPStatusCode_InternalServerError
                                                                     message:@"%@", zerr.localizedDescription ?: @"zip failed"];
                    return out;
                }
                GCDWebServerFileResponse *fr = [GCDWebServerFileResponse responseWithFile:zipPath isAttachment:YES];
                fr.contentType = @"application/zip";
                NSString *keep = zipPath;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_SEC)),
                               dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                                   (void)[fm removeItemAtPath:keep error:nil];
                               });
                out = fr;
            } @finally {
                MCFIXBypassHooksSet(NO);
            }
            return out;
        }];

        [server addHandlerForMethod:@"GET"
                               path:@"/api/download"
                       requestClass:[GCDWebServerRequest class]
                       processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
            MCFIXBypassHooksSet(YES);
            GCDWebServerResponse *out = nil;
            @try {
                NSString *p = request.query[@"p"] ?: @"";
                NSError *err = nil;
                NSString *abs = MCFIXBrowseResolveRel(p, &err);
                if (!abs) {
                    out = MCFIXAPIErrorJSON(err.localizedDescription, 400);
                    return out;
                }
                BOOL isDir = NO;
                if (![fm fileExistsAtPath:abs isDirectory:&isDir]) {
                    out = MCFIXAPIErrorJSON(@"not found", 404);
                    return out;
                }
                if (isDir) {
                    out = MCFIXAPIErrorJSON(@"not a file", 400);
                    return out;
                }
                out = [GCDWebServerFileResponse responseWithFile:abs isAttachment:YES];
            } @finally {
                MCFIXBypassHooksSet(NO);
            }
            return out;
        }];

        [server addHandlerForMethod:@"GET"
                               path:@"/api/ls"
                       requestClass:[GCDWebServerRequest class]
                       processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
            MCFIXBypassHooksSet(YES);
            GCDWebServerResponse *out = nil;
            @try {
                NSString *p = request.query[@"p"] ?: @"";
                NSError *err = nil;
                NSString *abs = MCFIXBrowseResolveRel(p, &err);
                if (!abs) {
                    out = MCFIXAPIErrorJSON(err.localizedDescription, 400);
                    return out;
                }
                BOOL isDir = NO;
                if (![fm fileExistsAtPath:abs isDirectory:&isDir]) {
                    out = MCFIXAPIErrorJSON(@"not found", 404);
                    return out;
                }
                if (!isDir) {
                    out = MCFIXAPIErrorJSON(@"not a directory", 400);
                    return out;
                }
                NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:abs error:&err];
                if (!names) {
                    out = MCFIXAPIErrorJSON(err.localizedDescription ?: @"list failed", 500);
                    return out;
                }
                NSArray<NSString *> *sorted =
                    [names sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
                NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
                for (NSString *name in sorted) {
                    if ([name isEqualToString:@"."] || [name isEqualToString:@".."]) {
                        continue;
                    }
                    NSString *child = [abs stringByAppendingPathComponent:name];
                    BOOL childDir = NO;
                    if (![fm fileExistsAtPath:child isDirectory:&childDir]) {
                        continue;
                    }
                    NSDictionary<NSFileAttributeKey, id> *attr = [fm attributesOfItemAtPath:child error:nil];
                    NSNumber *sz = childDir ? nil : attr[NSFileSize];
                    NSMutableDictionary *row = [@{@"name" : name, @"type" : childDir ? @"dir" : @"file"} mutableCopy];
                    if (sz) {
                        row[@"size"] = sz;
                    }
                    [entries addObject:row];
                }
                NSString *vfs = MCFIXBrowseVFSSandboxStd();
                NSString *relOut = @"";
                if (![abs isEqualToString:vfs]) {
                    NSString *prefix = [vfs hasSuffix:@"/"] ? vfs : [vfs stringByAppendingString:@"/"];
                    if ([abs hasPrefix:prefix]) {
                        relOut = [abs substringFromIndex:prefix.length];
                    }
                }
                out = MCFIXJSONResponse(
                    @{@"ok" : @YES, @"rel" : relOut, @"rootAbs" : vfs, @"entries" : [entries copy]}, 200);
            } @finally {
                MCFIXBypassHooksSet(NO);
            }
            return out;
        }];

        [server startWithPort:8080 bonjourName:nil];
        [MCFIXFTPServer start];
        MCFIXLogOnce(MCFIXLogCatBoot, @"http_server",
                     @"GCDWebServer :8080 | FTP :2121 | worldsRoots=%@ staging=%@",
                     worldsRoots, stagingRoot);
    });
}

@end
