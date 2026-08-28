#!/bin/bash
# Release pipeline for herdr-gui (fayazara/macos-app-skills release flow):
# build → icns → .app bundle → ad-hoc codesign → DMG + zip → commit/push → gh release.
#
# Usage:
#   scripts/release/make-release.sh [REPO_DIR] [NOTES.md]
#   REPO_DIR defaults to this repo's root; artifacts land in REPO_DIR/dist/.
#   Bump VER/BUILD below (and Info.plist is templated from them) before each run.
#   NOTES.md defaults to scripts/release/release-notes.md; if absent, the GitHub
#   release uses auto-generated notes.
set -euo pipefail

REPO="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
KIT="$(cd "$(dirname "$0")" && pwd)"
DIST="$REPO/dist"
APP="herdr-gui"
VER="0.1.0"
BUILD="1"
BID="com.seascheng.herdr-gui"
GITHUB_REPO="seascheng/herdr-gui"
REMOTE="https://github.com/${GITHUB_REPO}.git"

cd "$REPO"

echo "== 0/7 sanity =="
gh auth status >/dev/null || { echo "gh not authenticated"; exit 1; }
gh auth setup-git                            # git uses gh credentials for github.com
command -v create-dmg >/dev/null || { echo "create-dmg missing (brew install create-dmg)"; exit 1; }

echo "== 1/7 build =="
( cd swift-app && ./build.sh )

echo "== 2/7 app icon (icns) =="
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s        swift-app/Assets/AppIcon/app-icon.png --out "$ICONSET/icon_${s}x${s}.png"        >/dev/null
  sips -z $((s*2)) $((s*2)) swift-app/Assets/AppIcon/app-icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns -o "$DIST/AppIcon.icns" "$ICONSET" 2>/dev/null || {
  mkdir -p "$DIST" && iconutil -c icns -o "$DIST/AppIcon.icns" "$ICONSET"; }

echo "== 3/7 .app bundle =="
STAGE_PARENT="$(mktemp -d)"
STAGE="$STAGE_PARENT/${APP}.app"
mkdir -p "$STAGE/Contents/MacOS/CGhostty/lib" "$STAGE/Contents/Resources"
cp "swift-app/$APP" "$STAGE/Contents/MacOS/$APP"
# rpath is @executable_path/CGhostty/lib — preserve the layout inside the bundle
cp swift-app/CGhostty/lib/*.dylib "$STAGE/Contents/MacOS/CGhostty/lib/"
cp "$DIST/AppIcon.icns" "$STAGE/Contents/Resources/"
sed -e "s/@VER@/$VER/" -e "s/@BUILD@/$BUILD/" -e "s/@BID@/$BID/" \
    "$KIT/Info.plist" > "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
DYLIB_SIZE=$(du -sm "$STAGE/Contents/MacOS/CGhostty/lib" | cut -f1)
echo "  dylib size: ${DYLIB_SIZE}MB"
[ "$DYLIB_SIZE" -lt 90 ] || { echo "  dylib >=90MB — exceeds GitHub push limits; use git-lfs"; exit 1; }

echo "== 4/7 codesign (ad-hoc: no Developer ID on this machine) =="
codesign --force --sign - "$STAGE/Contents/MacOS/CGhostty/lib/"*.dylib
codesign --force --sign - "$STAGE"
codesign --verify --deep "$STAGE" && echo "  verify OK"

echo "== 5/7 DMG + zip =="
DMG="$DIST/${APP}-v${VER}-macos-arm64.dmg"
ZIP="$DIST/${APP}-v${VER}-macos-arm64.zip"
rm -f "$DMG" "$ZIP"
create-dmg --volname "$APP" --window-pos 200 120 --window-size 660 400 \
  --icon-size 160 --icon "${APP}.app" 180 170 --app-drop-link 480 170 \
  --hide-extension "${APP}.app" "$DMG" "$STAGE_PARENT" >/dev/null 2>&1 || \
  hdiutil create -volname "$APP" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
ditto -c -k --keepParent "$STAGE" "$ZIP"

echo "== 6/7 git commit / push =="
# Keep the vendored dylib tracked (repo must build from clone); ignore tmp/ + dist/.
sed -i '' '/^swift-app\/CGhostty\/lib\/$/d' .gitignore
grep -q '^tmp/$'  .gitignore || printf 'tmp/\n'  >> .gitignore
grep -q '^dist/$' .gitignore || printf 'dist/\n' >> .gitignore
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "$REMOTE"
else
  git remote add origin "$REMOTE"
fi
git fetch origin main
git add -A
git commit -m "${APP} v${VER}" || echo "  (nothing new to commit)"
git push -u origin main

echo "== 7/7 GitHub release =="
NOTES="${2:-$KIT/release-notes.md}"
NOTES_ARGS=(--generate-notes)
[ -f "$NOTES" ] && NOTES_ARGS=(--notes-file "$NOTES")
git tag -a "v${VER}" -m "${APP} v${VER}"
git push origin "v${VER}"
gh release create "v${VER}" "$DMG" "$ZIP" \
  --repo "$GITHUB_REPO" --title "v${VER}" "${NOTES_ARGS[@]}"

echo "DONE: https://github.com/${GITHUB_REPO}/releases/tag/v${VER}"
