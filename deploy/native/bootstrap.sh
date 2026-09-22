#!/usr/bin/env bash
# ===========================================================
# 부트스트랩 — 사람이 하는 일은 VM 생성과 SSH 접속까지
#
#   curl -fsSL https://raw.githubusercontent.com/YunHwa0905/legal-rag-chatbot/feat/sqlite/deploy/native/bootstrap.sh | bash
#
# 이 한 줄이 아래를 전부 수행합니다.
#
#   1. git / 기본 도구 확보
#   2. 저장소 clone (이미 있으면 갱신)
#   3. .env 생성 — 시크릿 자동 발급
#   4. NVIDIA 드라이버 설치 → 재부팅 → 부팅 후 스스로 이어서 실행
#   5. 이관 패키지 내려받기 (SNAPSHOT_URI 를 준 경우)
#   6. up.sh 호출 — 설치 · 데이터 준비 · 기동 · 검증
#
# 여러 번 실행해도 안전합니다. 이미 끝난 단계는 건너뜁니다.
#
# -----------------------------------------------------------
# 환경변수 (전부 선택)
#
#   BRANCH         받을 브랜치            기본 feat/sqlite
#   REPO_URL       저장소 주소
#   REPO_DIR       설치 위치              기본 ~/legal-rag-chatbot
#   SNAPSHOT_URI   이관 패키지 위치       s3://… 또는 https://…
#   SKIP_DRIVER=1  드라이버 설치 건너뛰기 (GPU 이미지를 쓰는 경우)
#   NO_START=1     준비만 하고 기동은 안 함
#
# 예)
#   curl -fsSL <raw url> | BRANCH=feat/sqlite SNAPSHOT_URI=s3://버킷/lexai bash
# ===========================================================

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/YunHwa0905/legal-rag-chatbot.git}"
BRANCH="${BRANCH:-feat/sqlite}"
REPO_DIR="${REPO_DIR:-$HOME/legal-rag-chatbot}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-$HOME/lexai-snapshots}"
DATA_DIR="${DATA_DIR:-$HOME/lexai-data}"
SECRET_FILE="$HOME/.lexai-secrets"
RESUME_UNIT="lexai-bootstrap-resume"

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

log()  { printf '\033[1;35m[bootstrap]\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m  OK\033[0m   %s\n' "$*"; }
warn() { printf '\033[0;33m  WARN\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m  FATAL\033[0m %s\n' "$*" >&2; exit 1; }


# -----------------------------------------------------------
# 1. 기본 도구
# -----------------------------------------------------------
log "1. 기본 도구"
need=""
for c in git curl openssl; do command -v "$c" >/dev/null 2>&1 || need="$need $c"; done
if [ -n "$need" ]; then
    sudo apt-get update -qq
    sudo apt-get install -y git curl openssl ca-certificates
fi
ok "git $(git --version | cut -d' ' -f3)"


# -----------------------------------------------------------
# 2. 저장소
#
# rsync 로 복사해 둔 디렉터리가 남아 있으면 clone 이 실패합니다.
# git 저장소가 아닌 디렉터리는 타임스탬프를 붙여 비켜둡니다.
# -----------------------------------------------------------
log "2. 저장소"
if [ -d "$REPO_DIR/.git" ]; then
    git -C "$REPO_DIR" fetch --quiet origin "$BRANCH"
    git -C "$REPO_DIR" checkout --quiet "$BRANCH"
    git -C "$REPO_DIR" merge --ff-only --quiet "origin/$BRANCH" || warn "로컬 커밋이 있어 갱신을 건너뜁니다"
    ok "갱신: $(git -C "$REPO_DIR" rev-parse --short HEAD) ($BRANCH)"
else
    if [ -e "$REPO_DIR" ]; then
        backup="${REPO_DIR}.bak-$(date +%Y%m%d-%H%M%S)"
        mv "$REPO_DIR" "$backup"
        warn "git 저장소가 아닌 디렉터리를 발견해 옮겼습니다: $backup"
    fi
    git clone --quiet --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
    ok "clone: $(git -C "$REPO_DIR" rev-parse --short HEAD) ($BRANCH)"
fi

NATIVE_DIR="$REPO_DIR/deploy/native"
[ -f "$NATIVE_DIR/up.sh" ] || die "스크립트를 찾지 못했습니다: $NATIVE_DIR/up.sh"


# -----------------------------------------------------------
# 3. .env
#
# 시크릿을 자동 발급합니다. 사람이 값을 만들어 넣는 단계를 없애는 게 목적이라,
# 이미 .env 가 있으면 건드리지 않습니다(재실행 시 비밀번호가 바뀌면 기존
# OpenSearch 색인에 접속하지 못합니다).
# -----------------------------------------------------------
log "3. 환경 파일"
if [ -f "$REPO_DIR/.env" ]; then
    ok "이미 존재 — 건너뜀"
else
    cp "$REPO_DIR/.env.example" "$REPO_DIR/.env"

    # HS256 이라 32바이트 이상이어야 합니다.
    jwt="$(openssl rand -base64 48 | tr -d '\n')"
    # OpenSearch 2.12+ 는 대문자·소문자·숫자·특수문자를 모두 요구합니다.
    # 무작위 부분에 네 종류를 확실히 덧붙여 복잡도 조건을 항상 만족시킵니다.
    ospw="$(openssl rand -base64 18 | tr -d '/+=\n')Aa1!"

    python3 - "$REPO_DIR/.env" "$jwt" "$ospw" "$DATA_DIR/lexai.db" <<'PY'
