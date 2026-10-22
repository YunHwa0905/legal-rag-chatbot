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
#   NO_UPDATE=1    이관 모드 — 옮겨온 저장소를 GitHub 에서 갱신하지 않음
#                  (저장소가 없으면 clone 하지 않고 멈춥니다)
#                  SNAPSHOT_URI 필수, 체크섬·소스 커밋이 패키지와 다르면 멈춤
#                  대상에 기존 설치(DB·스냅샷·유닛)가 있으면 멈춤
#                  verify.sh(응답 검증)는 기본으로 건너뜁니다 — 아래 RUN_VERIFY
#   RUN_VERIFY=1   이관 모드에서도 verify.sh 를 실행 (verify 계정 · 채팅이 DB 에 남음)
#   TARGET_USER    root 로 실행될 때 서비스를 돌릴 사용자 (기본: cb-user 가 있으면
#                  cb-user, 없으면 uid 1000)
#
# 진행 상황(오케스트레이터용): ~/lexai-run/status.json — README "상태 파일" 참고
#   FORCE_CLEAN=1  기존 설치가 있어도 진행 — 서비스 중지 → 색인 삭제 →
#                  기존 DB 는 ~/lexai-replaced/<시각> 으로 옮김 → 스냅샷 폴더 비움
#                  (패키지 검증이 모두 끝난 뒤에만 비웁니다)
#
# 예)
#   curl -fsSL <raw url> | BRANCH=feat/sqlite SNAPSHOT_URI=s3://버킷/lexai bash
#
#   # 저장소째 옮긴 경우 (Beetle 데이터 마이그레이션 등)
#   # ★ curl 로 받지 말고 옮겨온 스크립트를 실행하세요. 받은 스크립트는
#   #   브랜치 최신본이라 옮겨온 소스와 버전이 다를 수 있습니다.
#   NO_UPDATE=1 SNAPSHOT_URI=$HOME/lexai-backup/latest \
#     bash ~/legal-rag-chatbot/deploy/native/bootstrap.sh
# ===========================================================

set -euo pipefail

# -----------------------------------------------------------
# 무인 apt
#
# 이관 도구(postCommands)는 대화형이 아니므로 apt 가 질문을 던지면 멈춥니다.
#
# ★ export 만으로는 부족합니다. sudo 가 환경변수를 지우기 때문에(env_reset)
#   `sudo apt-get` 에는 이 값이 전달되지 않습니다. 호출마다 직접 넘깁니다.
#
# ★ needrestart 는 debconf 가 아니라 별도 도구라 DEBIAN_FRONTEND 로 막히지
#   않습니다. 커널이 올라가면 "Pending kernel upgrade" 대화상자를 띄우고,
#   무인 실행은 거기서 영원히 멈춥니다. 실제로 겪었습니다.
# -----------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive

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


# -----------------------------------------------------------
# GPU 판정
#
# ★ nvidia-smi 하나로 판단하면 안 됩니다. ubuntu-drivers 가 설치하는
#   headless 변형에는 그 명령이 없습니다(nvidia-utils 패키지에 들어 있습니다).
#   드라이버가 멀쩡히 올라와도 "없음" 으로 읽히고, 그러면 설치와 재부팅을
#   무한 반복합니다 — 실제로 겪었습니다. 커널 모듈 존재도 함께 봅니다.
# -----------------------------------------------------------
gpu_ready() {
    nvidia-smi >/dev/null 2>&1 && return 0
    [ -e /proc/driver/nvidia/version ]
}

# headless 설치로 빠진 nvidia-smi 를 채웁니다. 없어도 추론은 되지만,
# GPU 를 쓰는지 확인할 방법이 사라져 CPU 폴백을 못 잡습니다.
ensure_nvidia_smi() {
    command -v nvidia-smi >/dev/null 2>&1 && return 0
    local drv
    drv=$( { dpkg -l 2>/dev/null \
        | awk '$1=="ii" && $2 ~ /^nvidia-(headless|driver)-/ {print $2}' \
        | grep -oE '[0-9]{3}' | sort -u | tail -1; } || true )
    [ -n "$drv" ] || return 0
    log "   nvidia-smi 가 없어 nvidia-utils-${drv} 를 설치합니다"
    apt_q install -y "nvidia-utils-${drv}-server" >/dev/null 2>&1 \
        || apt_q install -y "nvidia-utils-${drv}" >/dev/null 2>&1 || true
}

gpu_desc() {
    nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1 \
        || head -1 /proc/driver/nvidia/version 2>/dev/null \
        || echo "드라이버 확인됨"
}

REPO_URL="${REPO_URL:-https://github.com/YunHwa0905/legal-rag-chatbot.git}"
BRANCH="${BRANCH:-feat/sqlite}"

