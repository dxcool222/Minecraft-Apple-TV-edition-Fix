#import "MCFIXFTPServer.h"

#import "MCFIXBypass.h"
#import "MCFIXGameDataVFS.h"
#import "MCFIXLog.h"

#import <arpa/inet.h>
#import <errno.h>
#import <netinet/in.h>
#import <stdlib.h>
#import <sys/socket.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

// FTP control channel. Port 21 requires root; 2121 is the conventional unprivileged alternative.
static const uint16_t kMCFIXFTPControlPort = 2121;
static const uint16_t kMCFIXFTPPassivePortMin = 12000;
static const uint16_t kMCFIXFTPPassivePortMax = 12999;

static void MCFIXFTPTuneSocket(int fd) {
    if (fd < 0) {
        return;
    }
    int nosigpipe = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe));
    int bufSize = 256 * 1024;
    (void)setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufSize, sizeof(bufSize));
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufSize, sizeof(bufSize));
}

static void MCFIXFTPApplyDataTimeouts(int fd) {
    if (fd < 0) {
        return;
    }
    struct timeval tv = {.tv_sec = 60, .tv_usec = 0};
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    (void)setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

static ssize_t MCFIXFTPSendRetry(int fd, const void *buf, size_t len) {
    ssize_t n;
    do {
        n = send(fd, buf, len, 0);
    } while (n < 0 && errno == EINTR);
    return n;
}

static ssize_t MCFIXFTPRecvRetry(int fd, void *buf, size_t len) {
    ssize_t n;
    do {
        n = recv(fd, buf, len, 0);
    } while (n < 0 && errno == EINTR);
    return n;
}

static BOOL MCFIXFTPSendAll(int fd, const void *bytes, size_t len) {
    if (fd < 0 || bytes == NULL) {
        return NO;
    }
    size_t off = 0;
    while (off < len) {
        ssize_t n = MCFIXFTPSendRetry(fd, (const char *)bytes + off, len - off);
        if (n <= 0) {
            return NO;
        }
        off += (size_t)n;
    }
    return YES;
}

#pragma mark - VFS path (same rules as HTTP browse)

static NSString *MCFIXFTPVFSRootStd(void) {
    return MCFIXGameDataVFSSandboxRootStd();
}

static BOOL MCFIXFTPIsUnderVFS(NSString *path, NSString *root) {
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

static NSString *_Nullable MCFIXFTPResolveRel(NSString *rel, NSError **error) {
    NSString *vfs = MCFIXFTPVFSRootStd();
    if (vfs.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCFIXFTP" code:1
                                    userInfo:@{NSLocalizedDescriptionKey : @"VFS root unavailable"}];
        }
        return nil;
    }
    NSString *s = rel.length ? rel : @"";
    s = [s stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    while ([s hasPrefix:@"/"]) {
        s = [s substringFromIndex:1];
    }
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    NSString *combined = s.length ? [vfs stringByAppendingPathComponent:s] : vfs;
    NSString *std = [combined stringByStandardizingPath];
    if (!MCFIXFTPIsUnderVFS(std, vfs)) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCFIXFTP" code:2
                                    userInfo:@{NSLocalizedDescriptionKey : @"path escapes VFS root"}];
        }
        return nil;
    }
    return std;
}

