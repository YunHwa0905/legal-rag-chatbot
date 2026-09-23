#!/usr/bin/env bash
# ===========================================================
# 한 번에 올리기 — 설치 → 데이터 준비 → 기동 → 검증
#
#   bash deploy/native/up.sh
#
# 백지 상태에서도, 이미 다 깔린 상태에서도 이 명령 하나면 됩니다.
# 각 단계가 멱등이라 이미 된 항목은 건너뜁니다.
#
# 옵션
#   --skip-install   설치 단계 건너뛰기 (재기동만 할 때)
#   --skip-verify    검증 단계 건너뛰기
#
# 종료는 자동화하지 않습니다 — bash deploy/native/stop.sh
# ===========================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SKIP_INSTALL=0
SKIP_VERIFY=0
for arg in "$@"; do
    case "$arg" in
        --skip-install) SKIP_INSTALL=1 ;;
        --skip-verify)  SKIP_VERIFY=1 ;;
        *) die "모르는 옵션: $arg" ;;
    esac
done

TOTAL_START=$(date +%s)

# 단계별 소요 시간을 남깁니다. 이관 예상 시간을 숫자로 잡기 위한 것입니다 —
# 나중에 "새 환경에서 몇 분 걸리나"를 물어볼 때 이 기록이 답이 됩니다.
declare -a PHASE_NAMES=()
declare -a PHASE_SECS=()

phase() {
    local name="$1"; shift
    local start; start=$(date +%s)
    echo
    printf '\033[1;35m━━ %s ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n' "$name"
    if ! "$@"; then
        echo
        die "[$name] 실패 — 위 메시지를 확인하세요"
    fi
    local elapsed=$(( $(date +%s) - start ))
    PHASE_NAMES+=("$name"); PHASE_SECS+=("$elapsed")
}

[ "$SKIP_INSTALL" = "1" ] || phase "설치"      bash "$HERE/install.sh"
phase "데이터 준비" bash "$HERE/restore.sh"
phase "기동"        bash "$HERE/start.sh"

# 검증은 실패해도 스크립트를 죽이지 않습니다. 어디까지 됐는지 보여주고
# 마지막에 결과만 알립니다.
VERIFY_RESULT="건너뜀"
if [ "$SKIP_VERIFY" != "1" ]; then
    echo
    printf '\033[1;35m━━ 검증 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
    vstart=$(date +%s)
    if bash "$HERE/verify.sh"; then VERIFY_RESULT="PASS"; else VERIFY_RESULT="FAIL"; fi
    PHASE_NAMES+=("검증"); PHASE_SECS+=($(( $(date +%s) - vstart )))
fi

TOTAL=$(( $(date +%s) - TOTAL_START ))

echo
printf '\033[1;35m━━ 요약 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
for i in "${!PHASE_NAMES[@]}"; do
    printf '  %-12s %4d초\n' "${PHASE_NAMES[$i]}" "${PHASE_SECS[$i]}"
done
printf '  %-12s %4d초\n' "합계" "$TOTAL"
echo
echo "  검증 결과 : $VERIFY_RESULT"
echo "  Frontend  : http://127.0.0.1:${FRONTEND_PORT}"
echo "  종료      : bash deploy/native/stop.sh"

[ "$VERIFY_RESULT" != "FAIL" ]
