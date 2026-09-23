#!/usr/bin/env bash
# ===========================================================
# Docker Compose 배포 — 사람이 하는 일은 VM 생성과 SSH 접속까지
#
#   curl -fsSL https://raw.githubusercontent.com/YunHwa0905/legal-rag-chatbot/feat/sqlite/deploy/compose/deploy.sh | bash
#
# 이 한 줄이 아래를 전부 수행합니다.
#
#   1. 기본 도구 확보
#   2. NVIDIA 드라이버 설치 → 재부팅 → 부팅 후 스스로 이어서 실행
#   3. Docker 엔진 + nvidia-container-toolkit → 컨테이너 GPU 통과 검증
#   4. compose 정의 수신 (파일 3개) — 저장소 clone 없음
#   5. .env 생성 — 시크릿 자동 발급
#   6. 레지스트리에서 이미지 pull → 기동
#   7. 이관 패키지가 있으면 색인 복원
#   8. 헬스체크
#
# -----------------------------------------------------------
# ★ 이 스크립트는 저장소와 독립적으로 동작합니다.
#
#   타겟 환경에 git 도 소스도 필요 없습니다. 이미지가 곧 산출물이고,
#   compose 정의는 raw URL 로 받는 파일 3개가 전부입니다. 네이티브
#   형태(deploy/native/bootstrap.sh)가 소스를 clone 해서 빌드하는 것과
#   대비되는 지점이며, 이관 실증에서 두 형태의 차이가 여기서 드러납니다.
#
#   저장소 안에 두는 이유는 버전 관리 때문입니다 — 커밋 해시로 재현성이
#   고정되고, compose 정의와 같이 움직입니다. 타겟 입장에서는 여전히
#   curl 한 줄이라 "소스 없는 배포" 성질은 그대로입니다.
# -----------------------------------------------------------
#
# 여러 번 실행해도 안전합니다. 이미 끝난 단계는 건너뜁니다.
#
# -----------------------------------------------------------
# 환경변수 (전부 선택)
#
#   BRANCH            compose 정의를 받을 브랜치   기본 feat/sqlite
#   DEPLOY_DIR        배포 디렉터리                기본 ~/lexai-compose
#   REGISTRY_PREFIX   레지스트리                   기본 yunhwa0905
#   IMAGE_TAG         이미지 태그                  기본 v2
#   SNAPSHOT_URI      이관 패키지 위치             s3://… 또는 https://…
#   SKIP_DRIVER=1     드라이버 설치 건너뛰기 (GPU 이미지를 쓰는 경우)
#   NO_START=1        준비만 하고 기동은 안 함
#
# 예) 다른 CSP 의 레지스트리에서 받아 띄우기
#   curl -fsSL <raw url> | REGISTRY_PREFIX=asia-northeast3-docker.pkg.dev/proj/repo \
#        IMAGE_TAG=v2 SNAPSHOT_URI=s3://버킷/lexai/20260923-1031 bash
# ===========================================================

set -euo pipefail

# 이관 도구(postCommands)는 대화형이 아니므로 apt 가 질문을 던지면 멈춥니다.
export DEBIAN_FRONTEND=noninteractive

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/YunHwa0905/legal-rag-chatbot}"
BRANCH="${BRANCH:-feat/sqlite}"
RAW_BASE="${REPO_RAW}/${BRANCH}"
SELF_URL="${RAW_BASE}/deploy/compose/deploy.sh"

DEPLOY_DIR="${DEPLOY_DIR:-$HOME/lexai-compose}"
RESUME_UNIT="lexai-compose-resume"
SECRET_FILE="$HOME/.lexai-secrets"

REGISTRY_PREFIX="${REGISTRY_PREFIX:-yunhwa0905}"
IMAGE_TAG="${IMAGE_TAG:-v2}"
INDEX_NAME="${INDEX_NAME:-legal_documents}"
SNAPSHOT_REPO="${SNAPSHOT_REPO:-lexai}"

RESUME=0
NO_START="${NO_START:-0}"
for arg in "${@:-}"; do
    case "$arg" in
        --resume)   RESUME=1 ;;
        --no-start) NO_START=1 ;;
        "")         ;;
        *) echo "모르는 옵션: $arg" >&2; exit 1 ;;
    esac
done

