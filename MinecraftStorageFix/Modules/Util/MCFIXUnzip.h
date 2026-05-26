#import <Foundation/Foundation.h>

/// Extracts a PKZIP archive to `destinationDirectory` (created if needed).
/// Rejects paths containing `..` or absolute entries. Uses minizip.
FOUNDATION_EXPORT BOOL MCFIXUnzipFileAtPath(NSString *zipPath, NSString *destinationDirectory, NSError **outError);

/// Returns YES if data begins with a local-file ZIP header.
FOUNDATION_EXPORT BOOL MCFIXDataLooksLikeZip(NSData *data);

/// Reads the first bytes of `path` (PK\x03\x04 …) so `.mcworld` works when the part has no filename / octet-stream.
FOUNDATION_EXPORT BOOL MCFIXFileLooksLikeZipAtPath(NSString *path);

/// Recursively zips `sourceDirectory` into `zipPath` (overwrite). Suitable for `.mcworld` (PKZIP).
FOUNDATION_EXPORT BOOL MCFIXZipDirectoryToFile(NSString *sourceDirectory, NSString *zipPath, NSError **outError);
