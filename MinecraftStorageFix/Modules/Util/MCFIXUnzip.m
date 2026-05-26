#import "MCFIXUnzip.h"

#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>
#include "unzip.h"
#include "zip.h"

static BOOL MCFIXZipEntryPathLooksSafe(NSString *relative) {
    if (relative.length == 0) {
        return NO;
    }
    if ([relative hasPrefix:@"/"] || [relative hasPrefix:@"\\"]) {
        return NO;
    }
    NSArray<NSString *> *parts = [relative pathComponents];
    for (NSString *p in parts) {
        if ([p isEqualToString:@".."]) {
            return NO;
        }
    }
    return YES;
}

static BOOL MCFIXZipAppendOneFile(zipFile zf, NSString *zipEntryName, NSString *filePath, NSError **outError) {
    FILE *f = fopen(filePath.fileSystemRepresentation, "rb");
    if (f == NULL) {
        if (outError) {
            *outError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        }
        return NO;
    }
    if (fseeko(f, 0, SEEK_END) != 0) {
        fclose(f);
        if (outError) {
            *outError = [NSError errorWithDomain:@"MCFIXUnzip" code:20 userInfo:nil];
        }
        return NO;
    }
    off_t sz = ftello(f);
    if (sz < 0) {
        fclose(f);
        if (outError) {
            *outError = [NSError errorWithDomain:@"MCFIXUnzip" code:21 userInfo:nil];
        }
        return NO;
    }
    if (fseeko(f, 0, SEEK_SET) != 0) {
        fclose(f);
        if (outError) {
            *outError = [NSError errorWithDomain:@"MCFIXUnzip" code:22 userInfo:nil];
        }
        return NO;
    }

    zip_fileinfo zi;
    memset(&zi, 0, sizeof(zi));
    int zip64 = (sz >= (off_t)0xffffffff) ? 1 : 0;
    const char *entry = zipEntryName.UTF8String;
    if (zipOpenNewFileInZip64(zf, entry, &zi, NULL, 0, NULL, 0, NULL, Z_DEFLATED, Z_DEFAULT_COMPRESSION, zip64) != ZIP_OK) {
        fclose(f);
        if (outError) {
            *outError = [NSError errorWithDomain:@"MCFIXUnzip" code:23
                                       userInfo:@{NSLocalizedDescriptionKey : @"zipOpenNewFile failed"}];
        }
        return NO;
    }

    char buf[65536];
    BOOL fail = NO;
    while (1) {
        size_t n = fread(buf, 1, sizeof(buf), f);
        if (n == 0) {
            break;
        }
        if (zipWriteInFileInZip(zf, buf, (unsigned int)n) < 0) {
            fail = YES;
            break;
        }
    }
    fclose(f);
    if (zipCloseFileInZip(zf) != ZIP_OK) {
        fail = YES;
    }
    if (fail) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"MCFIXUnzip" code:24
                                       userInfo:@{NSLocalizedDescriptionKey : @"zip write failed"}];
        }
        return NO;
    }
    return YES;
}

static BOOL MCFIXZipAddPath(zipFile zf, NSString *rootDir, NSString *fullPath, NSError **outError) {
    if (fullPath.length == 0 || rootDir.length == 0) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"MCFIXUnzip" code:25 userInfo:nil];
        }
        return NO;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:fullPath isDirectory:&isDir]) {
        if (outError) {
            *outError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
        }
        return NO;
    }

    if (isDir) {
        NSArray *children = [fm contentsOfDirectoryAtPath:fullPath error:outError];
        if (!children) {
            return NO;
        }
        for (NSString *name in children) {
            if ([name isEqualToString:@"."] || [name isEqualToString:@".."]) {
                continue;
            }
            NSString *next = [fullPath stringByAppendingPathComponent:name];
            if (!MCFIXZipAddPath(zf, rootDir, next, outError)) {
                return NO;
            }
        }
        return YES;
    }

    if (![fullPath hasPrefix:rootDir]) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"MCFIXUnzip" code:26 userInfo:nil];
        }
        return NO;
    }
    NSString *rel = [fullPath substringFromIndex:rootDir.length];
    if ([rel hasPrefix:@"/"]) {
        rel = [rel substringFromIndex:1];
    }
    if (!MCFIXZipEntryPathLooksSafe(rel)) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"MCFIXUnzip" code:27
                                       userInfo:@{NSLocalizedDescriptionKey : @"unsafe zip path"}];
        }
        return NO;
    }
    NSString *zipName = [rel stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    return MCFIXZipAppendOneFile(zf, zipName, fullPath, outError);
}

BOOL MCFIXDataLooksLikeZip(NSData *data) {
    if (data.length < 4) {
        return NO;
    }
    const unsigned char *b = (const unsigned char *)data.bytes;
    return (b[0] == 0x50 && b[1] == 0x4B && (b[2] == 0x03 || b[2] == 0x05 || b[2] == 0x07) &&
            (b[3] == 0x04 || b[3] == 0x06 || b[3] == 0x08));
}

BOOL MCFIXFileLooksLikeZipAtPath(NSString *path) {
    if (path.length == 0) {
        return NO;
    }
    NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!h) {
        return NO;
    }
    BOOL ok = NO;
    @try {
        NSData *head = [h readDataOfLength:4];
        ok = MCFIXDataLooksLikeZip(head);
    } @finally {
        [h closeFile];
    }
    return ok;
}

