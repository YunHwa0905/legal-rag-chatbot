#!/usr/bin/env bash
# ===========================================================
# 네이티브 설치 — 런타임 + OpenSearch + Ollama
#
#   bash deploy/native/install.sh
#
# 여러 번 실행해도 안전합니다. 이미 설치된 항목은 건너뜁니다.
# sudo 가 필요한 구간이 있어 중간에 비밀번호를 물을 수 있습니다.
#
# 이 스크립트가 끝나면 설치만 된 상태입니다. 데이터는 restore.sh,
# 기동은 start.sh 가 담당합니다.
# ===========================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

OPENSEARCH_TARBALL="opensearch-${OPENSEARCH_VERSION}-linux-x64.tar.gz"
OPENSEARCH_URL="https://artifacts.opensearch.org/releases/bundle/opensearch/${OPENSEARCH_VERSION}/${OPENSEARCH_TARBALL}"
OPENSEARCH_HEAP="${OPENSEARCH_HEAP:-2g}"

log "1. 런타임 패키지"
# -----------------------------------------------------------
missing=""
for pkg in sqlite3 mvn java pigz; do
    command -v "$pkg" >/dev/null 2>&1 || missing="$missing $pkg"
done
# python3 는 순정 Ubuntu 에도 있지만 venv/pip 모듈은 별도 패키지입니다.
python3 -c 'import venv' >/dev/null 2>&1 || missing="$missing python3-venv"

if [ -n "$missing" ]; then
    sudo apt-get update -qq
    # pigz — 이관 패키지 압축을 코어 수만큼 병렬로 돌립니다
    sudo apt-get install -y sqlite3 openjdk-11-jdk maven pigz python3-venv python3-pip
fi
if ! command -v node >/dev/null 2>&1; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi
ok "sqlite3 $(sqlite3 --version | cut -d' ' -f1) / node $(node --version) / maven $(mvn -v 2>/dev/null | head -1 | cut -d' ' -f3)"

# 호스트에 여러 JDK 가 깔려 있을 수 있습니다(DLAMI 는 21 이 기본).
# Tomcat 은 JDK 11 로 빌드/기동해야 하므로 경로 존재를 따로 확인합니다.
JAVA11_HOME="/usr/lib/jvm/java-11-openjdk-amd64"
if [ -d "$JAVA11_HOME" ]; then
    ok "JDK 11 $("$JAVA11_HOME/bin/java" -version 2>&1 | head -1 | cut -d'"' -f2) (Tomcat 용)"
else
    warn "JDK 11 경로를 찾지 못했습니다: $JAVA11_HOME"
    warn "Tomcat 기동 시 JAVA_HOME 을 직접 지정해야 합니다"
fi


log "2. 커널 파라미터"
# -----------------------------------------------------------
# OpenSearch 는 이 값이 낮으면 부팅에 실패합니다.
if [ "$(sysctl -n vm.max_map_count)" -lt 262144 ]; then
    echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-opensearch.conf >/dev/null
    sudo sysctl --system >/dev/null
fi
ok "vm.max_map_count = $(sysctl -n vm.max_map_count)"


log "3. Ollama"
# -----------------------------------------------------------
if ! command -v ollama >/dev/null 2>&1; then
    curl -fsSL https://ollama.com/install.sh | sh
else
    ok "이미 설치됨 — 건너뜀"
fi

# 유휴 시 모델을 내리지 않게 합니다. 네이티브 기본값은 5분이라
# 그대로 두면 잠깐만 쉬어도 다음 질문이 콜드 스타트가 됩니다
# (컨테이너 구성의 OLLAMA_KEEP_ALIVE=24h 와 조건을 맞춥니다).
sudo mkdir -p /etc/systemd/system/ollama.service.d
printf '[Service]\nEnvironment="OLLAMA_KEEP_ALIVE=24h"\n' \
    | sudo tee /etc/systemd/system/ollama.service.d/override.conf >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable --now ollama >/dev/null 2>&1 || true
sudo systemctl restart ollama
ok "KEEP_ALIVE: $(systemctl show ollama -p Environment --no-pager | tr ' ' '\n' | grep -i keep_alive || echo '미적용')"

if nvidia-smi --query-gpu=name --format=csv,noheader >/dev/null 2>&1; then
    ok "GPU: $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader)"
