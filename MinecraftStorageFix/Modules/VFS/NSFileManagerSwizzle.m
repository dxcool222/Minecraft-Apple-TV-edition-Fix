// NSFileManager + NSData swizzles routed through MCFIXPathByRedirecting.
//
// The category names below (mcfix_games_* / mcfix_worldIcon_*) are paired
// with stock selectors by method_exchangeImplementations in
// +[MinecraftStorageFix patchNSFileManagerLibraryGamesPathRedirect] /
// patchNSFileManagerWorldIconUITrace. After exchange, the *original* IMP
// lives on the mcfix_* selector, so each implementation calls into its own
// twin to reach the unhooked Foundation behavior.

#import <Foundation/Foundation.h>
#import "PathRedirect.h"
#import "../Icons/WorldIcon.h"
#import "MCFIXLog.h"

@implementation NSFileManager (MinecraftStorageFix_LibraryGames)

- (BOOL)mcfix_games_createDirectoryAtPath:(NSString *)path
              withIntermediateDirectories:(BOOL)createIntermediates
                               attributes:(NSDictionary *)attributes
                                    error:(NSError **)error {
    NSString *n = MCFIXPathByRedirectingGameStorage(path);
    return [self mcfix_games_createDirectoryAtPath:n
                       withIntermediateDirectories:createIntermediates
                                        attributes:attributes
                                             error:error];
}

- (BOOL)mcfix_games_createDirectoryAtURL:(NSURL *)url
              withIntermediateDirectories:(BOOL)createIntermediates
                               attributes:(NSDictionary *)attributes
                                    error:(NSError **)error {
    if (![url isFileURL]) {
        return [self mcfix_games_createDirectoryAtURL:url
                        withIntermediateDirectories:createIntermediates
                                         attributes:attributes
                                              error:error];
    }
    return [self mcfix_games_createDirectoryAtURL:MCFIXFileURLByRedirectingGameStorage(url)
                        withIntermediateDirectories:createIntermediates
                                         attributes:attributes
                                              error:error];
}

- (BOOL)mcfix_games_fileExistsAtPath:(NSString *)path {
    NSString *n = MCFIXPathByRedirectingGameStorage(path);
    if ([path rangeOfString:@"world_icon"].location != NSNotFound) {
        BOOL ok = [self mcfix_games_fileExistsAtPath:n];
        off_t bytes = -1;
        if (ok && gMCFIXWorldIconUITraceN <= 32) {
            bytes = MCFIXWorldIconFileBytes(n);
        }
        const char *rawC = path.fileSystemRepresentation;
        const char *resC = n.fileSystemRepresentation;
        MCFIXWorldIconTraceUI("nsfm", "probe", "fileExistsAtPath",
                              rawC ?: path.UTF8String, resC ?: n.UTF8String,
                              ok ? 0 : -1, bytes, -1);
        NSString *wid = MCFIXWorldIdFromWorldIconPath(path) ?: MCFIXWorldIdFromWorldIconPath(n);
        if (wid.length) {
            MCFIXWorldIconDualPathSnapshot(ok ? "LIST_PROBE" : "LIST_PROBE_MISS", wid, path);
        }
        return ok;
    }
    return [self mcfix_games_fileExistsAtPath:n];
}

- (NSData *)mcfix_worldIcon_contentsAtPath:(NSString *)path {
    if ([path rangeOfString:@"world_icon"].location == NSNotFound) {
        return [self mcfix_worldIcon_contentsAtPath:path];
    }
    NSString *red = MCFIXPathByRedirectingGameStorage(path);
    NSData *data = [self mcfix_worldIcon_contentsAtPath:red];
    off_t sz = data.length ? (off_t)data.length : -1;
    int jpeg = (data.length >= 3) ? (MCFIXWorldIconMagicLooksJPEG(data.bytes, data.length) ? 1 : 0) : -1;
    const char *rawC = path.fileSystemRepresentation;
    const char *resC = red.fileSystemRepresentation;
    MCFIXWorldIconTraceUI("nsfm", data ? "read" : "read_miss", "contentsAtPath",
                          rawC ?: path.UTF8String, resC ?: red.UTF8String,
                          data ? 0 : -1, sz, jpeg);
    return data;
}

- (NSData *)mcfix_worldIcon_dataWithContentsOfFile:(NSString *)path
                                           options:(NSDataReadingOptions)opts
                                             error:(NSError **)err {
    if ([path rangeOfString:@"world_icon"].location == NSNotFound) {
        return [self mcfix_worldIcon_dataWithContentsOfFile:path options:opts error:err];
    }
    NSString *red = MCFIXPathByRedirectingGameStorage(path);
    NSData *data = [self mcfix_worldIcon_dataWithContentsOfFile:red options:opts error:err];
    off_t sz = data.length ? (off_t)data.length : -1;
    int jpeg = (data.length >= 3) ? (MCFIXWorldIconMagicLooksJPEG(data.bytes, data.length) ? 1 : 0) : -1;
    const char *rawC = path.fileSystemRepresentation;
    const char *resC = red.fileSystemRepresentation;
    MCFIXWorldIconTraceUI("nsfm", data ? "read" : "read_miss", "dataWithContentsOfFile",
                          rawC ?: path.UTF8String, resC ?: red.UTF8String,
                          data ? 0 : -1, sz, jpeg);
    return data;
}

