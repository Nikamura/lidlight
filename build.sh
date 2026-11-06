#!/bin/sh
# Builds Lidlight.app.
#   ./build.sh            build into ./build
#   ./build.sh --install  build and install to ~/Applications
#   ./build.sh --zip      build and create build/Lidlight.zip (for releases)
set -eu
cd "$(dirname "$0")"

VERSION="${VERSION:-1.0.0}"
APP=build/Lidlight.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal binary (Apple Silicon + Intel)
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos13.0" -o "build/Lidlight-$arch" Sources/main.swift
done
lipo -create -output "$APP/Contents/MacOS/Lidlight" build/Lidlight-arm64 build/Lidlight-x86_64
rm build/Lidlight-arm64 build/Lidlight-x86_64

# App icon from assets/icon.png (1024x1024)
ICONSET=build/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s assets/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) assets/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.karolis.lidlight</string>
  <key>CFBundleName</key><string>Lidlight</string>
  <key>CFBundleDisplayName</key><string>Lidlight</string>
  <key>CFBundleExecutable</key><string>Lidlight</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" 2>/dev/null
echo "Built $APP ($VERSION)"

case "${1:-}" in
  --install)
    mkdir -p "$HOME/Applications"
    # Graceful quit (re-enables sleep); pkill would skip that.
    if pgrep -xq Lidlight; then
      osascript -e 'tell application id "dev.karolis.lidlight" to quit' || true
      sleep 1
    fi
    rm -rf "$HOME/Applications/Lidlight.app"
    cp -R "$APP" "$HOME/Applications/"
    echo "Installed to ~/Applications/Lidlight.app"
    ;;
  --zip)
    (cd build && ditto -c -k --keepParent Lidlight.app Lidlight.zip)
    echo "Created build/Lidlight.zip"
    ;;
esac
