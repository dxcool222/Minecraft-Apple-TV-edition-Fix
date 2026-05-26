#import "MCFIXCrashTrace.h"

#if !MCFIX_PRODUCTION_SILENT

#import <dlfcn.h>
#import <fcntl.h>
#import <mach-o/loader.h>
#import <os/lock.h>
#import <os/log.h>
#import <stdarg.h>
#import <signal.h>
#import <stdatomic.h>
#import <string.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <sys/ucontext.h>
#import <unistd.h>

static const char *kMCFIXBuildTag = "20260523";

/// Nominal __TEXT base for Minecraft Apple TV 1.1.5 in IDA (used with dladdr slide).
static const uint64_t kMCFIXIDANominalBase = 0x100000000ULL;
/// IDA anchors around marketplace catalog breadcrumbs (sub_100854430 / sub_1007CDBC0 / sub_100688CA8).
static const uint64_t kMCFIXIDA_Sub100854430 = 0x100854430ULL;
static const uint64_t kMCFIXIDA_Sub1007CDBC0 = 0x1007CDBC0ULL;
static const uint64_t kMCFIXIDA_Sub100688CA8 = 0x100688CA8ULL;

static os_log_t gMCFIXCrashTraceLog;
static char gMCFIXLastTrace[512];
static char gMCFIXTraceLogPath[PATH_MAX];
static os_unfair_lock gMCFIXTraceLock = OS_UNFAIR_LOCK_INIT;
static NSMutableSet<NSString *> *gMCFIXTraceOnceKeys;
static struct sigaction gMCFIXPrevSIGSEGV;
static struct sigaction gMCFIXPrevSIGBUS;
static struct sigaction gMCFIXPrevSIGABRT;
static _Atomic int gMCFIXInCrashHandler = 0;
static int gMCFIXTraceFd = -1;

static const char *MCFIXSignalName(int sig) {
    switch (sig) {
        case SIGSEGV: return "SIGSEGV";
        case SIGBUS: return "SIGBUS";
        case SIGABRT: return "SIGABRT";
        default: return "SIGNAL";
    }
}

static void MCFIXCrashTraceStoreLocked(NSString *line) {
    if (line.length == 0) {
        return;
    }
    const char *utf8 = line.UTF8String;
    if (utf8 == NULL) {
        return;
    }
    strlcpy(gMCFIXLastTrace, utf8, sizeof(gMCFIXLastTrace));
}

static void MCFIXSyncWriteRaw(const char *utf8) {
    if (utf8 == NULL || utf8[0] == '\0') {
        return;
    }
    size_t len = strlen(utf8);
    write(STDERR_FILENO, utf8, len);
    if (gMCFIXTraceFd >= 0) {
        write(gMCFIXTraceFd, utf8, len);
        fsync(gMCFIXTraceFd);
    }
}

static void MCFIXEmitToConsole(const char *line) {
    if (line == NULL || line[0] == '\0') {
        return;
    }
    NSLog(@"[MCFIX] %@", [NSString stringWithUTF8String:line]);
    if (gMCFIXCrashTraceLog != NULL) {
        os_log_error(gMCFIXCrashTraceLog, "[MCFIX] %{public}s", line);
    }
}

static void MCFIXSyncTraceEmitC(const char *utf8) {
    if (utf8 == NULL || utf8[0] == '\0') {
        return;
    }
    strlcpy(gMCFIXLastTrace, utf8, sizeof(gMCFIXLastTrace));
    MCFIXEmitToConsole(utf8);

    struct timeval tv;
    gettimeofday(&tv, NULL);
    char buf[768];
    int n = snprintf(buf, sizeof(buf), "%ld.%06d [MCFIX] %s\n",
                     (long)tv.tv_sec, (int)tv.tv_usec, utf8);
    if (n <= 0) {
        return;
    }
    size_t len = (size_t)((n < (int)sizeof(buf)) ? n : (int)sizeof(buf) - 1);
    write(STDERR_FILENO, buf, len);
    if (gMCFIXTraceFd >= 0) {
        write(gMCFIXTraceFd, buf, len);
        fsync(gMCFIXTraceFd);
    }
}

