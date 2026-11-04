#!/bin/bash
# KakaoBannerHider 빌드 스크립트
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="KakaoBannerHider"
APP="$APP_NAME.app"
BUILD=".build"
mkdir -p "$BUILD"

echo "==> 컴파일"
swiftc -O \
  -module-cache-path "$BUILD/mc" \
  -target arm64-apple-macos13.0 \
  -framework AppKit \
  -framework ApplicationServices \
  -o "$BUILD/$APP_NAME" \
  Sources/main.swift

echo "==> 앱 번들 구성"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Scripts/usage_fetcher.py "$APP/Contents/Resources/usage_fetcher.py"
chmod 644 "$APP/Contents/Resources/usage_fetcher.py"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ko</string>
    <key>CFBundleExecutable</key>
    <string>KakaoBannerHider</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.bear2u.kakaobannerhider</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>KakaoBannerHider</string>
    <key>CFBundleDisplayName</key>
    <string>카톡 배너 가리기</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> 애드혹 서명"
codesign --force --sign - --identifier "io.github.bear2u.kakaobannerhider" "$APP" >/dev/null 2>&1 || true

echo "==> 완료: $APP"