RESUME=0
NO_START="${NO_START:-0}"
NO_UPDATE="${NO_UPDATE:-0}"
FORCE_CLEAN="${FORCE_CLEAN:-0}"
RUN_VERIFY="${RUN_VERIFY:-0}"
for arg in "${@:-}"; do
    case "$arg" in
        --resume)   RESUME=1 ;;
        --no-start) NO_START=1 ;;
        "")         ;;
        *) echo "모르는 옵션: $arg" >&2; exit 1 ;;
    esac
done

# 이관 도구(postCommands)로 실행되면 TTY 가 없고 출력이 로그로 수집됩니다.
# 색상 제어문자가 섞이면 읽기 어려우니 TTY 일 때만 색을 씁니다.
if [ -t 1 ]; then
    C_HEAD="\033[1;35m"; C_OK="\033[0;32m"
    C_WARN="\033[0;33m"; C_ERR="\033[0;31m"; C_OFF="\033[0m"
else
    C_HEAD=""; C_OK=""; C_WARN=""; C_ERR=""; C_OFF=""
fi

log()  { printf '%b[bootstrap]%b %s\n' "$C_HEAD" "$C_OFF" "$*"; }
ok()   { printf '%b  OK%b   %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%b  WARN%b %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()  {
    printf '%b  FATAL%b %s\n' "$C_ERR" "$C_OFF" "$*" >&2
    if type status_set >/dev/null 2>&1; then status_set "last_error=$*"; fi
    exit 1
}


# -----------------------------------------------------------
# 실행 사용자
#
# 이관 도구는 이 스크립트를 root 로 실행할 수 있습니다. 그런데 서비스는
# 일반 사용자로 돌아야 합니다 — systemd 유닛의 User=, 파일 소유권, venv
# 경로가 전부 그 사용자 기준이기 때문입니다. root 로 그냥 진행하면
# /root 아래에 설치되어 나중에 사람이 SSH 로 붙었을 때 아무것도 안 보입니다.
#
# 그래서 root 면 대상 사용자를 정하고, 저장소를 그 사용자로 받은 뒤
# 같은 스크립트를 그 사용자로 다시 실행합니다.
#
#   TARGET_USER 로 직접 지정할 수 있고, 없으면 cb-user(Tumblebug · Beetle 이
#   만드는 VM 의 계정)를, 그것도 없으면 uid 1000 을 씁니다.
#   ★ uid 1000 을 먼저 보면 안 됩니다. AWS Deep Learning AMI 에서는 uid 1000 이
#     ubuntu 이고 cb-user 는 그 뒤에 만들어져, 엉뚱한 사용자로 설치됩니다.
# -----------------------------------------------------------
if [ "$(id -u)" -eq 0 ] && [ "${LEXAI_REEXEC:-0}" != "1" ]; then
    _user="${TARGET_USER:-${SUDO_USER:-}}"
    if [ -z "$_user" ] || [ "$_user" = "root" ]; then
        if getent passwd cb-user >/dev/null 2>&1; then
            _user="cb-user"
        else
            _user="$( { getent passwd 1000 | cut -d: -f1; } || true )"
        fi
    fi
    [ -n "$_user" ] || die "일반 사용자를 찾지 못했습니다. TARGET_USER 로 지정하세요."

    _home="$(getent passwd "$_user" | cut -d: -f6)"
    _repo="${REPO_DIR:-$_home/legal-rag-chatbot}"

    log "root 로 실행되었습니다 — ${_user} 사용자로 이어서 진행합니다"

    if ! command -v git >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y git curl openssl ca-certificates
    fi

    # 재실행할 스크립트가 디스크에 있어야 합니다. curl | bash 로 들어온 경우
    # 파일 경로가 없으므로 먼저 저장소를 받습니다.
    if [ ! -d "$_repo/.git" ]; then
        [ "$NO_UPDATE" = "1" ] && die "NO_UPDATE=1 인데 옮겨온 저장소가 없습니다: $_repo
  이관 모드는 새로 clone 하지 않습니다(브랜치 최신본이 깔리면 원본과 버전이 달라집니다).
  저장소 디렉터리를 먼저 옮기거나, REPO_DIR 로 위치를 지정하세요."
        sudo -u "$_user" -H git clone --quiet --branch "$BRANCH" "$REPO_URL" "$_repo"
        ok "clone (${_user}): $_repo"
    fi

    _args=()
    if [ "$RESUME" = "1" ]; then _args+=(--resume); fi
    if [ "$NO_START" = "1" ]; then _args+=(--no-start); fi

    exec sudo -u "$_user" -H env \
        LEXAI_REEXEC=1 \
        REPO_URL="$REPO_URL" BRANCH="$BRANCH" REPO_DIR="$_repo" \
        SNAPSHOT_URI="${SNAPSHOT_URI:-}" SKIP_DRIVER="${SKIP_DRIVER:-0}" \
        ALLOW_EMPTY_INDEX="${ALLOW_EMPTY_INDEX:-0}" \
        NO_UPDATE="$NO_UPDATE" FORCE_CLEAN="$FORCE_CLEAN" RUN_VERIFY="$RUN_VERIFY" \
        bash "$_repo/deploy/native/bootstrap.sh" "${_args[@]:-}"