static uint64_t MCFIXRuntimeToIDAOffset(uint64_t pc, uint64_t *out_slide) {
    Dl_info info;
    memset(&info, 0, sizeof(info));
    if (dladdr((void *)(uintptr_t)pc, &info) && info.dli_fbase != NULL) {
        uint64_t slide = (uint64_t)(uintptr_t)info.dli_fbase;
        if (out_slide != NULL) {
            *out_slide = slide;
        }
        return kMCFIXIDANominalBase + (pc - slide);
    }
    if (out_slide != NULL) {
        *out_slide = 0;
    }
    return pc;
}

static const char *MCFIXIDANearestAnchorName(uint64_t ida_pc) {
    uint64_t d0 = (ida_pc > kMCFIXIDA_Sub100854430) ? (ida_pc - kMCFIXIDA_Sub100854430)
                                                    : (kMCFIXIDA_Sub100854430 - ida_pc);
    uint64_t d1 = (ida_pc > kMCFIXIDA_Sub1007CDBC0) ? (ida_pc - kMCFIXIDA_Sub1007CDBC0)
                                                    : (kMCFIXIDA_Sub1007CDBC0 - ida_pc);
    uint64_t d2 = (ida_pc > kMCFIXIDA_Sub100688CA8) ? (ida_pc - kMCFIXIDA_Sub100688CA8)
                                                    : (kMCFIXIDA_Sub100688CA8 - ida_pc);
    if (d0 <= d1 && d0 <= d2) {
        return "sub_100854430(catalog_info.json 256B header)";
    }
    if (d1 <= d2) {
        return "sub_1007CDBC0(catalog row apply)";
    }
    return "sub_100688CA8(manifest semver parse)";
}

#if defined(__arm64__)

static void MCFIXDumpARM64MachineState(int sig, siginfo_t *info, void *uap) {
    ucontext_t *uc = (ucontext_t *)uap;
    if (uc == NULL) {
        return;
    }

    _STRUCT_ARM_THREAD_STATE64 *ss = &uc->uc_mcontext->__ss;
    void *fault = info ? info->si_addr : NULL;

    uint64_t x0 = ss->__x[0];
    uint64_t x1 = ss->__x[1];
    uint64_t x2 = ss->__x[2];
    uint64_t x3 = ss->__x[3];
    uint64_t x4 = ss->__x[4];
    uint64_t x5 = ss->__x[5];
    uint64_t x6 = ss->__x[6];
    uint64_t x7 = ss->__x[7];
    uint64_t x8 = ss->__x[8];
    uint64_t fp = ss->__fp;
    uint64_t lr = ss->__lr;
    uint64_t sp = ss->__sp;
    uint64_t pc = ss->__pc;

    uint64_t slide = 0;
    uint64_t ida_pc = MCFIXRuntimeToIDAOffset(pc, &slide);
    uint64_t ida_lr = MCFIXRuntimeToIDAOffset(lr, NULL);
    const char *anchor = MCFIXIDANearestAnchorName(ida_pc);

    char line[896];
    int n = snprintf(line, sizeof(line),
        "[MCFIX FATAL] %s si_addr=%p build=%s\n"
        "[MCFIX FATAL] ARM64 pc=0x%llx lr=0x%llx sp=0x%llx fp=0x%llx slide=0x%llx\n"
        "[MCFIX FATAL] IDA pc=0x%llx lr=0x%llx nearest=%s\n"
        "[MCFIX FATAL] X0=0x%llx X1=0x%llx X2=0x%llx X3=0x%llx X4=0x%llx\n"
        "[MCFIX FATAL] X5=0x%llx X6=0x%llx X7=0x%llx X8=0x%llx last=%s\n"
        "[MCFIX FATAL] IDA map: sub_100854430 X0=ctx X1=out* X2=path magic@buf+4=0x9BCFBADF len@buf+1;\n"
        "[MCFIX FATAL] IDA map: sub_1007CDBC0 X0=parent+8 X1=entry BL sub_100854430@0x1007CE074;\n"
        "[MCFIX FATAL] IDA map: sub_100688CA8 X0=row X1=entry X2=manifest semver (sub_10068B1B8)\n",
        MCFIXSignalName(sig), fault, kMCFIXBuildTag,
        (unsigned long long)pc, (unsigned long long)lr, (unsigned long long)sp, (unsigned long long)fp,
        (unsigned long long)slide,
        (unsigned long long)ida_pc, (unsigned long long)ida_lr, anchor,
        (unsigned long long)x0, (unsigned long long)x1, (unsigned long long)x2,
        (unsigned long long)x3, (unsigned long long)x4,
        (unsigned long long)x5, (unsigned long long)x6, (unsigned long long)x7, (unsigned long long)x8,
        gMCFIXLastTrace);
    if (n > 0) {
        MCFIXSyncWriteRaw(line);
    }
}