# 이관 도구로 실행되면 TTY 가 없고 출력이 로그로 수집됩니다.
# 색상 제어문자가 섞이면 읽기 어려우니 TTY 일 때만 색을 씁니다.
if [ -t 1 ]; then
    C_HEAD=$'\033[1;35m'; C_OK=$'\033[0;32m'
    C_WARN=$'\033[0;33m'; C_ERR=$'\033[0;31m'; C_OFF=$'\033[0m'
else
    C_HEAD=""; C_OK=""; C_WARN=""; C_ERR=""; C_OFF=""
fi

log()  { printf '%s[compose]%s %s\n' "$C_HEAD" "$C_OFF" "$*"; }
ok()   { printf '%s  OK%s   %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%s  WARN%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '%s  FATAL%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }


# -----------------------------------------------------------
# 실행 사용자
#
# 이관 도구는 이 스크립트를 root 로 실행할 수 있습니다. 그대로 진행하면
# 배포 디렉터리와 .env 가 /root 아래에 생겨, 나중에 사람이 SSH 로 붙었을 때
# 아무것도 보이지 않습니다. root 면 대상 사용자를 정해 그 사용자로 다시
# 실행합니다 (deploy/native/bootstrap.sh 와 같은 방식).
# -----------------------------------------------------------
if [ "$(id -u)" -eq 0 ] && [ "${LEXAI_REEXEC:-0}" != "1" ]; then
    _user="${TARGET_USER:-${SUDO_USER:-}}"
    if [ -z "$_user" ] || [ "$_user" = "root" ]; then
        _user="$( { getent passwd 1000 | cut -d: -f1; } || true )"
    fi
    [ -n "$_user" ] || die "일반 사용자를 찾지 못했습니다. TARGET_USER 로 지정하세요."

    _home="$(getent passwd "$_user" | cut -d: -f6)"

    log "root 로 실행되었습니다 — ${_user} 사용자로 이어서 진행합니다"

    if ! command -v curl >/dev/null 2>&1; then
        apt-get update -qq
        apt-get install -y curl ca-certificates openssl
    fi

    _dir="${DEPLOY_DIR:-$_home/lexai-compose}"
    sudo -u "$_user" -H mkdir -p "$_dir"
    sudo -u "$_user" -H curl -fsSL "$SELF_URL" -o "$_dir/deploy.sh"
    chmod +x "$_dir/deploy.sh"

    _args=()
    if [ "$RESUME" = "1" ]; then _args+=(--resume); fi
    if [ "$NO_START" = "1" ]; then _args+=(--no-start); fi

    exec sudo -u "$_user" -H env \
        LEXAI_REEXEC=1 \
        BRANCH="$BRANCH" DEPLOY_DIR="$_dir" \
        REGISTRY_PREFIX="$REGISTRY_PREFIX" IMAGE_TAG="$IMAGE_TAG" \
        SNAPSHOT_URI="${SNAPSHOT_URI:-}" SKIP_DRIVER="${SKIP_DRIVER:-0}" \
        bash "$_dir/deploy.sh" "${_args[@]:-}"
fi


# -----------------------------------------------------------
# 1. 기본 도구
# -----------------------------------------------------------
log "1. 기본 도구"
need=""
for c in curl openssl; do command -v "$c" >/dev/null 2>&1 || need="$need $c"; done
if [ -n "$need" ]; then
    sudo apt-get update -qq
    sudo apt-get install -y curl openssl ca-certificates
fi

mkdir -p "$DEPLOY_DIR"

# 재부팅 후 이어서 실행하려면 스크립트가 디스크에 있어야 합니다.
# curl | bash 로 들어온 경우 파일 경로가 없으므로 사본을 받아둡니다.
if [ ! -f "$DEPLOY_DIR/deploy.sh" ]; then
    curl -fsSL "$SELF_URL" -o "$DEPLOY_DIR/deploy.sh"
    chmod +x "$DEPLOY_DIR/deploy.sh"
fi
ok "배포 디렉터리: $DEPLOY_DIR"


# -----------------------------------------------------------
# 2. NVIDIA 드라이버
#
# 없으면 설치하고 재부팅합니다. 재부팅 뒤에는 systemd oneshot 이 이 스크립트를
# --resume 으로 다시 호출해 같은 지점부터 이어갑니다.
#
# 진행 상황: journalctl -u lexai-compose-resume -f
# -----------------------------------------------------------
log "2. GPU 드라이버"
if [ "${SKIP_DRIVER:-0}" = "1" ]; then
    ok "SKIP_DRIVER=1 — 건너뜀"
elif nvidia-smi >/dev/null 2>&1; then
    ok "$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader | head -1)"
