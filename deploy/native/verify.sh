#!/usr/bin/env bash
# ===========================================================
# 합격 기준 자동 검증
#
#   bash deploy/native/verify.sh
#
# 결과를 ~/lexai-run/results.csv 에 한 줄씩 누적합니다. 환경을 오갈 때마다
# 같은 기준으로 재기 위한 것입니다 — 12회쯤 반복하면 손으로 curl 을 치는
# 방식으로는 "이번엔 좀 느렸나?" 수준의 인상 비교밖에 안 남습니다.
#
# 환경 이름을 붙이려면: FORM=gcp-shell bash deploy/native/verify.sh
# 반복 측정:             FORM=gcp-shell RUNS=5 bash deploy/native/verify.sh
# ===========================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# 검증 자체는 실패해도 끝까지 돌아야 합니다(어디까지 되는지 보려고).
set +e

FORM="${FORM:-shell-native}"
RESULTS="$RUN_DIR/results.csv"
USER_NAME="${VERIFY_USER:-verify}"
USER_PW="${VERIFY_PW:-Verify1234!}"

# 웜 응답을 몇 번 잴지. 1회만 재면 "이번엔 좀 느렸나" 수준의 인상만 남습니다.
# 계약이 요구하는 p50/p95 를 내려면 반복이 필요합니다.
RUNS="${RUNS:-1}"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '\033[0;32m  PASS\033[0m %s\n' "$*"; }
fail() { FAIL=$((FAIL+1)); printf '\033[0;31m  FAIL\033[0m %s\n' "$*"; }

now_ms() { date +%s%3N; }
secs()   { awk -v ms="$1" 'BEGIN{printf "%.1f", ms/1000}'; }

# pct <백분위> <값...>  — 최근접 순위법. 표본이 적으면 p95 는 사실상
# 최댓값이므로, 의미 있는 p95 를 보려면 RUNS 를 20 이상으로 두세요.
pct() {
    local p="$1"; shift
    printf '%s\n' "$@" | sort -n | awk -v p="$p" '
        {v[NR]=$1}
        END {
            if (NR==0) {print 0; exit}
            i=int(p/100*NR+0.9999); if (i<1) i=1; if (i>NR) i=NR
            print v[i]
        }'
}

# 프론트를 통해 호출합니다. Tomcat 을 직접 치지 않는 이유는, 프론트의
# /api 프록시까지 한 번에 검증하기 위해서입니다(브라우저와 같은 경로).
FRONT="http://127.0.0.1:${FRONTEND_PORT}"


log "1. 프론트엔드"
code=$(curl -s -o /dev/null -w '%{http_code}' "$FRONT/")
[ "$code" = "200" ] && pass "HTTP $code" || fail "HTTP $code (기대 200)"


log "2. 인증"
# 이미 있는 계정이면 400 이 정상입니다. 로그인 성공 여부로만 판정합니다.
curl -s -o /dev/null -X POST "$FRONT/api/auth/signup" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"${USER_NAME}\",\"password\":\"${USER_PW}\",\"age\":30}"

TOKEN=$(curl -s -X POST "$FRONT/api/auth/login" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"${USER_NAME}\",\"password\":\"${USER_PW}\"}" \
    | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["token"])
except Exception: print("")' 2>/dev/null)

if [ -n "$TOKEN" ]; then
    pass "로그인 · JWT 발급 (프록시 경유)"
    AUTH_OK=1
else
    fail "로그인 실패 — Tomcat 또는 프록시 확인"
    AUTH_OK=0
fi


log "3. 채팅 (콜드)"
COLD_MS=0; WARM_MS=0; P95_MS=0; SRC_COUNT=0
if [ "$AUTH_OK" = "1" ]; then
    t0=$(now_ms)
    body=$(curl -s -X POST "$FRONT/api/chat" \
        -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
        -d '{"question":"전세 보증금을 돌려받지 못하면 어떻게 해야 하나요?","lawCategory":null,"sessionId":null}')
    COLD_MS=$(( $(now_ms) - t0 ))

    SRC_COUNT=$(printf '%s' "$body" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); print(len(d.get("sources") or []))
except Exception: print(-1)' 2>/dev/null)
    ANSWER_LEN=$(printf '%s' "$body" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); print(len(d.get("answer") or ""))