#else

static void MCFIXDumpARM64MachineState(int sig, siginfo_t *info, void *uap) {
    (void)sig;
    (void)info;
    (void)uap;
}

#endif

static void MCFIXCopyTraceToDocuments(const char *srcPath) {
    if (srcPath == NULL || srcPath[0] == '\0') {
        return;
    }
    NSArray<NSString *> *docsDirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                        NSUserDomainMask,
                                                                        YES);
    NSString *docs = docsDirs.firstObject;
    if (docs.length == 0) {
        return;
    }
    NSString *dst = [docs stringByAppendingPathComponent:@"mcfix_last_boot_trace.log"];
    NSData *data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:srcPath]];
    if (data.length == 0) {
        return;
    }
    [data writeToFile:dst atomically:YES];
    NSLog(@"[MCFIX PREVBOOT] copied previous trace to Documents/mcfix_last_boot_trace.log (%lu bytes)",
          (unsigned long)data.length);
}

static void MCFIXReplayPreviousBootTrace(const char *logPath) {
    if (logPath == NULL || logPath[0] == '\0') {
        return;
    }
    struct stat st;
    if (stat(logPath, &st) != 0 || st.st_size <= 0) {
        return;
    }

    MCFIXCopyTraceToDocuments(logPath);

    size_t cap = 65536;
    if ((size_t)st.st_size < cap) {
        cap = (size_t)st.st_size;
    }
    int rfd = open(logPath, O_RDONLY);
    if (rfd < 0) {
        return;
    }
    char *buf = (char *)malloc(cap + 1);
    if (buf == NULL) {
        close(rfd);
        return;
    }
    ssize_t nread = read(rfd, buf, cap);
    close(rfd);
    if (nread <= 0) {
        free(buf);
        return;
    }
    buf[nread] = '\0';

    NSLog(@"[MCFIX PREVBOOT] ===== PREVIOUS BOOT TRACE (%zd bytes) build=%s =====",
          nread, kMCFIXBuildTag);
    os_log_error(gMCFIXCrashTraceLog,
                 "[MCFIX PREVBOOT] ===== PREVIOUS BOOT TRACE (%zd bytes) =====", nread);

    char *cursor = buf;
    while (*cursor != '\0') {
        char *eol = strchr(cursor, '\n');
        if (eol != NULL) {
            *eol = '\0';
        }
        if (cursor[0] != '\0') {
            NSLog(@"[MCFIX PREVBOOT] %s", cursor);
            os_log_error(gMCFIXCrashTraceLog, "[MCFIX PREVBOOT] %{public}s", cursor);
        }
        if (eol == NULL) {
            break;
        }
        cursor = eol + 1;
    }

    NSLog(@"[MCFIX PREVBOOT] ===== END PREVIOUS BOOT =====");
    os_log_error(gMCFIXCrashTraceLog, "[MCFIX PREVBOOT] ===== END PREVIOUS BOOT =====");
    free(buf);
}