elif ! lspci 2>/dev/null | grep -qi nvidia; then
    warn "NVIDIA GPU 가 없는 인스턴스입니다 — 드라이버 설치를 건너뜁니다"
    warn "추론이 CPU 로 떨어져 응답이 1~3분이 됩니다. 백엔드 타임아웃이 180초라"
    warn "채팅이 실패할 수 있으니 .env 의 MAX_NEW_TOKENS 를 낮추세요."
else
    log "   드라이버가 없어 설치합니다 (설치 후 자동 재부팅)"
    sudo apt-get update -qq
    sudo apt-get install -y ubuntu-drivers-common
    sudo ubuntu-drivers install --gpgpu || sudo ubuntu-drivers autoinstall

    sudo tee "/etc/systemd/system/${RESUME_UNIT}.service" >/dev/null <<EOF
[Unit]
Description=LexAI compose deploy resume (드라이버 재부팅 후 이어서 실행)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=$(id -un)
Environment=HOME=$HOME
Environment=BRANCH=$BRANCH
Environment=DEPLOY_DIR=$DEPLOY_DIR
Environment=REGISTRY_PREFIX=$REGISTRY_PREFIX
Environment=IMAGE_TAG=$IMAGE_TAG
Environment=SNAPSHOT_URI=${SNAPSHOT_URI:-}
Environment=NO_START=$NO_START
ExecStart=$DEPLOY_DIR/deploy.sh --resume

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable "$RESUME_UNIT" >/dev/null

    warn "재부팅합니다. 재접속 후 아래로 진행 상황을 확인하세요:"
    warn "  journalctl -u ${RESUME_UNIT} -f"
    sleep 3
    sudo reboot
    exit 0
fi

if [ "$RESUME" = "1" ]; then
    sudo systemctl disable "$RESUME_UNIT" >/dev/null 2>&1 || true
    ok "재부팅 후 자동 재개 — 유닛 해제"
fi


# -----------------------------------------------------------
# 3. Docker + nvidia-container-toolkit
#
# 네이티브 형태와 갈리는 지점입니다. 네이티브는 호스트 드라이버만 있으면
# Ollama 가 GPU 를 바로 쓰지만, 컨테이너는 toolkit 이 있어야 디바이스가
# 안으로 전달됩니다. 없으면 에러 없이 CPU 로 폴백해 응답이 1~3분이 되고,
# 서비스는 정상으로 보이기 때문에 늦게 발견됩니다 — 그래서 여기서 실제로
# 컨테이너를 하나 띄워 확인합니다.
# -----------------------------------------------------------
log "3. Docker"
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker "$(id -un)"
    ok "Docker 설치 — $(id -un) 를 docker 그룹에 추가"
else
    ok "이미 설치됨 — $(docker --version | cut -d' ' -f3 | tr -d ,)"
fi

# 방금 그룹에 추가된 경우 현재 셸에는 아직 반영되지 않습니다.
# 재로그인 대신 sudo 로 우회합니다(재실행 시에는 그냥 docker 로 붙습니다).
if docker info >/dev/null 2>&1; then
    DOCKER="docker"
else
    DOCKER="sudo docker"
fi

# docker-compose.registry.yml 의 build: !reset null 은 v2.24+ 문법입니다.
# 낮은 버전이면 본체의 build: 가 살아남아 소스 없는 환경에서 빌드를 시도합니다.
cver="$($DOCKER compose version --short 2>/dev/null || echo 0)"
cmajor="${cver%%.*}"; crest="${cver#*.}"; cminor="${crest%%.*}"
if [ "${cmajor:-0}" -lt 2 ] || { [ "${cmajor:-0}" -eq 2 ] && [ "${cminor:-0}" -lt 24 ]; }; then
    die "Docker Compose ${cver} 는 너무 낮습니다 — v2.24 이상이 필요합니다 (build: !reset)"
fi
ok "Compose v${cver}"

