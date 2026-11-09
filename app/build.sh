#!/bin/sh
# Builds a self-contained "Office Room.app" (Apple Silicon + Intel, bundles Node and the server JS),
# installs it into ~/Applications, and writes a zip to share with others into app/dist/.
set -e
cd "$(dirname "$0")"
NODE_VERSION=26.13.0
MIN_MACOS=13.0
NAME="Office Room"
STAGE="build/$NAME.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)

rm -rf build && mkdir -p build
swift icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns

for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos$MIN_MACOS" -o "build/OfficeRoom-$arch" \
    main.swift OfficeScene.swift OfficeStore.swift NativeUI.swift PromptInput.swift \
    -framework Cocoa -framework SwiftUI -framework SceneKit
done
lipo -create -output build/OfficeRoom build/OfficeRoom-arm64 build/OfficeRoom-x86_64

# Official Node.js runtime, downloaded once and checksum-verified.
mkdir -p .cache
[ -f ".cache/SHASUMS256-$NODE_VERSION.txt" ] || curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/SHASUMS256.txt" -o ".cache/SHASUMS256-$NODE_VERSION.txt"
for a in arm64 x64; do
  dir="node-v$NODE_VERSION-darwin-$a"
  if [ ! -x ".cache/$dir/bin/node" ]; then
    curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/$dir.tar.gz" -o ".cache/$dir.tar.gz"
    (cd .cache && grep " $dir.tar.gz\$" "SHASUMS256-$NODE_VERSION.txt" | shasum -a 256 -c -)
    tar -xzf ".cache/$dir.tar.gz" -C .cache && rm ".cache/$dir.tar.gz"
  fi
done

R="$STAGE/Contents/Resources"
mkdir -p "$STAGE/Contents/MacOS" "$R/server" "$R/node/bin"
cp build/OfficeRoom "$STAGE/Contents/MacOS/OfficeRoom"
cp build/AppIcon.icns "$R/AppIcon.icns"
cp Info.plist "$STAGE/Contents/Info.plist"
cp ../*.js ../index.html "$R/server/"
lipo -create -output "$R/node/bin/node" ".cache/node-v$NODE_VERSION-darwin-arm64/bin/node" ".cache/node-v$NODE_VERSION-darwin-x64/bin/node"
cp ".cache/node-v$NODE_VERSION-darwin-arm64/LICENSE" "$R/node/LICENSE"

codesign --force --sign - "$R/node/bin/node"
codesign --force --sign - "$STAGE"
codesign --verify --deep --strict "$STAGE"

APP="$HOME/Applications/$NAME.app"
mkdir -p "$HOME/Applications" && rm -rf "$APP" && ditto "$STAGE" "$APP"
echo "installed: $APP"

PKG="build/pkg/$NAME"
mkdir -p "$PKG" dist
ditto "$STAGE" "$PKG/$NAME.app"
cp README-share.txt "$PKG/อ่านก่อนเปิด.txt"
ZIP="dist/Office-Room-$VERSION.zip"
rm -f "$ZIP" && ditto -c -k --keepParent "$PKG" "$ZIP"
echo "share: $(pwd)/$ZIP"
