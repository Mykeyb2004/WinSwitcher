#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_CONFIG="${1:-release}"
APP_NAME="WinSwitcher"
APP_BUNDLE="${ROOT_DIR}/build/${APP_NAME}.app"

echo "==> Building ${APP_NAME} (${BUILD_CONFIG})..."
cd "${ROOT_DIR}"

SWIFT_FLAGS=()
if [[ "${WS_USE_TMP_CACHE:-0}" == "1" ]]; then
    mkdir -p /tmp/ws-clang-cache /tmp/ws-swiftpm
    export TMPDIR=/tmp
    export CLANG_MODULE_CACHE_PATH=/tmp/ws-clang-cache
    export SWIFTPM_MODULECACHE_OVERRIDE=/tmp/ws-clang-cache
    SWIFT_FLAGS+=(--disable-sandbox --cache-path /tmp/ws-swiftpm/cache --config-path /tmp/ws-swiftpm/config --security-path /tmp/ws-swiftpm/security)
fi

swift build -c "${BUILD_CONFIG}" "${SWIFT_FLAGS[@]}"

BIN_PATH="$(swift build -c "${BUILD_CONFIG}" "${SWIFT_FLAGS[@]}" --show-bin-path)/${APP_NAME}"
if [[ ! -f "${BIN_PATH}" ]]; then
    echo "Error: compiled binary not found at ${BIN_PATH}"
    exit 1
fi

echo "==> Packaging ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "${ROOT_DIR}/Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
printf "APPL????" > "${APP_BUNDLE}/Contents/PkgInfo"

echo "==> Ad-hoc code signing ${APP_BUNDLE}..."
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "==> Done! App bundle created at:"
echo "    ${APP_BUNDLE}"
echo "    Run: open \"${APP_BUNDLE}\""