if nvidia-smi >/dev/null 2>&1; then
    if ! $DOCKER info 2>/dev/null | grep -qi nvidia; then
        log "   nvidia-container-toolkit 설치"
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
            | sudo gpg --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
            | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
            | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
        sudo apt-get update -qq
        sudo apt-get install -y nvidia-container-toolkit
        sudo nvidia-ctk runtime configure --runtime=docker
        sudo systemctl restart docker
        ok "toolkit 설치 · docker 런타임 등록"
    else
        ok "toolkit 이미 등록됨 — 건너뜀"
    fi

    # toolkit 이 호스트의 nvidia-smi 를 컨테이너 안으로 주입하므로,
    # 별도의 CUDA 이미지를 받지 않고 작은 베이스 이미지로 확인할 수 있습니다.
    log "   컨테이너 GPU 통과 확인"
    if gpu="$($DOCKER run --rm --gpus all ubuntu:22.04 \
             nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1)"; then
        ok "컨테이너에서 GPU 인식: $gpu"
    else
        die "컨테이너가 GPU 를 보지 못합니다 — toolkit 설정을 확인하세요 (docker info | grep -i nvidia)"
    fi
else
    warn "호스트에 GPU 가 없어 컨테이너 GPU 검증을 건너뜁니다"
fi


# -----------------------------------------------------------
# 4. compose 정의 수신
#
# 받는 것은 아래 3개뿐입니다. 이미지는 레지스트리에서 오므로 소스는
# 필요 없지만, compose 본체가 바인드 마운트하는 파일 두 개는 호스트에
# 있어야 합니다 — 그래서 저장소와 같은 상대 경로로 배치합니다.
#
#   docker-compose.yml            서비스 정의 (build: 포함 — 아래에서 덮음)
#   docker-compose.registry.yml   build: 제거 + image: 지정
#   deploy/schema.sqlite.sql      tomcat 이 최초 기동 시 스키마를 만드는 파일
#
#   deploy/snapshots/             OpenSearch path.repo — 색인 복원 위치
# -----------------------------------------------------------
log "4. compose 정의"
mkdir -p "$DEPLOY_DIR/deploy/snapshots"

fetch_raw() {  # fetch_raw <저장소 상대경로>
    curl -fsSL "${RAW_BASE}/$1" -o "$DEPLOY_DIR/$1" \
        || die "받지 못했습니다: ${RAW_BASE}/$1"
}
fetch_raw "docker-compose.yml"
fetch_raw "docker-compose.registry.yml"
fetch_raw "deploy/schema.sqlite.sql"
ok "파일 3개 수신 (브랜치 $BRANCH)"


# -----------------------------------------------------------
# 5. .env
#
# 시크릿을 자동 발급합니다. 이미 있으면 건드리지 않습니다 — 재실행할 때
# 비밀번호가 바뀌면 기존 OpenSearch 볼륨에 접속하지 못합니다.
# -----------------------------------------------------------
log "5. 환경 파일"
ENV_FILE="$DEPLOY_DIR/.env"
if [ -f "$ENV_FILE" ]; then
    ok "이미 존재 — 건너뜀"
else
    # HS256 이라 32바이트 이상이어야 합니다.
    jwt="$(openssl rand -base64 48 | tr -d '\n')"
    # OpenSearch 2.12+ 는 대문자·소문자·숫자·특수문자를 모두 요구합니다.
    # 무작위 부분에 네 종류를 확실히 덧붙여 복잡도 조건을 항상 만족시킵니다.
    ospw="$(openssl rand -base64 18 | tr -d '/+=\n')Aa1!"

    cat > "$ENV_FILE" <<EOF
# deploy.sh 가 생성했습니다 — $(date '+%Y-%m-%d %H:%M:%S')
# 값을 바꾸면 docker compose up -d 로 다시 적용하세요.

JWT_SECRET=$jwt
JWT_EXPIRATION=86400000

OPENSEARCH_PASSWORD=$ospw
OPENSEARCH_HEAP=2g

# SQLite 가 datetime('now','localtime') 으로 기록하므로 반드시 필요합니다.
TZ=Asia/Seoul

# 이관 전후 동등성 비교용. 평소 운영은 TEMPERATURE=0.1 · LLM_SEED=-1.
TEMPERATURE=0.1
LLM_SEED=-1

REGISTRY_PREFIX=$REGISTRY_PREFIX
IMAGE_TAG=$IMAGE_TAG
EOF
    chmod 600 "$ENV_FILE"

    { echo "생성 시각 : $(date '+%Y-%m-%d %H:%M:%S') (compose)"
      echo "JWT_SECRET=$jwt"
      echo "OPENSEARCH_PASSWORD=$ospw"; } > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"

    ok "생성 — 시크릿 2종 자동 발급"
    warn "시크릿 사본: $SECRET_FILE (이관 시 대상 환경에 같은 값을 넣어야 합니다)"
fi

# 뒤에서 OpenSearch 에 붙을 때 씁니다.
OS_PW="$(grep -E '^OPENSEARCH_PASSWORD=' "$ENV_FILE" | tail -1 | cut -d= -f2-)"


