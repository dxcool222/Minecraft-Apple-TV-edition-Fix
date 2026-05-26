#import <Foundation/Foundation.h>

/// Plain FTP (RFC 959 subset) on port **2121**, rooted at `MCFIXGameDataVFSSandboxRoot()`.
/// For **FileZilla**: Host = Apple TV IP, Port = 2121, Protocol = FTP, Encryption = "Only use plain FTP".
@interface MCFIXFTPServer : NSObject
+ (void)start;
@end
