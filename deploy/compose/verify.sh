#!/usr/bin/env bash
# ===========================================================
# 합격 기준 자동 검증 — Docker Compose 형태
#
#   bash ~/lexai-compose/verify.sh
#   FORM=aws-b RUNS=5 bash ~/lexai-compose/verify.sh
#
# 네이티브의 deploy/native/verify.sh 와 같은 항목을 같은 형식으로 판정해
# 같은 CSV 에 누적합니다. 두 형태의 수치를 나란히 비교하기 위한 것이라
# 판정 기준과 열 구성을 일부러 맞춰 두었습니다.
#
# ★ 이 스크립트는 저장소와 독립적으로 동작합니다. 컨테이너 형태의 타겟에는
#   소스가 없으므로 common.sh 를 source 하지 않고 필요한 것을 직접 갖습니다.
#   deploy.sh 가 이 파일을 함께 받아 배포 디렉터리에 둡니다.
#
# 환경변수
#   FORM    결과에 붙일 환경 이름       기본 docker-compose
#   RUNS    웜 응답 반복 횟수           기본 1
#   ALLOW_EMPTY_INDEX=1  색인이 비어 있어도 FAIL 로 보지 않음 (기동 검증용)
# ===========================================================

set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FORM="${FORM:-docker-compose}"
RUNS="${RUNS:-1}"
ALLOW_EMPTY_INDEX="${ALLOW_EMPTY_INDEX:-0}"
INDEX_NAME="${INDEX_NAME:-legal_documents}"
RESULTS="${RESULTS:-$HOME/lexai-run/results.csv}"
USER_NAME="${VERIFY_USER:-verify}"
USER_PW="${VERIFY_PW:-Verify1234!}"
FRONT="http://127.0.0.1:${FRONTEND_PORT:-80}"

mkdir -p "$(dirname "$RESULTS")"

if [ -t 1 ]; then
    C_HEAD=$'\033[1;35m'; C_OK=$'\033[0;32m'
    C_WARN=$'\033[0;33m'; C_ERR=$'\033[0;31m'; C_OFF=$'\033[0m'
else
    C_HEAD=""; C_OK=""; C_WARN=""; C_ERR=""; C_OFF=""