else
    warn "GPU 를 인식하지 못했습니다. 추론이 CPU 로 떨어져 응답이 1~3분이 됩니다."
    warn "백엔드의 FastAPI 호출 타임아웃이 180초라 그대로 두면 채팅이 실패할 수 있습니다."
fi


log "4. OpenSearch ${OPENSEARCH_VERSION}"
# -----------------------------------------------------------
if [ ! -d "$OPENSEARCH_HOME" ]; then
    cd "$HOME"
    [ -f "$OPENSEARCH_TARBALL" ] || curl -fL# -O "$OPENSEARCH_URL"
    tar -xzf "$OPENSEARCH_TARBALL"
    ok "압축 해제: $OPENSEARCH_HOME"
else
    ok "이미 설치됨 — 건너뜀"
fi

OS_YML="$OPENSEARCH_HOME/config/opensearch.yml"

# -----------------------------------------------------------
# 설정 주입
#
# ★ "지우고 다시 추가" 패턴입니다. 그냥 덧붙이면 재실행할 때마다 같은 키가
#   쌓여서 Duplicate field 로 기동이 즉시 실패합니다. 실제로 겪은 문제입니다.
#
# 뒤의 두 줄이 없으면 스냅샷 복원이 403 으로 막힙니다
# (no permissions for [] — 권한 부족이 아니라 보안 플러그인의 복원 게이트).
# 컨테이너 이미지는 이 값이 켜져 있어서 겪지 않던 문제입니다.
# -----------------------------------------------------------
sed -i '/^discovery\.type:/d; /^path\.repo:/d; /^plugins\.security\.enable_snapshot_restore_privilege:/d; /^plugins\.security\.check_snapshot_restore_write_privileges:/d' "$OS_YML"
printf '\ndiscovery.type: single-node\npath.repo: ["%s"]\nplugins.security.enable_snapshot_restore_privilege: true\nplugins.security.check_snapshot_restore_write_privileges: false\n' \
    "$SNAPSHOT_DIR" >> "$OS_YML"

for key in discovery.type path.repo enable_snapshot_restore_privilege; do
    count=$(grep -c "$key" "$OS_YML" || true)
    [ "$count" -eq 1 ] || die "opensearch.yml 에 '$key' 가 ${count}번 있습니다 — 직접 정리하세요"
done
ok "opensearch.yml 설정 4개 주입"

sed -i "s/^-Xms.*/-Xms${OPENSEARCH_HEAP}/; s/^-Xmx.*/-Xmx${OPENSEARCH_HEAP}/" "$OPENSEARCH_HOME/config/jvm.options"
ok "heap ${OPENSEARCH_HEAP}"

mkdir -p "$SNAPSHOT_DIR" "$DATA_DIR"

# -----------------------------------------------------------
# 보안 플러그인 데모 설정 (최초 1회)
#
# 인증서와 admin 계정을 만듭니다. 이미 적용돼 있으면 건너뜁니다.
# 비밀번호를 컨테이너 구성과 같게 두면 AI 서버 설정을 그대로 쓸 수 있습니다.
# -----------------------------------------------------------
if grep -q "^plugins.security.ssl.transport.pemcert_filepath" "$OS_YML"; then
    ok "보안 설정 이미 적용됨 — 건너뜀"
else
    load_opensearch_creds
    demo_tool="$OPENSEARCH_HOME/plugins/opensearch-security/tools/install_demo_configuration.sh"
    if [ -x "$demo_tool" ]; then
        OPENSEARCH_INITIAL_ADMIN_PASSWORD="$OPENSEARCH_PASSWORD" \
            bash "$demo_tool" -y -i -s
        ok "보안 데모 설정 적용"
    else
        warn "데모 설정 스크립트를 찾지 못했습니다: $demo_tool"
        warn "아래를 한 번 수동 실행한 뒤 Ctrl+C 로 빠져나오세요:"
        warn "  cd $OPENSEARCH_HOME && OPENSEARCH_INITIAL_ADMIN_PASSWORD='<비번>' ./opensearch-tar-install.sh"
    fi
fi


