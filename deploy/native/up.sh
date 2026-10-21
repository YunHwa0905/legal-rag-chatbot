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
# 환경변수로도 받습니다. bootstrap 이관 모드가 이 값으로 검증을 끕니다.
SKIP_VERIFY="${SKIP_VERIFY:-0}"
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
# 이관해 온 DB 가 원본과 같은지, 서비스가 DB 에 쓰기 전에 확인합니다.
# (원본 지문이 없는 일반 배포에서는 그냥 지나갑니다)
DATA_RESULT="해당 없음"
if [ -f "$DATA_DIR/source-fingerprint.tsv" ]; then
    phase "데이터 보존 확인" bash "$HERE/check-data.sh"
    DATA_RESULT="PASS"
fi
phase "기동"        bash "$HERE/start.sh"

# 검증은 실패해도 스크립트를 죽이지 않습니다. 어디까지 됐는지 보여주고
# 마지막에 결과만 알립니다.
VERIFY_RESULT="건너뜀"
if [ "$SKIP_VERIFY" = "1" ]; then
    echo
    ok "검증 건너뜀 — 수동 실행: bash deploy/native/verify.sh (verify 계정 · 채팅이 DB 에 남습니다)"
else
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
echo "  데이터 보존 : $DATA_RESULT"
echo "  검증 결과 : $VERIFY_RESULT"
echo "  Frontend  : http://127.0.0.1:${FRONTEND_PORT}"
echo "  종료      : bash deploy/native/stop.sh"

# ★ 이관 모드(bootstrap NO_UPDATE=1)는 VERIFY_GATE=0 으로 부릅니다.
#   이관 도구(Beetle transx postCmd)는 종료 코드만 보고 이관 전체의 성패를
#   기록합니다. 데이터 보존과 기동은 위에서 이미 실패 시 멈추므로, 여기까지
#   왔다면 이관 자체는 성공입니다. 응답 시간 같은 검증 결과는 FAIL 이어도
#   이관 실패로 기록하지 않고 크게 경고만 남깁니다(results.csv 에도 남습니다).
if [ "$VERIFY_RESULT" = "FAIL" ] && [ "${VERIFY_GATE:-1}" = "0" ]; then
    warn "검증 FAIL — 이관(데이터 보존 · 기동)은 성공으로 끝냅니다. 원인: ~/lexai-run/results.csv"
    exit 0
fi
[ "$VERIFY_RESULT" != "FAIL" ]
