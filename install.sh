#!/bin/bash
# KakaoBannerHider 설치: /Applications 로 복사하고 실행
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="KakaoBannerHider"
SRC="$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"

if [ ! -d "$SRC" ]; then
  echo "빌드된 앱이 없습니다. 먼저 ./build.sh 를 실행하세요." >&2
  exit 1
fi

echo "==> 종료 중 (실행 중이면)"
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5

echo "==> $DEST 로 복사"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
codesign --force --sign - --identifier "io.github.bear2u.kakaobannerhider" "$DEST" >/dev/null 2>&1 || true

echo "==> 실행"
open "$DEST"

cat <<EOF

설치 완료. 메뉴 막대의 AD 아이콘을 확인하세요.
처음 실행하면 '손쉬운 사용' 권한을 물어봅니다 → 허용해 주세요.
(시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용)

EOF
