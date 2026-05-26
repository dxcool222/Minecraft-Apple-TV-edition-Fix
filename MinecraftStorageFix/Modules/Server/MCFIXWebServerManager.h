#import <Foundation/Foundation.h>

/// LAN file access: GCDWebServer HTTP on **8080** + plain FTP on **2121** (FileZilla: FTP, no TLS).
///
/// **Architecture**
///
/// * Fishhook + `MCFIXPathByRedirectingGameStorage` = Minecraft runtime I/O into the
///   Caches `GameData/vfs/...` mirror when paths match configured tails.
/// * GCDWebServer lists every VFS `minecraftWorlds` path that is a redirect target (same tails as the hook layer).
/// * Staging under `NSTemporaryDirectory()/mcfix_uploads` is the only ingest path;
///   `/restore` promotes into the live slot after checks.
/// * `MCFIX_BypassHooks` makes hooked POSIX pass paths through unchanged **on the
///   current thread only** — it skips VFS rewriting for that syscall, not “partial” logic.
///
/// **Multipart / temp files**
///
/// Parser temp files use `tmp/<UUID>` under the app container. Only explicit tails
/// like `tmp/minecraftpe` / `tmp/Temp/games` are redirected; generic tmp files are
/// not, so upload scratch space cannot be remapped into worlds. See comment in
/// `MinecraftStorageFix.m` on `MCFIXTailNeedsGameVFSCacheRedirect`.
///
/// **`MCFIX_BypassHooks` + GCDWebServer**
///
/// The flag is C11 `_Thread_local`: each pthread has its own value. libdispatch
/// worker threads may run handlers concurrently or reuse threads sequentially; either
/// way one request cannot observe another’s bypass bit, and `@finally` resets the
/// current thread after each handler. There is no process-global “stuck bypass”.
///
/// Optional world-session guard: `MCFIXWebServerSetGameWorldSessionActive` in
/// `MCFIXWebServerWorldOps.h`.
@interface MCFIXWebServerManager : NSObject
+ (void)start;
@end