static NSString *_Nullable MCFIXFTPResolvePath(NSString *arg, NSString *cwdRel, NSError **error) {
    NSString *combined;
    if ([arg hasPrefix:@"/"]) {
        combined = [[arg substringFromIndex:1] stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    } else {
        combined = cwdRel.length ? [cwdRel stringByAppendingFormat:@"/%@", arg] : arg;
    }
    return MCFIXFTPResolveRel(combined, error);
}

static NSString *MCFIXFTPRelFromAbs(NSString *abs) {
    NSString *vfs = MCFIXFTPVFSRootStd();
    abs = [abs stringByStandardizingPath];
    if ([abs isEqualToString:vfs]) {
        return @"";
    }
    NSString *prefix = [vfs hasSuffix:@"/"] ? vfs : [vfs stringByAppendingString:@"/"];
    if (![abs hasPrefix:prefix]) {
        return @"";
    }
    return [abs substringFromIndex:prefix.length];
}

static NSString *MCFIXFTPPWDDisplay(NSString *cwdRel) {
    if (cwdRel.length == 0) {
        return @"/";
    }
    return [@"/" stringByAppendingString:cwdRel];
}

static BOOL MCFIXFTPSendStr(int fd, NSString *line) {
    if (fd < 0) {
        return NO;
    }
    NSString *full = line.length ? [line stringByAppendingString:@"\r\n"] : @"\r\n";
    const char *utf = [full UTF8String];
    return MCFIXFTPSendAll(fd, utf, strlen(utf));
}

// `acc` doubles as the per-connection read buffer so bytes past a newline
// survive to the next call.
static BOOL MCFIXFTPReadLine(int fd, NSMutableData *acc, NSString **outLine) {
    *outLine = nil;
    uint8_t chunk[512];
    for (;;) {
        const uint8_t *bytes = (const uint8_t *)acc.bytes;
        NSUInteger len = acc.length;
        for (NSUInteger i = 0; i < len; i++) {
            if (bytes[i] != '\n') {
                continue;
            }
            NSUInteger lineLen = i + 1;
            NSData *lineData = [NSData dataWithBytes:bytes length:lineLen];
            NSUInteger remaining = len - lineLen;
            if (remaining > 0) {
                uint8_t *mutableBytes = (uint8_t *)acc.mutableBytes;
                memmove(mutableBytes, mutableBytes + lineLen, remaining);
            }
            acc.length = remaining;
            NSString *s = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
            if (!s) {
                s = [[NSString alloc] initWithData:lineData encoding:NSISOLatin1StringEncoding];
            }
            if (!s) {
                return NO;
            }
            if ([s hasSuffix:@"\r\n"]) {
                s = [s substringToIndex:s.length - 2];
            } else if ([s hasSuffix:@"\n"]) {
                s = [s substringToIndex:s.length - 1];
            }
            *outLine = s;
            return YES;
        }
        ssize_t n = MCFIXFTPRecvRetry(fd, chunk, sizeof(chunk));
        if (n <= 0) {
            return NO;
        }
        [acc appendBytes:chunk length:(NSUInteger)n];
    }
}

static void MCFIXFTPParseCmd(NSString *line, NSString **cmd, NSString **arg) {
    NSString *trim = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSRange sp = [trim rangeOfString:@" "];
    if (sp.location == NSNotFound) {
        *cmd = [trim uppercaseString];
        *arg = @"";
    } else {
        *cmd = [[trim substringToIndex:sp.location] uppercaseString];
        *arg = [[trim substringFromIndex:sp.location + 1]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
}

static BOOL MCFIXFTPGetIPv4ForPassive(int ctrlFd, struct in_addr *outAddr) {
    struct sockaddr_storage ss;
    socklen_t slen = sizeof(ss);
    if (getsockname(ctrlFd, (struct sockaddr *)&ss, &slen) != 0) {
        return NO;
    }
    if (ss.ss_family == AF_INET) {
        struct sockaddr_in *sin = (struct sockaddr_in *)&ss;
        *outAddr = sin->sin_addr;
        return YES;
    }
    return NO;
}

static NSData *MCFIXFTPBuildLIST(NSFileManager *fm, NSString *dirAbs) {
    NSMutableData *data = [NSMutableData data];
    NSArray *names = [fm contentsOfDirectoryAtPath:dirAbs error:nil];
    if (!names) {
        return data;
    }
    NSArray *sorted = [names sortedArrayUsingSelector:@selector(localizedStandardCompare:)];

    static NSDateFormatter *fmtTime;
    static NSDateFormatter *fy;
    static dispatch_once_t sOnce = 0;
    dispatch_once(&sOnce, ^{
        NSLocale *locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        NSTimeZone *tz = [NSTimeZone localTimeZone];
        fmtTime = [[NSDateFormatter alloc] init];
        fmtTime.locale = locale;
        fmtTime.timeZone = tz;
        fmtTime.dateFormat = @"MMM dd HH:mm";
        fy = [[NSDateFormatter alloc] init];
        fy.locale = locale;
        fy.timeZone = tz;
        fy.dateFormat = @"MMM dd yyyy";
    });

    NSTimeInterval cutoff = -180 * 24 * 3600.0;

    for (NSString *name in sorted) {
        if ([name isEqualToString:@"."] || [name isEqualToString:@".."]) {
            continue;
        }
        NSString *full = [dirAbs stringByAppendingPathComponent:name];
        NSDictionary *attr = [fm attributesOfItemAtPath:full error:nil];
        if (!attr) {
            continue;
        }
        BOOL isDir = [attr[NSFileType] isEqualToString:NSFileTypeDirectory];
        NSDate *mod = attr[NSFileModificationDate];
        NSString *dateStr = @"Jan 01 2000";
        if (mod) {
            NSTimeInterval age = [mod timeIntervalSinceNow];
            if (age < cutoff) {
                dateStr = [fy stringFromDate:mod];
            } else {
                dateStr = [fmtTime stringFromDate:mod];
            }
        }
        unsigned long long sz = isDir ? 0 : [attr[NSFileSize] unsignedLongLongValue];
        NSString *perm = isDir ? @"drwxr-xr-x" : @"-rw-r--r--";
        NSString *line = [NSString stringWithFormat:@"%@ 1 0 0 %llu %@ %@\r\n", perm, sz, dateStr, name];
        [data appendData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    }
    return data;
}

static int MCFIXFTPOpenPassiveListener(struct in_addr bindAddr, uint16_t *outPort) {
    uint16_t range = kMCFIXFTPPassivePortMax - kMCFIXFTPPassivePortMin + 1;
    uint16_t startOffset = (uint16_t)arc4random_uniform(range);

    for (uint16_t i = 0; i < range; i++) {
        uint16_t p = kMCFIXFTPPassivePortMin + ((startOffset + i) % range);
        int s = socket(AF_INET, SOCK_STREAM, 0);
        if (s < 0) {
            continue;
        }
        MCFIXFTPTuneSocket(s);
        int yes = 1;
        (void)setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

        struct sockaddr_in addr = {};
        addr.sin_family = AF_INET;
        addr.sin_addr = bindAddr;
        addr.sin_port = htons(p);
        if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) == 0 && listen(s, 1) == 0) {
            *outPort = p;
            return s;
        }
        close(s);
    }
    return -1;
}

static int MCFIXFTPAcceptData(int listenFd) {
    struct sockaddr_in cli;
    socklen_t l = sizeof(cli);
    int d = accept(listenFd, (struct sockaddr *)&cli, &l);
    if (d >= 0) {
        MCFIXFTPTuneSocket(d);
        MCFIXFTPApplyDataTimeouts(d);
    }
    return d;
}

static int MCFIXFTPConnectActive(const char *host, uint16_t port) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) {
        return -1;
    }
    MCFIXFTPTuneSocket(s);
    struct sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
        close(s);
        return -1;
    }
    if (connect(s, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(s);
        return -1;
    }
    MCFIXFTPApplyDataTimeouts(s);
    return s;
}

