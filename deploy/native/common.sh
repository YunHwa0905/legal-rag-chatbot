#!/usr/bin/env bash
# ===========================================================
# 공통 설정 — 다른 스크립트가 source 해서 씁니다.
#
#   source "$(dirname "$0")/common.sh"
#
# 직접 실행하는 스크립트가 아닙니다.
# ===========================================================

set -euo pipefail

# -----------------------------------------------------------
# 경로
# -----------------------------------------------------------
REPO_DIR="${REPO_DIR:-$HOME/legal-rag-chatbot}"
OPENSEARCH_VERSION="${OPENSEARCH_VERSION:-2.13.0}"
OPENSEARCH_HOME="${OPENSEARCH_HOME:-$HOME/opensearch-${OPENSEARCH_VERSION}}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-$HOME/lexai-snapshots}"
DATA_DIR="${DATA_DIR:-$HOME/lexai-data}"
DB_PATH="${DB_PATH:-$DATA_DIR/lexai.db}"
RUN_DIR="${RUN_DIR:-$HOME/lexai-run}"
LOG_DIR="$RUN_DIR/logs"
PID_DIR="$RUN_DIR/pids"

# -----------------------------------------------------------
# systemd
#
# 앱 3종을 유닛으로 돌립니다. 직접 nohup 으로 띄우던 방식에서 옮긴 이유는
# 이관 도구가 워크로드를 식별할 수 있어야 하기 때문입니다 — 실행 명령
# (ExecStart)과 환경변수(EnvironmentFile)가 표준 위치에 노출됩니다.
#
# 부수 효과로 종료가 확실해집니다. mvn 은 JVM 을 자식으로 띄우는데,
# systemd 는 cgroup 단위로 정리해서 자식이 남지 않습니다.
# -----------------------------------------------------------
# OpenSearch 도 유닛입니다. 예전에는 PID 파일로 띄웠는데, enable 이 없어
# 재부팅하면 올라오지 않았고 이관 도구가 식별할 수도 없었습니다.
# -----------------------------------------------------------
# 무인 apt
#
# ★ sudo 는 환경변수를 지웁니다(env_reset). 스크립트 맨 위에서
#   export DEBIAN_FRONTEND=noninteractive 를 해도 `sudo apt-get` 에는
#   전달되지 않아, 지금까지 사실상 무력했습니다. 호출마다 직접 넘깁니다.
#
# ★ needrestart 는 debconf 가 아니라 별도 도구라 DEBIAN_FRONTEND 로
#   막히지 않습니다. 커널이 올라가면 "Pending kernel upgrade" 대화상자를
#   띄우는데, 무인 실행에서는 거기서 영원히 멈춥니다. 실제로 겪었습니다.
# -----------------------------------------------------------
apt_q() {
    sudo DEBIAN_FRONTEND=noninteractive \
         NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 \
         apt-get "$@"
}

# ollama 설치 스크립트나 nodesource 처럼 남이 부르는 apt 도 있어서,
# 호출을 고치는 것만으로는 부족합니다. 설정 파일로 한 번 막아둡니다.
silence_needrestart() {
    [ -d /etc/needrestart ] || return 0
    [ -f /etc/needrestart/conf.d/99-lexai.conf ] && return 0
    sudo mkdir -p /etc/needrestart/conf.d
    printf '$nrconf{restart} = "a";\n$nrconf{kernelhints} = -1;\n' \
        | sudo tee /etc/needrestart/conf.d/99-lexai.conf >/dev/null
}

SYSTEMD_DIR="/etc/systemd/system"
ENV_DIR="${ENV_DIR:-/etc/lexai}"
ENV_FILE="$ENV_DIR/lexai.env"
UNITS="lexai-opensearch lexai-ai lexai-tomcat lexai-frontend"

