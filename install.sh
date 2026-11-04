#!/bin/bash
#
# KakaoBannerHider 설치 스크립트
#   빌드 → /Applications 설치 → LaunchServices 등록 → 실행 까지 한 번에.
#
# 사용법:
#   ./install.sh                # 빌드 + 설치 + 실행
#   ./install.sh --no-build     # 이미 빌드된 앱만 설치 (빌드 생략)
#   ./install.sh --no-launch    # 설치만 하고 실행은 하지 않음
#   ./install.sh --uninstall    # 앱과 설정 제거
#
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="KakaoBannerHider"
BUNDLE_ID="io.github.bear2u.kakaobannerhider"
SRC="$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"
PREFS="$HOME/Library/Preferences/$BUNDLE_ID.plist"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

DO_BUILD=1
DO_LAUNCH=1
DO_UNINSTALL=0

usage() {
  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
  case "$arg" in
    --no-build)   DO_BUILD=0 ;;
    --no-launch)  DO_LAUNCH=0 ;;
    --uninstall)  DO_UNINSTALL=1 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "알 수 없는 옵션: $arg (--help 참고)" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------- 제거
if [ "$DO_UNINSTALL" = 1 ]; then
  echo "==> 종료"
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.3
  echo "==> $DEST 삭제"
  rm -rf "$DEST"
  echo "==> 설정 삭제"
  rm -f "$PREFS"
  echo "==> 완료. Launchpad에서 사라지기까지 몇 초 걸릴 수 있습니다."
  exit 0
fi

# ---------------------------------------------------------------- 빌드
if [ "$DO_BUILD" = 1 ]; then
  echo "==> 빌드"
  ./build.sh
fi

if [ ! -d "$SRC" ]; then
  echo "빌드된 앱이 없습니다. ./install.sh (빌드 포함) 로 다시 실행하세요." >&2
  exit 1
fi

# ---------------------------------------------------------------- 설치
echo "==> 실행 중인 인스턴스 종료"
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5

echo "==> $DEST 로 설치"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# 설치본은 build.sh가 이미 애드혹 서명한 그대로 쓴다.
# (다시 서명하면 코드 해시가 바뀌어 손쉬운 사용 권한이 초기화된다)
codesign --verify --deep --strict "$DEST"

echo "==> LaunchServices 등록 (Launchpad/응용 프로그램에 표시)"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$DEST" || true
fi

if [ "$DO_LAUNCH" = 1 ]; then
  echo "==> 실행"
  open "$DEST"
fi

cat <<EOF

설치 완료: $DEST
  - Launchpad / 응용 프로그램에서 "$APP_NAME" 를 클릭해 실행할 수 있습니다.
  - 메뉴 막대 오른쪽 위에 AD(빗금) 아이콘이 생깁니다. 창은 열리지 않습니다.

처음 실행(또는 새로 빌드한 뒤)에는 '손쉬운 사용' 권한을 한 번 허용해야 합니다.
  시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용 → $APP_NAME

제거: ./install.sh --uninstall

EOF