# -----------------------------------------------------------
# 6. 이관 패키지
#
# 색인 스냅샷을 deploy/snapshots 에 풀어둡니다. OpenSearch 컨테이너가
# 이 디렉터리를 /mnt/snapshots (path.repo) 로 마운트하므로, 기동 후
# 복원 API 가 바로 읽을 수 있습니다.
# -----------------------------------------------------------
log "6. 이관 패키지"
if [ -z "${SNAPSHOT_URI:-}" ]; then
    ok "SNAPSHOT_URI 미지정 — 건너뜀 (색인 없이 뜨면 답변에 근거가 없습니다)"
else
    tmp="$(mktemp -d)"

    # ★ 순정 Ubuntu 이미지에는 클라우드 CLI 가 없습니다. 이관 도구가 부르는
    #   무인 실행이라 "직접 설치하세요" 로 끝내면 거기서 멈춥니다.
    ensure_cli() {  # ensure_cli <명령> <apt 패키지> <설치 안내>
        command -v "$1" >/dev/null 2>&1 && return 0
        log "   $1 설치"
        sudo apt-get update -qq
        sudo apt-get install -y "$2" >/dev/null 2>&1 \
            || die "$1 를 설치하지 못했습니다 — $3"
        ok "$1 설치됨"
    }

    fetch() {  # fetch <원본> <받을 파일>
        case "$1" in
            s3://*)   ensure_cli aws awscli "https://aws.amazon.com/cli/ 참고"
                      aws s3 cp "$1" "$2" --only-show-errors ;;
            gs://*)   ensure_cli gsutil google-cloud-cli "https://cloud.google.com/sdk/docs/install 참고 (apt 저장소 등록 필요)"
                      gsutil -q cp "$1" "$2" ;;
            http*)    curl -fsSL "$1" -o "$2" ;;
            *)        cp "$1" "$2" ;;
        esac
    }

    log "   내려받는 중: $SNAPSHOT_URI"
    fetch "${SNAPSHOT_URI%/}/opensearch-snapshots.tar.gz" "$tmp/opensearch-snapshots.tar.gz"

    # 전송 손상을 압축 풀기 전에 잡습니다. 깨진 아카이브를 풀어봐야
    # 뒤에서 더 알기 어려운 형태로 실패할 뿐입니다.
    if fetch "${SNAPSHOT_URI%/}/checksums.sha256" "$tmp/checksums.sha256" 2>/dev/null; then
        if ( cd "$tmp" && grep "opensearch-snapshots.tar.gz" checksums.sha256 | sha256sum -c --quiet ); then
            ok "아카이브 체크섬 확인"
        else
            die "아카이브 체크섬 불일치 — 전송이 온전하지 않습니다"
        fi
    else
        warn "checksums.sha256 이 없어 아카이브 체크섬 확인을 건너뜁니다"
    fi

    # -xf 는 압축 형식을 자동 판별합니다 (gzip / 무압축 둘 다 처리).
    tar -xf "$tmp/opensearch-snapshots.tar.gz" -C "$DEPLOY_DIR/deploy/snapshots"
    ok "색인 스냅샷 배치 ($(du -sh "$DEPLOY_DIR/deploy/snapshots" | cut -f1))"
    rm -rf "$tmp"
fi


# -----------------------------------------------------------
# 7. 기동
# -----------------------------------------------------------
cd "$DEPLOY_DIR"
compose() { $DOCKER compose -f docker-compose.yml -f docker-compose.registry.yml "$@"; }

if [ "$NO_START" = "1" ]; then
    echo
    log "준비 완료 (NO_START=1 — 기동은 하지 않았습니다)"
    echo "  기동: cd $DEPLOY_DIR && docker compose -f docker-compose.yml -f docker-compose.registry.yml up -d --no-build"
    exit 0
fi

log "7. 이미지 받기"
log "   ${REGISTRY_PREFIX}/lexai-{frontend,tomcat,ai}:${IMAGE_TAG}"
compose pull
ok "pull 완료"

log "8. 기동"
# --no-build 로 빌드 경로를 확실히 막습니다. registry 오버레이가 build: 를
# 지우지만, 오버레이를 빠뜨린 실행을 여기서도 한 번 더 걸러냅니다.
compose up -d --no-build