fi
log()  { printf '%s[verify]%s %s\n' "$C_HEAD" "$C_OFF" "$*"; }
warn() { printf '%s  WARN%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '%s  PASS%s %s\n' "$C_OK" "$C_OFF" "$*"; }
fail() { FAIL=$((FAIL+1)); printf '%s  FAIL%s %s\n' "$C_ERR" "$C_OFF" "$*"; }

now_ms() { date +%s%3N; }
secs()   { awk -v ms="$1" 'BEGIN{printf "%.1f", ms/1000}'; }

# pct <백분위> <값...> — 최근접 순위법. 표본이 적으면 p95 는 사실상
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

# docker 를 sudo 없이 쓸 수 있는지 한 번만 판정합니다.
if docker info >/dev/null 2>&1; then DOCKER="docker"; else DOCKER="sudo docker"; fi
compose() { $DOCKER compose -f docker-compose.yml -f docker-compose.registry.yml "$@"; }

# ★ </dev/null 은 필수입니다 — docker compose exec 는 -T 여도 stdin 을 읽습니다.
dex() { compose exec -T "$@" </dev/null 2>/dev/null; }

OS_PW="$( { grep -E '^OPENSEARCH_PASSWORD=' .env | tail -1 | cut -d= -f2-; } || true )"
os() { dex opensearch curl -sk -u "admin:${OS_PW}" "$@"; }
OS_BASE="https://127.0.0.1:9200"
DB_IN="/var/lib/lexai/lexai.db"
sq() { dex tomcat sqlite3 "$DB_IN" "$1" | tr -d '\r'; }


log "1. 프론트엔드"
code=$(curl -s -o /dev/null -w '%{http_code}' "$FRONT/")
if [ "$code" = "200" ]; then pass "HTTP $code"; else fail "HTTP $code (기대 200)"; fi


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
    fail "로그인 실패 — tomcat 또는 프록시 확인"
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
        fail "답변 없음 ($(secs "$COLD_MS")초) — docker compose logs ai"
    fi

    # 근거 문서가 0건이면 색인이 비었거나 벡터 검색이 죽은 것입니다.
    # 응답 자체는 200 으로 오기 때문에 이 항목이 없으면 놓칩니다.
    if [ "${SRC_COUNT:-0}" -gt 0 ]; then
        pass "근거 문서 ${SRC_COUNT}건 (RAG 동작)"
    elif [ "$ALLOW_EMPTY_INDEX" = "1" ]; then
        warn "근거 문서 0건 — 빈 색인이라 예상된 결과입니다 (ALLOW_EMPTY_INDEX=1)"
    else
        fail "근거 문서 0건 — 색인 또는 k-NN 확인"
    fi

    log "4. 채팅 (워밍업 후 · ${RUNS}회)"
    # 콜드 응답은 모델의 VRAM 로드가 섞여 기준선으로 쓸 수 없습니다.
    # 여기서부터가 이관 전후 동등성의 좌변이 됩니다.
    samples=()
    for i in $(seq 1 "$RUNS"); do
        t0=$(now_ms)
        curl -s -o /dev/null -X POST "$FRONT/api/chat" \
            -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
            -d '{"question":"임대차 계약 갱신 거절 사유는?","lawCategory":null,"sessionId":null}'
        ms=$(( $(now_ms) - t0 ))
        samples+=("$ms")
        if [ "$RUNS" -gt 1 ]; then printf '       %d/%d  %s초\n' "$i" "$RUNS" "$(secs "$ms")"; fi
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
OS_DOCS=$( { os "$OS_BASE/${INDEX_NAME}/_count" | grep -o '"count":[0-9]*' | cut -d: -f2; } || true )
if [ "${OS_DOCS:-0}" -gt 0 ] 2>/dev/null; then
    pass "OpenSearch ${OS_DOCS}건"
elif [ "$ALLOW_EMPTY_INDEX" = "1" ]; then
    # "비어 있음"과 "아예 없음"은 다릅니다. 매핑까지 확인해야 빈 색인이
    # 제대로 만들어졌는지 알 수 있습니다.
    if os -o /dev/null -w '%{http_code}' "$OS_BASE/${INDEX_NAME}" | grep -q 200; then
        warn "OpenSearch 0건 — 빈 색인이라 예상된 결과입니다 (매핑은 존재)"
    else
        fail "색인이 아예 없습니다 — 빈 색인 생성이 실패한 상태입니다"
    fi
else
    fail "OpenSearch 색인 비어 있음"
fi

DB_USERS=$(sq "SELECT COUNT(*) FROM users;")
DB_MSGS=$(sq "SELECT COUNT(*) FROM chat_message;")
if [ "${DB_MSGS:-0}" -gt 0 ] 2>/dev/null; then
    pass "SQLite 사용자 ${DB_USERS} · 메시지 ${DB_MSGS}"
else
    fail "SQLite 에 메시지가 기록되지 않음"
fi

# 타임존 확인. UTC 로 기록되면 TZ 가 컨테이너에 전달되지 않은 것입니다.
LAST_TS=$(sq "SELECT created_at FROM chat_message ORDER BY id DESC LIMIT 1;")
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
# 쉬운 성질이라 여기서 확인합니다.
#
# 네이티브는 root-context.xml 파일을 직접 읽어 설정 존재도 확인하지만,
# 컨테이너에는 소스가 없어 WAR 안에 있습니다. 대신 실행 중인 앱이 실제로
# FK 를 강제하는지 — 고아 행이 있는지 — 로 판정합니다.
# -----------------------------------------------------------
orphans=$(dex tomcat sqlite3 "$DB_IN" "PRAGMA foreign_keys=ON; PRAGMA foreign_key_check;" | grep -c . )
if [ "${orphans:-0}" -eq 0 ]; then
    pass "참조 무결성 (고아 행 0)"
else
    fail "고아 행 ${orphans}건 — FK 가 강제되지 않은 채 기록됐습니다"
fi


log "6. 로그 에러"
# 서비스가 켜진 시점 이후만 봅니다 — 이전 회차의 실패가 이번 판정에
# 섞이면 안 되기 때문입니다.
errs=0
for svc in ai tomcat frontend opensearch; do
    since=$(compose ps --format '{{.Service}} {{.RunningFor}}' 2>/dev/null | awk -v s="$svc" '$1==s {print}')
    [ -n "$since" ] || continue
    logs=$(compose logs --no-color --since 1h "$svc" 2>/dev/null)
    # DEBUG 로그에 error='null' 같은 문자열이 흔해서 단순 grep 은 오탐이
    # 심합니다. 실제 문제 패턴만 셉니다.
    n=$(printf '%s' "$logs" | grep -cE "Traceback \(most recent|^Caused by:|Exception in thread|\bERROR\b|\bSEVERE\b")
    if [ "${n:-0}" -gt 0 ]; then
        warn "${svc} 에 에러 흔적 ${n}건 — docker compose logs ${svc}"
        errs=$((errs + n))
    fi
done
if [ "$errs" -eq 0 ]; then
    pass "에러 없음"
else
    warn "총 ${errs}건 — 치명적 여부는 직접 확인하세요"
fi


# -----------------------------------------------------------
# 결과 누적 — 네이티브와 같은 형식, 같은 파일
# -----------------------------------------------------------
HEADER="timestamp,form,runs,pass,fail,cold_sec,p50_sec,p95_sec,sources,os_docs,db_msgs,result"
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
column -s, -t "$RESULTS" 2>/dev/null | tail -6

[ "$FAIL" -eq 0 ]
