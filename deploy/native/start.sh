#!/usr/bin/env bash
# ===========================================================
# 네이티브 기동
#
#   bash deploy/native/start.sh              # 전부
#   bash deploy/native/start.sh opensearch   # 하나만
#
# 대상: opensearch | ollama | ai | tomcat | frontend | all
#
# 이미 떠 있는 것은 건너뜁니다. 로그는 ~/lexai-run/logs, PID 는 ~/lexai-run/pids.
# ===========================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

TARGET="${1:-all}"
want() { [ "$TARGET" = "all" ] || [ "$TARGET" = "$1" ]; }


# -----------------------------------------------------------
# Ollama — systemd 서비스라 PID 관리가 필요 없습니다.
# -----------------------------------------------------------
if want ollama; then
    log "Ollama"
    if systemctl is-active --quiet ollama; then
        ok "이미 실행 중"
    else
        sudo systemctl start ollama
        wait_for "Ollama" 60 curl -sf "http://127.0.0.1:${OLLAMA_PORT}/api/tags" \
            || die "Ollama 기동 실패"
        ok "기동"
    fi
fi


# -----------------------------------------------------------
# OpenSearch
#
# ★ LD_LIBRARY_PATH 를 반드시 먼저 export 합니다. 없으면 기동은 되지만
#   벡터 검색이 들어오는 순간 UnsatisfiedLinkError 로 노드가 죽습니다.
#   BM25 만으로는 멀쩡해 보여서 기동 확인만으로는 안 잡히는 함정입니다.
# -----------------------------------------------------------
if want opensearch; then
    log "OpenSearch"
    if port_in_use "$OPENSEARCH_PORT"; then
        ok "이미 실행 중 (포트 ${OPENSEARCH_PORT})"
    else
        export_knn_lib_path
        (
            cd "$OPENSEARCH_HOME"
            ./bin/opensearch -d -p "$PID_DIR/opensearch.pid" \
                > "$LOG_DIR/opensearch.log" 2>&1
        )
        load_opensearch_creds
        if ! wait_for "OpenSearch" 180 os_curl "$OS_BASE/_cluster/health"; then
            die "기동 실패 — $LOG_DIR/opensearch.log 확인"
        fi
        # 샤드 복구까지 기다립니다. 응답만 보고 넘어가면 다음 단계의 _count 가
        # 빈 값을 받아 "색인 없음"으로 오판합니다.
        if ! wait_for "샤드 복구" 180 os_ready; then
            warn "클러스터 상태가 yellow/green 이 아닙니다 — 색인 조회가 실패할 수 있습니다"
        fi
        ok "기동 (PID $(cat "$PID_DIR/opensearch.pid" 2>/dev/null || echo '?'))"
    fi
fi