- (BOOL)mcfix_games_fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDir {
    return [self mcfix_games_fileExistsAtPath:MCFIXPathByRedirectingGameStorage(path) isDirectory:isDir];
}

- (BOOL)mcfix_games_copyItemAtPath:(NSString *)s toPath:(NSString *)d error:(NSError **)e {
    return [self mcfix_games_copyItemAtPath:MCFIXPathByRedirectingGameStorage(s) toPath:MCFIXPathByRedirectingGameStorage(d) error:e];
}

- (BOOL)mcfix_games_moveItemAtPath:(NSString *)s toPath:(NSString *)d error:(NSError **)e {
    return [self mcfix_games_moveItemAtPath:MCFIXPathByRedirectingGameStorage(s) toPath:MCFIXPathByRedirectingGameStorage(d) error:e];
}

- (BOOL)mcfix_games_removeItemAtPath:(NSString *)path error:(NSError **)e {
    return [self mcfix_games_removeItemAtPath:MCFIXPathByRedirectingGameStorage(path) error:e];
}

- (NSArray *)mcfix_games_contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)e {
    return [self mcfix_games_contentsOfDirectoryAtPath:MCFIXPathByRedirectingGameStorage(path) error:e];
}

- (NSArray *)mcfix_games_subpathsOfDirectoryAtPath:(NSString *)path error:(NSError **)e {
    return [self mcfix_games_subpathsOfDirectoryAtPath:MCFIXPathByRedirectingGameStorage(path) error:e];
}

- (NSDictionary *)mcfix_games_attributesOfItemAtPath:(NSString *)path error:(NSError **)e {
    return [self mcfix_games_attributesOfItemAtPath:MCFIXPathByRedirectingGameStorage(path) error:e];
}

- (BOOL)mcfix_games_createFileAtPath:(NSString *)path contents:(NSData *)data attributes:(NSDictionary *)attr {
    return [self mcfix_games_createFileAtPath:MCFIXPathByRedirectingGameStorage(path) contents:data attributes:attr];
}

- (NSEnumerator *)mcfix_games_enumeratorAtPath:(NSString *)path {
    return [self mcfix_games_enumeratorAtPath:MCFIXPathByRedirectingGameStorage(path)];
}

- (BOOL)mcfix_games_isReadableFileAtPath:(NSString *)path {
    return [self mcfix_games_isReadableFileAtPath:MCFIXPathByRedirectingGameStorage(path)];
}

- (BOOL)mcfix_games_isWritableFileAtPath:(NSString *)path {
    return [self mcfix_games_isWritableFileAtPath:MCFIXPathByRedirectingGameStorage(path)];
}

- (BOOL)mcfix_games_copyItemAtURL:(NSURL *)s toURL:(NSURL *)d error:(NSError **)e {
    NSURL *s2 = [s isFileURL] ? MCFIXFileURLByRedirectingGameStorage(s) : s;
    NSURL *d2 = [d isFileURL] ? MCFIXFileURLByRedirectingGameStorage(d) : d;
    return [self mcfix_games_copyItemAtURL:s2 toURL:d2 error:e];
}

- (BOOL)mcfix_games_moveItemAtURL:(NSURL *)s toURL:(NSURL *)d error:(NSError **)e {
    NSURL *s2 = [s isFileURL] ? MCFIXFileURLByRedirectingGameStorage(s) : s;
    NSURL *d2 = [d isFileURL] ? MCFIXFileURLByRedirectingGameStorage(d) : d;
    return [self mcfix_games_moveItemAtURL:s2 toURL:d2 error:e];
}

- (BOOL)mcfix_games_removeItemAtURL:(NSURL *)u error:(NSError **)e {
    if (![u isFileURL]) {
        return [self mcfix_games_removeItemAtURL:u error:e];
    }
    return [self mcfix_games_removeItemAtURL:MCFIXFileURLByRedirectingGameStorage(u) error:e];
}

- (NSArray *)mcfix_games_contentsOfDirectoryAtURL:(NSURL *)url
                       includingPropertiesForKeys:(NSArray *)keys
                                         options:(NSDirectoryEnumerationOptions)mask
                                           error:(NSError **)e {
    NSURL *u2 = ([url isFileURL]) ? MCFIXFileURLByRedirectingGameStorage(url) : url;
    return [self mcfix_games_contentsOfDirectoryAtURL:u2
                           includingPropertiesForKeys:keys
                                             options:mask
                                               error:e];
}

- (NSDirectoryEnumerator *)mcfix_games_enumeratorAtURL:(NSURL *)url
                            includingPropertiesForKeys:(NSArray *)keys
                                              options:(NSDirectoryEnumerationOptions)mask
                                         errorHandler:(BOOL (^)(NSURL *, NSError *))handler {
    NSURL *u2 = ([url isFileURL]) ? MCFIXFileURLByRedirectingGameStorage(url) : url;
    return [self mcfix_games_enumeratorAtURL:u2
                  includingPropertiesForKeys:keys
                                    options:mask
                                errorHandler:handler];
}

@end