log "5. systemd 유닛"
# -----------------------------------------------------------
# 앱 3종을 유닛으로 등록합니다.
#
# 여기서는 파일만 설치합니다. 환경변수 파일은 기동 시점에 .env 로부터
# 만들어야 최신 값이 반영되므로 start.sh 가 담당합니다.
# -----------------------------------------------------------
RUN_USER="$(id -un)"
JAVA11_HOME="${JAVA11_HOME:-/usr/lib/jvm/java-11-openjdk-amd64}"

sudo mkdir -p "$ENV_DIR"

write_unit() {  # write_unit <이름> <설명> <작업디렉터리> <실행명령>
    sudo tee "$SYSTEMD_DIR/$1.service" >/dev/null <<EOF
[Unit]
Description=$2
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
WorkingDirectory=$3
EnvironmentFile=${ENV_FILE}
ExecStart=$4
Restart=on-failure
RestartSec=5
# 로그는 journal 로 갑니다: journalctl -u $1 -f
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

write_unit "lexai-ai" \
    "LexAI AI server (FastAPI RAG)" \
    "$REPO_DIR/ai" \
    "$REPO_DIR/ai/.venv/bin/uvicorn main:app --host 0.0.0.0 --port $AI_PORT"

# mvn 은 JVM 을 자식으로 띄우지만 systemd 가 cgroup 으로 묶어 정리하므로
# 예전처럼 프로세스 그룹을 직접 다룰 필요가 없습니다.
write_unit "lexai-tomcat" \
    "LexAI backend (Spring Legacy WAR on Tomcat)" \
    "$REPO_DIR/backend_spring" \
    "/usr/bin/mvn -q tomcat7:run"

write_unit "lexai-frontend" \
    "LexAI frontend (static + /api proxy)" \
    "$REPO_DIR/frontend" \
    "/usr/bin/node server.js"

sudo systemctl daemon-reload
ok "유닛 3종 등록 — $SYSTEMD_DIR/lexai-*.service"
ok "환경변수 파일: $ENV_FILE (start.sh 가 생성)"



log "6. 애플리케이션 의존성"
# -----------------------------------------------------------
if [ -d "$REPO_DIR/frontend" ]; then
    (cd "$REPO_DIR/frontend" && npm ci --omit=dev >/dev/null)
    ok "frontend 의존성 설치"
fi

# -----------------------------------------------------------
# AI venv
#
# ★ 예전에는 "없으면 직접 만드세요" 경고만 했습니다. 색인을 만들던 VM 에는
#   venv 가 이미 있어서 문제가 드러나지 않았지만, 순정 VM 에서는 여기를
#   그냥 지나간 뒤 start.sh 가 없는 uvicorn 을 찾다 실패합니다.
#   무인 기동이 목적이므로 직접 만듭니다.
#
# torch 는 CPU 빌드를 먼저 명시적으로 넣습니다 — 컨테이너(ai/Dockerfile)와
# 같은 방식입니다. LLM 추론은 Ollama(GPU)가 담당하고 여기서 torch 가 쓰이는
# 곳은 질문 1건 임베딩뿐이라 CPU 로 50ms 수준입니다. CUDA 빌드는 약 2.5GB
# 더 크고, 두 형태의 응답 시간을 비교할 때 조건도 어긋납니다.
# -----------------------------------------------------------
VENV="$REPO_DIR/ai/.venv"
if [ -x "$VENV/bin/uvicorn" ]; then
    ok "AI venv 확인 ($("$VENV/bin/python" --version 2>&1 | cut -d' ' -f2))"
else
    if [ -d "$VENV" ]; then
        warn "venv 가 있지만 uvicorn 이 없습니다 — 다시 만듭니다"
        rm -rf "$VENV"
    fi
    log "   venv 생성 · 의존성 설치 (수 분 걸립니다)"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --quiet --upgrade pip
    "$VENV/bin/pip" install --quiet --no-cache-dir \
        --index-url https://download.pytorch.org/whl/cpu torch==2.4.1
    "$VENV/bin/pip" install --quiet --no-cache-dir -r "$REPO_DIR/ai/requirements_server.txt"
    [ -x "$VENV/bin/uvicorn" ] || die "uvicorn 이 설치되지 않았습니다 — 위 오류를 확인하세요"
    ok "AI venv 생성 ($("$VENV/bin/python" --version 2>&1 | cut -d' ' -f2))"
fi


echo
log "설치 완료"
echo "  다음: bash deploy/native/restore.sh   (색인 복원 + 모델 준비 + 스키마)"
