#!/bin/bash
# 打可分发版：release build + universal binary (arm64 + x86_64) + ad-hoc 签名 + zip
#
# 注意：这是 ad-hoc 签名，不是 Apple Developer ID 签名。
# 同事第一次打开会被 Gatekeeper 拦，需要"右键 → 打开"两次，
# 或在终端跑：xattr -dr com.apple.quarantine /Applications/ClaudeHistoryViewer.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/ClaudeHistoryViewer.app"

VERSION="0.3.0"
ZIP_NAME="ClaudeHistoryViewer-${VERSION}-universal.zip"
RES_BUNDLE_NAME="ClaudeHistoryViewer_ClaudeHistoryViewer.bundle"

cd "$ROOT"

echo "==> Cleaning dist/"
rm -rf "$DIST"
mkdir -p "$DIST"

echo "==> Building arm64 (release)"
swift build -c release --arch arm64

echo "==> Building x86_64 (release)"
swift build -c release --arch x86_64

ARM_BIN="$ROOT/.build/arm64-apple-macosx/release/ClaudeHistoryViewer"
X86_BIN="$ROOT/.build/x86_64-apple-macosx/release/ClaudeHistoryViewer"

echo "==> Lipo into universal"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/ClaudeHistoryViewer" "$ARM_BIN" "$X86_BIN"
lipo -info "$APP/Contents/MacOS/ClaudeHistoryViewer"

echo "==> Copying localized resource bundle into .app"
RES_BUNDLE_SRC="$ROOT/.build/arm64-apple-macosx/release/$RES_BUNDLE_NAME"
if [ ! -d "$RES_BUNDLE_SRC" ]; then
  echo "ERROR: $RES_BUNDLE_SRC not found"
  exit 1
fi
cp -R "$RES_BUNDLE_SRC" "$APP/Contents/Resources/"

echo "==> Copying app icon"
cp "$ROOT/scripts/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>           <string>ClaudeHistoryViewer</string>
  <key>CFBundleIconFile</key>             <string>AppIcon</string>
  <key>CFBundleIdentifier</key>           <string>local.claudehistory.viewer</string>
  <key>CFBundleName</key>                 <string>Claude History Viewer</string>
  <key>CFBundleDisplayName</key>          <string>Claude History Viewer</string>
  <key>CFBundlePackageType</key>          <string>APPL</string>
  <key>CFBundleShortVersionString</key>   <string>${VERSION}</string>
  <key>CFBundleVersion</key>              <string>1</string>
  <key>LSMinimumSystemVersion</key>       <string>14.0</string>
  <key>NSHighResolutionCapable</key>      <true/>
  <key>NSPrincipalClass</key>             <string>NSApplication</string>
  <key>CFBundleDevelopmentRegion</key>    <string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>zh-Hans</string>
    <string>ja</string>
    <string>ko</string>
    <string>de</string>
  </array>
</dict>
</plist>
PLIST

echo "==> Ad-hoc codesign (no Developer ID)"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP" || true

echo "==> Zipping"
cd "$DIST"
# ditto 保留扩展属性 / 签名，比普通 zip 更适合 .app
ditto -c -k --sequesterRsrc --keepParent "ClaudeHistoryViewer.app" "$ZIP_NAME"

echo
echo "============================================================"
echo "DONE"
echo "  App: $APP"
echo "  Zip: $DIST/$ZIP_NAME"
echo "  Size: $(du -h "$DIST/$ZIP_NAME" | cut -f1)"
echo "============================================================"
echo
echo "把 $ZIP_NAME 发给同事。同事的操作："
echo "  1. 解压 → 把 ClaudeHistoryViewer.app 拖到 /Applications/"
echo "  2. 首次打开：右键 → 打开 → 在弹窗里再次点 \"打开\""
echo "     （ad-hoc 签名不被 Gatekeeper 信任，必须手动放行）"
echo "  3. 或在终端跑："
echo "     xattr -dr com.apple.quarantine /Applications/ClaudeHistoryViewer.app"
echo
echo "需要 macOS 14+。Intel / Apple Silicon 都可用（universal binary）。"
