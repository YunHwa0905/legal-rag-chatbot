#!/usr/bin/env bash
# ===========================================================
# 데이터 보존 확인 — 이관해 온 DB 가 원본과 같은지
#
#   bash deploy/native/check-data.sh
#
# up.sh 가 "데이터 준비" 직후 · "기동" 전에 자동으로 부릅니다.
# bootstrap.sh 가 이관 패키지의 지문(data-fingerprint.tsv)을
# ~/lexai-data/source-fingerprint.tsv 로 놓아 둔 경우에만 동작합니다.
#
# 서비스 기동 전에 재는 이유: verify.sh 가 verify 계정과 채팅을 DB 에
# 더하므로, 그 뒤에 세면 원본과 항상 달라 보입니다.
#
# 통과하면 지문 파일을 source-fingerprint.checked-<시각>.tsv 로 바꿔 둡니다.
# 같은 VM 에서 up.sh 를 다시 돌릴 때(이미 verify 데이터가 더해진 뒤)
# 같은 비교를 반복해 거짓 FAIL 이 나지 않게 하기 위해서입니다.
# ===========================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

WANT="$DATA_DIR/source-fingerprint.tsv"
REPORT="$RUN_DIR/data-check.txt"

# -----------------------------------------------------------
# 런타임 비교 (경고만) — 원본과 같은 Ollama 버전 · 모델로 떴는지
#
# 데이터가 아니라 "같은 조건에서 답하는가" 의 문제라 실패로 보지 않습니다.
# 다르면 답변 비교(동등성) 때 변수가 되므로 기록을 남깁니다.
# -----------------------------------------------------------
RT="$DATA_DIR/source-runtime.txt"
if [ -f "$RT" ]; then
    log "런타임 비교 (원본 ↔ 이 VM)"
    rt_ok=yes
    want_v="$(awk '$1=="ollama"{print $2}' "$RT")"
    have_v="$(ollama_version)"
    if [ "$want_v" = "$have_v" ]; then ok "Ollama ${have_v} (원본과 같음)"
    else warn "Ollama 버전 다름 — 원본 ${want_v:-?} / 이 VM ${have_v:-?}"; rt_ok=no; fi
    have_models="$(ollama list 2>/dev/null | awk 'NR>1 {print $1" "$2}' || true)"
    while read -r _ name id; do
        [ -n "$name" ] || continue
        got="$(printf '%s\n' "$have_models" | awk -v n="$name" '$1==n {print $2}')"
        if [ "$got" = "$id" ]; then ok "모델 $name ($id)"
        else warn "모델 $name 다름 — 원본 $id / 이 VM ${got:-없음}"; rt_ok=no; fi
    done < <(awk '$1=="model"' "$RT")
    status_set runtime_match="$rt_ok"
    mv "$RT" "$DATA_DIR/source-runtime.checked-$(date +%Y%m%d-%H%M%S).txt"
fi

if [ ! -f "$WANT" ]; then
    ok "비교할 원본 지문이 없습니다 — 건너뜀 (이관이 아닌 배포)"
    exit 0
fi
[ -f "$DB_PATH" ] || die "DB 파일이 없습니다: $DB_PATH"

log "데이터 보존 확인 (원본 패키지 ↔ 이 VM)"
if check_data_fingerprint "$DB_PATH" "$WANT" | tee "$REPORT.tmp"; then
    result=PASS
else
    result=FAIL
fi
{ echo "데이터 보존 확인 : $result"; echo "시각 : $(date '+%Y-%m-%d %H:%M:%S %Z')"; echo "DB   : $DB_PATH"; echo; cat "$REPORT.tmp"; } > "$REPORT"
rm -f "$REPORT.tmp"

status_set data_check="$result" data_check_report="$REPORT"
if [ "$result" = "PASS" ]; then
    mv "$WANT" "$DATA_DIR/source-fingerprint.checked-$(date +%Y%m%d-%H%M%S).tsv"
    ok "데이터 보존 PASS — 모든 테이블의 행 수와 내용이 원본과 같습니다 (기록: $REPORT)"
else
    die "데이터 보존 FAIL — 원본과 다른 테이블이 있습니다 (기록: $REPORT)"
fi
