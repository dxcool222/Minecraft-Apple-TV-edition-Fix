#!/usr/bin/env bash
# Build MinecraftStorageFix (Xcode), inject it into a target IPA, and repack.
# The script supports custom input/output IPA names and includes a built-in
# help/tutorial mode:
#
#   ./scripts/build_and_inject_ipa.sh --help
#
# Required tooling:
#   - Xcode (full, not just CLT) at /Applications/Xcode.app
#   - python3
#   - ldid
#   - zip / unzip
#
# Default behavior (no args):
#   input  = Minecraft_1.1.5_decrypted.ipa
#   output = Minecraft_1.1.5_MCStorageFix.ipa

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IPA_IN_ARG="${1:-}"
OUT_IPA_ARG="${2:-}"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/build_and_inject_ipa.sh [input.ipa] [output.ipa]
  ./scripts/build_and_inject_ipa.sh --help

What this script does:
  1) Builds MinecraftStorageFix.framework with Xcode.
  2) Unzips the input IPA into a temp work folder.
  3) Copies the framework into Payload/minecraftappletv.app/Frameworks.
  4) Patches the game binary (patch_game_binary.py).
  5) Injects LC_LOAD_DYLIB for MinecraftStorageFix (inject_dylib.py).
  6) Re-signs the app binary with ldid.
  7) Re-zips Payload into a new output IPA.

Examples:
  # Defaults: Minecraft_1.1.5_decrypted.ipa -> Minecraft_1.1.5_MCStorageFix.ipa
  ./scripts/build_and_inject_ipa.sh

  # Any input IPA -> <basename>_MCStorageFix.ipa (framework + binary patches)
  ./scripts/build_and_inject_ipa.sh "Minecraft_1.1.5_decrypted.ipa"

  # Explicit output name
  ./scripts/build_and_inject_ipa.sh "Minecraft_1.1.5_decrypted.ipa" "Minecraft_tvOS_Restored.ipa"

Notes:
  - This is NOT a hybrid asset-merge build; it injects MinecraftStorageFix + patches minecraftappletv.
  - patch_game_binary.py targets tvOS 1.1.5; other versions may fail signature checks.
  - Paths can be relative to repo root or absolute.
  - Detailed execution log is written to build_inject.log.
  - macOS: double-click BUILD_NOW.command (same pipeline, 1.1.5 defaults).
EOF
}

