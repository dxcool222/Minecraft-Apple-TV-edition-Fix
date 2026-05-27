#!/bin/bash
# Double-click helper: build MinecraftStorageFix, inject framework, patch binary, repack.
# Output: Minecraft_1.1.5_MCStorageFix.ipa.
# For other IPAs or names, use Terminal: ./scripts/build_and_inject_ipa.sh "your.ipa"
set -euo pipefail
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
cd "$(dirname "$0")"
exec bash scripts/build_and_inject_ipa.sh "$@"
