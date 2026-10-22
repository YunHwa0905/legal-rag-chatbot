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

# 상태 파일 — bootstrap 에서 이어 왔으면(LEXAI_RUN_ID) 같은 기록을 이어 쓰고,
# 사람이 up.sh 를 따로 돌린 경우에는 새 기록으로 시작합니다.
if [ -z "${LEXAI_RUN_ID:-}" ]; then
    rm -f "$STATUS_FILE"
    LEXAI_RUN_ID="$(date +%Y%m%d-%H%M%S)"
    status_set run_id="$LEXAI_RUN_ID" operation=deploy state=running started_at="$(now_iso)" \
               data_check=NA verify=NA
fi
status_set phase=up
trap '_rc=$?; if [ "$_rc" -ne 0 ]; then status_set state=failed exit_code="$_rc" finished_at="$(now_iso)"; fi' EXIT

# 단계별 소요 시간을 남깁니다. 이관 예상 시간을 숫자로 잡기 위한 것입니다 —
# 나중에 "새 환경에서 몇 분 걸리나"를 물어볼 때 이 기록이 답이 됩니다.
declare -a PHASE_NAMES=()
declare -a PHASE_SECS=()

phase() {
    local name="$1"; shift
    local start; start=$(date +%s)
    echo
    printf '%s━━ %s ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$C_HEAD" "$name" "$C_OFF"
    status_set phase="$name"
    if ! "$@"; then
        echo
        # die 를 쓰지 않습니다 — 하위 스크립트가 남긴 last_error(진짜 원인)를
        # "[단계] 실패" 문구로 덮어쓰지 않기 위해서입니다.
        status_set failed_phase="$name"
        printf '%s  FATAL%s [%s] 실패 — 위 메시지를 확인하세요\n' "$C_ERR" "$C_OFF" "$name" >&2
        exit 1
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
    printf '%s━━ 검증 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$C_HEAD" "$C_OFF"
    status_set phase=검증
    vstart=$(date +%s)
    if bash "$HERE/verify.sh"; then VERIFY_RESULT="PASS"; else VERIFY_RESULT="FAIL"; fi
    PHASE_NAMES+=("검증"); PHASE_SECS+=($(( $(date +%s) - vstart )))
fi

TOTAL=$(( $(date +%s) - TOTAL_START ))

echo
printf '%s━━ 요약 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$C_HEAD" "$C_OFF"
for i in "${!PHASE_NAMES[@]}"; do
    printf '  %-12s %4d초\n' "${PHASE_NAMES[$i]}" "${PHASE_SECS[$i]}"
done
printf '  %-12s %4d초\n' "합계" "$TOTAL"
echo
echo "  데이터 보존 : $DATA_RESULT"
echo "  검증 결과 : $VERIFY_RESULT"
echo "  Frontend  : http://127.0.0.1:${FRONTEND_PORT}"
echo "  종료      : bash deploy/native/stop.sh"

case "$VERIFY_RESULT" in
    PASS) status_set verify=PASS ;;
    FAIL) status_set verify=FAIL ;;
    *)    status_set verify=SKIPPED ;;
esac
status_set total_seconds="$TOTAL"

# ★ 이관 모드(bootstrap NO_UPDATE=1)는 VERIFY_GATE=0 으로 부릅니다.
#   오케스트레이터는 종료 코드(또는 status.json 의 state)로 이관 전체의 성패를
#   기록합니다. 데이터 보존과 기동은 위에서 이미 실패 시 멈추므로, 여기까지
#   왔다면 이관 자체는 성공입니다. 응답 시간 같은 검증 결과는 FAIL 이어도
#   이관 실패로 기록하지 않고 크게 경고만 남깁니다(results.csv · status.json verify).
if [ "$VERIFY_RESULT" = "FAIL" ] && [ "${VERIFY_GATE:-1}" = "0" ]; then
    warn "검증 FAIL — 이관(데이터 보존 · 기동)은 성공으로 끝냅니다. 원인: ~/lexai-run/results.csv"
    status_set state=success phase=done exit_code=0 finished_at="$(now_iso)"
    exit 0
fi
if [ "$VERIFY_RESULT" = "FAIL" ]; then exit 1; fi
status_set state=success phase=done exit_code=0 finished_at="$(now_iso)"