fi


REPO_DIR="${REPO_DIR:-$HOME/legal-rag-chatbot}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-$HOME/lexai-snapshots}"
DATA_DIR="${DATA_DIR:-$HOME/lexai-data}"
SECRET_FILE="$HOME/.lexai-secrets"
RESUME_UNIT="lexai-bootstrap-resume"
DRIVER_TRIES_FILE="$HOME/.lexai-driver-tries"
DRIVER_MAX_TRIES="${DRIVER_MAX_TRIES:-2}"
RUN_DIR="${RUN_DIR:-$HOME/lexai-run}"
STATUS_FILE="$RUN_DIR/status.json"

# -----------------------------------------------------------
# 상태 파일 (오케스트레이터용)
#
# 이 스크립트는 25~30분 걸려 백그라운드로 띄울 수밖에 없어, 호출한 쪽이
# 종료 코드를 받지 못합니다. 대신 ~/lexai-run/status.json 을 폴링합니다.
# 형식은 common.sh 의 status_set 과 같습니다(이 시점엔 저장소가 없을 수 있어
# 여기에 따로 둡니다). 필드는 deploy/native/README.md "상태 파일" 절 참고.
# -----------------------------------------------------------
status_set() {
    mkdir -p "$RUN_DIR" 2>/dev/null || return 0
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
now_iso() { date '+%Y-%m-%dT%H:%M:%S%z'; }

if [ "$RESUME" = "1" ]; then
    # 재부팅 뒤 이어서 실행 — 같은 기록(run_id)을 이어 씁니다.
    LEXAI_RUN_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("run_id",""))' "$STATUS_FILE" 2>/dev/null || true)"
    status_set state=running phase=bootstrap:resume
else
    rm -f "$STATUS_FILE"
    LEXAI_RUN_ID="$(date +%Y%m%d-%H%M%S)"
    status_set run_id="$LEXAI_RUN_ID" \
               operation="$([ "$NO_UPDATE" = "1" ] && echo migrate || echo deploy)" \
               state=running phase=bootstrap started_at="$(now_iso)" \
               force_clean="$FORCE_CLEAN" data_check=NA verify=NA
fi
export LEXAI_RUN_ID
trap '_rc=$?; if [ "$_rc" -ne 0 ]; then status_set state=failed exit_code="$_rc" finished_at="$(now_iso)"; fi' EXIT


# -----------------------------------------------------------
# 1. 기본 도구
# -----------------------------------------------------------
log "1. 기본 도구"
status_set phase=bootstrap:1-tools
silence_needrestart
# ★ lspci 가 빠지면 안 됩니다. 아래 4절이 GPU 유무를 lspci 로 판정하는데,
#   명령이 없으면 출력이 비어 "GPU 없음"으로 읽히고 드라이버 설치를 조용히
#   건너뜁니다. GPU 인스턴스에서 추론이 CPU 로 떨어지는데 메시지는
#   "GPU 가 없는 인스턴스"라고 나오는, 원인 찾기 어려운 실패가 됩니다.
need=""
for c in git curl openssl lspci; do command -v "$c" >/dev/null 2>&1 || need="$need $c"; done
if [ -n "$need" ]; then
    apt_q update -qq
    apt_q install -y git curl openssl ca-certificates pciutils
fi
ok "git $(git --version | cut -d' ' -f3)"


# -----------------------------------------------------------
# 2. 저장소
#
# rsync 로 복사해 둔 디렉터리가 남아 있으면 clone 이 실패합니다.
# git 저장소가 아닌 디렉터리는 타임스탬프를 붙여 비켜둡니다.
# -----------------------------------------------------------
log "2. 저장소"
status_set phase=bootstrap:2-repo
# -----------------------------------------------------------
# NO_UPDATE=1 (이관 모드)
#
# 저장소를 통째로 옮겨온 경우 여기서 fetch · merge 를 하면 옮겨온 소스가
# 브랜치 최신본으로 바뀌어, 원본에 배포돼 있던 버전과 달라집니다.
# 이관 모드에서는 저장소를 건드리지 않고, 5절에서 패키지의 소스 커밋과
# 대조합니다.
# -----------------------------------------------------------
if [ "$NO_UPDATE" = "1" ]; then
    [ -d "$REPO_DIR/.git" ] || die "NO_UPDATE=1 인데 옮겨온 저장소가 없습니다: $REPO_DIR
  이관 모드는 새로 clone 하지 않습니다(브랜치 최신본이 깔리면 원본과 버전이 달라집니다).
  저장소 디렉터리를 먼저 옮기거나, REPO_DIR 로 위치를 지정하세요."
    ok "NO_UPDATE=1 — 갱신하지 않음: $(git -C "$REPO_DIR" rev-parse --short HEAD) ($(git -C "$REPO_DIR" branch --show-current 2>/dev/null || echo '-'))"
