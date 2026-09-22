#!/usr/bin/env bash
# ===========================================================
# 네이티브 종료 — 기동의 역순
#
#   bash deploy/native/stop.sh              # 앱 + OpenSearch
#   bash deploy/native/stop.sh frontend     # 하나만
#   bash deploy/native/stop.sh all-with-ollama
#
# Ollama 는 systemd 서비스라 기본적으로 건드리지 않습니다.
# 모델이 VRAM 에 올라간 상태를 유지해야 다음 검증에서 콜드 스타트를
# 다시 겪지 않기 때문입니다.
# ===========================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# stop 은 실패해도 계속 진행해야 합니다(이미 죽어 있는 것이 정상 경로).
set +e

TARGET="${1:-all}"
want() { [ "$TARGET" = "all" ] || [ "$TARGET" = "all-with-ollama" ] || [ "$TARGET" = "$1" ]; }

# stop_pid <이름> <pid파일> [group]
#   group 을 주면 프로세스 그룹째 종료합니다. mvn 처럼 자식 JVM 을 띄우는
#   경우 리더만 죽이면 Tomcat 이 포트를 잡은 채 남습니다.
stop_pid() {
    local name="$1" pidfile="$2" group="${3:-}"
    if [ ! -f "$pidfile" ]; then
        ok "$name: PID 파일 없음 — 건너뜀"
        return
    fi
    local pid
    pid="$(cat "$pidfile")"
    if ! kill -0 "$pid" 2>/dev/null; then
        ok "$name: 이미 종료됨 (PID $pid)"
        rm -f "$pidfile"
        return
    fi

    if [ -n "$group" ]; then
        kill -TERM -"$pid" 2>/dev/null
    else
        kill -TERM "$pid" 2>/dev/null
    fi

    local waited=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 30 ]; do
        sleep 1; waited=$((waited + 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
        warn "$name: TERM 으로 안 죽어 KILL 합니다 (PID $pid)"
        if [ -n "$group" ]; then kill -KILL -"$pid" 2>/dev/null; else kill -KILL "$pid" 2>/dev/null; fi
    fi
    rm -f "$pidfile"
    ok "$name 종료 (${waited}s)"
}

log "종료 시작"

want frontend   && stop_pid "Frontend"   "$PID_DIR/frontend.pid"
want tomcat     && stop_pid "Tomcat"     "$PID_DIR/tomcat.pid" group
# 안전망: setsid 가 프로세스 그룹을 새로 만드는지는 실행 환경(잡 컨트롤 여부)에
# 따라 달라집니다. 그룹 종료가 빗나가면 mvn 이 띄운 JVM 이 포트를 잡은 채 남아,
# 다음 기동이 "이미 실행 중"으로 오판합니다. 포트로 확인하고 정리합니다.
if want tomcat && port_in_use "$TOMCAT_PORT"; then
    warn "Tomcat 포트가 아직 열려 있어 프로세스를 직접 정리합니다"
    pkill -f "tomcat7:run" 2>/dev/null
    sleep 3
    port_in_use "$TOMCAT_PORT" && warn "포트 ${TOMCAT_PORT} 가 여전히 점유 중입니다" || ok "Tomcat 정리 완료"
fi
want ai         && stop_pid "AI 서버"     "$PID_DIR/ai.pid"
want opensearch && stop_pid "OpenSearch" "$PID_DIR/opensearch.pid"

if [ "$TARGET" = "all-with-ollama" ] || [ "$TARGET" = "ollama" ]; then
    sudo systemctl stop ollama && ok "Ollama 종료"
fi

echo
log "남은 포트 확인"
for p in "$FRONTEND_PORT" "$AI_PORT" "$TOMCAT_PORT" "$OPENSEARCH_PORT"; do
    if port_in_use "$p"; then
        warn "포트 $p 가 아직 점유돼 있습니다"
        ss -tlnp 2>/dev/null | grep ":$p " | head -1
    fi
done
ok "종료 완료"