import io, sys, re
path, jwt, ospw, dbpath = sys.argv[1:5]
s = io.open(path, encoding="utf-8").read()
for key, val in (("JWT_SECRET", jwt), ("OPENSEARCH_PASSWORD", ospw), ("DB_PATH", dbpath)):
    s = re.sub(rf"(?m)^{key}=.*$", f"{key}={val}", s)
io.open(path, "w", encoding="utf-8", newline="\n").write(s)
PY

    chmod 600 "$REPO_DIR/.env"
    { echo "생성 시각 : $(date '+%Y-%m-%d %H:%M:%S')"
      echo "JWT_SECRET=$jwt"
      echo "OPENSEARCH_PASSWORD=$ospw"; } > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"

    ok "생성 — 시크릿 2종 자동 발급"
    warn "시크릿 사본: $SECRET_FILE (이관 시 대상 환경에 같은 값을 넣어야 합니다)"
fi


# -----------------------------------------------------------
# 4. NVIDIA 드라이버
#
# 없으면 설치하고 재부팅합니다. 재부팅 뒤에는 systemd oneshot 이 이 스크립트를
# --resume 으로 다시 호출해 같은 지점부터 이어갑니다 — 사람이 다시 접속해
# 명령을 칠 필요가 없습니다.
#
# 진행 상황: journalctl -u lexai-bootstrap-resume -f
# -----------------------------------------------------------
log "4. GPU 드라이버"
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

    # 재부팅 후 이어서 실행할 유닛을 등록합니다.
    sudo tee "/etc/systemd/system/${RESUME_UNIT}.service" >/dev/null <<EOF
[Unit]
Description=LexAI bootstrap resume (드라이버 재부팅 후 이어서 실행)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=$(id -un)
Environment=HOME=$HOME
Environment=BRANCH=$BRANCH
Environment=REPO_DIR=$REPO_DIR
Environment=SNAPSHOT_URI=${SNAPSHOT_URI:-}
Environment=NO_START=$NO_START
ExecStart=$NATIVE_DIR/bootstrap.sh --resume

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable "$RESUME_UNIT" >/dev/null
    chmod +x "$NATIVE_DIR"/*.sh

    warn "재부팅합니다. 재접속 후 아래로 진행 상황을 확인하세요:"
    warn "  journalctl -u ${RESUME_UNIT} -f"
    sleep 3
    sudo reboot
    exit 0
fi

# 재부팅으로 돌아온 경우, 다음 부팅부터는 다시 돌지 않도록 유닛을 해제합니다.
if [ "$RESUME" = "1" ]; then
    sudo systemctl disable "$RESUME_UNIT" >/dev/null 2>&1 || true
    ok "재부팅 후 자동 재개 — 유닛 해제"
fi


# -----------------------------------------------------------
# 5. 이관 패키지
#
# SNAPSHOT_URI 를 주면 색인 스냅샷과 DB 를 받아 제자리에 둡니다.
# 주지 않으면 이 단계를 건너뛰고, 색인이 없으면 up.sh 가 거기서 멈춥니다
# (색인 없이 기동하면 서비스는 정상으로 보이는데 답변만 근거가 없습니다).
# -----------------------------------------------------------
log "5. 이관 패키지"
if [ -z "${SNAPSHOT_URI:-}" ]; then
    ok "SNAPSHOT_URI 미지정 — 건너뜀"
else
    mkdir -p "$SNAPSHOT_DIR" "$DATA_DIR"
    tmp="$(mktemp -d)"

    fetch() {  # fetch <원본> <받을 파일>
        case "$1" in
            s3://*)   command -v aws >/dev/null 2>&1 || die "aws CLI 가 필요합니다"
                      aws s3 cp "$1" "$2" --only-show-errors ;;
            gs://*)   command -v gsutil >/dev/null 2>&1 || die "gsutil 이 필요합니다"
                      gsutil -q cp "$1" "$2" ;;
            http*)    curl -fsSL "$1" -o "$2" ;;
            *)        cp "$1" "$2" ;;
        esac
    }

    log "   내려받는 중: $SNAPSHOT_URI"
    fetch "${SNAPSHOT_URI%/}/opensearch-snapshots.tar.gz" "$tmp/snap.tar.gz"
    tar -xzf "$tmp/snap.tar.gz" -C "$SNAPSHOT_DIR"
    ok "색인 스냅샷 배치 ($(du -sh "$SNAPSHOT_DIR" | cut -f1))"

    if fetch "${SNAPSHOT_URI%/}/lexai.db" "$tmp/lexai.db" 2>/dev/null; then
        cp "$tmp/lexai.db" "$DATA_DIR/lexai.db"
        ok "DB 배치 ($(du -h "$DATA_DIR/lexai.db" | cut -f1))"
    else
        warn "DB 파일이 없어 건너뜁니다 — 빈 DB 로 시작합니다"
    fi
    rm -rf "$tmp"
fi


# -----------------------------------------------------------
# 6. 설치 · 기동 · 검증
# -----------------------------------------------------------
chmod +x "$NATIVE_DIR"/*.sh

if [ "$NO_START" = "1" ]; then
    echo
    log "준비 완료 (NO_START=1 — 기동은 하지 않았습니다)"
    echo "  기동: bash $NATIVE_DIR/up.sh"
    exit 0
fi

log "6. up.sh 실행"
exec bash "$NATIVE_DIR/up.sh"
