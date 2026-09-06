#!/usr/bin/env bash
set -euo pipefail

# Resolve paths from this script so it works from any current directory and
# remains safe when the checkout path contains spaces.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/Token Usage.app"
BUILD_DIR="$PROJECT_DIR/.build/release"
BINARY_PATH="$BUILD_DIR/TokenUsage"
INFO_PLIST_PATH="$PROJECT_DIR/Sources/TokenBall/Resources/Info.plist"
MODULE_CACHE_DIR="$PROJECT_DIR/.build/ModuleCache"

mkdir -p "$DIST_DIR" "$MODULE_CACHE_DIR"

# Keep Swift/Clang's module cache inside the checkout. This also makes the
# package reproducible in restricted environments where the user cache is not
# writable.
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" \
SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIR" \
swift build \
    --package-path "$PROJECT_DIR" \
    --configuration release \
    --disable-sandbox

if [[ ! -f "$BINARY_PATH" ]]; then
    echo "error: release executable not found at $BINARY_PATH" >&2
    exit 1
fi

if [[ ! -f "$INFO_PLIST_PATH" ]]; then
    echo "error: Info.plist not found at $INFO_PLIST_PATH" >&2
    exit 1
fi

# Only replace the exact generated output. No signing or installation is
# performed; callers can inspect or sign the bundle in a separate release
# workflow.
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY_PATH" "$APP_DIR/Contents/MacOS/TokenUsage"
cp "$INFO_PLIST_PATH" "$APP_DIR/Contents/Info.plist"
chmod 0755 "$APP_DIR/Contents/MacOS/TokenUsage"

if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null
fi

echo "已生成未进行发布签名的 App：$APP_DIR"
