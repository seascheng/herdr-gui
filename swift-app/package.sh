#!/bin/bash
# Package herdr-gui into dist/Herdr.app + zip. Builds first via build.sh.
set -e
cd "$(dirname "$0")"

VERSION="${1:-0.2.0}"

./build.sh

DIST=dist
APP="$DIST/Herdr.app"
rm -rf "$APP" "$DIST/Herdr-$VERSION.zip"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp herdr-gui "$APP/Contents/MacOS/herdr-gui"
strip "$APP/Contents/MacOS/herdr-gui"

# AppIcon.icns from the 1024px source.
ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 64 128 256 512; do
    sips -z $size $size Assets/AppIcon/app-icon.png \
        --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Assets/AppIcon/app-icon.png \
        --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
sips -z 1024 1024 Assets/AppIcon/app-icon.png \
    --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Herdr</string>
    <key>CFBundleDisplayName</key>       <string>Herdr</string>
    <key>CFBundleIdentifier</key>        <string>dev.herdr.gui</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleExecutable</key>        <string>herdr-gui</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>LSMinimumSystemVersion</key>    <string>12.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"

BIN_SIZE=$(stat -f%z "$APP/Contents/MacOS/herdr-gui")
ZIP_SIZE=$(stat -f%z /dev/null)
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/Herdr-$VERSION.zip"
ZIP_SIZE=$(stat -f%z "$DIST/Herdr-$VERSION.zip")

echo "app:    $APP  (binary $(numfmt --to=iec $BIN_SIZE 2>/dev/null || echo ${BIN_SIZE}B))"
echo "zip:    $DIST/Herdr-$VERSION.zip  ($(numfmt --to=iec $ZIP_SIZE 2>/dev/null || echo ${ZIP_SIZE}B))"