except Exception: print(0)' 2>/dev/null)

    if [ "${ANSWER_LEN:-0}" -gt 50 ]; then
        pass "답변 생성 ($(secs "$COLD_MS")초, ${ANSWER_LEN}자)"
    else
        fail "답변 없음 ($(secs "$COLD_MS")초) — AI 서버 로그 확인: $LOG_DIR/ai.log"
    fi

    # 근거 문서가 0건이면 색인이 비었거나 벡터 검색이 죽은 것입니다.
    # 응답 자체는 200 으로 오기 때문에 이 항목이 없으면 놓칩니다.
    if [ "${SRC_COUNT:-0}" -gt 0 ]; then
        pass "근거 문서 ${SRC_COUNT}건 (RAG 동작)"
    else
        fail "근거 문서 0건 — 색인 또는 k-NN 확인"
    fi

    log "4. 채팅 (워밍업 후 · ${RUNS}회)"
    # 콜드 응답은 모델의 VRAM 로드가 섞여 기준선으로 쓸 수 없습니다.
    # 여기서부터가 비교 가능한 수치입니다 — 이관 전후 동등성의 좌변이 됩니다.
    samples=()
    for i in $(seq 1 "$RUNS"); do
        t0=$(now_ms)
        curl -s -o /dev/null -X POST "$FRONT/api/chat" \
            -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
            -d '{"question":"임대차 계약 갱신 거절 사유는?","lawCategory":null,"sessionId":null}'
        ms=$(( $(now_ms) - t0 ))
        samples+=("$ms")
        [ "$RUNS" -gt 1 ] && printf '       %d/%d  %s초\n' "$i" "$RUNS" "$(secs "$ms")"
    done

    WARM_MS=$(pct 50 "${samples[@]}")
    P95_MS=$(pct 95 "${samples[@]}")

    # 백엔드의 FastAPI 호출 타임아웃이 180초라 그 아래여야 의미가 있습니다.
    if [ "$P95_MS" -lt 180000 ]; then
        if [ "$RUNS" -gt 1 ]; then
            pass "p50 $(secs "$WARM_MS")초 · p95 $(secs "$P95_MS")초 (${RUNS}회)"
        else
            pass "응답 $(secs "$WARM_MS")초"
        fi
    else
        fail "p95 $(secs "$P95_MS")초 — 백엔드 타임아웃(180초) 초과 위험"
    fi
else
    fail "인증 실패로 채팅 검증 건너뜀"
fi


log "5. 데이터"
load_opensearch_creds
OS_DOCS=$(os_curl "$OS_BASE/${INDEX_NAME:-legal_documents}/_count" | grep -o '"count":[0-9]*' | cut -d: -f2)
[ "${OS_DOCS:-0}" -gt 0 ] && pass "OpenSearch ${OS_DOCS}건" || fail "OpenSearch 색인 비어 있음"

DB_USERS=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM users;" 2>/dev/null)
DB_MSGS=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM chat_message;" 2>/dev/null)
[ "${DB_MSGS:-0}" -gt 0 ] && pass "SQLite 사용자 ${DB_USERS} · 메시지 ${DB_MSGS}" \
                          || fail "SQLite 에 메시지가 기록되지 않음"

# 타임존 확인. UTC 로 기록되면 TZ 가 프로세스에 전달되지 않은 것입니다.
LAST_TS=$(sqlite3 "$DB_PATH" "SELECT created_at FROM chat_message ORDER BY id DESC LIMIT 1;" 2>/dev/null)
DB_HOUR=$(printf '%s' "$LAST_TS" | cut -d' ' -f2 | cut -d: -f1)
UTC_HOUR=$(date -u +%H)
if [ -n "$LAST_TS" ] && [ "$DB_HOUR" != "$UTC_HOUR" ]; then
    pass "타임존 (마지막 기록 $LAST_TS)"
else
    fail "시각이 UTC 로 기록된 듯합니다 ($LAST_TS) — TZ=Asia/Seoul 확인"
fi

# -----------------------------------------------------------
# 참조 무결성
#
# SQLite 는 FK 가 커넥션마다 기본 OFF 라, 걸지 않으면 스키마의 FK 가
# 선언만 되고 검사되지 않습니다. MySQL 에서 넘어오며 조용히 사라지기
# 쉬운 성질이라 여기서 확인합니다 (root-context.xml 의 dataSourceProperties).
#
# 두 가지를 봅니다.
#   1) 실제 데이터에 고아 행이 있는가 — 앱이 FK 없이 써왔다면 여기서 나옵니다
#   2) 설정이 실제로 들어있는가      — 1) 은 데이터가 적으면 통과할 수 있어서
# -----------------------------------------------------------
orphans=$(sqlite3 "$DB_PATH" "PRAGMA foreign_keys=ON; PRAGMA foreign_key_check;" 2>/dev/null | grep -c . || true)
# ★ grep -c 는 0건일 때도 "0" 을 출력하면서 종료코드 1 을 냅니다.
#   || echo 0 을 붙이면 "0" 이 두 번 나와 뒤의 정수 비교가 깨집니다.
fk_cfg=$( { grep -c 'key="foreign_keys">true' \
    "$REPO_DIR/backend_spring/src/main/webapp/WEB-INF/spring/root-context.xml" 2>/dev/null; } || true )

