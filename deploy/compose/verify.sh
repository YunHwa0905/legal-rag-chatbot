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

# ★ 네이티브 검증(common.sh 가 TZ=Asia/Seoul 을 export)과 같은 시간대로
#   기록해야 한 표에서 행 순서가 맞습니다. 섞이면 9시간 차이로 뒤집혀
#   어느 회차가 먼저인지 읽을 수 없게 됩니다.
export TZ="${TZ:-$( { grep -E '^TZ=' .env 2>/dev/null | tail -1 | cut -d= -f2-; } || true )}"
export TZ="${TZ:-Asia/Seoul}"

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

# -----------------------------------------------------------
# 추론 결과 비교 — 네이티브 verify.sh 와 같은 형식으로 남깁니다.
#
# 계약은 이관 전후의 "추론 결과 일치"를 요구하는데, 지금까지는 응답을
# -o /dev/null 로 버려서 비교할 원본이 남지 않았습니다.
#
# 웜 응답의 답변 해시를 회차마다 비교하는 이유는, 결정적 설정이 실제로
# 걸려 있는지 설정 파일만 봐서는 알 수 없기 때문입니다. 같은 질문에 매번
# 다른 답이 나오면 이관 전후 비교 자체가 성립하지 않습니다.
# -----------------------------------------------------------
COLD_Q="전세 보증금을 돌려받지 못하면 어떻게 해야 하나요?"
WARM_Q="임대차 계약 갱신 거절 사유는?"
ANSWER_DIR="${ANSWER_DIR:-$HOME/lexai-run/answers}"
ANSWER_SHA="-"
ANSWER_UNIQ=0

# ★ json.load(sys.stdin) 을 쓰면 안 됩니다. stdin 을 플랫폼 기본 인코딩으로
#   읽기 때문에, 로케일이 C 인 환경에서는 한글 답변이 통째로 깨집니다.
#   바이트로 받아 UTF-8 로 명시해서 해석합니다.
answer_hash() {
    printf '%s' "$1" | python3 -c 'import sys,json,hashlib
try: a = json.loads(sys.stdin.buffer.read().decode("utf-8")).get("answer") or ""
except Exception: a = ""
print(hashlib.sha256(a.encode("utf-8")).hexdigest()[:12] if a else "-")' 2>/dev/null \
        || printf '%s' "-"
}

