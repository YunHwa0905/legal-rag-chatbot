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
        wait_for "OpenSearch" 180 os_curl "$OS_BASE/_cluster/health" \
            || die "기동 실패 — $LOG_DIR/opensearch.log 확인"
        ok "기동 (PID $(cat "$PID_DIR/opensearch.pid" 2>/dev/null || echo '?'))"
    fi
fi


# -----------------------------------------------------------
# AI 서버
# -----------------------------------------------------------
if want ai; then
    log "AI 서버"
    if port_in_use "$AI_PORT"; then
        ok "이미 실행 중 (포트 ${AI_PORT})"
    else
        [ -d "$REPO_DIR/ai/.venv" ] || die "venv 가 없습니다: $REPO_DIR/ai/.venv"
        load_opensearch_creds
        (
            cd "$REPO_DIR/ai"
            # shellcheck disable=SC1091
            source .venv/bin/activate
            export OPENSEARCH_HOST=127.0.0.1
            export OPENSEARCH_PORT="$OPENSEARCH_PORT"
            export OPENSEARCH_USE_SSL=true
            export OPENSEARCH_USER OPENSEARCH_PASSWORD
            export OLLAMA_BASE_URL="http://127.0.0.1:${OLLAMA_PORT}"
            export OLLAMA_MODEL="${OLLAMA_MODEL:-legal-gemma}"
            export EMBEDDING_DEVICE="${EMBEDDING_DEVICE:-cpu}"
            nohup uvicorn main:app --host 0.0.0.0 --port "$AI_PORT" \
                > "$LOG_DIR/ai.log" 2>&1 &
            echo $! > "$PID_DIR/ai.pid"
        )
        # 임베딩 모델 로드 때문에 최초 기동이 오래 걸립니다.
        wait_for "AI 서버" 300 curl -sf "http://127.0.0.1:${AI_PORT}/api/v1/health" \
            || die "기동 실패 — $LOG_DIR/ai.log 확인"
        ok "기동 (PID $(cat "$PID_DIR/ai.pid"))"
    fi
fi


# -----------------------------------------------------------
# Tomcat
#
# db.properties 를 .env 로부터 생성합니다. 컨테이너 구성에서
# docker-entrypoint.sh 가 하던 일을 여기서 대신합니다.
#
# ★ 경로는 반드시 절대경로여야 합니다. 상대경로면 mvn 실행 위치를 따라가
#   빈 DB 를 새로 만들고, 테이블이 없어 첫 회원가입이 500 으로 실패합니다.
# -----------------------------------------------------------
if want tomcat; then
    log "Tomcat"
    if port_in_use "$TOMCAT_PORT"; then
        ok "이미 실행 중 (포트 ${TOMCAT_PORT})"
    else
        [ -f "$DB_PATH" ] || die "DB 파일이 없습니다: $DB_PATH (restore.sh 를 먼저 실행하세요)"

        JWT_SECRET="$(env_value JWT_SECRET)"
        [ "${#JWT_SECRET}" -ge 32 ] || die "JWT_SECRET 이 32자 미만입니다 (HS256 최소 길이)"

        props="$REPO_DIR/backend_spring/src/main/resources/db.properties"
        cat > "$props" <<EOF
# start.sh 가 .env 로부터 자동 생성합니다. 직접 수정해도 다음 기동에서 덮어씁니다.
# ★ git 추적 파일이므로 커밋하지 마세요.
db.driver.Class=org.sqlite.JDBC
db.url=jdbc:sqlite:${DB_PATH}
fastapi.url=http://127.0.0.1:${AI_PORT}
redis.host=127.0.0.1
redis.port=6379
jwt.secret=${JWT_SECRET}
jwt.expiration=$(env_value JWT_EXPIRATION || echo 86400000)
EOF
        ok "db.properties 생성 (db=$DB_PATH)"

        (
            cd "$REPO_DIR/backend_spring"
            export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-11-openjdk-amd64}"
            # setsid 로 별도 프로세스 그룹을 만듭니다. mvn 이 JVM 을 자식으로
            # 띄우기 때문에, 종료할 때 그룹째 정리해야 Tomcat 이 남지 않습니다.
            setsid nohup mvn -q tomcat7:run > "$LOG_DIR/tomcat.log" 2>&1 &
            echo $! > "$PID_DIR/tomcat.pid"
        )
        # 컨텍스트 루트는 404 라서 HTTP 응답으로 판정하면 안 됩니다. 포트로 봅니다.
        if ! wait_for "Tomcat" 240 port_in_use "$TOMCAT_PORT"; then
            die "기동 실패 — $LOG_DIR/tomcat.log 확인"
        fi
        ok "기동 (PGID $(cat "$PID_DIR/tomcat.pid"))"
    fi
fi


# -----------------------------------------------------------
# Frontend
#
# /api 는 이 서버가 Tomcat 으로 프록시합니다(리버스 프록시 불필요).
# -----------------------------------------------------------
if want frontend; then
    log "Frontend"
    if port_in_use "$FRONTEND_PORT"; then
        ok "이미 실행 중 (포트 ${FRONTEND_PORT})"
    else
        (
            cd "$REPO_DIR/frontend"
            export PORT="$FRONTEND_PORT"
            export BACKEND_URL="${API_BASE}"
            nohup node server.js > "$LOG_DIR/frontend.log" 2>&1 &
            echo $! > "$PID_DIR/frontend.pid"
        )
        wait_for "Frontend" 30 curl -sf -o /dev/null "http://127.0.0.1:${FRONTEND_PORT}/" \
            || die "기동 실패 — $LOG_DIR/frontend.log 확인"
        ok "기동 (PID $(cat "$PID_DIR/frontend.pid"))"
    fi
fi


echo
log "기동 완료"
echo "  Frontend : http://127.0.0.1:${FRONTEND_PORT}"
echo "  API      : ${API_BASE}"
echo "  로그     : $LOG_DIR"
echo "  검증     : bash deploy/native/verify.sh"