if [ "${orphans:-0}" -eq 0 ] && [ "${fk_cfg:-0}" -ge 1 ]; then
    pass "참조 무결성 (고아 행 0 · FK 강제 설정됨)"
elif [ "${orphans:-0}" -gt 0 ]; then
    fail "고아 행 ${orphans}건 — FK 가 강제되지 않은 채 기록됐습니다"
else
    fail "root-context.xml 에 foreign_keys=true 가 없습니다 — FK 가 검사되지 않습니다"
fi


log "6. 로그 에러"
# 앱 로그는 journal 로 갑니다. 서비스가 켜진 시점 이후만 봅니다 —
# 이전 회차의 실패가 이번 판정에 섞이면 안 되기 때문입니다.
errs=0
for unit in lexai-ai lexai-tomcat lexai-frontend; do
    systemctl is-active --quiet "$unit" || continue
    since=$(systemctl show -p ActiveEnterTimestamp --value "$unit" 2>/dev/null)
    if [ -n "$since" ]; then
        logs=$(journalctl -u "$unit" --since "$since" --no-pager 2>/dev/null)
    else
        logs=$(journalctl -u "$unit" -n 500 --no-pager 2>/dev/null)
    fi
    # DEBUG 로그에 error='null' 같은 문자열이 흔해서 단순 grep 은 오탐이
    # 심합니다(디버그 출력만으로 수십 건). 실제 문제 패턴만 셉니다.
    n=$(printf '%s' "$logs" | grep -cE "Traceback \(most recent|^Caused by:|Exception in thread|ERROR|SEVERE")
    if [ "${n:-0}" -gt 0 ]; then
        warn "${unit} 에 에러 흔적 ${n}건 — journalctl -u ${unit}"
        errs=$((errs + n))
    fi
done

# OpenSearch 는 tarball 배포라 파일 로그를 씁니다.
if [ -f "$LOG_DIR/opensearch.log" ]; then
    n=$(grep -cE "^\[.*\]\[ERROR|Exception in thread" "$LOG_DIR/opensearch.log" 2>/dev/null)
    if [ "${n:-0}" -gt 0 ]; then
        warn "opensearch.log 에 에러 흔적 ${n}건"
        errs=$((errs + n))
    fi
fi

[ "$errs" -eq 0 ] && pass "에러 없음" || warn "총 ${errs}건 — 치명적 여부는 직접 확인하세요"


# -----------------------------------------------------------
# 결과 누적
# -----------------------------------------------------------
HEADER="timestamp,form,runs,pass,fail,cold_sec,p50_sec,p95_sec,sources,os_docs,db_msgs,result"

# 열이 늘어난 뒤에도 옛 파일에 그대로 덧붙이면 칸이 밀려 읽을 수 없게 됩니다.
# 헤더가 다르면 옛 파일을 비켜두고 새로 시작합니다.
if [ -f "$RESULTS" ] && [ "$(head -1 "$RESULTS")" != "$HEADER" ]; then
    mv "$RESULTS" "${RESULTS%.csv}-$(date +%Y%m%d-%H%M%S).csv"
    warn "결과 형식이 바뀌어 이전 기록을 따로 보관했습니다"
fi
[ -f "$RESULTS" ] || echo "$HEADER" > "$RESULTS"

VERDICT=$([ "$FAIL" -eq 0 ] && echo PASS || echo FAIL)
echo "$(date '+%Y-%m-%d %H:%M:%S'),${FORM},${RUNS},${PASS},${FAIL},$(secs "$COLD_MS"),$(secs "$WARM_MS"),$(secs "$P95_MS"),${SRC_COUNT},${OS_DOCS:-0},${DB_MSGS:-0},${VERDICT}" >> "$RESULTS"

echo
log "결과: ${PASS} PASS / ${FAIL} FAIL → ${VERDICT}"
echo "  누적 기록: $RESULTS"
column -s, -t "$RESULTS" 2>/dev/null | tail -5

[ "$FAIL" -eq 0 ]
