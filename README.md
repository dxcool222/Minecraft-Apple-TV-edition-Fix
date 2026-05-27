# Minecraft tvOS Storage Fix

`tweak-1.3` is a restoration tweak for legacy Minecraft tvOS builds. It is meant for non-jailbroken Apple TVs where the original game crashes or fails because it expects App Store iCloud services that are no longer available to a sideloaded copy.

The fix is packaged as `MinecraftStorageFix.framework`. The build script injects that framework into a decrypted Minecraft tvOS IPA, patches the 1.1.5 game binary, and repacks the app so it can run with local world storage instead of iCloud world storage.

No setup is required inside the game. Once the framework is loaded, it installs its storage, CloudKit, iCloud, keychain, and FTP fixes automatically.

No jailbreak is required.

This repo does not include Minecraft IPAs or copyrighted game assets. You need your own legally obtained decrypted IPA.

## What This Fixes

The original tvOS version expects a real App Store environment:

- iCloud and CloudKit entitlements
- iCloud account state
- Cloud-backed world sync
- writable game folders under `Library/games` and `Documents/games`
- keychain and Xbox service entitlements

When the app is sideloaded onto a non-jailbroken Apple TV, those assumptions break. The common failures are startup crashes, iCloud setup hangs, failed world sync, worlds not saving, or no practical way to get saved worlds off the device.

This tweak changes the game to use local storage and exposes that storage over FTP.

## What The Tweak Does

### Saves worlds locally

Minecraft writes data through both POSIX file calls and Objective-C filesystem APIs. The tweak catches both paths and redirects game storage into a writable folder inside the app sandbox.

The main storage root is `Library/Caches/MinecraftStorageFix/GameData/vfs` inside the app container.

The redirected game roots include `Library/games`, `Documents/games`, `tmp/Temp/games`, and `tmp/minecraftpe`.

This keeps worlds, options, skins, icons, and related game files in local storage that survives relaunches.

### Bypasses iCloud and CloudKit crashes

The original game tries to initialize iCloud and CloudKit during startup and world sync. On a sideloaded Apple TV, those calls can fail hard enough to crash or block the game.

The tweak provides safe local replacements:

- fake ubiquity identity token
- fake CloudKit container and database responses
- safe empty success callbacks for CloudKit operations
- iCloud notification callbacks turned into no-ops
- runtime vtable patches for the deeper C++ iCloud gates
- guards for sync paths that can create failed cloud backup state

The result is simple: the game can boot and save worlds without a working iCloud container.

### Lets you pull worlds off over FTP

The tweak starts a plain FTP server inside the game process.

Connection details:

- Host: your Apple TV IP address
- Port: `2121`
- Protocol: plain FTP, no TLS
- Username: anything
- Password: anything

The FTP server is rooted at the MinecraftStorageFix local storage folder. World folders are under paths like `Library/games/com.mojang/minecraftWorlds` and `Documents/games/com.mojang/minecraftWorlds`.

Use FileZilla or another FTP client from the same local network to back up or inspect worlds.

### Handles sideload entitlement issues

Sideloaded builds can fail keychain, notification, StoreKit, and Xbox-related entitlement checks. The tweak patches the pieces that matter for local play:

- Xbox Live keychain access-group failures
- `SecItemAdd`, `SecItemCopyMatching`, `SecItemUpdate`, and `SecItemDelete`
- late-loading Xbox and MSA runtime classes
- push notification registration paths
- StoreKit receipt and payment checks used by some offline UI paths

### Applies 1.1.5 binary patches

The build script runs `scripts/patch_game_binary.py` against the main `minecraftappletv` executable.

Current patches target Minecraft tvOS 1.1.5:

- `sub_1006634DC`: force catalog ownership true
- `sub_100369B34`: hide skin and pack padlocks

The patcher checks the original bytes before writing. If the binary does not match the expected 1.1.5 executable, it stops instead of patching the wrong file.

## Supported Version

Current target:

- Game version: Minecraft tvOS 1.1.5
- App bundle: `Payload/minecraftappletv.app`
- Main executable: `minecraftappletv`
- Output name: `Minecraft_1.1.5_MCStorageFix.ipa` by default

This project injects the framework and applies the 1.1.5 binary patches. It does not merge game assets or build alternate game versions.

## Requirements