if [[ "${IPA_IN_ARG}" == "-h" || "${IPA_IN_ARG}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 2 ]]; then
  echo "ERROR: too many arguments."
  echo
  usage
  exit 1
fi

# Usage:
#   ./build_and_inject_ipa.sh [input.ipa] [output.ipa]
# If omitted, it keeps the legacy behavior (Minecraft_1.1.5_decrypted.ipa -> Minecraft_1.1.5_MCStorageFix.ipa).
if [[ -n "${IPA_IN_ARG}" ]]; then
  if [[ "${IPA_IN_ARG}" == /* ]]; then
    IPA_IN="${IPA_IN_ARG}"
  else
    IPA_IN="${ROOT}/${IPA_IN_ARG}"
  fi
else
  IPA_IN="${ROOT}/Minecraft_1.1.5_decrypted.ipa"
fi

if [[ -n "${OUT_IPA_ARG}" ]]; then
  if [[ "${OUT_IPA_ARG}" == /* ]]; then
    OUT_IPA="${OUT_IPA_ARG}"
  else
    OUT_IPA="${ROOT}/${OUT_IPA_ARG}"
  fi
else
  if [[ "${IPA_IN}" == "${ROOT}/Minecraft_1.1.5_decrypted.ipa" ]]; then
    OUT_IPA="${ROOT}/Minecraft_1.1.5_MCStorageFix.ipa"
  else
    # Use a derived output name to avoid overwriting a previously patched IPA.
    IPA_BASENAME="$(basename "${IPA_IN}" .ipa)"
    OUT_IPA="${ROOT}/${IPA_BASENAME}_MCStorageFix.ipa"
  fi
fi
WORK="${ROOT}/ipa_inject_work"
LOG="${ROOT}/build_inject.log"

MCFIX_PROJ="${ROOT}/MinecraftStorageFix.xcodeproj"
MCFIX_DD="${ROOT}/dd_build"
MCFIX_FW="${MCFIX_DD}/Build/Products/Release-appletvos/MinecraftStorageFix.framework"
MCFIX_LOAD="@executable_path/Frameworks/MinecraftStorageFix.framework/MinecraftStorageFix"

BIN_IN_APP="minecraftappletv"
INJECT_PY="$(dirname "$0")/inject_dylib.py"
PATCH_PY="$(dirname "$0")/patch_game_binary.py"

if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

exec > "${LOG}" 2>&1
echo "=== build_and_inject_ipa.sh $(date) ==="
echo "input : ${IPA_IN}"
echo "output: ${OUT_IPA}"

cd "${ROOT}"

[[ -f "${IPA_IN}" ]]              || { echo "ERROR: missing ${IPA_IN}"; exit 1; }
[[ -d "${MCFIX_PROJ}" ]]          || { echo "ERROR: missing ${MCFIX_PROJ}"; exit 1; }
[[ -f "${INJECT_PY}" ]]           || { echo "ERROR: missing ${INJECT_PY}"; exit 1; }
[[ -f "${PATCH_PY}" ]]            || { echo "ERROR: missing ${PATCH_PY}"; exit 1; }
command -v ldid   >/dev/null      || { echo "ERROR: ldid not on PATH (brew install ldid)"; exit 1; }
command -v python3 >/dev/null     || { echo "ERROR: python3 not on PATH"; exit 1; }

echo
echo "=== 1/4 Build MinecraftStorageFix (Xcode) ==="
rm -rf "${MCFIX_DD}"
xcodebuild -project "${MCFIX_PROJ}" \
  -scheme MinecraftStorageFix \
  -configuration Release-appletvos \
  -sdk appletvos \
  -derivedDataPath "${MCFIX_DD}" \
  clean build \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_ALLOWED=NO

[[ -d "${MCFIX_FW}" ]] || { echo "ERROR: framework not produced at ${MCFIX_FW}"; exit 1; }
echo "MinecraftStorageFix: $(lipo -info "${MCFIX_FW}/MinecraftStorageFix" 2>&1)"

echo
echo "=== 2/4 Stage IPA and copy framework ==="
rm -rf "${WORK}"
mkdir -p "${WORK}"
unzip -q "${IPA_IN}" -d "${WORK}"

APP="${WORK}/Payload/minecraftappletv.app"
[[ -d "${APP}" ]] || { echo "ERROR: ${APP} missing after unzip"; ls -la "${WORK}/Payload" || true; exit 1; }
mkdir -p "${APP}/Frameworks"
rm -rf "${APP}/Frameworks/MinecraftStorageFix.framework"
# Clean up old SideloadFix / XBLFocusFix from previous installs.
rm -rf "${APP}/Frameworks/XBLFocusFix.framework"
rm -rf "${APP}/Frameworks/SideloadFix.framework"
cp -R "${MCFIX_FW}" "${APP}/Frameworks/"

TARGET="${APP}/${BIN_IN_APP}"
[[ -f "${TARGET}" ]] || { echo "ERROR: main binary missing at ${TARGET}"; exit 1; }

echo
echo "=== 3/4 Patch main binary (sub_1006634DC + sub_100369B34) ==="
python3 "${PATCH_PY}" "${TARGET}"

echo
echo "=== 4/4 Inject LC_LOAD_DYLIB and resign ==="
python3 "${INJECT_PY}" "${TARGET}" "${MCFIX_LOAD}"

ldid -S "${TARGET}"

echo
echo "=== verify ==="
otool -L "${TARGET}" | grep -i 'MinecraftStorageFix' || {
  echo "ERROR: MinecraftStorageFix load command missing after inject"; exit 1; }

rm -f "${OUT_IPA}"
( cd "${WORK}" && zip -qry "${OUT_IPA}" Payload )

ls -lh "${OUT_IPA}"
echo "SUCCESS: ${OUT_IPA}"
