#!/bin/bash
# Build the SwiftUI agent-app for iOS devices (arm64) on a headless macOS CI
# worker and package an ad-hoc-signed .ipa.  No xcodeproj, no simulator
# runtime: SwiftPM + a destination JSON against the Xcode-shipped iPhoneOS.sdk.
#
# Usage: tool/build-ios.sh [output-dir]
set -e
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:-$ROOT/build}"
APP_NAME="agent-app"
MARKETING_VERSION="0.5.1"

command -v swift >/dev/null || { echo "swift not found"; exit 1; }
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
[ -d "$SDK" ] || { echo "iPhoneOS.sdk missing"; exit 1; }
TOOLCHAIN_BIN="$(dirname "$(xcrun --find swift)")"

DEST="$(mktemp /tmp/ios-dest.XXXXXX.json)"
cat > "$DEST" <<JSON
{
  "version": 1,
  "toolchain-bin-dir": "$TOOLCHAIN_BIN",
  "target": "arm64-apple-ios17.0",
  "sdk": "$SDK",
  "extra-cc-flags": [],
  "extra-swiftc-flags": [],
  "extra-cpp-flags": [],
  "extra-cxx-flags": [],
  "extra-linker-flags": []
}
JSON

echo "== swift build (ios-arm64 release) =="
(cd "$ROOT" && swift build -c release --destination "$DEST")
BIN_PATH="$(cd "$ROOT" && swift build -c release --destination "$DEST" --show-bin-path)"
BIN="$BIN_PATH/$APP_NAME"
[ -x "$BIN" ] || { echo "built binary not found at $BIN"; exit 2; }

echo "== assemble $APP_NAME.app =="
STAGE="$(mktemp -d)"
APP="$STAGE/Payload/$APP_NAME.app"
mkdir -p "$APP"
cp "$BIN" "$APP/$APP_NAME"
sed -e "s/@VERSION@/$MARKETING_VERSION/g" "$ROOT/tool/Info-ios.plist" > "$APP/Info.plist"
# App icon: rendered from the shared design language (AS mark, amber) by
# tools/gen-icons.py, emitted under the names CFBundleIcons references.
ICON_SRC="$ROOT/tool/icons"
if [ -f "$ICON_SRC/icon-192.png" ]; then
  cp "$ICON_SRC/icon-192.png" "$APP/AppIcon60x60@2x.png"   # 120x120 @2x
  cp "$ICON_SRC/icon-192.png" "$APP/AppIcon60x60@3x.png"   # 180x180 @3x
  cp "$ICON_SRC/icon-192.png" "$APP/AppIcon76x76@2x.png"   # 152x152 @2x
fi
mkdir -p "$APP/_CodeSignature"

echo "== codesign (ad-hoc) =="
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

echo "== package .ipa =="
mkdir -p "$OUT_DIR"
IPA="$OUT_DIR/Easy-Agent-swiftui-ios-$MARKETING_VERSION.ipa"
rm -f "$IPA"
(cd "$STAGE" && zip -qyr "$IPA" Payload)
rm -rf "$STAGE" "$DEST"

echo "IPA_OK $IPA"
shasum -a 256 "$IPA"
ls -la "$IPA"