- macOS
- full Xcode installed at `/Applications/Xcode.app`
- Apple TV SDK
- `python3`
- `ldid`
- `zip` and `unzip`

`optool` is not needed. The repo includes its own Python load-command injector.

## Build

Put your decrypted Minecraft tvOS 1.1.5 IPA in the repo root, then run `./scripts/build_and_inject_ipa.sh "Minecraft_1.1.5_decrypted.ipa"`.

Default output: `Minecraft_1.1.5_MCStorageFix.ipa`

Custom output: `./scripts/build_and_inject_ipa.sh "Minecraft_1.1.5_decrypted.ipa" "Minecraft_tvOS_Restored.ipa"`

Help: `./scripts/build_and_inject_ipa.sh --help`

`BUILD_NOW.command` is a Finder-friendly wrapper around the same script. With no arguments it uses `Minecraft_1.1.5_decrypted.ipa` as input and writes `Minecraft_1.1.5_MCStorageFix.ipa`.

## Build Pipeline

The build script does the following:

1. Builds `MinecraftStorageFix.framework` with Xcode for Apple TV.
2. Extracts the input IPA into `ipa_inject_work`.
3. Copies the framework into `Payload/minecraftappletv.app/Frameworks`.
4. Runs `patch_game_binary.py` on `minecraftappletv`.
5. Runs `inject_dylib.py` so the app loads `MinecraftStorageFix.framework` at startup.
6. Re-signs the main executable with `ldid`.
7. Repackages the final IPA.

The full build log is written to `build_inject.log`.

## Project Layout

- `MinecraftStorageFix.xcodeproj`: Xcode project
- `MinecraftStorageFix/MinecraftStorageFix.m`: startup hook installation
- `MinecraftStorageFix/Modules/VFS`: local storage redirect, bootstrap, migrations
- `MinecraftStorageFix/Modules/CloudKit`: fake CloudKit, iCloud bypasses, vtable patches
- `MinecraftStorageFix/Modules/Server`: built-in FTP server
- `MinecraftStorageFix/Modules/Icons`: world and achievement icon handling
- `MinecraftStorageFix/Modules/Marketplace`: local catalog and entitlement helpers
- `MinecraftStorageFix/Modules/Xbox`: keychain and Xbox hardening
- `MinecraftStorageFix/Modules/Sideload`: sideload entitlement and StoreKit fixes
- `MinecraftStorageFix/Modules/Lifecycle`: startup watchdog and diagnostics
- `MinecraftStorageFix/Modules/Vendor`: fishhook
- `scripts/build_and_inject_ipa.sh`: main build and injection script
- `scripts/inject_dylib.py`: Mach-O load-command injector
- `scripts/patch_game_binary.py`: Minecraft tvOS 1.1.5 binary patcher
- `BUILD_NOW.command`: macOS double-click build helper

## Debugging

Production logging is off by default in `MinecraftStorageFix/Modules/Log/MCFIXLog.h`.

Set `MCFIX_PRODUCTION_SILENT` to `0` and rebuild if you need device logs.

Useful log categories:

- `MCFIX Boot`: startup and migrations
- `MCFIX VFS`: storage redirect setup
- `MCFIX CK`: CloudKit and iCloud shims
- `MCFIX Icon`: world and achievement icon paths
- `MCFIX XBL`: Xbox and keychain handling
- `MCFIX Err`: runtime patch or filesystem errors

## Troubleshooting

### The app still crashes

Check `build_inject.log` first. Make sure the framework was copied into the app and the load command injection step succeeded.

### Worlds do not show over FTP

Launch the game once after installing the patched IPA. The VFS tree is created during startup. Then connect to your Apple TV IP on port `2121` using plain FTP.

### The patcher says the signature is missing

The executable is not the expected Minecraft tvOS 1.1.5 binary, or it was already modified. The patcher intentionally stops in that case.

### `ldid` is missing

Install `ldid` and make sure your shell can find it with `which ldid`.

### Xcode build fails

Make sure full Xcode is installed and the Apple TV SDK is available with `xcodebuild -showsdks`.

## Disclaimer

This is an independent preservation and compatibility project for legally owned copies of Minecraft tvOS. It is not affiliated with, endorsed by, or associated with Mojang Studios, Microsoft, or Apple Inc. Do not distribute game binaries or copyrighted assets.