elif [ -d "$REPO_DIR/.git" ]; then
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
status_set commit="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)"
log "3. 환경 파일"
status_set phase=bootstrap:3-env
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
    ok "시크릿 사본: $SECRET_FILE (저장소째 이관하면 .env 가 함께 옮겨집니다)"
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
status_set phase=bootstrap:4-driver
if [ "${SKIP_DRIVER:-0}" = "1" ]; then
    ok "SKIP_DRIVER=1 — 건너뜀"
elif gpu_ready; then
    ensure_nvidia_smi
    rm -f "$DRIVER_TRIES_FILE"   # 성공했으니 시도 횟수를 비웁니다
    ok "$(gpu_desc)"
elif ! lspci 2>/dev/null | grep -qi nvidia; then
    warn "NVIDIA GPU 가 없는 인스턴스입니다 — 드라이버 설치를 건너뜁니다"
    warn "추론이 CPU 로 떨어져 응답이 1~3분이 됩니다. 백엔드 타임아웃이 180초라"
    warn "채팅이 실패할 수 있으니 .env 의 MAX_NEW_TOKENS 를 낮추세요."
else
    # -----------------------------------------------------------
    # ★ 재부팅 횟수 제한
    #
    #   설치가 먹히지 않으면 이 분기가 매 부팅마다 다시 돌아 무한히
    #   재부팅합니다. 사람이 보고 있으면 금방 알아채지만, 이관 도구가
    #   부르는 무인 실행에서는 아무도 모르는 채로 VM 만 계속 돕니다.
    #   실제로 겪었고, 비용만 쌓이고 원인은 안 보이는 최악의 실패입니다.
    # -----------------------------------------------------------
    tries=$( { cat "$DRIVER_TRIES_FILE" 2>/dev/null; } || echo 0 )
    tries=$(( ${tries:-0} + 1 ))
    echo "$tries" > "$DRIVER_TRIES_FILE"

    if [ "$tries" -gt "$DRIVER_MAX_TRIES" ]; then
        sudo systemctl disable "$RESUME_UNIT" >/dev/null 2>&1 || true
        die "드라이버 설치를 ${DRIVER_MAX_TRIES}회 시도했는데도 GPU 를 인식하지 못합니다.
  무한 재부팅을 막기 위해 멈춥니다(재개 유닛 해제 완료).
  확인해 보세요:
    cat /proc/driver/nvidia/version     # 커널 모듈이 올라왔는지
    lsmod | grep nvidia
    sudo dmesg | grep -i nvidia | tail
  모듈은 있는데 nvidia-smi 만 없다면 아래로 채운 뒤 다시 실행하세요:
    sudo apt-get install -y nvidia-utils-<버전>-server
  다시 시도하려면: rm $DRIVER_TRIES_FILE"
    fi

    log "   드라이버가 없어 설치합니다 (${tries}/${DRIVER_MAX_TRIES}회차 · 설치 후 자동 재부팅)"
    apt_q update -qq
    apt_q install -y ubuntu-drivers-common
    sudo ubuntu-drivers install --gpgpu || sudo ubuntu-drivers autoinstall
    # ubuntu-drivers 는 headless 변형을 깔아 nvidia-smi 를 빠뜨립니다.
    # 재부팅 전에 채워둬야 다음 부팅의 판정이 정상 동작합니다.
    ensure_nvidia_smi

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
# ★ 재부팅 뒤에는 환경이 새로 시작됩니다. curl | bash 앞에 붙인 변수는
#   여기 적어두지 않으면 사라지고, restore.sh 가 스냅샷이 없다며 죽습니다.
Environment=ALLOW_EMPTY_INDEX=${ALLOW_EMPTY_INDEX:-0}
# ★ 이 값이 빠지면 재부팅 뒤 2절이 옮겨온 소스를 브랜치 최신본으로 갱신합니다.
Environment=NO_UPDATE=$NO_UPDATE
Environment=FORCE_CLEAN=$FORCE_CLEAN
Environment=RUN_VERIFY=$RUN_VERIFY
ExecStart=$NATIVE_DIR/bootstrap.sh --resume

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable "$RESUME_UNIT" >/dev/null
    chmod +x "$NATIVE_DIR"/*.sh

    warn "재부팅합니다. 재접속 후 아래로 진행 상황을 확인하세요:"
    warn "  journalctl -u ${RESUME_UNIT} -f"
    status_set state=rebooting phase=bootstrap:4-driver
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
status_set phase=bootstrap:5-package
# NO_UPDATE=1 (이관 모드) 에서는 검증을 하나도 건너뛰지 않습니다.
#   - checksums.sha256 · lexai.db · source-commit.txt 가 전부 있어야 하고
#   - 세 파일의 체크섬이 모두 맞아야 하며
#   - 패키지의 소스 커밋이 옮겨온 저장소의 HEAD 와 같아야 합니다.
# 하나라도 어긋나면 "데이터는 보존됐다"는 결론을 낼 수 없으므로 멈춥니다.
STRICT="$NO_UPDATE"

if [ -z "${SNAPSHOT_URI:-}" ]; then
    [ "$STRICT" = "1" ] && die "NO_UPDATE=1 (이관 모드) 에는 SNAPSHOT_URI 가 필요합니다 — backup.sh 패키지 경로를 지정하세요"
    ok "SNAPSHOT_URI 미지정 — 건너뜀"
else
    mkdir -p "$SNAPSHOT_DIR" "$DATA_DIR"
    tmp="$(mktemp -d)"

    # ★ 순정 Ubuntu 이미지에는 클라우드 CLI 가 없습니다. AWS DL AMI 처럼
    #   미리 깔려 있는 이미지에서만 동작하고 순정에서는 이 단계에서 바로
    #   막히므로, 필요한 것만 그 자리에서 설치합니다. 이관 도구가 부르는
    #   무인 실행이라 "직접 설치하세요" 로 끝내면 거기서 멈춥니다.
    ensure_cli() {  # ensure_cli <명령> <apt 패키지> <설치 안내>
        command -v "$1" >/dev/null 2>&1 && return 0
        log "   $1 설치"
        apt_q update -qq
        apt_q install -y "$2" >/dev/null 2>&1 \
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
            # ★ 로컬 경로(Beetle 로 옮겨 온 패키지)는 복사하지 않고 링크합니다.
            #   5GB 아카이브를 임시 폴더로 한 번 더 복사하면 대상 디스크를
            #   두 배로 쓰고 시간도 그만큼 듭니다. 체크섬 · 압축 해제 · DB 복사는
            #   링크를 따라가므로 그대로 동작합니다.
            *)        [ -f "$1" ] || return 1
                      ln -s "$(readlink -f "$1")" "$2" ;;
        esac
    }

    # check_sum <파일명> — checksums.sha256 의 해당 줄로 $tmp/<파일명> 을 검사
    check_sum() {
        ( cd "$tmp" && grep -E "[[:space:]]\*?(\./)?$(printf '%s' "$1" | sed 's/\./\\./g')\$" checksums.sha256 | sha256sum -c --quiet ) >/dev/null 2>&1
    }
    has_sum() {
        [ -f "$tmp/checksums.sha256" ] \
            && grep -qE "[[:space:]]\*?(\./)?$(printf '%s' "$1" | sed 's/\./\\./g')\$" "$tmp/checksums.sha256"
    }

    log "   내려받는 중: $SNAPSHOT_URI"

    # 체크섬 파일을 먼저 받습니다. 이관 모드에서는 없으면 바로 멈춥니다 —
    # 수 GB 아카이브를 다 옮긴 뒤에 알게 되면 그 시간이 통째로 날아갑니다.
    if ! fetch "${SNAPSHOT_URI%/}/checksums.sha256" "$tmp/checksums.sha256" 2>/dev/null; then
        rm -f "$tmp/checksums.sha256"
        [ "$STRICT" = "1" ] && die "checksums.sha256 이 없습니다 — 이관 모드에서는 무결성 검증 없이 진행하지 않습니다"
        warn "checksums.sha256 이 없어 체크섬 확인을 건너뜁니다"
    fi

    # 이관 모드: 소스 커밋을 가장 먼저 대조합니다(가장 싸고, 틀리면 나머지가 무의미).
    if [ "$STRICT" = "1" ]; then
        fetch "${SNAPSHOT_URI%/}/source-commit.txt" "$tmp/source-commit.txt" 2>/dev/null \
            || die "source-commit.txt 가 없습니다 — 소스 커밋을 기록하는 backup.sh 로 패키지를 다시 만드세요"
        has_sum source-commit.txt || die "checksums.sha256 에 source-commit.txt 항목이 없습니다"
        check_sum source-commit.txt || die "source-commit.txt 체크섬 불일치 — 전송이 온전하지 않습니다"

        want="$(tr -d '[:space:]' < "$tmp/source-commit.txt")"
        have="$(git -C "$REPO_DIR" rev-parse HEAD)"
        if [ "$want" != "$have" ]; then
            die "소스 커밋 불일치 — 원본과 다른 버전의 소스입니다
  패키지(원본) : $want
  옮겨온 소스  : $have
  원본에서 패키지를 만든 뒤 저장소가 바뀌었거나, 다른 시점의 저장소를 옮겼습니다."
        fi
        ok "소스 커밋 일치 (${have:0:7})"

        # 커밋은 같아도 커밋되지 않은 수정은 해시에 드러나지 않습니다.
        dirty="$(git -C "$REPO_DIR" -c core.fileMode=false status --porcelain --untracked-files=no 2>/dev/null || true)"
        if [ -n "$dirty" ]; then
            warn "옮겨온 저장소에 커밋되지 않은 수정이 있습니다 (원본에 있던 수정이면 정상):"
            printf '%s\n' "$dirty" | sed 's/^/    /' >&2
        fi
    fi

    fetch "${SNAPSHOT_URI%/}/opensearch-snapshots.tar.gz" "$tmp/opensearch-snapshots.tar.gz"

    # 전송 손상을 압축 풀기 전에 잡습니다. 있는데 안 맞으면 여기서 멈춥니다 —
    # 깨진 아카이브를 풀어봐야 뒤에서 더 알기 어려운 형태로 실패할 뿐입니다.
    if [ -f "$tmp/checksums.sha256" ]; then
        if has_sum opensearch-snapshots.tar.gz; then
            check_sum opensearch-snapshots.tar.gz \
                || die "아카이브 체크섬 불일치 — 전송이 온전하지 않습니다"
            ok "아카이브 체크섬 확인"
        else
            [ "$STRICT" = "1" ] && die "checksums.sha256 에 opensearch-snapshots.tar.gz 항목이 없습니다"
            warn "checksums.sha256 에 아카이브 항목이 없어 확인을 건너뜁니다"
        fi
    fi

    HAVE_DB=0
    if fetch "${SNAPSHOT_URI%/}/lexai.db" "$tmp/lexai.db" 2>/dev/null; then
        # ★ 체크섬 파일에는 DB 해시도 들어 있는데 위에서 아카이브 줄만 골라
        #   검사하고 있었습니다. 같은 망 안에서 복사할 때는 드러나지 않지만,
        #   오브젝트 스토리지나 HTTP 로 받으면 잘린 DB 가 그대로 들어가고
        #   SQLite 는 한참 뒤에 알아보기 어려운 형태로 실패합니다.
        if has_sum lexai.db; then
            check_sum lexai.db || die "DB 체크섬 불일치 — 전송이 온전하지 않습니다"
            ok "DB 체크섬 확인"
        elif [ "$STRICT" = "1" ]; then
            die "checksums.sha256 에 lexai.db 항목이 없습니다"
        fi
        HAVE_DB=1
    else
        # 이관 모드에서 DB 없이 시작하면 사용자·대화 기록이 사라진 채로
        # 정상 기동한 것처럼 보입니다. 데이터 보존 검증이 거짓 PASS 가 됩니다.
        [ "$STRICT" = "1" ] && die "lexai.db 가 없습니다 — 이관 모드에서는 빈 DB 로 시작하지 않습니다"
        warn "DB 파일이 없어 건너뜁니다 — 빈 DB 로 시작합니다"
    fi

    # 데이터 지문 — 대상에서 복원 직후 원본과 자동 비교합니다(check-data.sh).
    HAVE_FP=0
    if fetch "${SNAPSHOT_URI%/}/data-fingerprint.tsv" "$tmp/data-fingerprint.tsv" 2>/dev/null; then
        if has_sum data-fingerprint.tsv; then
            check_sum data-fingerprint.tsv || die "data-fingerprint.tsv 체크섬 불일치 — 전송이 온전하지 않습니다"
        elif [ "$STRICT" = "1" ]; then
            die "checksums.sha256 에 data-fingerprint.tsv 항목이 없습니다"
        fi
        HAVE_FP=1
        ok "데이터 지문 확인"
    elif [ "$STRICT" = "1" ]; then
        die "data-fingerprint.tsv 가 없습니다 — 데이터 보존을 판정할 수 없습니다. 지금 버전의 backup.sh 로 패키지를 다시 만드세요"
    fi

    # 런타임 기록 — 원본과 같은 Ollama 버전으로 설치합니다(없으면 최신).
    # 데이터가 아니라 답변 조건이라, 없어도 멈추지 않습니다.
    HAVE_RT=0
    if fetch "${SNAPSHOT_URI%/}/runtime-versions.txt" "$tmp/runtime-versions.txt" 2>/dev/null; then
        if has_sum runtime-versions.txt; then
            check_sum runtime-versions.txt || die "runtime-versions.txt 체크섬 불일치 — 전송이 온전하지 않습니다"
        fi
        HAVE_RT=1
        src_ollama="$(awk '$1=="ollama"{print $2}' "$tmp/runtime-versions.txt")"
        if [ -n "$src_ollama" ] && [ -z "${OLLAMA_VERSION:-}" ]; then export OLLAMA_VERSION="$src_ollama"; fi
        ok "런타임 기록 확인 (원본 Ollama ${src_ollama:-?})"
    elif [ "$STRICT" = "1" ]; then
        warn "runtime-versions.txt 가 없습니다 — Ollama 는 최신 버전으로 설치됩니다"
    fi

    # 압축 해제 전에 공간을 봅니다. 풀다가 No space left 로 죽으면 반쯤 풀린
    # 스냅샷이 남아 다음 시도의 정합성 대조까지 막습니다.
    # (풀린 크기는 아카이브의 약 1.15배 — 1차 실행 5.27GB → 6.0GB)
    need_kb=$(( $(stat -L -c %s "$tmp/opensearch-snapshots.tar.gz") / 1024 * 12 / 10 ))
    free_kb=$(df -Pk "$SNAPSHOT_DIR" | awk 'NR==2 {print $4}')
    if [ "$free_kb" -lt "$need_kb" ]; then
        die "스냅샷을 풀 공간이 부족합니다 — 필요 약 $((need_kb/1024/1024))GB / 여유 $((free_kb/1024/1024))GB (df -h 확인)"
    fi

    # -----------------------------------------------------------
    # 기존 설치 확인 (패키지 검증이 모두 끝난 뒤, 무엇이든 덮어쓰기 전)
    #
    # ★ 이미 LexAI 가 깔린 VM 에 다시 이관하면(A→B→A) 세 가지가 조용히 꼬입니다.
    #   - restore.sh 는 색인에 문서가 있으면 복원을 건너뛰어 옛 색인이 남습니다.
    #   - 옛 스냅샷 파일이 남아 새 패키지와 섞이고, 정합성 대조가 어긋납니다.
    #   - DB 파일만 바뀌고 옛 -wal/-shm 이 남으면, 다음 열 때 옛 WAL 이 새 DB 에
    #     덧씌워져 손상되거나 내용이 섞일 수 있습니다.
    #   이관 모드에서는 기존 설치를 찾으면 멈추고, FORCE_CLEAN=1 일 때만 비웁니다.
    #   (이관 모드가 아니면 예전처럼 재실행을 허용합니다 — 같은 VM 재시도용)
    # -----------------------------------------------------------
    found=()
    for f in lexai.db lexai.db-wal lexai.db-shm lexai.db-journal; do
        if [ -e "$DATA_DIR/$f" ]; then found+=("DB 파일   $DATA_DIR/$f"); fi
    done
    if [ -n "$(ls -A "$SNAPSHOT_DIR" 2>/dev/null)" ]; then
        found+=("스냅샷    $SNAPSHOT_DIR ($(du -sh "$SNAPSHOT_DIR" 2>/dev/null | cut -f1))")
    fi
    for u in lexai-opensearch lexai-ai lexai-tomcat lexai-frontend; do
        if [ -f "/etc/systemd/system/$u.service" ]; then found+=("서비스    $u"); fi
    done

    if [ "${#found[@]}" -gt 0 ] && { [ "$STRICT" = "1" ] || [ "$FORCE_CLEAN" = "1" ]; }; then
        if [ "$FORCE_CLEAN" != "1" ]; then
            die "이 VM 에 기존 LexAI 설치가 있습니다 — 그대로 덮으면 옛 색인이 남고 DB 가 손상될 수 있습니다
$(printf '    %s\n' "${found[@]}")
  새 VM 으로 이관하거나, 기존 데이터를 비우고 진행하려면 FORCE_CLEAN=1 을 함께 주세요.
  (이 VM 에서 이전 이관이 중간에 실패해 다시 돌리는 경우도 같습니다)"
        fi

        log "   FORCE_CLEAN=1 — 기존 설치를 비웁니다"
        printf '    %s\n' "${found[@]}"

        # 1) 쓰기 중지. DB 에 쓰는 것은 Tomcat 뿐이지만 AI 서버도 색인을 읽으므로 같이 멈춥니다.
        for t in frontend tomcat ai; do bash "$NATIVE_DIR/stop.sh" "$t" >/dev/null; done
        ok "frontend · tomcat · ai 정지"

        # 2) 색인과 스냅샷 저장소 등록을 지웁니다. 파일만 지우면 OpenSearch 가
        #    저장소 세대 정보를 기억하고 있어 새 스냅샷 등록이 어긋날 수 있습니다.
        if [ -f /etc/systemd/system/lexai-opensearch.service ]; then
            (
                source "$NATIVE_DIR/common.sh"
                load_opensearch_creds
                sudo systemctl start lexai-opensearch
                wait_for "OpenSearch" 180 os_ready || die "OpenSearch 가 준비되지 않았습니다 — $LOG_DIR 확인"
                code=$(os_curl -o /dev/null -w '%{http_code}' -X DELETE "$OS_BASE/${INDEX_NAME:-legal_documents}")
                case "$code" in
                    200|404) ok "색인 삭제 (${INDEX_NAME:-legal_documents}, HTTP $code)" ;;
                    401)     die "OpenSearch 인증 실패 — .env 의 OPENSEARCH_PASSWORD 가 이 VM 에 설치된 값과 다릅니다" ;;
                    *)       die "색인 삭제 실패 (HTTP $code)" ;;
                esac
                os_curl -o /dev/null -X DELETE "$OS_BASE/_snapshot/${SNAPSHOT_REPO:-lexai}" || true
                ok "스냅샷 저장소 등록 해제"
            )
        fi

        # 3) DB 는 지우지 않고 옮겨 둡니다(작아서 공간 부담이 없고, 되돌릴 길을 남깁니다).
        replaced="$HOME/lexai-replaced/$(date +%Y%m%d-%H%M%S)"
        for f in lexai.db lexai.db-wal lexai.db-shm lexai.db-journal source-fingerprint.tsv source-runtime.txt; do
            if [ -e "$DATA_DIR/$f" ]; then mkdir -p "$replaced"; mv "$DATA_DIR/$f" "$replaced/"; fi
        done
        for f in "$DATA_DIR"/source-fingerprint.checked-*.tsv "$DATA_DIR"/source-runtime.checked-*.txt; do
            if [ -e "$f" ]; then mkdir -p "$replaced"; mv "$f" "$replaced/"; fi
        done
        [ -d "$replaced" ] && ok "기존 DB 보관: $replaced"

        # 4) 스냅샷 폴더는 패키지 사본이라 비웁니다(수 GB).
        find "$SNAPSHOT_DIR" -mindepth 1 -delete 2>/dev/null || sudo find "$SNAPSHOT_DIR" -mindepth 1 -delete
        ok "스냅샷 폴더 비움"
    elif [ "${#found[@]}" -gt 0 ]; then
        warn "기존 설치가 있습니다 — 이관 모드가 아니라 예전처럼 덮어씁니다 (같은 VM 재시도용)"
    fi

    # -xf 는 압축 형식을 자동 판별합니다 (gzip / 무압축 둘 다 처리).
    tar -xf "$tmp/opensearch-snapshots.tar.gz" -C "$SNAPSHOT_DIR"
    ok "색인 스냅샷 배치 ($(du -sh "$SNAPSHOT_DIR" | cut -f1))"

    if [ "$HAVE_DB" = "1" ]; then
        cp "$tmp/lexai.db" "$DATA_DIR/lexai.db"
        ok "DB 배치 ($(du -h "$DATA_DIR/lexai.db" | cut -f1))"
    fi
    if [ "$HAVE_FP" = "1" ]; then
        cp "$tmp/data-fingerprint.tsv" "$DATA_DIR/source-fingerprint.tsv"
    fi
    if [ "$HAVE_RT" = "1" ]; then
        cp "$tmp/runtime-versions.txt" "$DATA_DIR/source-runtime.txt"
    fi
    rm -rf "$tmp"
fi


# -----------------------------------------------------------
# 6. 설치 · 기동 · 검증
# -----------------------------------------------------------
chmod +x "$NATIVE_DIR"/*.sh

if [ "$NO_START" = "1" ]; then
    echo
    status_set state=prepared phase=bootstrap:done finished_at="$(now_iso)"
    log "준비 완료 (NO_START=1 — 기동은 하지 않았습니다)"
    echo "  기동: bash $NATIVE_DIR/up.sh"
    exit 0
fi

log "6. up.sh 실행"
# 이관 모드
# ★ verify.sh 는 verify 계정을 가입시키고 실제로 채팅을 보내 DB 에 기록을
#   남깁니다. 이관을 반복할 때마다 그 기록이 쌓여 리뷰어가 보는 데이터에
#   섞이므로, 응답 검증은 첫 배포(이관 모드가 아닌 실행)에서만 돌립니다.
#   이관에서는 대신 아래가 자동으로 확인됩니다(읽기만 함):
#     - check-data.sh  테이블별 행 수 · 내용이 원본과 같은지
#     - start.sh       서비스마다 헬스체크 통과 + 모델 GPU 적재
#   필요하면 RUN_VERIFY=1 로 켭니다. 그때도 응답 속도 FAIL 은 이관 실패로
#   보고하지 않습니다(VERIFY_GATE=0, up.sh 참고).
if [ "$NO_UPDATE" = "1" ]; then
    export VERIFY_GATE="${VERIFY_GATE:-0}"
    if [ "$RUN_VERIFY" != "1" ]; then export SKIP_VERIFY=1; fi
    # 압축 해제한 스냅샷의 목록 파일(contents.tsv)이 없으면 정합성 대조를
    # 건너뛰지 않고 실패로 봅니다(common.sh verify_manifest).
    export REQUIRE_MANIFEST=1
fi
status_set phase=up
exec bash "$NATIVE_DIR/up.sh"