# -----------------------------------------------------------
# 포트
#
# ★ localhost 가 아니라 127.0.0.1 을 씁니다. Node 17+ 는 DNS 응답 순서를
#   그대로 따르는데 localhost 가 ::1(IPv6) 로 먼저 해석되는 반면 Tomcat 은
#   IPv4 에만 바인딩돼 있어 연결이 거부됩니다. 실제로 겪은 문제입니다.
# -----------------------------------------------------------
FRONTEND_PORT="${FRONTEND_PORT:-3000}"
AI_PORT="${AI_PORT:-8000}"
TOMCAT_PORT="${TOMCAT_PORT:-8181}"
TOMCAT_CONTEXT="${TOMCAT_CONTEXT:-/backend_spring}"
OPENSEARCH_PORT="${OPENSEARCH_PORT:-9200}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"

API_BASE="http://127.0.0.1:${TOMCAT_PORT}${TOMCAT_CONTEXT}"
OS_BASE="https://127.0.0.1:${OPENSEARCH_PORT}"

# -----------------------------------------------------------
# 타임존
#
# 스키마와 매퍼가 시각을 datetime('now','localtime') 으로 기록합니다.
# 이 localtime 은 JVM 설정이 아니라 프로세스의 OS 타임존을 따르므로,
# 설정하지 않으면 UTC 로 기록되어 9시간 어긋납니다.
# -----------------------------------------------------------
export TZ="${TZ:-Asia/Seoul}"

# -----------------------------------------------------------
# 출력 헬퍼
# -----------------------------------------------------------
# ★ 색상은 터미널일 때만 씁니다. 리모트 커맨드 · 오케스트레이터 · 로그 파일로
#   받으면 터미널이 아니므로, 그대로 두면 \033[0;32m 같은 제어문자가 로그에
#   섞여 읽기도 파싱하기도 어렵습니다. NO_COLOR=1 로 강제로 끌 수도 있습니다.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_INFO=$'\033[0;36m'; C_OK=$'\033[0;32m'; C_WARN=$'\033[0;33m'
    C_ERR=$'\033[0;31m'; C_HEAD=$'\033[1;35m'; C_OFF=$'\033[0m'
else
    C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_HEAD=""; C_OFF=""
fi
log()  { printf '%s[%s]%s %s\n' "$C_INFO" "$(date +%H:%M:%S)" "$C_OFF" "$*"; }
ok()   { printf '%s  OK%s   %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%s  WARN%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()  {
    printf '%s  FATAL%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2
    status_set "last_error=$*"
    exit 1
}

# -----------------------------------------------------------
# 상태 파일 (오케스트레이터용)
#
# 배포 · 이관은 25~30분 걸려 백그라운드로 띄울 수밖에 없고, 그러면 호출한
# 쪽은 종료 코드를 받지 못합니다. 대신 이 JSON 을 폴링하면 됩니다.
#   ~/lexai-run/status.json         bootstrap · up.sh (배포 · 이관)
#   ~/lexai-run/backup-status.json  backup.sh
# 필드와 값은 deploy/native/README.md 의 "상태 파일" 절에 정리돼 있습니다.
# 쓰기 실패가 배포를 멈추게 하지 않도록 오류는 무시합니다.
# -----------------------------------------------------------
STATUS_FILE="${STATUS_FILE:-${RUN_DIR}/status.json}"