# -----------------------------------------------------------
# 환경변수 파일
#
# 앱 3종이 공유하는 설정을 표준 위치에 한 번만 씁니다. 유닛의
# EnvironmentFile 이 이 파일을 읽으므로, 이관 도구도 같은 경로에서
# 워크로드 설정을 확인할 수 있습니다.
#
# 매 기동마다 .env 로부터 새로 만듭니다 — 설정을 고치고 재기동하면
# 그대로 반영되고, 어느 값이 적용됐는지 한 곳에서 확인됩니다.
# -----------------------------------------------------------
write_env_file() {
    load_opensearch_creds

    local jwt; jwt="$(env_value JWT_SECRET)"
    [ "${#jwt}" -ge 32 ] || die "JWT_SECRET 이 32자 미만입니다 (HS256 최소 길이)"
    [ -f "$DB_PATH" ] || die "DB 파일이 없습니다: $DB_PATH (restore.sh 를 먼저 실행하세요)"

    local seed temp
    seed="$(env_value LLM_SEED)"
    temp="$(env_value TEMPERATURE)"

    sudo mkdir -p "$ENV_DIR"
    {
        echo "# start.sh 가 .env 로부터 자동 생성합니다. 직접 수정하면 다음 기동에 덮어써집니다."
        echo "TZ=${TZ}"
        echo "DB_PATH=${DB_PATH}"
        echo "OPENSEARCH_HOST=127.0.0.1"
        echo "OPENSEARCH_PORT=${OPENSEARCH_PORT}"
        echo "OPENSEARCH_USE_SSL=true"
        echo "OPENSEARCH_USER=${OPENSEARCH_USER}"
        echo "OPENSEARCH_PASSWORD=${OPENSEARCH_PASSWORD}"
        echo "OLLAMA_BASE_URL=http://127.0.0.1:${OLLAMA_PORT}"
        echo "OLLAMA_MODEL=${OLLAMA_MODEL:-legal-gemma}"
        echo "EMBEDDING_DEVICE=${EMBEDDING_DEVICE:-cpu}"
        # if 로 쓰는 이유: [ ] && echo 형태면 값이 빌 때 AND-list 가 실패로
        # 잡히고, set -e 가 이 파이프라인 서브셸을 그 자리에서 끝내버려
        # 아래 항목들이 파일에 기록되지 않습니다.
        if [ -n "$seed" ]; then echo "LLM_SEED=${seed}"; fi
        if [ -n "$temp" ]; then echo "TEMPERATURE=${temp}"; fi
        echo "PORT=${FRONTEND_PORT}"
        echo "BACKEND_URL=${API_BASE}"
        echo "JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-11-openjdk-amd64}"
    } | sudo tee "$ENV_FILE" >/dev/null

    # OpenSearch 비밀번호가 들어 있으므로 일반 읽기를 막습니다.
    sudo chown "root:$(id -gn)" "$ENV_FILE"
    sudo chmod 640 "$ENV_FILE"

    # db.properties 는 Spring 의 property-placeholder 가 클래스패스에서
    # 읽으므로 별도로 필요합니다(EnvironmentFile 로는 대체 불가).
    cat > "$REPO_DIR/backend_spring/src/main/resources/db.properties" <<EOF
# start.sh 가 .env 로부터 자동 생성합니다. 직접 수정해도 다음 기동에서 덮어씁니다.
db.driver.Class=org.sqlite.JDBC
db.url=jdbc:sqlite:${DB_PATH}
fastapi.url=http://127.0.0.1:${AI_PORT}
redis.host=127.0.0.1
redis.port=6379
jwt.secret=${jwt}
jwt.expiration=$(env_value JWT_EXPIRATION || echo 86400000)
EOF
}

# start_unit <유닛> <설명> <준비완료 판정 명령...>
start_unit() {
    local unit="$1" label="$2"; shift 2
    log "$label"
    [ -f "$SYSTEMD_DIR/${unit}.service" ] || die "유닛이 없습니다 — install.sh 를 먼저 실행하세요"

    if systemctl is-active --quiet "$unit"; then
        ok "이미 실행 중"
        return
    fi
    sudo systemctl start "$unit"
    if ! wait_for "$label" 300 "$@"; then
        sudo systemctl status "$unit" --no-pager -l | tail -15
        die "기동 실패 — journalctl -u ${unit} -n 50"
    fi
    ok "기동 (systemd: ${unit})"
}

if want ai || want tomcat || want frontend; then
    write_env_file
    ok "환경변수 파일 생성: $ENV_FILE"
fi

# 임베딩 모델을 미리 로드하므로 최초 기동이 오래 걸립니다.
if want ai; then
    start_unit lexai-ai "AI 서버" curl -sf "http://127.0.0.1:${AI_PORT}/api/v1/health"
fi

# 컨텍스트 루트는 404 라서 HTTP 응답으로 판정하면 안 됩니다. 포트로 봅니다.
if want tomcat; then
    start_unit lexai-tomcat "Tomcat" port_in_use "$TOMCAT_PORT"
fi

if want frontend; then
    start_unit lexai-frontend "Frontend" curl -sf -o /dev/null "http://127.0.0.1:${FRONTEND_PORT}/"
fi


echo
log "기동 완료"
echo "  Frontend : http://127.0.0.1:${FRONTEND_PORT}"
echo "  API      : ${API_BASE}"
echo "  로그     : journalctl -u lexai-ai -f   (lexai-tomcat / lexai-frontend)"
echo "  OpenSearch : $LOG_DIR/opensearch.log"
echo "  검증     : bash deploy/native/verify.sh"