save_answer() {
    mkdir -p "$ANSWER_DIR"
    printf '%s' "$3" | python3 -c 'import sys,json,hashlib
out, form, q = sys.argv[1], sys.argv[2], sys.argv[3]
try: d = json.loads(sys.stdin.buffer.read().decode("utf-8"))
except Exception: d = {}
a = d.get("answer") or ""
rec = {"form": form, "question": q, "answer": a,
       "answer_sha256": hashlib.sha256(a.encode("utf-8")).hexdigest(),
       "source_count": len(d.get("sources") or []),
       "sources": d.get("sources") or []}
with open(out, "w", encoding="utf-8") as f:
    json.dump(rec, f, ensure_ascii=False, indent=2)' "$1" "$FORM" "$2" 2>/dev/null || true
}


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
        -d "$(printf '{"question":"%s","lawCategory":null,"sessionId":null}' "$COLD_Q")")
    COLD_MS=$(( $(now_ms) - t0 ))

    # 환경 간 대조용으로 본문과 근거 문서를 통째로 남깁니다.
    ANSWER_SHA=$(answer_hash "$body")
    ANSWER_FILE="$ANSWER_DIR/${FORM}-$(date +%Y%m%d-%H%M%S)-cold.json"
    save_answer "$ANSWER_FILE" "$COLD_Q" "$body"

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
    elif [ "$ALLOW_EMPTY_INDEX" = "1" ]; then
        # 근거 문서가 하나도 없으면 RAG 가 답을 만들 수 없습니다. 색인이
        # 비어 있는 게 전제인 기동 검증에서는 예상된 결과입니다.
        warn "답변 없음 ($(secs "$COLD_MS")초) — 빈 색인이라 예상된 결과입니다 (ALLOW_EMPTY_INDEX=1)"
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
    samples=(); warm_hashes=()
    for i in $(seq 1 "$RUNS"); do
        t0=$(now_ms)
        # ★ 응답을 버리지 않습니다. 내용을 비교하려면 본문이 있어야 합니다.
        wbody=$(curl -s -X POST "$FRONT/api/chat" \
            -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
            -d "$(printf '{"question":"%s","lawCategory":null,"sessionId":null}' "$WARM_Q")")
        ms=$(( $(now_ms) - t0 ))
        samples+=("$ms")
        warm_hashes+=("$(answer_hash "$wbody")")
        if [ "$RUNS" -gt 1 ]; then printf '       %d/%d  %s초\n' "$i" "$RUNS" "$(secs "$ms")"; fi
    done

    WARM_MS=$(pct 50 "${samples[@]}")
    P95_MS=$(pct 95 "${samples[@]}")

    # 백엔드의 FastAPI 호출 타임아웃이 180초라 그 아래여야 의미가 있습니다.
    #
    # ★ 플래그만 보면 안 됩니다. deploy.sh 는 SNAPSHOT_URI 를 안 주면 색인이
    #   비어 있을 것으로 보고 ALLOW_EMPTY_INDEX=1 을 넘기는데, 이미 데이터가
    #   있는 환경에 다시 배포하면 그 가정이 틀립니다. 실제로 같은 실행에서
    #   「색인 253,207건 PASS」와 「빈 색인이라 기준선으로 쓸 수 없습니다」가
    #   같이 나왔습니다. 근거 문서가 실제로 0건일 때만 빈 색인으로 봅니다.
    if [ "$ALLOW_EMPTY_INDEX" = "1" ] && [ "${SRC_COUNT:-0}" -le 0 ]; then
        # 색인이 비면 검색도 생성도 하지 않으므로 이 숫자는 기준선이 아닙니다.
        warn "응답 $(secs "$WARM_MS")초 — 빈 색인이라 기준선으로 쓸 수 없습니다"
    elif [ "$P95_MS" -lt 180000 ]; then
        if [ "$RUNS" -gt 1 ]; then
            pass "p50 $(secs "$WARM_MS")초 · p95 $(secs "$P95_MS")초 (${RUNS}회)"
        else
            pass "응답 $(secs "$WARM_MS")초"
        fi
    else
        fail "p95 $(secs "$P95_MS")초 — 백엔드 타임아웃(180초) 초과 위험"
    fi

    # 같은 질문에 같은 답이 나오는지. 결정적 설정이 실제로 걸렸는지는
    # 설정을 읽어서가 아니라 결과로 확인해야 합니다.
    if [ "$ALLOW_EMPTY_INDEX" = "1" ] && [ "${SRC_COUNT:-0}" -le 0 ]; then
        :   # 색인이 비면 생성 자체를 하지 않으므로 판정 대상이 아닙니다.
    elif [ "$RUNS" -le 1 ]; then
        warn "응답 재현성은 RUNS 를 2 이상으로 둬야 판정됩니다"
    else
        ANSWER_UNIQ=$(printf '%s\n' "${warm_hashes[@]}" | sort -u | wc -l)
        if [ "${warm_hashes[0]}" = "-" ]; then
            fail "응답을 읽지 못해 재현성을 판정하지 못했습니다"
        elif [ "$ANSWER_UNIQ" -eq 1 ]; then
            pass "응답 재현성 — ${RUNS}회 모두 동일 (${warm_hashes[0]})"
        else
            fail "응답 재현성 — ${RUNS}회 중 서로 다른 답변 ${ANSWER_UNIQ}종. .env 의 TEMPERATURE 와 LLM_SEED 를 확인하세요 (운영 기본값은 0.1 · -1 로 비결정적입니다)"
        fi
    fi
else
    fail "인증 실패로 채팅 검증 건너뜀"
fi