status_set() {  # status_set 키=값 ...
    [ -n "${STATUS_FILE:-}" ] || return 0
    mkdir -p "$(dirname "$STATUS_FILE")" 2>/dev/null || return 0
    python3 - "$STATUS_FILE" "$@" <<'PY' 2>/dev/null || true
import json, os, sys, time
path = sys.argv[1]
try:
    data = json.load(open(path))
except Exception:
    data = {}
for kv in sys.argv[2:]:
    k, _, v = kv.partition("=")
    data[k] = v
data["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, ensure_ascii=False, indent=1)
os.replace(tmp, path)
PY
}

status_get() {  # status_get 키 — 없으면 빈 문자열
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' \
        "$STATUS_FILE" "$1" 2>/dev/null || true
}

now_iso() { date '+%Y-%m-%dT%H:%M:%S%z'; }

# Ollama 버전 (예: 0.12.3). 서버가 꺼져 있으면 경고 줄이 섞이므로 숫자만 뽑습니다.
ollama_version() {
    { ollama --version 2>/dev/null || true; } | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true
}

# -----------------------------------------------------------
# .env 에서 값 하나 읽기
#
# source 하지 않는 이유: .env 의 DB_URL 같은 값에 & 가 들어 있어서
# 셸이 백그라운드 실행으로 해석해 버립니다. 필요한 키만 꺼내 씁니다.
# -----------------------------------------------------------
env_value() {
    local key="$1"
    [ -f "$REPO_DIR/.env" ] || die ".env 가 없습니다: $REPO_DIR/.env"
    # set -o pipefail 때문에 grep 이 못 찾으면 파이프라인이 실패로 잡힙니다.
    # 값이 없는 것은 호출한 쪽이 판단할 일이라 여기서는 빈 문자열을 돌려줍니다.
    #
    # ★ tail -1 입니다. 같은 키가 여러 번 있으면 마지막 값이 이깁니다 —
    #   docker compose 가 .env 를 읽는 방식과 같게 맞춘 것입니다. head -1
    #   이면 뒤에 덧붙인 값이 조용히 무시되어, 두 형태가 서로 다른 설정으로
    #   도는 상황이 생깁니다(실제로 TEMPERATURE 에서 겪었습니다).
    { grep "^${key}=" "$REPO_DIR/.env" | tail -1 | cut -d= -f2- ; } || true
}

# -----------------------------------------------------------
# OpenSearch 접속 정보 (지연 로딩)
# -----------------------------------------------------------
load_opensearch_creds() {
    OPENSEARCH_USER="${OPENSEARCH_USER:-$(env_value OPENSEARCH_USER || echo admin)}"
    OPENSEARCH_USER="${OPENSEARCH_USER:-admin}"
    OPENSEARCH_PASSWORD="$(env_value OPENSEARCH_PASSWORD)"
    [ -n "$OPENSEARCH_PASSWORD" ] || die ".env 에 OPENSEARCH_PASSWORD 가 비어 있습니다"
    export OPENSEARCH_USER OPENSEARCH_PASSWORD
}

os_curl() {
    curl -sk -u "${OPENSEARCH_USER}:${OPENSEARCH_PASSWORD}" "$@"
}

# 노드가 응답하는 것과 인덱스를 읽을 수 있는 것은 다릅니다. 기동 직후에는
# _cluster/health 가 200 을 주면서도 샤드 복구가 끝나지 않아 _count 가 실패합니다.
# 그 상태에서 "색인이 없다"고 판단하면 멀쩡한 색인을 두고 복원을 시도하게 됩니다.
os_ready() {
    local st
    st=$(os_curl "$OS_BASE/_cluster/health" 2>/dev/null | grep -o '"status":"[a-z]*"' | cut -d'"' -f4) || return 1
    [ "$st" = "yellow" ] || [ "$st" = "green" ]
}

# 클러스터가 통째로 green 이어도 특정 색인의 샤드는 아직 복구 중일 수 있습니다.
# 색인 단위로 한 번 더 기다립니다 — OpenSearch 가 서버 쪽에서 막아 주는
# API 라 폴링보다 정확합니다. 색인이 아예 없으면 408/404 로 떨어지므로
# 호출한 쪽이 그대로 판단하면 됩니다.
os_wait_index() {
    local idx="${1:-${INDEX_NAME:-legal_documents}}" secs="${2:-120}"
    os_curl -s -o /dev/null -w '%{http_code}' \
        "$OS_BASE/_cluster/health/${idx}?wait_for_status=yellow&timeout=${secs}s" 2>/dev/null \
        | grep -q '^200$'
}

# -----------------------------------------------------------
# k-NN 네이티브 라이브러리 경로
#
# ★ 이게 없으면 벡터 검색이 들어오는 순간 노드가 죽습니다
#   (UnsatisfiedLinkError: no opensearchknn_nmslib in java.library.path).
#   Deep Learning AMI 가 LD_LIBRARY_PATH 를 미리 채워두는 탓에 k-NN
#   플러그인이 자기 라이브러리 경로를 넣지 못해서 생깁니다.
#   BM25 만 쓰면 멀쩡히 돌기 때문에 기동 확인만으로는 절대 안 잡힙니다.
# -----------------------------------------------------------
#   지금은 lexai-opensearch 유닛의 Environment= 로 들어가 있습니다.
#   유닛을 손볼 때 이 줄을 지우면 같은 증상이 돌아옵니다.
#
# 설치된 유닛에 실제로 들어갔는지 확인합니다. 유닛을 다시 만들거나 손으로
# 고친 뒤 빠지는 일을 막기 위한 것입니다.
check_knn_lib_path() {
    local unit="$SYSTEMD_DIR/lexai-opensearch.service"
    [ -f "$unit" ] || return 0
    grep -q "LD_LIBRARY_PATH=.*opensearch-knn/lib" "$unit" \
        || die "lexai-opensearch 유닛에 k-NN 라이브러리 경로가 없습니다 — install.sh 를 다시 실행하세요"
}

# -----------------------------------------------------------
# 포트 점유 확인
# -----------------------------------------------------------
port_in_use() {
    ss -tln 2>/dev/null | grep -q ":$1 "
}

# -----------------------------------------------------------
# 데이터 정합성
#
# 계약 요구사항이 "용량 · 파일 개수 · 해시" 세 가지 대조입니다. 옮기는
# 도중 조용히 잘리거나 빠지는 일을 잡기 위한 것이라, 셋을 모두 봐야
# 의미가 있습니다 — 개수만 맞고 내용이 다르거나, 해시는 같은데 파일이
# 빠져 있는 경우를 각각 놓치기 때문입니다.
#
# 목록 파일(contents.tsv) 형식: 상대경로 <TAB> 바이트 <TAB> sha256
# -----------------------------------------------------------
MANIFEST_NAME="contents.tsv"

# write_manifest <디렉터리> — 자기 자신은 목록에서 제외합니다.
write_manifest() {
    local dir="$1"
    ( cd "$dir" && find . -type f ! -name "$MANIFEST_NAME" -print0         | sort -z         | while IFS= read -r -d "" f; do
            printf '%s	%s	%s
' "${f#./}" "$(stat -c %s "$f")" "$(sha256sum "$f" | cut -d" " -f1)"
          done ) > "$dir/$MANIFEST_NAME"
}

# verify_manifest <디렉터리> — 개수 · 총 용량 · 해시를 대조합니다.
# 하나라도 어긋나면 1 을 돌려주고 어긋난 항목을 출력합니다.
verify_manifest() {
    local dir="$1" manifest="$1/$MANIFEST_NAME"
    if [ ! -f "$manifest" ]; then
        # 이관 모드(bootstrap NO_UPDATE=1 → REQUIRE_MANIFEST=1)에서는 대조 없이
        # 넘어가면 "데이터가 온전하다"는 근거가 하나 빠지므로 실패로 봅니다.
        if [ "${REQUIRE_MANIFEST:-0}" = "1" ]; then
            warn "목록 파일이 없습니다: $manifest — 이관 모드에서는 대조 없이 진행하지 않습니다"
            return 1
        fi
        warn "목록 파일이 없어 정합성 대조를 건너뜁니다: $manifest"
        return 0
    fi

    local want_count want_bytes have_count have_bytes bad=0
    want_count=$(wc -l < "$manifest")
    want_bytes=$(awk -F"	" '{s+=$2} END {print s+0}' "$manifest")

    have_count=$(find "$dir" -type f ! -name "$MANIFEST_NAME" | wc -l)
    have_bytes=$(find "$dir" -type f ! -name "$MANIFEST_NAME" -printf '%s
' | awk '{s+=$1} END {print s+0}')

    [ "$want_count" = "$have_count" ] || { warn "파일 개수 불일치: 기대 ${want_count} / 실제 ${have_count}"; bad=1; }
    [ "$want_bytes" = "$have_bytes" ] || { warn "총 용량 불일치: 기대 ${want_bytes} / 실제 ${have_bytes}"; bad=1; }

    # 해시는 sha256sum -c 에 맡깁니다. 목록 형식을 그 도구가 읽는 형태로 바꿔 넘깁니다.
    local mismatched
    mismatched=$( ( cd "$dir" && awk -F"	" '{print $3"  "$1}' "$MANIFEST_NAME"         | sha256sum -c --quiet 2>&1 ) | head -20 || true )
    if [ -n "$mismatched" ]; then
        warn "해시 불일치:"
        printf '%s
' "$mismatched" >&2
        bad=1
    fi

    if [ "$bad" = "0" ]; then
        ok "정합성 대조 통과 — 파일 ${have_count}개 / $(numfmt --to=iec "$have_bytes" 2>/dev/null || echo "${have_bytes}B")"
        return 0
    fi
    return 1
}

# -----------------------------------------------------------
# 스키마 버전 (SQLite PRAGMA user_version)
#
# ★ schema.sqlite.sql 은 CREATE ... IF NOT EXISTS 만 씁니다. 테이블이 이미
#   있으면 아무것도 바꾸지 않으므로, 컬럼을 추가한 새 코드로 옛 DB 를
#   이관하면 코드는 새 컬럼을 찾는데 DB 에는 없어 그제서야 오류가 납니다.
#   그래서 스키마 변경은 deploy/migrations/NNNN_설명.sql 로만 하고,
#   적용한 번호를 DB 자체(user_version)에 기록합니다. 규칙은 그 폴더의 README.
#
#   v0 = schema.sqlite.sql (기준선, 고치지 않음)
# -----------------------------------------------------------
SCHEMA_MIGRATIONS_DIR="${SCHEMA_MIGRATIONS_DIR:-$REPO_DIR/deploy/migrations}"

# 번호 순서로 마이그레이션 파일을 나열합니다. 번호가 겹치면 멈춥니다.
schema_migration_files() {
    local f b n prev=0
    for f in "$SCHEMA_MIGRATIONS_DIR"/[0-9][0-9][0-9][0-9]_*.sql; do
        [ -e "$f" ] || continue
        b="$(basename "$f")"; n=$((10#${b%%_*}))
        [ "$n" -gt "$prev" ] || die "마이그레이션 번호가 겹치거나 0 입니다: $b"
        prev="$n"
        printf '%s\n' "$f"
    done
}

schema_latest_version() {
    local last
    last="$(schema_migration_files | tail -1)"
    if [ -z "$last" ]; then echo 0; else last="$(basename "$last")"; echo $((10#${last%%_*})); fi
}

# apply_schema_migrations <DB 경로> — 아직 적용하지 않은 번호만 순서대로 적용합니다.
# 파일마다 한 트랜잭션이라, 실패하면 그 파일의 변경과 버전 기록이 함께 취소됩니다.
apply_schema_migrations() {
    local db="$1" cur latest f b n files
    cur="$(sqlite3 "$db" "PRAGMA user_version;")"
    files="$(schema_migration_files)"
    latest="$(schema_latest_version)"

    if [ "$cur" -gt "$latest" ]; then
        die "DB 스키마가 코드보다 새 버전입니다 (DB v${cur} / 코드 v${latest})
  더 새 코드에서 만든 DB 를 옛 코드로 옮긴 경우입니다. 같은 커밋의 코드로 이관하세요."
    fi

    for f in $files; do
        b="$(basename "$f")"; n=$((10#${b%%_*}))
        [ "$n" -le "$cur" ] && continue
        { printf 'BEGIN;\n'; cat "$f"; printf '\nPRAGMA user_version = %d;\nCOMMIT;\n' "$n"; } \
            | sqlite3 -bail "$db" >/dev/null \
            || die "스키마 마이그레이션 실패: $b — DB 는 v${cur} 그대로입니다"
        ok "마이그레이션 적용: $b (v${n})"
        cur="$n"
    done
    ok "스키마 버전 v${cur} (코드 최신 v${latest})"
}

# -----------------------------------------------------------
# 데이터 지문 (이관 전후 데이터 보존 확인)
#
# 테이블마다 "행 수 + 내용 해시" 를 남깁니다. 원본에서 패키지를 만들 때
# 한 번(backup.sh), 대상에서 복원 직후 · 서비스 기동 전에 한 번(check-data.sh)
# 계산해 비교합니다.
#
# ★ 기동 전에 비교하는 이유: 배포 마지막의 verify.sh 가 verify 계정을
#   가입시키고 채팅을 보내 DB 에 행을 더합니다. 그 뒤에 세면 원본과
#   항상 달라 보입니다.
# ★ 컬럼 목록을 같이 기록하고 대상에서도 그 컬럼만 해시합니다. 대상에서
#   마이그레이션이 컬럼을 더해도 원본 데이터 비교는 그대로 유효합니다.
#
# 형식(TSV): 테이블 <TAB> 행수 <TAB> 컬럼,목록 <TAB> sha256
# -----------------------------------------------------------
_table_hash() {  # _table_hash <db> <테이블> <컬럼,목록>
    sqlite3 -readonly "$1" ".mode quote" "SELECT $3 FROM \"$2\" ORDER BY rowid;" | sha256sum | cut -d' ' -f1
}

# write_data_fingerprint <db> <출력 파일>
write_data_fingerprint() {
    local db="$1" out="$2" t cols n
    : > "$out"
    for t in $(sqlite3 -readonly "$db" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;"); do
        cols="$(sqlite3 -readonly "$db" "SELECT group_concat('\"'||name||'\"', ',') FROM (SELECT name FROM pragma_table_info('$t') ORDER BY cid);")"
        n="$(sqlite3 -readonly "$db" "SELECT COUNT(*) FROM \"$t\";")"
        printf '%s\t%s\t%s\t%s\n' "$t" "$n" "$cols" "$(_table_hash "$db" "$t" "$cols")" >> "$out"
    done
}

# check_data_fingerprint <db> <기대 지문 파일> — 표로 출력하고, 하나라도 다르면 1
check_data_fingerprint() {
    local db="$1" want="$2" t n cols h have_n have_h bad=0 status
    printf '    %-22s %10s %10s  %s\n' "테이블" "원본" "대상" "내용"
    while IFS=$'\t' read -r t n cols h; do
        [ -n "$t" ] || continue
        if [ "$(sqlite3 -readonly "$db" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$t';")" != "1" ]; then
            printf '    %-22s %10s %10s  %s\n' "$t" "$n" "-" "테이블 없음"; bad=1; continue
        fi
        have_n="$(sqlite3 -readonly "$db" "SELECT COUNT(*) FROM \"$t\";")"
        if ! have_h="$(_table_hash "$db" "$t" "$cols" 2>/dev/null)" || [ -z "$have_h" ]; then
            printf '    %-22s %10s %10s  %s\n' "$t" "$n" "$have_n" "컬럼 누락"; bad=1; continue
        fi
        if [ "$have_n" = "$n" ] && [ "$have_h" = "$h" ]; then status="일치"; else status="불일치"; bad=1; fi
        printf '    %-22s %10s %10s  %s\n' "$t" "$n" "$have_n" "$status"
    done < "$want"
    [ "$bad" = "0" ]
}

# 조건이 참이 될 때까지 대기. wait_for <설명> <최대초> <명령...>
wait_for() {
    local label="$1" timeout="$2"; shift 2
    local waited=0
    printf '       %s 대기' "$label"
    while ! "$@" >/dev/null 2>&1; do
        if [ "$waited" -ge "$timeout" ]; then
            printf '\n'; return 1
        fi
        sleep 3; waited=$((waited + 3)); printf '.'
    done
    printf ' (%ds)\n' "$waited"
    return 0
}

mkdir -p "$LOG_DIR" "$PID_DIR"
