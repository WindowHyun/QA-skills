#!/usr/bin/env bash
# QA 리포트 작성용 컨텍스트 수집.
#
# 사용법:
#   collect_context.sh                      # 기본 브랜치 대비 현재 브랜치 변경분
#   collect_context.sh --base origin/main   # 비교 기준 지정
#   collect_context.sh --path src/payment   # 특정 경로의 코드/테스트 현황
#
# 출력: 변경 파일 목록, 디프 통계, 변경된 심볼 후보, 관련 테스트 파일 후보.
# 이 출력은 분석의 출발점일 뿐이다. 실제 파일을 열어 로직을 읽는 단계를 대체하지 않는다.

set -uo pipefail

BASE=""
TARGET_PATH=""

while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:-}"; shift 2 ;;
    --path) TARGET_PATH="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "알 수 없는 옵션: $1" >&2; exit 1 ;;
  esac
done

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "git 저장소가 아닙니다. --path 로 경로를 직접 지정해 분석하세요." >&2
  [ -z "$TARGET_PATH" ] && exit 1
fi

section() { printf '\n===== %s =====\n' "$1"; }

# 테스트 파일로 보이는 경로인지 판단
is_test_path() {
  case "$1" in
    *test*|*Test*|*spec*|*Spec*|*__tests__*|*/tests/*) return 0 ;;
    *) return 1 ;;
  esac
}

if [ -n "$TARGET_PATH" ]; then
  section "대상 경로: $TARGET_PATH"
  find "$TARGET_PATH" -type f \
    ! -path '*/node_modules/*' ! -path '*/.git/*' ! -path '*/dist/*' ! -path '*/build/*' \
    | head -200

  section "이 경로의 테스트 파일"
  find "$TARGET_PATH" -type f \( -name '*test*' -o -name '*spec*' -o -name '*Test*' \) \
    ! -path '*/node_modules/*' | head -50

  section "최근 변경 이력"
  git log --oneline -15 -- "$TARGET_PATH" 2>/dev/null
  exit 0
fi

# --- 디프 기준 분석 ---
if [ -z "$BASE" ]; then
  for candidate in origin/main origin/master origin/develop main master; do
    if git rev-parse --verify "$candidate" >/dev/null 2>&1; then BASE="$candidate"; break; fi
  done
fi

if [ -z "$BASE" ]; then
  echo "비교 기준을 찾지 못했습니다. --base <ref> 로 지정하세요." >&2
  exit 1
fi

MERGE_BASE="$(git merge-base "$BASE" HEAD 2>/dev/null || echo "$BASE")"

section "비교 기준"
echo "base : $BASE ($MERGE_BASE)"
echo "head : $(git rev-parse --short HEAD) $(git log -1 --pretty=%s)"

section "변경 통계"
git diff --stat "$MERGE_BASE"...HEAD
if [ -n "$(git status --porcelain)" ]; then
  echo "(커밋되지 않은 변경 있음)"
  git status --short
fi

CHANGED="$(git diff --name-only "$MERGE_BASE"...HEAD; git diff --name-only HEAD)"
CHANGED="$(printf '%s\n' "$CHANGED" | sort -u | sed '/^$/d')"

section "변경된 소스 파일"
SRC_FILES=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if is_test_path "$f"; then continue; fi
  SRC_FILES="${SRC_FILES}${f}"$'\n'
  echo "$f"
done <<< "$CHANGED"

section "변경에 포함된 테스트 파일"
printf '%s\n' "$CHANGED" | while IFS= read -r f; do
  [ -z "$f" ] && continue
  is_test_path "$f" && echo "$f"
done

section "변경된 함수·심볼 후보"
{
  # 디프 훅 헤더의 함수 컨텍스트
  git diff -U0 "$MERGE_BASE"...HEAD | grep -E '^@@.*@@ .+' | sed 's/^@@[^@]*@@ *//'
  # 추가·삭제된 정의부 (언어 무관 휴리스틱)
  git diff -U0 "$MERGE_BASE"...HEAD | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' \
    | grep -E '(function |def |class |interface |type |struct |fun |func |const [A-Za-z_]+ *= *\(|=> *\{)'
} | sed 's/^[+-]//' | sed 's/^[[:space:]]*//' | sort -u | head -60

section "관련 테스트 파일 후보 (파일명 매칭)"
printf '%s\n' "$SRC_FILES" | while IFS= read -r f; do
  [ -z "$f" ] && continue
  stem="$(basename "$f")"; stem="${stem%%.*}"
  [ ${#stem} -lt 3 ] && continue
  matches="$(git ls-files "*${stem}*" | while IFS= read -r c; do is_test_path "$c" && echo "$c"; done)"
  [ -n "$matches" ] && { echo "[$f]"; printf '%s\n' "$matches" | sed 's/^/  /'; }
done

section "다음 할 일"
cat <<'TIP'
1) 위 소스 파일들을 직접 열어 진입점 / 데이터 흐름 / 분기 / 상태를 파악한다.
2) 변경된 공개 심볼의 호출 지점을 grep 으로 찾아 회귀 영향 범위를 만든다.
3) references/risk-checklist.md 를 코드에 대입해 실제 성립하는 위험만 추린다.
TIP