log "5. 데이터"
# ★ 노드가 응답하는 것과 색인을 읽을 수 있는 것은 다릅니다. 기동 직후에는
#   클러스터가 200 을 주면서도 샤드 복구가 끝나지 않아 _count 가 0 을
#   돌려줍니다. 색인 단위로 서버 쪽에서 기다리게 합니다.
os -o /dev/null "$OS_BASE/_cluster/health/${INDEX_NAME}?wait_for_status=yellow&timeout=${OS_WAIT:-120}s" || true

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
# 두 가지를 봅니다.
#   1) 실제 데이터에 고아 행이 있는가 — 앱이 FK 없이 써왔다면 여기서 나옵니다
#   2) 설정이 실제로 들어있는가      — 1) 은 데이터가 적으면 통과할 수 있어서
#
# ★ 2) 가 지금까지 네이티브에만 있었습니다. 같은 시점에 네이티브는
#   「고아 행 0 · FK 강제 설정됨」, 컴포즈는 「고아 행 0」 으로 판정이 갈렸고
#   그만큼 항목 수도 달랐습니다(9 대 10). 동등성 검증 도구가 형태마다 다른
#   항목을 재면 두 수치를 나란히 놓을 수 없습니다.
#
#   컨테이너에는 소스가 없어 WAR 안의 설정을 봅니다. 배포 경로가 이미지마다
#   다를 수 있으므로, 파일을 못 찾은 경우는 FAIL 이 아니라 WARN 입니다 —
#   설정이 틀린 것과 확인하지 못한 것은 다릅니다.
# -----------------------------------------------------------
orphans=$(dex tomcat sqlite3 "$DB_IN" "PRAGMA foreign_keys=ON; PRAGMA foreign_key_check;" | grep -c . )
fk_xml=$(dex tomcat sh -c 'grep -rl "foreign_keys" "${CATALINA_HOME:-/usr/local/tomcat}/webapps" 2>/dev/null | head -1')
fk_cfg=0
if [ -n "${fk_xml:-}" ]; then
    fk_cfg=$(dex tomcat sh -c "grep -c 'key=\"foreign_keys\">true' '$fk_xml' 2>/dev/null" | tr -d '\r')
fi

if [ "${orphans:-0}" -gt 0 ]; then
    fail "고아 행 ${orphans}건 — FK 가 강제되지 않은 채 기록됐습니다"
elif [ -z "${fk_xml:-}" ]; then
    warn "배포본에서 설정 파일을 찾지 못해 FK 강제 여부를 확인하지 못했습니다 (고아 행 0)"
    pass "참조 무결성 (고아 행 0)"
elif [ "${fk_cfg:-0}" -ge 1 ]; then
    pass "참조 무결성 (고아 행 0 · FK 강제 설정됨)"
else
    fail "배포본에 foreign_keys=true 가 없습니다 — FK 가 검사되지 않습니다"
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
    # ★ "Not yet initialized" 는 OpenSearch 기동 창에서 매번 나옵니다.
    #   보안 플러그인이 초기화 전에 들어온 요청을 거절하는 것이고 곧 사라집니다.
    #   항상 뜨는 경고를 남겨두면 진짜 경고까지 흘려보게 되므로 제외합니다.
    n=$( { printf '%s' "$logs" \
        | grep -E "Traceback \(most recent|^Caused by:|Exception in thread|\bERROR\b|\bSEVERE\b" \
        | grep -vc "Not yet initialized"; } || true )
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
# answer_sha  콜드 응답 본문의 해시 — 이관 전후 이 값이 같으면 같은 답입니다.
# answer_uniq 웜 응답 중 서로 다른 답변의 수 — 1 이어야 결정적입니다.
HEADER="timestamp,form,runs,pass,fail,cold_sec,p50_sec,p95_sec,sources,os_docs,db_msgs,answer_sha,answer_uniq,result"
if [ -f "$RESULTS" ] && [ "$(head -1 "$RESULTS")" != "$HEADER" ]; then
    mv "$RESULTS" "${RESULTS%.csv}-$(date +%Y%m%d-%H%M%S).csv"
    warn "결과 형식이 바뀌어 이전 기록을 따로 보관했습니다"
fi
[ -f "$RESULTS" ] || echo "$HEADER" > "$RESULTS"

VERDICT=$([ "$FAIL" -eq 0 ] && echo PASS || echo FAIL)
echo "$(date '+%Y-%m-%d %H:%M:%S'),${FORM},${RUNS},${PASS},${FAIL},$(secs "$COLD_MS"),$(secs "$WARM_MS"),$(secs "$P95_MS"),${SRC_COUNT},${OS_DOCS:-0},${DB_MSGS:-0},${ANSWER_SHA},${ANSWER_UNIQ},${VERDICT}" >> "$RESULTS"

echo
log "결과: ${PASS} PASS / ${FAIL} FAIL → ${VERDICT}"
echo "  누적 기록: $RESULTS"
[ -n "${ANSWER_FILE:-}" ] && echo "  응답 보존: $ANSWER_FILE"
column -s, -t "$RESULTS" 2>/dev/null | tail -6

[ "$FAIL" -eq 0 ]
