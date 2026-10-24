#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Joplin Native"
EXEC=JoplinNative
BUNDLE_ID=io.github.malkafen.JoplinNative
VERSION=${VERSION:-$(git describe --tags --always 2>/dev/null || echo 0.0.0)}
VERSION=${VERSION#v}
case "$VERSION" in [0-9]*) ;; *) VERSION=0.0.0-$VERSION ;; esac
SHORT_VERSION=${VERSION%%-*}

swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/$EXEC" "$APP/Contents/MacOS/$EXEC"
SDK_VERSION=$(xcrun --show-sdk-version)
MIN_VERSION=$(otool -l "$APP/Contents/MacOS/$EXEC" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
xcrun vtool -set-build-version macos "${MIN_VERSION:-14.0}" "$SDK_VERSION" -replace \
  -output "$APP/Contents/MacOS/$EXEC.tmp" "$APP/Contents/MacOS/$EXEC"
mv "$APP/Contents/MacOS/$EXEC.tmp" "$APP/Contents/MacOS/$EXEC"
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done

if [ ! -f build/AppIcon.icns ] || [ Tools/make-icon.swift -nt build/AppIcon.icns ] || [ Tools/AppIcon.svg -nt build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset
  swift Tools/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$EXEC</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Joplin Export File</string>
      <key>CFBundleTypeExtensions</key><array><string>jex</string></array>
      <key>CFBundleTypeRole</key><string>Viewer</string>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$APP"
echo "Built: $APP"

if [ "${1:-}" = "--install" ]; then
  pkill -x "$EXEC" 2>/dev/null && sleep 1 || true
  DEST="/Applications/$APP_NAME.app"
  if [ -w /Applications ]; then
    rm -rf "$DEST" && ditto "$APP" "$DEST"
  else
    sudo rm -rf "$DEST" && sudo ditto "$APP" "$DEST"
  fi
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" || true
  echo "Installed: $DEST"
fi