# ai 는 임베딩 모델을 미리 로드하고, 그 전에 ollama-init 이 모델을 받습니다.
# 최초 기동은 수 분 걸립니다(모델 5GB 다운로드 포함).
log "   서비스 준비 대기 (최초 기동은 수 분 걸립니다)"
deadline=$(( $(date +%s) + 900 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    if compose ps --format '{{.Service}} {{.Health}}' 2>/dev/null | grep -q '^ai healthy'; then
        break
    fi
    sleep 10
done
if compose ps --format '{{.Service}} {{.Health}}' 2>/dev/null | grep -q '^ai healthy'; then
    ok "ai 준비됨"
else
    warn "ai 가 15분 안에 준비되지 않았습니다 — docker compose logs ai 를 확인하세요"
fi


# -----------------------------------------------------------
# 8. 색인 복원
#
# 스냅샷을 넣어둔 경우에만 돕니다. 이미 색인이 있으면 건너뜁니다 —
# 재실행으로 멀쩡한 색인을 덮어쓰는 일을 막습니다.
# -----------------------------------------------------------
log "9. 색인"
os() {  # os <curl 인자...>
    $DOCKER compose -f docker-compose.yml -f docker-compose.registry.yml \
        exec -T opensearch curl -sk -u "admin:${OS_PW}" "$@"
}
OS_BASE="https://127.0.0.1:9200"

count=$( { os "$OS_BASE/${INDEX_NAME}/_count" | grep -o '"count":[0-9]*' | cut -d: -f2; } || true )
if [ -n "${count:-}" ] && [ "${count:-0}" -gt 0 ] 2>/dev/null; then
    ok "색인이 이미 있습니다 (${count}건) — 복원 건너뜀"
elif [ -z "$(ls -A "$DEPLOY_DIR/deploy/snapshots" 2>/dev/null)" ]; then
    warn "색인도 스냅샷도 없습니다 — 서비스는 뜨지만 답변에 근거 문서가 붙지 않습니다"
    warn "  SNAPSHOT_URI 를 주고 다시 실행하세요"
else
    os -X PUT "$OS_BASE/_snapshot/${SNAPSHOT_REPO}" \
        -H 'Content-Type: application/json' \
        -d '{"type":"fs","settings":{"location":"/mnt/snapshots"}}' >/dev/null
    ok "스냅샷 저장소 등록"

    # 패키지마다 스냅샷 이름이 달라(legal-<타임스탬프>) 고정할 수 없습니다.
    # SUCCESS 인 것 중 가장 최근 것을 고릅니다.
    snap=$( { os "$OS_BASE/_cat/snapshots/${SNAPSHOT_REPO}?h=id,status,endEpoch" \
        | awk '$2=="SUCCESS"' | sort -k3 -n | tail -1 | awk '{print $1}'; } || true )
    [ -n "$snap" ] || die "복원할 스냅샷이 없습니다 — deploy/snapshots 내용을 확인하세요"

    log "   복원 중: $snap (수 분 걸립니다)"
    started=$(date +%s)
    os -X POST "$OS_BASE/_snapshot/${SNAPSHOT_REPO}/${snap}/_restore?wait_for_completion=true" \
        -H 'Content-Type: application/json' \
        -d "{\"indices\":\"${INDEX_NAME}\"}" >/dev/null
    elapsed=$(( $(date +%s) - started ))

    count=$( { os "$OS_BASE/${INDEX_NAME}/_count" | grep -o '"count":[0-9]*' | cut -d: -f2; } || true )
    [ "${count:-0}" -gt 0 ] || die "복원 후에도 색인이 비어 있습니다"
    ok "복원 완료 — ${count}건 (${elapsed}초)"
fi


# -----------------------------------------------------------
# 9. 헬스체크
# -----------------------------------------------------------
log "10. 확인"
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1/" || echo 000)
[ "$code" = "200" ] && ok "프론트엔드 HTTP $code" || warn "프론트엔드 HTTP $code (기대 200)"

echo
compose ps --format 'table {{.Service}}\t{{.Status}}'

echo
log "배포 완료: $DEPLOY_DIR"
echo "  로그   : cd $DEPLOY_DIR && docker compose logs -f"
echo "  종료   : cd $DEPLOY_DIR && docker compose down"
echo "  재기동 : bash $DEPLOY_DIR/deploy.sh"
echo
echo "  ※ 보안 그룹에서 80 을 열지 않았다면 SSH 터널로 접속하세요:"
echo "      ssh -L 8080:localhost:80 ubuntu@<이 VM 의 IP>   → http://localhost:8080"
