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
SYSTEMD_DIR="/etc/systemd/system"
ENV_DIR="${ENV_DIR:-/etc/lexai}"
ENV_FILE="$ENV_DIR/lexai.env"
UNITS="lexai-ai lexai-tomcat lexai-frontend"

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
log()  { printf '\033[0;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[0;32m  OK\033[0m   %s\n' "$*"; }
warn() { printf '\033[0;33m  WARN\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m  FATAL\033[0m %s\n' "$*" >&2; exit 1; }

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

# -----------------------------------------------------------
# k-NN 네이티브 라이브러리 경로
#
# ★ 이게 없으면 벡터 검색이 들어오는 순간 노드가 죽습니다
#   (UnsatisfiedLinkError: no opensearchknn_nmslib in java.library.path).
#   Deep Learning AMI 가 LD_LIBRARY_PATH 를 미리 채워두는 탓에 k-NN
#   플러그인이 자기 라이브러리 경로를 넣지 못해서 생깁니다.
#   BM25 만 쓰면 멀쩡히 돌기 때문에 기동 확인만으로는 절대 안 잡힙니다.
# -----------------------------------------------------------
export_knn_lib_path() {
    local knn_lib="$OPENSEARCH_HOME/plugins/opensearch-knn/lib"
    [ -d "$knn_lib" ] || die "k-NN 라이브러리 디렉터리가 없습니다: $knn_lib"
    export LD_LIBRARY_PATH="${knn_lib}:${LD_LIBRARY_PATH:-}"
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
    [ -f "$manifest" ] || { warn "목록 파일이 없어 정합성 대조를 건너뜁니다: $manifest"; return 0; }

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