BOOL MCFIXUnzipFileAtPath(NSString *zipPath, NSString *destinationDirectory, NSError **outError) {
    if (zipPath.length == 0 || destinationDirectory.length == 0) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"MCFIXUnzip" code:1 userInfo:nil];
        }
        return NO;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm createDirectoryAtPath:destinationDirectory withIntermediateDirectories:YES attributes:nil error:outError]) {
        return NO;
    }

    unzFile uf = unzOpen64(zipPath.fileSystemRepresentation);
    if (uf == NULL) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"MCFIXUnzip" code:2
                                        userInfo:@{NSLocalizedDescriptionKey : @"unzOpen failed"}];
        }
        return NO;
    }

    BOOL ok = YES;
    int err = unzGoToFirstFile(uf);
    char nameBuf[2048];

    while (err == UNZ_OK) {
        unz_file_info64 info;
        memset(&info, 0, sizeof(info));
        if (unzGetCurrentFileInfo64(uf, &info, nameBuf, (uLong)sizeof(nameBuf), NULL, 0, NULL, 0) != UNZ_OK) {
            ok = NO;
            break;
        }

        NSString *rel = [[NSString stringWithUTF8String:nameBuf] stringByReplacingOccurrencesOfString:@"\\"
                                                                                           withString:@"/"];
        if (!MCFIXZipEntryPathLooksSafe(rel)) {
            ok = NO;
            if (outError) {
                *outError = [NSError errorWithDomain:@"MCFIXUnzip" code:3
                                            userInfo:@{NSLocalizedDescriptionKey : @"unsafe zip path"}];
            }
            break;
        }

        BOOL isDir = (rel.length > 0 && [rel hasSuffix:@"/"]);

        NSString *outPath = [destinationDirectory stringByAppendingPathComponent:rel];
        if (isDir) {
            if (![fm createDirectoryAtPath:outPath withIntermediateDirectories:YES attributes:nil error:outError]) {
                ok = NO;
                break;
            }
        } else {
            NSString *parent = [outPath stringByDeletingLastPathComponent];
            if (![fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:outError]) {
                ok = NO;
                break;
            }

            if (unzOpenCurrentFile(uf) != UNZ_OK) {
                ok = NO;
                if (outError) {
                    *outError = [NSError errorWithDomain:@"MCFIXUnzip" code:4 userInfo:nil];
                }
                break;
            }

            NSMutableData *buffer = [NSMutableData dataWithLength:65536];
            void *bp = buffer.mutableBytes;
            FILE *out = fopen(outPath.fileSystemRepresentation, "wb");
            if (out == NULL) {
                (void)unzCloseCurrentFile(uf);
                ok = NO;
                if (outError) {
                    *outError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
                }
                break;
            }

            BOOL writeFail = NO;
            while (1) {
                int r = unzReadCurrentFile(uf, bp, (unsigned)buffer.length);
                if (r == 0) {
                    break;
                }
                if (r < 0) {
                    writeFail = YES;
                    break;
                }
                size_t w = fwrite(bp, 1, (size_t)r, out);
                if (w != (size_t)r) {
                    writeFail = YES;
                    break;
                }
            }
            fclose(out);
            (void)unzCloseCurrentFile(uf);
            if (writeFail) {
                ok = NO;
                (void)[fm removeItemAtPath:outPath error:nil];
                if (outError) {
                    *outError = [NSError errorWithDomain:@"MCFIXUnzip" code:5 userInfo:nil];
                }
                break;
            }
        }

        err = unzGoToNextFile(uf);
    }

    if (ok && err != UNZ_END_OF_LIST_OF_FILE && err != UNZ_OK) {
        ok = NO;
     if (outError && *outError == nil) {
            *outError = [NSError errorWithDomain:@"MCFIXUnzip" code:6 userInfo:nil];
        }
    }

    unzClose(uf);
    return ok;
}

BOOL MCFIXZipDirectoryToFile(NSString *sourceDirectory, NSString *zipPath, NSError **outError) {
    if (sourceDirectory.length == 0 || zipPath.length == 0) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"MCFIXUnzip" code:28 userInfo:nil];
        }
        return NO;
    }

    NSString *root = [sourceDirectory stringByStandardizingPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:root isDirectory:&isDir] || !isDir) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"MCFIXUnzip" code:29
                                       userInfo:@{NSLocalizedDescriptionKey : @"source not a directory"}];
        }
        return NO;
    }

    (void)[fm removeItemAtPath:zipPath error:nil];

    zipFile zf = zipOpen64(zipPath.fileSystemRepresentation, APPEND_STATUS_CREATE);
    if (zf == NULL) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"MCFIXUnzip" code:30
                                       userInfo:@{NSLocalizedDescriptionKey : @"zipOpen failed"}];
        }
        return NO;
    }

    BOOL ok = MCFIXZipAddPath(zf, root, root, outError);
    if (zipClose(zf, NULL) != ZIP_OK) {
        ok = NO;
        if (outError && *outError == nil) {
            *outError = [NSError errorWithDomain:@"MCFIXUnzip" code:31 userInfo:nil];
        }
    }
    if (!ok) {
        (void)[fm removeItemAtPath:zipPath error:nil];
    }
    return ok;
}