static BOOL MCFIXFTPParsePORT(NSString *arg, char *hostOut, size_t hostCap, uint16_t *portOut) {
    NSArray *parts = [arg componentsSeparatedByString:@","];
    if (parts.count != 6) {
        return NO;
    }
    NSMutableString *h = [NSMutableString string];
    for (NSInteger i = 0; i < 4; i++) {
        if (i) {
            [h appendString:@"."];
        }
        [h appendString:[parts[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
    }
    NSInteger p1 = [parts[4] integerValue];
    NSInteger p2 = [parts[5] integerValue];
    if (p1 < 0 || p1 > 255 || p2 < 0 || p2 > 255) {
        return NO;
    }
    *portOut = (uint16_t)(p1 * 256 + p2);
    if (hostCap > 0) {
        strncpy(hostOut, [h UTF8String], hostCap - 1);
        hostOut[hostCap - 1] = 0;
    }
    return YES;
}

static void MCFIXFTPClientLoop(int ctrlFd) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableData *lineBuf = [NSMutableData data];

    __block NSString *cwdRel = @"";
    __block BOOL loggedIn = NO;
    __block int pasvListenFd = -1;
    __block int activeDataFd = -1;
    __block NSString *renameFromAbs = nil;

    void (^closePassive)(void) = ^{
        if (pasvListenFd >= 0) {
            close(pasvListenFd);
            pasvListenFd = -1;
        }
    };

    void (^closeActive)(void) = ^{
        if (activeDataFd >= 0) {
            close(activeDataFd);
            activeDataFd = -1;
        }
    };

    int (^openDataOut)(NSString **) = ^int(NSString **errMsg) {
        if (pasvListenFd >= 0) {
            int d = MCFIXFTPAcceptData(pasvListenFd);
            closePassive();
            if (d < 0) {
                if (errMsg) {
                    *errMsg = @"passive accept failed";
                }
                return -1;
            }
            return d;
        }
        if (activeDataFd >= 0) {
            int d = activeDataFd;
            activeDataFd = -1;
            return d;
        }
        if (errMsg) {
            *errMsg = @"no data connection";
        }
        return -1;
    };

    if (!MCFIXFTPSendStr(ctrlFd, @"220 mcfix FTP (VFS root = GameData sandbox)")) {
        return;
    }

    NSString *line;
    while (MCFIXFTPReadLine(ctrlFd, lineBuf, &line)) {
        NSString *cmd;
        NSString *arg;
        MCFIXFTPParseCmd(line, &cmd, &arg);

        if ([cmd isEqualToString:@"USER"]) {
            (void)MCFIXFTPSendStr(ctrlFd, @"331 password please (any)");
            continue;
        }
        if ([cmd isEqualToString:@"PASS"]) {
            (void)arg;
            loggedIn = YES;
            (void)MCFIXFTPSendStr(ctrlFd, @"230 logged in (local LAN only — no encryption)");
            continue;
        }
        if (!loggedIn) {
            (void)MCFIXFTPSendStr(ctrlFd, @"530 please login with USER then PASS");
            continue;
        }

        MCFIXBypassHooksSet(YES);
        @try {
            if ([cmd isEqualToString:@"QUIT"]) {
                (void)MCFIXFTPSendStr(ctrlFd, @"221 bye");
                break;
            }

            if ([cmd isEqualToString:@"NOOP"]) {
                (void)MCFIXFTPSendStr(ctrlFd, @"200 OK");
                continue;
            }

            if ([cmd isEqualToString:@"TYPE"]) {
                (void)[arg uppercaseString];
                (void)MCFIXFTPSendStr(ctrlFd, @"200 TYPE set");
                continue;
            }

            if ([cmd isEqualToString:@"STRU"] || [cmd isEqualToString:@"MODE"]) {
                (void)MCFIXFTPSendStr(ctrlFd, @"200 OK");
                continue;
            }

            if ([cmd isEqualToString:@"SYST"]) {
                (void)MCFIXFTPSendStr(ctrlFd, @"215 UNIX Type: L8");
                continue;
            }

            if ([cmd isEqualToString:@"FEAT"]) {
                (void)MCFIXFTPSendStr(ctrlFd, @"211-Features:\r\n UTF8\r\n EPSV\r\n PASV\r\n211 End");
                continue;
            }

            if ([cmd isEqualToString:@"OPTS"] && [[arg uppercaseString] hasPrefix:@"UTF8"]) {
                (void)MCFIXFTPSendStr(ctrlFd, @"200 UTF8 enabled");
                continue;
            }

            if ([cmd isEqualToString:@"PWD"]) {
                (void)MCFIXFTPSendStr(ctrlFd,
                    [NSString stringWithFormat:@"257 \"%@\"", MCFIXFTPPWDDisplay(cwdRel)]);
                continue;
            }

            if ([cmd isEqualToString:@"CWD"] || [cmd isEqualToString:@"XCWD"]) {
                NSError *err = nil;
                NSString *abs = MCFIXFTPResolvePath(arg, cwdRel, &err);
                if (!abs) {
                    (void)MCFIXFTPSendStr(ctrlFd, [NSString stringWithFormat:@"550 %@", err.localizedDescription]);
                    continue;
                }
                BOOL isDir = NO;
                if (![fm fileExistsAtPath:abs isDirectory:&isDir] || !isDir) {
                    MCFIXFTPSendStr(ctrlFd, @"550 not a directory");
                    continue;
                }
                cwdRel = MCFIXFTPRelFromAbs(abs);
                (void)MCFIXFTPSendStr(ctrlFd, @"250 CWD ok");
                continue;
            }

            if ([cmd isEqualToString:@"CDUP"] || [cmd isEqualToString:@"XCUP"]) {
                if (cwdRel.length == 0) {
                    (void)MCFIXFTPSendStr(ctrlFd, @"250 CDUP ok");
                    continue;
                }
                NSString *parent = [cwdRel stringByDeletingLastPathComponent];
                NSError *err = nil;
                NSString *abs = MCFIXFTPResolveRel(parent, &err);
                if (!abs) {
                    (void)MCFIXFTPSendStr(ctrlFd, @"550 failed");
                    continue;
                }
                cwdRel = MCFIXFTPRelFromAbs(abs);
                (void)MCFIXFTPSendStr(ctrlFd, @"250 CDUP ok");
                continue;
            }

            if ([cmd isEqualToString:@"PASV"]) {
                closePassive();
                closeActive();
                struct in_addr bindAddr;
                if (!MCFIXFTPGetIPv4ForPassive(ctrlFd, &bindAddr)) {
                    (void)MCFIXFTPSendStr(ctrlFd, @"425 PASV: cannot get local IPv4 (try EPSV)");
                    continue;
                }
                uint16_t port = 0;
                int lst = MCFIXFTPOpenPassiveListener(bindAddr, &port);
                if (lst < 0) {
                    (void)MCFIXFTPSendStr(ctrlFd, @"425 PASV: bind failed");
                    continue;
                }
                pasvListenFd = lst;
                uint32_t a = ntohl(bindAddr.s_addr);
                (void)MCFIXFTPSendStr(ctrlFd, [NSString stringWithFormat:@"227 Entering Passive Mode (%u,%u,%u,%u,%u,%u)",
                                                  (a >> 24) & 0xff, (a >> 16) & 0xff, (a >> 8) & 0xff, a & 0xff,
                                                  port / 256, port % 256]);
                continue;
            }

            if ([cmd isEqualToString:@"EPSV"]) {
                closePassive();
                closeActive();
                struct in_addr bindAddr;
                if (!MCFIXFTPGetIPv4ForPassive(ctrlFd, &bindAddr)) {
                    (void)MCFIXFTPSendStr(ctrlFd, @"522 EPSV: IPv4 only here");
                    continue;
                }
                uint16_t port = 0;
                int lst = MCFIXFTPOpenPassiveListener(bindAddr, &port);
                if (lst < 0) {
                    (void)MCFIXFTPSendStr(ctrlFd, @"425 EPSV: bind failed");
                    continue;
                }
                pasvListenFd = lst;
                (void)MCFIXFTPSendStr(ctrlFd, [NSString stringWithFormat:@"229 Entering Extended Passive Mode (|||%u|)", port]);
                continue;
            }

            if ([cmd isEqualToString:@"PORT"]) {
                closePassive();
                closeActive();
                char hbuf[64];
                uint16_t dport = 0;
                if (!MCFIXFTPParsePORT(arg, hbuf, sizeof(hbuf), &dport)) {
                    (void)MCFIXFTPSendStr(ctrlFd, @"501 bad PORT syntax");
                    continue;
                }
                int s = MCFIXFTPConnectActive(hbuf, dport);
                if (s < 0) {
                    (void)MCFIXFTPSendStr(ctrlFd, @"425 cannot connect data");
                    continue;
                }
                activeDataFd = s;
                (void)MCFIXFTPSendStr(ctrlFd, @"200 PORT ok");
                continue;
            }

            if ([cmd isEqualToString:@"LIST"] || [cmd isEqualToString:@"NLST"]) {
                NSError *err = nil;
                NSString *targetRel = cwdRel;
                if (arg.length && ![arg isEqualToString:@"-a"] && ![arg isEqualToString:@"-l"]) {
                    NSString *combined;
                    if ([arg hasPrefix:@"/"]) {
                        combined = [[arg substringFromIndex:1] stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
                    } else {
                        combined = cwdRel.length ? [cwdRel stringByAppendingFormat:@"/%@", arg] : arg;
                    }
                    targetRel = combined;
                }
                NSString *abs = MCFIXFTPResolveRel(targetRel, &err);
                if (!abs) {
                    (void)MCFIXFTPSendStr(ctrlFd, [NSString stringWithFormat:@"550 %@", err.localizedDescription]);
                    continue;
                }
                BOOL isDir = NO;
                if (![fm fileExistsAtPath:abs isDirectory:&isDir]) {
                    (void)MCFIXFTPSendStr(ctrlFd, @"550 not found");
                    continue;
                }
                NSString *xferPath = abs;
                if (!isDir) {
                    xferPath = [abs stringByDeletingLastPathComponent];
                }

                NSString *derr = nil;
                int d = openDataOut(&derr);
                if (d < 0) {
                    (void)MCFIXFTPSendStr(ctrlFd, [NSString stringWithFormat:@"425 %@", derr]);
                    continue;
                }
                (void)MCFIXFTPSendStr(ctrlFd, @"150 opening data connection");
                BOOL listOK = YES;
                if ([cmd isEqualToString:@"NLST"]) {
                    NSArray *names = [fm contentsOfDirectoryAtPath:xferPath error:nil];
                    NSMutableString *blob = [NSMutableString string];
                    for (NSString *n in [names sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
                        if ([n hasPrefix:@"."]) {
                            continue;
                        }
                        [blob appendFormat:@"%@\r\n", n];
                    }
                    NSData *raw = [blob dataUsingEncoding:NSUTF8StringEncoding];
                    listOK = MCFIXFTPSendAll(d, raw.bytes, raw.length);
                } else {
                    NSData *raw = MCFIXFTPBuildLIST(fm, xferPath);
                    listOK = MCFIXFTPSendAll(d, raw.bytes, raw.length);
                }
                close(d);
                if (listOK) {
                    (void)MCFIXFTPSendStr(ctrlFd, @"226 transfer complete");
                } else {
                    (void)MCFIXFTPSendStr(ctrlFd, @"426 connection closed; transfer aborted");
                }
                continue;
            }

            if ([cmd isEqualToString:@"RETR"]) {
                NSError *err = nil;
                NSString *abs = MCFIXFTPResolvePath(arg, cwdRel, &err);
                if (!abs) {
                    (void)MCFIXFTPSendStr(ctrlFd, [NSString stringWithFormat:@"550 %@", err.localizedDescription]);
                    continue;
                }
                BOOL isDir = NO;
                if (![fm fileExistsAtPath:abs isDirectory:&isDir] || isDir) {
                    (void)MCFIXFTPSendStr(ctrlFd, @"550 not a plain file");
                    continue;
                }
                NSString *derr = nil;
                int d = openDataOut(&derr);
                if (d < 0) {
                    (void)MCFIXFTPSendStr(ctrlFd, [NSString stringWithFormat:@"425 %@", derr]);
                    continue;
                }
                (void)MCFIXFTPSendStr(ctrlFd, @"150 sending file");
                NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:abs];
                if (!fh) {
                    close(d);
                    (void)MCFIXFTPSendStr(ctrlFd, @"450 cannot open file");
                    continue;
                }
                BOOL transferOK = YES;
                @try {
                    while (transferOK) {
                        @autoreleasepool {
                            NSData *chunk = [fh readDataOfLength:256 * 1024];
                            if (chunk.length == 0) {
                                break;
                            }
                            NSUInteger off = 0;
                            while (off < chunk.length) {
                                ssize_t n = MCFIXFTPSendRetry(d, (const char *)chunk.bytes + off, chunk.length - off);
                                if (n <= 0) {
                                    transferOK = NO;
                                    break;
                                }
                                off += (NSUInteger)n;
                            }
                        }
                    }
                } @finally {
                    [fh closeFile];
                    close(d);
                }
                if (transferOK) {
                    (void)MCFIXFTPSendStr(ctrlFd, @"226 transfer complete");
                } else {
                    (void)MCFIXFTPSendStr(ctrlFd, @"426 connection closed; transfer aborted");
                }
                continue;
            }

            if ([cmd isEqualToString:@"STOR"]) {
                NSError *err = nil;
                NSString *abs = MCFIXFTPResolvePath(arg, cwdRel, &err);
                if (!abs) {
                    (void)MCFIXFTPSendStr(ctrlFd, [NSString stringWithFormat:@"550 %@", err.localizedDescription]);
                    continue;
                }
                BOOL existDir = NO;
                if ([fm fileExistsAtPath:abs isDirectory:&existDir] && existDir) {
                    (void)MCFIXFTPSendStr(ctrlFd, @"550 path is a directory");
                    continue;
                }
                NSString *parent = [abs stringByDeletingLastPathComponent];
                if (![fm fileExistsAtPath:parent]) {
                    if (![fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:&err]) {
                        (void)MCFIXFTPSendStr(ctrlFd, @"550 cannot create parent folder");
                        continue;
                    }
                }
                NSString *derr = nil;
                int d = openDataOut(&derr);
                if (d < 0) {
                    (void)MCFIXFTPSendStr(ctrlFd, [NSString stringWithFormat:@"425 %@", derr]);
                    continue;
                }
                (void)MCFIXFTPSendStr(ctrlFd, @"150 receive file");
                if (![fm fileExistsAtPath:abs]) {
                    if (![fm createFileAtPath:abs contents:nil attributes:nil]) {
                        close(d);
                        (void)MCFIXFTPSendStr(ctrlFd, @"552 cannot create file");
                        continue;
                    }
                }
                NSFileHandle *outFh = [NSFileHandle fileHandleForWritingAtPath:abs];
                if (!outFh) {
                    close(d);
                    (void)MCFIXFTPSendStr(ctrlFd, @"450 cannot open for write");
                    continue;
                }
                [outFh truncateFileAtOffset:0];
                BOOL transferOK = YES;
                uint8_t *buf = (uint8_t *)malloc(256 * 1024);
                if (!buf) {
                    [outFh closeFile];
                    close(d);
                    (void)MCFIXFTPSendStr(ctrlFd, @"451 local resource failure");
                    continue;
                }
                @try {
                    ssize_t n = 0;
                    while (transferOK && (n = MCFIXFTPRecvRetry(d, buf, 256 * 1024)) > 0) {
                        @autoreleasepool {
                            @try {
                                [outFh writeData:[NSData dataWithBytes:buf length:(NSUInteger)n]];
                            } @catch (NSException *ex) {
                                (void)ex;
                                transferOK = NO;
                            }
                        }
                    }
                    if (n < 0) {
                        transferOK = NO;
                    }
                } @finally {
                    free(buf);
                    [outFh closeFile];
                    close(d);
                }
                if (transferOK) {
                    (void)MCFIXFTPSendStr(ctrlFd, @"226 transfer complete");
                } else {
                    (void)[fm removeItemAtPath:abs error:nil];
                    (void)MCFIXFTPSendStr(ctrlFd, @"426 connection closed; transfer aborted");
                }
                continue;
            }

            if ([cmd isEqualToString:@"DELE"]) {
                NSError *err = nil;
                NSString *abs = MCFIXFTPResolvePath(arg, cwdRel, &err);
                if (!abs) {
                    (void)MCFIXFTPSendStr(ctrlFd, [NSString stringWithFormat:@"550 %@", err.localizedDescription]);
                    continue;
                }
                BOOL isDir = NO;
                if (![fm fileExistsAtPath:abs isDirectory:&isDir] || isDir) {
                    (void)MCFIXFTPSendStr(ctrlFd, @"550 not a file");
                    continue;
                }
                if (![fm removeItemAtPath:abs error:&err]) {
                    (void)MCFIXFTPSendStr(ctrlFd, @"450 delete failed");
                    continue;
                }
                (void)MCFIXFTPSendStr(ctrlFd, @"250 file removed");
                continue;
            }

            if ([cmd isEqualToString:@"RMD"]) {
                NSError *err = nil;
                NSString *abs = MCFIXFTPResolvePath(arg, cwdRel, &err);
                if (!abs) {
                    (void)MCFIXFTPSendStr(ctrlFd, [NSString stringWithFormat:@"550 %@", err.localizedDescription]);
                    continue;
                }
                BOOL isDir = NO;
                if (![fm fileExistsAtPath:abs isDirectory:&isDir] || !isDir) {
                    (void)MCFIXFTPSendStr(ctrlFd, @"550 not a directory");
                    continue;
                }
                if (![fm removeItemAtPath:abs error:&err]) {
                    (void)MCFIXFTPSendStr(ctrlFd, @"450 remove folder failed (must be empty)");
                    continue;
                }
                (void)MCFIXFTPSendStr(ctrlFd, @"250 directory removed");
                continue;
            }

            if ([cmd isEqualToString:@"MKD"] || [cmd isEqualToString:@"XMKD"]) {
                NSError *err = nil;
                NSString *abs = MCFIXFTPResolvePath(arg, cwdRel, &err);
                if (!abs) {
                    (void)MCFIXFTPSendStr(ctrlFd, [NSString stringWithFormat:@"550 %@", err.localizedDescription]);
                    continue;
                }
                if ([fm fileExistsAtPath:abs]) {
                    (void)MCFIXFTPSendStr(ctrlFd, @"550 already exists");
                    continue;
                }
                if (![fm createDirectoryAtPath:abs withIntermediateDirectories:NO attributes:nil error:&err]) {
                    (void)MCFIXFTPSendStr(ctrlFd, @"550 mkdir failed");
                    continue;
                }
                (void)MCFIXFTPSendStr(ctrlFd, [NSString stringWithFormat:@"257 \"%@\" created", MCFIXFTPPWDDisplay(MCFIXFTPRelFromAbs(abs))]);
                continue;
            }

            if ([cmd isEqualToString:@"RNFR"]) {
                NSError *err = nil;
                NSString *abs = MCFIXFTPResolvePath(arg, cwdRel, &err);
                if (!abs || ![fm fileExistsAtPath:abs]) {
                    renameFromAbs = nil;
                    (void)MCFIXFTPSendStr(ctrlFd, @"550 RNFR failed");
                    continue;
                }
                renameFromAbs = abs;
                (void)MCFIXFTPSendStr(ctrlFd, @"350 send RNTO");
                continue;
            }

            if ([cmd isEqualToString:@"RNTO"]) {
                if (renameFromAbs.length == 0) {
                    (void)MCFIXFTPSendStr(ctrlFd, @"503 bad sequence (RNFR first)");
                    continue;
                }
                NSError *err = nil;
                NSString *dest = MCFIXFTPResolvePath(arg, cwdRel, &err);
                if (!dest) {
                    renameFromAbs = nil;
                    (void)MCFIXFTPSendStr(ctrlFd, [NSString stringWithFormat:@"550 %@", err.localizedDescription]);
                    continue;
                }
                if ([fm fileExistsAtPath:dest]) {
                    renameFromAbs = nil;
                    (void)MCFIXFTPSendStr(ctrlFd, @"550 destination exists");
                    continue;
                }
                if (![fm moveItemAtPath:renameFromAbs toPath:dest error:&err]) {
                    renameFromAbs = nil;
                    (void)MCFIXFTPSendStr(ctrlFd, @"550 rename failed");
                    continue;
                }
                renameFromAbs = nil;
                (void)MCFIXFTPSendStr(ctrlFd, @"250 rename ok");
                continue;
            }

            if ([cmd isEqualToString:@"SIZE"]) {
                NSError *err = nil;
                NSString *abs = MCFIXFTPResolvePath(arg, cwdRel, &err);
                if (!abs) {
                    (void)MCFIXFTPSendStr(ctrlFd, @"550 bad path");
                    continue;
                }
                BOOL isDir = NO;
                if (![fm fileExistsAtPath:abs isDirectory:&isDir] || isDir) {
                    (void)MCFIXFTPSendStr(ctrlFd, @"550 not a file");
                    continue;
                }
                NSDictionary *attr = [fm attributesOfItemAtPath:abs error:nil];
                unsigned long long sz = [[attr objectForKey:NSFileSize] unsignedLongLongValue];
                (void)MCFIXFTPSendStr(ctrlFd, [NSString stringWithFormat:@"213 %llu", sz]);
                continue;
            }

            if ([cmd isEqualToString:@"ABOR"]) {
                closePassive();
                closeActive();
                renameFromAbs = nil;
                (void)MCFIXFTPSendStr(ctrlFd, @"226 ABOR ok");
                continue;
            }

            if ([cmd isEqualToString:@"HELP"]) {
                (void)MCFIXFTPSendStr(ctrlFd, @"214 Commands: USER PASS PASV EPSV PORT LIST NLST RETR STOR DELE RMD MKD CWD CDUP PWD RNFR RNTO SIZE QUIT");
                continue;
            }

            (void)MCFIXFTPSendStr(ctrlFd, [NSString stringWithFormat:@"502 \"%@\" not implemented", cmd]);

        } @finally {
            MCFIXBypassHooksSet(NO);
        }
    }

    renameFromAbs = nil;
    closePassive();
    closeActive();
    close(ctrlFd);
}

static void MCFIXFTPRun(void) {
    MCFIXBypassEnsureKey();

    int lst = socket(AF_INET, SOCK_STREAM, 0);
    if (lst < 0) {
        MCFIXLog(MCFIXLogCatError, @"FTP: socket failed");
        return;
    }
    MCFIXFTPTuneSocket(lst);
    int yes = 1;
    (void)setsockopt(lst, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in a = {};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    a.sin_port = htons(kMCFIXFTPControlPort);
    if (bind(lst, (struct sockaddr *)&a, sizeof(a)) != 0 || listen(lst, 16) != 0) {
        MCFIXLog(MCFIXLogCatError, @"FTP: bind/listen on port %u failed", (unsigned)kMCFIXFTPControlPort);
        close(lst);
        return;
    }
    MCFIXLogOnce(MCFIXLogCatBoot, @"ftp_listen",
                 @"FTP listening on :%u — GameData VFS root (plain FTP; FileZilla: no encryption)",
          (unsigned)kMCFIXFTPControlPort);
    for (;;) {
        struct sockaddr_in cli;
        socklen_t clen = sizeof(cli);
        int c = accept(lst, (struct sockaddr *)&cli, &clen);
        if (c < 0) {
            continue;
        }
        MCFIXFTPTuneSocket(c);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            MCFIXFTPClientLoop(c);
            close(c);
        });
    }
}

@implementation MCFIXFTPServer

+ (void)start {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        MCFIXBypassEnsureKey();
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            MCFIXFTPRun();
        });
    });
}

@end
