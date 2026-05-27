#!/bin/bash
# 把 swift build 出来的可执行文件包成正经的 macOS .app bundle，
# 这样 open 之后会在 Dock 里出现、窗口会正常聚焦。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/ClaudeHistoryViewer.app"
BIN_SRC="$ROOT/.build/debug/ClaudeHistoryViewer"

cd "$ROOT"
swift build

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN_SRC" "$APP/Contents/MacOS/ClaudeHistoryViewer"

# 复制 SPM 生成的本地化资源 bundle（含 .lproj/Localizable.strings）
RES_BUNDLE="$ROOT/.build/debug/ClaudeHistoryViewer_ClaudeHistoryViewer.bundle"
if [ -d "$RES_BUNDLE" ]; then
  cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>           <string>ClaudeHistoryViewer</string>
  <key>CFBundleIdentifier</key>           <string>local.claudehistory.viewer</string>
  <key>CFBundleName</key>                 <string>Claude History Viewer</string>
  <key>CFBundleDisplayName</key>          <string>Claude History Viewer</string>
  <key>CFBundlePackageType</key>          <string>APPL</string>
  <key>CFBundleShortVersionString</key>   <string>0.3.0</string>
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

echo "Built: $APP"