static void MCFIXOpenSyncTraceLog(void) {
    const char *tmp = NSTemporaryDirectory().UTF8String;
    if (tmp == NULL || tmp[0] == '\0') {
        return;
    }
    snprintf(gMCFIXTraceLogPath, sizeof(gMCFIXTraceLogPath), "%smcfix_boot_trace.log", tmp);

    MCFIXReplayPreviousBootTrace(gMCFIXTraceLogPath);

    gMCFIXTraceFd = open(gMCFIXTraceLogPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (gMCFIXTraceFd < 0) {
        gMCFIXTraceLogPath[0] = '\0';
        return;
    }
    char hdr[256];
    int hn = snprintf(hdr, sizeof(hdr),
                      "=== mcfix boot trace build=%s pid=%d ===\n",
                      kMCFIXBuildTag, (int)getpid());
    if (hn > 0) {
        size_t hlen = (size_t)((hn < (int)sizeof(hdr)) ? hn : (int)sizeof(hdr) - 1);
        write(gMCFIXTraceFd, hdr, hlen);
        fsync(gMCFIXTraceFd);
    }
}

void MCFIXCrashTrace(NSString *fmt, ...) {
    if (fmt.length == 0) {
        return;
    }
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    os_unfair_lock_lock(&gMCFIXTraceLock);
    MCFIXCrashTraceStoreLocked(line);
    os_unfair_lock_unlock(&gMCFIXTraceLock);

    const char *utf8 = line.UTF8String;
    if (utf8 != NULL) {
        MCFIXSyncTraceEmitC(utf8);
    }
}

void MCFIXCrashTraceOnce(NSString *key, NSString *fmt, ...) {
    if (key.length == 0 || fmt.length == 0) {
        return;
    }
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gMCFIXTraceOnceKeys = [NSMutableSet set];
    });

    os_unfair_lock_lock(&gMCFIXTraceLock);
    BOOL seen = [gMCFIXTraceOnceKeys containsObject:key];
    if (!seen) {
        [gMCFIXTraceOnceKeys addObject:key];
    }
    os_unfair_lock_unlock(&gMCFIXTraceLock);
    if (seen) {
        return;
    }

    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    MCFIXCrashTrace(@"%@", line);
}

NSString *MCFIXCrashTraceLastLine(void) {
    os_unfair_lock_lock(&gMCFIXTraceLock);
    NSString *line = [NSString stringWithUTF8String:gMCFIXLastTrace] ?: @"";
    os_unfair_lock_unlock(&gMCFIXTraceLock);
    return line;
}

NSString *MCFIXCrashTraceLogFilePath(void) {
    if (gMCFIXTraceLogPath[0] == '\0') {
        return @"";
    }
    return [NSString stringWithUTF8String:gMCFIXTraceLogPath];
}

static void MCFIXCrashSignalHandler(int sig, siginfo_t *info, void *uap) {
    if (atomic_exchange(&gMCFIXInCrashHandler, 1) != 0) {
        return;
    }

    MCFIXDumpARM64MachineState(sig, info, uap);

    os_log_fault(gMCFIXCrashTraceLog, "[MCFIX FATAL] %{public}s si_addr=%p last=%{public}s",
                 MCFIXSignalName(sig), info ? info->si_addr : NULL, gMCFIXLastTrace);

    struct sigaction *prev = NULL;
    if (sig == SIGSEGV) {
        prev = &gMCFIXPrevSIGSEGV;
    } else if (sig == SIGBUS) {
        prev = &gMCFIXPrevSIGBUS;
    } else if (sig == SIGABRT) {
        prev = &gMCFIXPrevSIGABRT;
    }
    if (prev != NULL) {
        if (prev->sa_flags & SA_SIGINFO) {
            if (prev->sa_sigaction != NULL) {
                prev->sa_sigaction(sig, info, uap);
                return;
            }
        } else if (prev->sa_handler != NULL && prev->sa_handler != SIG_DFL &&
                   prev->sa_handler != SIG_IGN) {
            prev->sa_handler(sig);
            return;
        }
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static void MCFIXInstallSignalTrap(int sig, struct sigaction *storePrev) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_SIGINFO;
    sa.sa_sigaction = MCFIXCrashSignalHandler;
    sigaction(sig, &sa, storePrev);
}

void MCFIXCrashTraceInstall(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gMCFIXCrashTraceLog = os_log_create("com.mcfix.storage", "crash-trace");
        MCFIXOpenSyncTraceLog();
        MCFIXInstallSignalTrap(SIGSEGV, &gMCFIXPrevSIGSEGV);
        MCFIXInstallSignalTrap(SIGBUS, &gMCFIXPrevSIGBUS);
        MCFIXInstallSignalTrap(SIGABRT, &gMCFIXPrevSIGABRT);
        MCFIXCrashTrace(@"install pid=%d build=%@ — 2nd launch dumps PREVBOOT; filter: MCFIX PREVBOOT",
                        (int)getpid(), @(kMCFIXBuildTag));
    });
}

#endif /* !MCFIX_PRODUCTION_SILENT */
