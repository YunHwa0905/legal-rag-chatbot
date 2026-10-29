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
#   4. compose 정의 · 스크립트 수신 (커밋 SHA 고정) — 저장소 clone 없음
#   5. .env 생성 — 시크릿 자동 발급
#   6. 이관 패키지가 있으면 검증 · 기존 설치 확인 · 스냅샷 배치
#   7. 레지스트리에서 이미지 pull (패키지의 images.lock 이 있으면 같은 digest)
#   8. 기동 전 DB 배치 · 데이터 지문 비교
#   9. OpenSearch 만 먼저 띄워 색인 복원
#  10. 전체 기동 · 준비 확인 · 런타임 비교 · 모델 예열
#  11. verify.sh (이관 모드에서는 기본 생략)
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
#   IMAGE_TAG         이미지 태그                  기본 v3
#   SNAPSHOT_URI      이관 패키지 위치             s3://… 또는 https://…
#   SKIP_DRIVER=1     드라이버 설치 건너뛰기 (GPU 이미지를 쓰는 경우)
#   NO_START=1        준비만 하고 기동은 안 함
#   NO_UPDATE=1       **이관 모드.** 옮겨 온 배포 디렉터리를 그대로 쓰고(GitHub 에서
#                     다시 받지 않음), 패키지와 커밋 · 배포 파일 · 이미지 digest ·
#                     체크섬 · 데이터 지문을 대조합니다. SNAPSHOT_URI 필수
#   FORCE_CLEAN=1     기존 설치(데이터 볼륨)가 있어도 진행 — 기존 DB 는
#                     ~/lexai-replaced/<시각> 으로 보관하고 데이터 볼륨을 새로 만듭니다
#   RUN_VERIFY=1      이관 모드에서도 verify.sh 실행 (기본은 생략 — DB 에 기록이 남음)
#   SKIP_VERIFY=1     verify.sh 생략
#   TARGET_USER       root 로 실행될 때 사용할 계정 (기본 cb-user → uid 1000)
#
# 진행 상황(오케스트레이터용): ~/lexai-run/status.json — README 참고
#
# 예) 다른 CSP 의 레지스트리에서 받아 띄우기
#   curl -fsSL <raw url> | REGISTRY_PREFIX=asia-northeast3-docker.pkg.dev/proj/repo \
#        IMAGE_TAG=v3 SNAPSHOT_URI=s3://버킷/lexai/20260923-1031 bash
# ===========================================================

set -euo pipefail

# 시각은 KST 로 통일합니다(네이티브와 같음). DB 기록 · 로그 · status.json 이
# 같은 시간대여야 비교하기 쉽습니다. VM 시스템 시간대는 바꾸지 않습니다.
export TZ="${TZ:-Asia/Seoul}"

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
#   무인 실행은 거기서 영원히 멈춥니다.
# -----------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive

apt_q() {
    sudo DEBIAN_FRONTEND=noninteractive \
         NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 \
         apt-get "$@"
}

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
#   무한 반복합니다. 커널 모듈 존재도 함께 봅니다.
# -----------------------------------------------------------
gpu_ready() {
    nvidia-smi >/dev/null 2>&1 && return 0
    [ -e /proc/driver/nvidia/version ]
}

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

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/YunHwa0905/legal-rag-chatbot}"
BRANCH="${BRANCH:-feat/sqlite}"
RAW_BASE="${REPO_RAW}/${BRANCH}"
SELF_URL="${RAW_BASE}/deploy/compose/deploy.sh"

# ★ 사용자가 준 값을 따로 기억합니다. root 로 실행되면 아래 기본값이 /root/... 가
#   되는데, 대상 사용자로 넘어갈 때 그 값을 그대로 넘기면 남의 홈에 쓰려다 실패합니다.
DEPLOY_DIR_GIVEN="${DEPLOY_DIR:-}"
DEPLOY_DIR="${DEPLOY_DIR:-$HOME/lexai-compose}"
RESUME_UNIT="lexai-compose-resume"
DRIVER_TRIES_FILE="$HOME/.lexai-driver-tries"
DRIVER_MAX_TRIES="${DRIVER_MAX_TRIES:-2}"
# ★ 네이티브(bootstrap.sh)는 ~/.lexai-secrets 를 씁니다. 같은 이름을 쓰면
#   한 호스트에서 두 형태를 오갈 때 먼저 받은 쪽 시크릿이 덮여 사라집니다.
#   형태별 VM 을 권장하지만 실제로 겹치는 일이 생겨 이름을 나눕니다.
SECRET_FILE="$HOME/.lexai-secrets.compose"

# ★ 명시하지 않았으면 기존 .env 의 값을 씁니다. 예전에는 여기서 기본값을
#   export 해서, .env 에 다른 태그를 적어도 셸 환경변수가 이겨 조용히 무시됐습니다.
_env_from_file() {
    [ -f "$DEPLOY_DIR/.env" ] || return 0
    { grep -E "^$1=" "$DEPLOY_DIR/.env" | tail -1 | cut -d= -f2-; } 2>/dev/null || true
}
REGISTRY_PREFIX="${REGISTRY_PREFIX:-$(_env_from_file REGISTRY_PREFIX)}"
REGISTRY_PREFIX="${REGISTRY_PREFIX:-yunhwa0905}"
IMAGE_TAG="${IMAGE_TAG:-$(_env_from_file IMAGE_TAG)}"
IMAGE_TAG="${IMAGE_TAG:-v3}"
REPO_API="${REPO_API:-https://api.github.com/repos/${REPO_RAW#https://raw.githubusercontent.com/}}"
REPO_GIT="${REPO_GIT:-https://github.com/${REPO_RAW#https://raw.githubusercontent.com/}.git}"
INDEX_NAME="${INDEX_NAME:-legal_documents}"
SNAPSHOT_REPO="${SNAPSHOT_REPO:-lexai}"

RESUME=0
NO_START="${NO_START:-0}"
NO_UPDATE="${NO_UPDATE:-0}"
FORCE_CLEAN="${FORCE_CLEAN:-0}"
RUN_VERIFY="${RUN_VERIFY:-0}"
SKIP_VERIFY="${SKIP_VERIFY:-0}"
# 이관 오케스트레이터 · WidgetRAG 는 LLM_TEMPERATURE 라는 이름을 씁니다 — 있으면 그 값이 이깁니다.
# 여기서 TEMPERATURE 로 옮겨 담아 아래(재실행 · 재부팅 유닛 · .env 생성)는 그대로 씁니다.
TEMPERATURE="${LLM_TEMPERATURE:-${TEMPERATURE:-}}"
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
    C_HEAD=$'\033[1;35m'; C_OK=$'\033[0;32m'; C_INFO=$'\033[0;36m'
    C_WARN=$'\033[0;33m'; C_ERR=$'\033[0;31m'; C_OFF=$'\033[0m'
else
    C_HEAD=""; C_OK=""; C_INFO=""; C_WARN=""; C_ERR=""; C_OFF=""
fi

log()  { printf '%s[compose]%s %s\n' "$C_HEAD" "$C_OFF" "$*"; }
ok()   { printf '%s  OK%s   %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%s  WARN%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()  {
    printf '%s  FATAL%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2
    if type status_set >/dev/null 2>&1; then status_set "last_error=$*"; fi
    exit 1
}


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
    # ★ cb-user(Tumblebug · Beetle 이 만드는 VM 의 계정)를 먼저 봅니다. AWS Deep
    #   Learning AMI 에서는 uid 1000 이 ubuntu 라, uid 1000 부터 보면 엉뚱한
    #   계정에 설치되고 리모트 커맨드(cb-user)에서는 보이지 않습니다.
    if [ -z "$_user" ] || [ "$_user" = "root" ]; then
        if getent passwd cb-user >/dev/null 2>&1; then
            _user="cb-user"
        else
            _user="$( { getent passwd 1000 | cut -d: -f1; } || true )"
        fi
    fi
    [ -n "$_user" ] || die "일반 사용자를 찾지 못했습니다. TARGET_USER 로 지정하세요."

    _home="$(getent passwd "$_user" | cut -d: -f6)"

    log "root 로 실행되었습니다 — ${_user} 사용자로 이어서 진행합니다"

    if ! command -v curl >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates openssl
    fi

    _dir="${DEPLOY_DIR_GIVEN:-$_home/lexai-compose}"
    if [ "$NO_UPDATE" = "1" ]; then
        # 이관 모드: 옮겨 온 사본을 그대로 씁니다(받으면 브랜치 최신본이 됩니다).
        [ -f "$_dir/deploy.sh" ] || die "NO_UPDATE=1 인데 옮겨 온 배포 디렉터리가 없습니다: $_dir"
    else
        sudo -u "$_user" -H mkdir -p "$_dir"
        sudo -u "$_user" -H curl -fsSL "$SELF_URL" -o "$_dir/deploy.sh"
        chmod +x "$_dir/deploy.sh"
    fi

    _args=()
    if [ "$RESUME" = "1" ]; then _args+=(--resume); fi
    if [ "$NO_START" = "1" ]; then _args+=(--no-start); fi

    # 바로 위에서 사본을 새로 받았으므로 아래 0절의 갱신·재실행은 건너뜁니다.
    exec sudo -u "$_user" -H env \
        LEXAI_REEXEC=1 LEXAI_FROMFILE=1 \
        BRANCH="$BRANCH" DEPLOY_DIR="$_dir" \
        REGISTRY_PREFIX="$REGISTRY_PREFIX" IMAGE_TAG="$IMAGE_TAG" \
        SNAPSHOT_URI="${SNAPSHOT_URI:-}" SKIP_DRIVER="${SKIP_DRIVER:-0}" \
        NO_UPDATE="$NO_UPDATE" FORCE_CLEAN="$FORCE_CLEAN" \
        RUN_VERIFY="$RUN_VERIFY" SKIP_VERIFY="$SKIP_VERIFY" \
        ALLOW_HOST_OLLAMA="${ALLOW_HOST_OLLAMA:-0}" \
        TEMPERATURE="${TEMPERATURE:-}" LLM_SEED="${LLM_SEED:-}" \
        FRONTEND_PORT="${FRONTEND_PORT:-}" SKIP_WARMUP="${SKIP_WARMUP:-0}" \
        ${VERIFY_GATE:+VERIFY_GATE="$VERIFY_GATE"} \
        REPO_RAW="$REPO_RAW" ${REPO_GIT:+REPO_GIT="$REPO_GIT"} \
        bash "$_dir/deploy.sh" "${_args[@]:-}"
fi


# -----------------------------------------------------------
# 0. 사본 갱신 후 파일에서 다시 실행
#
# 본 작업을 시작하기 전에 끝내야 합니다. 뒤에 두면 아래 1절이 두 번
# 출력됩니다(갈아타면서 처음부터 다시 도니까요).
#
# 두 가지를 동시에 해결합니다.
#
# 1) curl | bash 로 들어오면 스크립트 본문 자체가 stdin 입니다. 뒤에서
#    docker compose exec 같이 stdin 을 읽는 명령이 돌면 아직 읽지 않은
#    본문을 통째로 삼켜버리고, bash 는 EOF 를 만나 종료 코드 0 으로 조용히
#    끝납니다. 에러 한 줄 없이 중간에 멈추는 가장 나쁜 실패 방식이고
#    실제로 겪었습니다 — DB 복원까지만 찍히고 색인 복원이 사라졌습니다.
#    디스크의 사본으로 갈아타면 본문이 stdin 과 무관해집니다.
#
# 2) 재부팅 후 재개(resume 유닛)도 이 사본을 실행합니다.
#
# 사본은 매번 새로 받습니다. "없을 때만" 받으면 옛 사본이 계속 실행되어
# 고친 내용이 영영 반영되지 않습니다.
#
# 이미 사본에서 실행 중이면(LEXAI_FROMFILE=1) 건드리지 않습니다. bash 는
# 스크립트를 조금씩 읽어가므로, 실행 중인 파일을 덮어쓰면 남은 부분이
# 깨집니다.
# -----------------------------------------------------------
# ★ 이관 모드(NO_UPDATE=1)에서는 갱신하지 않습니다. 옮겨 온 사본을 받으면
#   브랜치 최신본으로 바뀌어 원본에 배포돼 있던 버전과 달라집니다.
if [ "$NO_UPDATE" = "1" ] && [ "${LEXAI_FROMFILE:-0}" != "1" ]; then
    [ -f "$DEPLOY_DIR/deploy.sh" ] || die "NO_UPDATE=1 인데 옮겨 온 배포 디렉터리가 없습니다: $DEPLOY_DIR"
    export LEXAI_FROMFILE=1
fi
if [ "${LEXAI_FROMFILE:-0}" != "1" ]; then
    if ! command -v curl >/dev/null 2>&1; then
        apt_q update -qq
        apt_q install -y curl ca-certificates
    fi
    mkdir -p "$DEPLOY_DIR"

    if curl -fsSL "$SELF_URL" -o "$DEPLOY_DIR/.deploy.sh.new"; then
        mv "$DEPLOY_DIR/.deploy.sh.new" "$DEPLOY_DIR/deploy.sh"
        chmod +x "$DEPLOY_DIR/deploy.sh"
    else
        rm -f "$DEPLOY_DIR/.deploy.sh.new"
        [ -f "$DEPLOY_DIR/deploy.sh" ] || die "스크립트를 받지 못했습니다: $SELF_URL"
        warn "최신본을 받지 못해 기존 사본을 씁니다"
    fi

    export LEXAI_FROMFILE=1
    export BRANCH DEPLOY_DIR REGISTRY_PREFIX IMAGE_TAG INDEX_NAME SNAPSHOT_REPO
    export SNAPSHOT_URI="${SNAPSHOT_URI:-}" SKIP_DRIVER="${SKIP_DRIVER:-0}"
    export NO_UPDATE FORCE_CLEAN RUN_VERIFY SKIP_VERIFY
    exec bash "$DEPLOY_DIR/deploy.sh" "${@:-}" </dev/null
fi


# -----------------------------------------------------------
# 상태 파일 (오케스트레이터용)
#
# 배포 · 이관은 수십 분 걸려 백그라운드로 띄울 수밖에 없고, 그러면 호출한
# 쪽은 종료 코드를 받지 못합니다. 대신 ~/lexai-run/status.json 을 폴링합니다.
# 형식은 네이티브(deploy/native/common.sh status_set)와 같고 form 만 다릅니다.
# -----------------------------------------------------------
RUN_DIR="${RUN_DIR:-$HOME/lexai-run}"
STATUS_FILE="$RUN_DIR/status.json"
status_set() {  # status_set 키=값 ...
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
CUR_PHASE="compose:1-tools"
phase() { CUR_PHASE="$1"; status_set state=running phase="$1"; }

if [ "$RESUME" = "1" ]; then
    status_set state=running phase=compose:resume
else
    rm -f "$STATUS_FILE"
    status_set run_id="$(date +%Y%m%d-%H%M%S)" form=compose \
               operation="$([ "$NO_UPDATE" = "1" ] && echo migrate || echo deploy)" \
               state=running phase=compose:1-tools started_at="$(now_iso)" start_epoch="$(date +%s)" \
               force_clean="$FORCE_CLEAN" data_check=NA verify=NA
fi
trap '_rc=$?; if [ "$_rc" -ne 0 ]; then status_set state=failed exit_code="$_rc" failed_phase="$CUR_PHASE" finished_at="$(now_iso)"; fi' EXIT


# -----------------------------------------------------------
# 1. 기본 도구
# -----------------------------------------------------------
log "1. 기본 도구"
silence_needrestart
# ★ lspci 가 빠지면 안 됩니다 — 2절이 GPU 유무를 lspci 로 판정하는데,
#   명령이 없으면 출력이 비어 "GPU 없음"으로 읽히고 드라이버 설치를 건너뜁니다.
need=""
for c in curl openssl lspci git python3; do command -v "$c" >/dev/null 2>&1 || need="$need $c"; done
if [ -n "$need" ]; then
    apt_q update -qq
    apt_q install -y curl openssl ca-certificates pciutils git python3
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
phase compose:2-driver
if [ "${SKIP_DRIVER:-0}" = "1" ]; then
    ok "SKIP_DRIVER=1 — 건너뜀"
elif gpu_ready; then
    ensure_nvidia_smi
    rm -f "$DRIVER_TRIES_FILE"
    ok "$(gpu_desc)"
elif ! lspci 2>/dev/null | grep -qi nvidia; then
    warn "NVIDIA GPU 가 없는 인스턴스입니다 — 드라이버 설치를 건너뜁니다"
    warn "추론이 CPU 로 떨어져 응답이 1~3분이 됩니다. 백엔드 타임아웃이 180초라"
    warn "채팅이 실패할 수 있으니 .env 의 MAX_NEW_TOKENS 를 낮추세요."
else
    # ★ 설치가 먹히지 않으면 이 분기가 매 부팅마다 다시 돌아 무한히
    #   재부팅합니다. 무인 실행에서는 아무도 모르는 채로 VM 만 계속 돕니다.
    tries=$( { cat "$DRIVER_TRIES_FILE" 2>/dev/null; } || echo 0 )
    tries=$(( ${tries:-0} + 1 ))
    echo "$tries" > "$DRIVER_TRIES_FILE"

    if [ "$tries" -gt "$DRIVER_MAX_TRIES" ]; then
        sudo systemctl disable "$RESUME_UNIT" >/dev/null 2>&1 || true
        die "드라이버 설치를 ${DRIVER_MAX_TRIES}회 시도했는데도 GPU 를 인식하지 못합니다.
  무한 재부팅을 막기 위해 멈춥니다(재개 유닛 해제 완료).
  확인: cat /proc/driver/nvidia/version · lsmod | grep nvidia · sudo dmesg | grep -i nvidia
  모듈은 있는데 nvidia-smi 만 없다면: sudo apt-get install -y nvidia-utils-<버전>-server
  다시 시도하려면: rm $DRIVER_TRIES_FILE"
    fi

    log "   드라이버가 없어 설치합니다 (${tries}/${DRIVER_MAX_TRIES}회차 · 설치 후 자동 재부팅)"
    apt_q update -qq
    apt_q install -y ubuntu-drivers-common
    sudo ubuntu-drivers install --gpgpu || sudo ubuntu-drivers autoinstall
    ensure_nvidia_smi

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
# ★ 여기 적지 않은 값은 재부팅 뒤 사라집니다(이관 모드가 일반 배포로 바뀌는 등).
Environment=NO_UPDATE=$NO_UPDATE
Environment=FORCE_CLEAN=$FORCE_CLEAN
Environment=RUN_VERIFY=$RUN_VERIFY
Environment=SKIP_VERIFY=$SKIP_VERIFY
Environment=ALLOW_HOST_OLLAMA=${ALLOW_HOST_OLLAMA:-0}
Environment=TEMPERATURE=${TEMPERATURE:-}
Environment=LLM_SEED=${LLM_SEED:-}
Environment=FRONTEND_PORT=${FRONTEND_PORT:-}
Environment=SKIP_WARMUP=${SKIP_WARMUP:-0}
Environment=LEXAI_FROMFILE=1
ExecStart=$DEPLOY_DIR/deploy.sh --resume

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable "$RESUME_UNIT" >/dev/null

    warn "재부팅합니다. 재접속 후 아래로 진행 상황을 확인하세요:"
    warn "  journalctl -u ${RESUME_UNIT} -f"
    status_set state=rebooting phase=compose:2-driver
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
phase compose:3-docker
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
        apt_q update -qq
        apt_q install -y nvidia-container-toolkit
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

    # -----------------------------------------------------------
    # 호스트 Ollama 가 떠 있으면 GPU 를 이중으로 잡습니다.
    #
    # 네이티브 형태를 내릴 때 stop.sh 를 인자 없이 부르면 ollama.service 는
    # 남습니다 — 모델 5GB 재적재 비용 때문에 의도된 기본값입니다. 그 상태로
    # 컴포즈를 띄우면 호스트와 컨테이너가 같은 모델을 각자 올려 VRAM 이
    # 정확히 두 배가 되고, 측정값이 조용히 오염됩니다. 실제로 겪었습니다 —
    # 5,331 MiB 가 10,659 MiB 로 찍히고 콜드가 2배, p95 편차가 4배였습니다.
    #
    # GPU 메모리가 작은 인스턴스에서는 오염이 아니라 기동 실패가 됩니다.
    # 다른 사전 조건(드라이버 · 디스크 · 컨테이너 GPU 통과)은 전부 스스로
    # 확인하면서 이것만 빠져 있었습니다.
    # -----------------------------------------------------------
    if systemctl is-active --quiet ollama 2>/dev/null; then
        used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1)
        if [ "${ALLOW_HOST_OLLAMA:-0}" = "1" ]; then
            warn "호스트 ollama.service 가 떠 있습니다 (GPU ${used:-?} MiB) — ALLOW_HOST_OLLAMA=1 로 진행합니다"
        else
            die "호스트 ollama.service 가 떠 있습니다 (GPU ${used:-?} MiB 사용 중).
         컨테이너 Ollama 와 모델을 각자 올려 VRAM 이 두 배가 되고 측정값이 오염됩니다.
         내리고 다시 실행하세요:  bash deploy/native/stop.sh all-with-ollama
         의도한 것이라면:         ALLOW_HOST_OLLAMA=1 로 다시 실행"
        fi
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
phase compose:4-files
mkdir -p "$DEPLOY_DIR/deploy/snapshots"

# 배포 디렉터리에 두는 파일 — 이관 패키지의 deploy-files.sha256 도 이 목록입니다.
DEPLOY_FILES="docker-compose.yml docker-compose.registry.yml deploy/schema.sqlite.sql deploy.sh backup.sh verify.sh datacheck.sh migcompare.py golden-questions.txt"

if [ "$NO_UPDATE" = "1" ]; then
    # 이관 모드: 옮겨 온 파일만 씁니다. 하나라도 없으면 멈춥니다.
    for f in $DEPLOY_FILES DEPLOY_COMMIT; do
        [ -f "$DEPLOY_DIR/$f" ] || die "NO_UPDATE=1 인데 옮겨 온 배포 디렉터리에 $f 가 없습니다 ($DEPLOY_DIR)"
    done
    DEPLOY_COMMIT="$(tr -d '[:space:]' < "$DEPLOY_DIR/DEPLOY_COMMIT")"
    ok "NO_UPDATE=1 — 옮겨 온 정의 사용 (커밋 ${DEPLOY_COMMIT:0:7})"
else
    # -----------------------------------------------------------
    # ★ 브랜치 이름이 아니라 커밋 SHA 로 받습니다.
    #   브랜치는 움직이므로, 이름으로 받으면 언제 받았느냐에 따라 내용이
    #   달라지고 무엇을 받았는지 기록도 남지 않습니다. SHA 를 먼저 정하고
    #   그 SHA 의 파일을 받아 DEPLOY_COMMIT 에 적어 둡니다 — 이관 패키지가
    #   이 값을 실어 나르고, 대상은 같은 값인지 대조합니다.
    # -----------------------------------------------------------
    # git ls-remote 는 요청 횟수 제한이 없어 먼저 씁니다(GitHub API 는 IP 당 시간 60회).
    DEPLOY_COMMIT="$( { git ls-remote "$REPO_GIT" "refs/heads/${BRANCH}" 2>/dev/null | cut -f1; } || true )"
    if ! printf '%s' "$DEPLOY_COMMIT" | grep -qE '^[0-9a-f]{40}$'; then
        DEPLOY_COMMIT="$(curl -fsSL -H 'Accept: application/vnd.github.sha' "${REPO_API}/commits/${BRANCH}" 2>/dev/null || true)"
    fi
    if printf '%s' "$DEPLOY_COMMIT" | grep -qE '^[0-9a-f]{40}$'; then
        FETCH_BASE="${REPO_RAW}/${DEPLOY_COMMIT}"
        ok "브랜치 ${BRANCH} → 커밋 ${DEPLOY_COMMIT:0:7}"
    else
        DEPLOY_COMMIT="unknown"
        FETCH_BASE="$RAW_BASE"
        warn "커밋을 확인하지 못해 브랜치 최신본을 받습니다 (GitHub API 제한 등) — 커밋 대조가 불가능합니다"
    fi

    fetch_raw() {  # fetch_raw <저장소 상대경로> <배포 디렉터리 상대경로>
        curl -fsSL "${FETCH_BASE}/$1" -o "$DEPLOY_DIR/$2.new" \
            || die "받지 못했습니다: ${FETCH_BASE}/$1"
        mv "$DEPLOY_DIR/$2.new" "$DEPLOY_DIR/$2"
    }
    fetch_raw "docker-compose.yml"            "docker-compose.yml"
    fetch_raw "docker-compose.registry.yml"   "docker-compose.registry.yml"
    fetch_raw "deploy/schema.sqlite.sql"      "deploy/schema.sqlite.sql"
    # 검증 · 패키지 · 데이터 지문 스크립트 — 타겟에 저장소가 없으므로 함께 둡니다.
    fetch_raw "deploy/compose/verify.sh"      "verify.sh"
    fetch_raw "deploy/compose/backup.sh"      "backup.sh"
    fetch_raw "deploy/compose/datacheck.sh"   "datacheck.sh"
    # 이관 동등성 비교 — backup.sh 가 기준을 뜨고, 이관 뒤 이 스크립트가 대조합니다.
    fetch_raw "deploy/migcompare.py"          "migcompare.py"
    fetch_raw "deploy/golden-questions.txt"   "golden-questions.txt"
    chmod +x "$DEPLOY_DIR/verify.sh" "$DEPLOY_DIR/backup.sh" "$DEPLOY_DIR/datacheck.sh"
    # deploy.sh 자신도 같은 커밋의 사본으로 맞춥니다(위 0절은 브랜치로 받았습니다).
    # 실행 중인 파일을 덮어쓰면 bash 가 남은 부분을 깨뜨려 읽으므로, 다음 실행부터
    # 적용되도록 이름을 바꿔 원자적으로 교체합니다(실행 중인 inode 는 그대로).
    if [ "$DEPLOY_COMMIT" != "unknown" ]; then fetch_raw "deploy/compose/deploy.sh" "deploy.sh"; chmod +x "$DEPLOY_DIR/deploy.sh"; fi
    printf '%s\n' "$DEPLOY_COMMIT" > "$DEPLOY_DIR/DEPLOY_COMMIT"
    ok "파일 9개 수신 (커밋 ${DEPLOY_COMMIT:0:7})"
fi
status_set commit="$DEPLOY_COMMIT"


# -----------------------------------------------------------
# 5. .env
#
# 시크릿을 자동 발급합니다. 이미 있으면 건드리지 않습니다 — 재실행할 때
# 비밀번호가 바뀌면 기존 OpenSearch 볼륨에 접속하지 못합니다.
# -----------------------------------------------------------
log "5. 환경 파일"
phase compose:5-env
ENV_FILE="$DEPLOY_DIR/.env"
if [ -f "$ENV_FILE" ]; then
    # 옮겨 오는 과정에서 권한이 풀렸을 수 있습니다(시크릿 파일).
    chmod 600 "$ENV_FILE" 2>/dev/null || true
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

# 이관 전후 동등성 비교용. 진입물에서 넘긴 값이 그대로 들어옵니다.
#   TEMPERATURE=0 LLM_SEED=42 ... bash   → 결정적 (답변 비교 가능)
# 평소 운영 기본값은 0.1 · -1 입니다.
#
# ★ 전에는 이 두 줄에 0.1 · -1 을 하드코딩해서, 진입물에 결정적 설정을
#   줘도 조용히 무시됐습니다. 문서마다 그 값을 주라고 적어뒀는데 정작
#   컴포즈 쪽은 받지 않고 있었고, 같은 질문에 매번 다른 답이 나왔습니다.
TEMPERATURE=${TEMPERATURE:-0.1}
LLM_SEED=${LLM_SEED:--1}

REGISTRY_PREFIX=$REGISTRY_PREFIX
IMAGE_TAG=$IMAGE_TAG

# 프론트엔드를 여는 호스트 포트
FRONTEND_PORT=${FRONTEND_PORT:-80}
EOF
    chmod 600 "$ENV_FILE"

    { echo "생성 시각 : $(date '+%Y-%m-%d %H:%M:%S') (compose)"
      echo "JWT_SECRET=$jwt"
      echo "OPENSEARCH_PASSWORD=$ospw"; } > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"

    ok "생성 — 시크릿 2종 자동 발급"
    ok "시크릿 사본: $SECRET_FILE (배포 디렉터리째 이관하면 .env 가 함께 옮겨집니다)"
fi


# 뒤에서 OpenSearch 에 붙을 때 씁니다.
OS_PW="$(grep -E '^OPENSEARCH_PASSWORD=' "$ENV_FILE" | tail -1 | cut -d= -f2-)"
[ -n "$OS_PW" ] || die ".env 에 OPENSEARCH_PASSWORD 가 없습니다: $ENV_FILE"


# -----------------------------------------------------------
# 공통 도구 (6절 이후)
# -----------------------------------------------------------
cd "$DEPLOY_DIR"

# ★ 이관 모드(NO_UPDATE=1)는 검증을 하나도 건너뛰지 않습니다. 패키지 · 커밋 ·
#   배포 파일 · 이미지 digest · 데이터 지문 중 하나라도 어긋나면 "데이터가
#   보존됐다" 는 결론을 낼 수 없으므로 멈춥니다(네이티브 bootstrap.sh 와 같음).
STRICT="$NO_UPDATE"

FRONTEND_PORT="${FRONTEND_PORT:-$(_env_from_file FRONTEND_PORT)}"
FRONTEND_PORT="${FRONTEND_PORT:-80}"
export FRONTEND_PORT

SNAP_DIR="$DEPLOY_DIR/deploy/snapshots"
# 패키지에서 꺼낸 작은 파일(DB · 지문 · 런타임 기록)을 두는 곳. 컨테이너에
# 마운트해서 쓰므로 심볼릭 링크가 아니라 실제 파일이어야 합니다.
RESTORE_DIR="$DEPLOY_DIR/.restore"
# 마지막으로 적용을 끝낸 패키지(checksums.sha256 의 해시). 같은 패키지로
# 다시 실행하면 데이터 단계를 건너뜁니다 — 재시도가 데이터를 건드리지 않게.
APPLIED_MARK="$DEPLOY_DIR/.package-applied"
# opensearchproject/opensearch 이미지의 실행 계정. 스냅샷 디렉터리(바인드
# 마운트)에 쓰려면 이 uid 가 소유해야 합니다.
OS_UID=1000

# ★ 기본 compose 파일 목록. 이관 패키지로 이미지를 고정하면 lock 파일이,
#   사용자가 덮어쓸 값이 있으면 override 파일이 뒤에 붙습니다.
#   (-f 를 주면 docker-compose.override.yml 은 자동으로 읽히지 않아 직접 붙입니다)
compose_files() {
    local f="docker-compose.yml:docker-compose.registry.yml"
    [ -f docker-compose.lock.yml ] && f="$f:docker-compose.lock.yml"
    [ -f docker-compose.override.yml ] && f="$f:docker-compose.override.yml"
    printf '%s' "$f"
}
# ★ 환경변수(COMPOSE_FILE=…)로 넘기면 안 됩니다 — DOCKER 가 "sudo docker" 이면
#   sudo 가 환경을 지워 registry 오버레이 없이 실행됩니다. -f 로 넘깁니다.
compose() {
    local a=() f fs
    IFS=: read -ra fs <<< "$(compose_files)"
    for f in "${fs[@]}"; do a+=(-f "$f"); done
    $DOCKER compose "${a[@]}" "$@"
}

# .env 의 COMPOSE_FILE 을 실제 목록과 맞춥니다. 그래야 사람이 배포 디렉터리에서
# 그냥 `docker compose ps` · `docker compose logs` 를 쳐도 같은 정의를 봅니다
# (registry 오버레이가 빠지면 build: 가 살아나 소스 없는 VM 에서 빌드를 시도합니다).
_env_set() {  # _env_set <키> <값> — .env 의 한 줄을 맞춥니다(없으면 추가)
    local want="$1=$2"
    if grep -qE "^$1=" "$ENV_FILE"; then
        grep -qxF "$want" "$ENV_FILE" || sed -i "s#^$1=.*#${want}#" "$ENV_FILE"
    else
        printf '%s\n' "$want" >> "$ENV_FILE"
    fi
}
sync_compose_file_env() {
    if ! grep -qE '^COMPOSE_FILE=' "$ENV_FILE"; then
        printf '\n# 배포 디렉터리에서 docker compose 를 그냥 쳐도 같은 정의를 쓰도록 deploy.sh 가 관리합니다\n' >> "$ENV_FILE"
    fi
    _env_set COMPOSE_FILE "$(compose_files)"
    # 셸에서 준 포트가 compose(.env 를 읽음)에도 그대로 적용되게 맞춥니다.
    _env_set FRONTEND_PORT "$FRONTEND_PORT"
}

# trun [-v 호스트:컨테이너 ...] '<bash 명령>'
# tomcat 이미지(sqlite3 · bash 포함)로 lexai_data 볼륨에 일회성 컨테이너를 붙입니다.
# 서비스를 띄우지 않고도 볼륨 안의 DB 를 다룰 수 있습니다.
trun() {
    local vols=()
    while [ "$#" -gt 1 ] && [ "$1" = "-v" ]; do vols+=(-v "$2"); shift 2; done
    compose run --rm --no-deps -T "${vols[@]}" --entrypoint bash tomcat -c "$1" </dev/null
}

PROJECT="$( { compose config --format json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])'; } 2>/dev/null || true )"
[ -n "$PROJECT" ] || PROJECT="$(basename "$DEPLOY_DIR" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_-')"
vol_exists() { $DOCKER volume inspect "${PROJECT}_$1" >/dev/null 2>&1; }

# ★ </dev/null 은 필수입니다 — docker compose exec 는 -T 여도 stdin 을 읽습니다.
os() { compose exec -T opensearch curl -sk -u "admin:${OS_PW}" "$@" </dev/null; }
OS_BASE="https://127.0.0.1:9200"
os_count() { { os "$OS_BASE/${INDEX_NAME}/_count" | grep -o '"count":[0-9]*' | cut -d: -f2; } 2>/dev/null || true; }
os_code()  { { os -o /dev/null -w '%{http_code}' "$OS_BASE/${INDEX_NAME}"; } 2>/dev/null || echo 000; }

svc_health() {
    local cid; cid="$( { compose ps -q "$1" 2>/dev/null | head -1; } || true )"
    [ -n "$cid" ] || { echo none; return 0; }
    $DOCKER inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || echo none
}
wait_healthy() {  # wait_healthy <서비스> <초>
    local deadline=$(( $(date +%s) + $2 )) h
    while :; do
        h="$(svc_health "$1")"
        if [ "$h" = "healthy" ]; then return 0; fi
        if [ "$(date +%s)" -ge "$deadline" ]; then return 1; fi
        sleep 5
    done
}

# 기존 사용자의 배포 디렉터리라도 스냅샷 폴더는 OpenSearch(uid 1000)가 써야
# 합니다. Tumblebug VM 의 cb-user 는 uid 1000 이 아닌 경우가 많아(Ubuntu AMI 는
# ubuntu 가 1000) 그대로 두면 backup.sh 의 스냅샷 생성이 권한 오류로 실패합니다.
own_snapdir() {
    mkdir -p "$SNAP_DIR" 2>/dev/null || sudo mkdir -p "$SNAP_DIR"
    if [ "$(stat -c %u "$SNAP_DIR")" != "$OS_UID" ] || [ -n "$(find "$SNAP_DIR" ! -uid "$OS_UID" -print -quit 2>/dev/null)" ]; then
        sudo chown -R "$OS_UID:$OS_UID" "$SNAP_DIR"
    fi
}


# -----------------------------------------------------------
# 6. 이관 패키지
#
# 받아서 검증만 하고, 데이터에 손대는 일은 이미지를 받은 뒤(8절~)에 합니다.
# 검증 순서는 싼 것부터 — 커밋 · 배포 파일 · 이미지 digest 가 틀리면 수 GB
# 아카이브를 볼 필요도 없습니다.
#
#   checksums.sha256       아래 파일 전부의 SHA-256
#   source-commit.txt      원본 배포의 커밋(DEPLOY_COMMIT)
#   deploy-files.sha256    원본 배포 디렉터리의 정의 · 스크립트 해시
#   images.lock            원본에서 실제로 돌던 이미지 digest (서비스별)
#   opensearch-snapshots.tar.gz  색인 스냅샷 (안에 contents.tsv)
#   lexai.db               SQLite (VACUUM INTO)
#   data-fingerprint.tsv   테이블별 행 수 · 내용 해시
#   runtime-versions.txt   Ollama 버전 · 모델 ID
#
# 네이티브 패키지(deploy/native/backup.sh)도 받습니다 — 형태 간 이관.
# 그 경우 images.lock · deploy-files.sha256 이 없으므로 이관 모드가 아닌
# 일반 배포(NO_UPDATE 없이)로 실행합니다.
# -----------------------------------------------------------
log "6. 이관 패키지"
phase compose:6-package
HAVE_PKG=0; PKG_SKIP=0; HAVE_DB=0; HAVE_FP=0; HAVE_RT=0; PKG_ID=""

if [ -z "${SNAPSHOT_URI:-}" ]; then
    [ "$STRICT" = "1" ] && die "NO_UPDATE=1 (이관 모드) 에는 SNAPSHOT_URI 가 필요합니다 — backup.sh 패키지 경로(예: ~/lexai-backup/latest)를 지정하세요"
    ok "SNAPSHOT_URI 미지정 — 건너뜀 (색인 없이 뜨면 답변에 근거가 없습니다)"
    if [ -f docker-compose.lock.yml ]; then
        rm -f docker-compose.lock.yml
        ok "이전 이관의 이미지 고정(docker-compose.lock.yml)을 해제했습니다 — 태그 ${IMAGE_TAG} 기준으로 받습니다"
    fi
else
    HAVE_PKG=1
    rm -rf "$RESTORE_DIR"
    mkdir -p "$RESTORE_DIR"
    tmp="$RESTORE_DIR"

    # ★ 순정 Ubuntu 이미지에는 클라우드 CLI 가 없습니다. 이관 도구가 부르는
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
            #   수 GB 아카이브를 한 번 더 복사하면 디스크를 두 배로 쓰고 시간도 그만큼 듭니다.
            *)        [ -f "$1" ] || return 1
                      ln -s "$(readlink -f "$1")" "$2" ;;
        esac
    }
    # 컨테이너에 마운트할 작은 파일은 링크를 실제 파일로 바꿉니다
    # (링크 대상은 마운트 밖이라 컨테이너에서 깨집니다).
    materialize() { if [ -L "$1" ]; then cp --remove-destination "$(readlink -f "$1")" "$1"; fi; }

    _sum_re() { printf '[[:space:]]\\*?(\\./)?%s$' "$(printf '%s' "$1" | sed 's/\./\\./g')"; }
    has_sum()   { [ -f "$tmp/checksums.sha256" ] && grep -qE "$(_sum_re "$1")" "$tmp/checksums.sha256"; }
    check_sum() { ( cd "$tmp" && grep -E "$(_sum_re "$1")" checksums.sha256 | sha256sum -c --quiet ) >/dev/null 2>&1; }
    # need <파일> <필수 여부 1|0> — 받고 체크섬까지 확인. 없으면 1 을 돌려줍니다.
    need() {
        if ! fetch "${SNAPSHOT_URI%/}/$1" "$tmp/$1" 2>/dev/null; then
            rm -f "$tmp/$1"
            [ "$2" = "1" ] && die "패키지에 $1 이 없습니다 — 이관 모드에서는 필수입니다 (지금 버전의 backup.sh 로 다시 만드세요)"
            return 1
        fi
        if has_sum "$1"; then
            check_sum "$1" || die "$1 체크섬 불일치 — 전송이 온전하지 않습니다"
        elif [ "$2" = "1" ]; then
            die "checksums.sha256 에 $1 항목이 없습니다"
        elif [ -f "$tmp/checksums.sha256" ]; then
            warn "checksums.sha256 에 $1 항목이 없어 확인을 건너뜁니다"
        fi
        return 0
    }

    log "   패키지: $SNAPSHOT_URI"
    if fetch "${SNAPSHOT_URI%/}/checksums.sha256" "$tmp/checksums.sha256" 2>/dev/null; then
        materialize "$tmp/checksums.sha256"
        PKG_ID="$(sha256sum "$tmp/checksums.sha256" | cut -c1-64)"
    else
        rm -f "$tmp/checksums.sha256"
        [ "$STRICT" = "1" ] && die "checksums.sha256 이 없습니다 — 이관 모드에서는 무결성 검증 없이 진행하지 않습니다"
        warn "checksums.sha256 이 없어 체크섬 확인을 건너뜁니다"
        PKG_ID="nochecksum:${SNAPSHOT_URI}"
    fi

    # --- 커밋 -------------------------------------------------
    if need source-commit.txt "$STRICT"; then
        pkg_commit="$(tr -d '[:space:]' < "$tmp/source-commit.txt")"
        if [ "$pkg_commit" = "$DEPLOY_COMMIT" ]; then
            ok "커밋 일치 (${DEPLOY_COMMIT:0:7})"
        elif [ "$STRICT" = "1" ]; then
            die "커밋 불일치 — 원본과 다른 버전의 배포 정의입니다
  패키지(원본)  : $pkg_commit
  옮겨 온 배포  : $DEPLOY_COMMIT
  원본에서 패키지를 만든 뒤 배포 디렉터리가 바뀌었거나, 다른 시점의 디렉터리를 옮겼습니다."
        else
            warn "커밋 다름 — 패키지 ${pkg_commit:0:7} / 이번 배포 ${DEPLOY_COMMIT:0:7} (형태 간 이관이거나 새 버전으로 올리는 경우 정상)"
        fi
    else
        pkg_commit=""
    fi

    # --- 배포 파일 --------------------------------------------
    # ★ 커밋이 같아도 옮겨 온 디렉터리의 파일을 누가 고쳤으면 커밋은 그걸 모릅니다.
    if need deploy-files.sha256 "$STRICT"; then
        if [ "$STRICT" = "1" ]; then
            # ★ pipefail 이라 sha256sum 의 실패(=불일치)가 대입문의 실패가 되어 if 가
            #   거꾸로 읽힙니다. 상태는 버리고 출력만 봅니다.
            bad="$( { (cd "$DEPLOY_DIR" && sha256sum -c "$tmp/deploy-files.sha256" 2>&1) || true; } | { grep -v ': OK$' || true; } )"
            if [ -n "$bad" ]; then
                die "옮겨 온 배포 파일이 원본과 다릅니다:
$(printf '%s\n' "$bad" | sed 's/^/    /')"
            fi
            ok "배포 파일 $(grep -c . "$tmp/deploy-files.sha256")개 원본과 일치"
        fi
    fi

    # --- 이미지 digest ----------------------------------------
    # 태그(v2 · latest)는 다시 푸시되면 다른 내용이 됩니다. 원본에서 실제로
    # 돌던 digest 로 고정해야 "같은 것을 옮겼다" 가 성립합니다.
    rm -f docker-compose.lock.yml
    LOCK_SVCS="frontend tomcat ai ollama ollama-init opensearch"
    if need images.lock "$STRICT"; then
        materialize "$tmp/images.lock"
        if [ "$STRICT" != "1" ] && [ "$pkg_commit" != "$DEPLOY_COMMIT" ]; then
            warn "images.lock 은 커밋이 같을 때만 씁니다 — 이번 배포의 태그 기준으로 받습니다"
        else
            {
                echo "# deploy.sh 가 이관 패키지의 images.lock 으로 만든 파일입니다."
                echo "# 원본에서 실제로 돌던 이미지(digest)로 고정합니다. 지우면 태그 기준으로 돌아갑니다."
                echo "services:"
            } > docker-compose.lock.yml.new
            n=0
            for svc in $LOCK_SVCS; do
                ref="$(awk -v s="$svc" '$1==s {print $2}' "$tmp/images.lock" | tail -1)"
                if ! printf '%s' "$ref" | grep -qE '@sha256:[0-9a-f]{64}$'; then
                    rm -f docker-compose.lock.yml.new
                    [ "$STRICT" = "1" ] && die "images.lock 에 ${svc} 의 digest 가 없습니다 — 원본과 같은 이미지임을 보장할 수 없습니다"
                    warn "images.lock 에 ${svc} 가 없어 이미지 고정을 쓰지 않습니다"; n=-1; break
                fi
                printf '  %s:\n    image: %s\n' "$svc" "$ref" >> docker-compose.lock.yml.new
                n=$((n + 1))
            done
            if [ "$n" -gt 0 ]; then
                mv docker-compose.lock.yml.new docker-compose.lock.yml
                ok "이미지 digest 고정 ${n}개 (docker-compose.lock.yml)"
            fi
        fi
    fi

    # --- 아카이브 · DB · 지문 · 런타임 -------------------------
    need opensearch-snapshots.tar.gz 1
    ok "아카이브 체크섬 확인"

    if need lexai.db "$STRICT"; then
        materialize "$tmp/lexai.db"; HAVE_DB=1; ok "DB 체크섬 확인 ($(du -h "$tmp/lexai.db" | cut -f1))"
    else
        warn "패키지에 lexai.db 가 없습니다 — 빈 DB 로 시작합니다"
    fi
    if need data-fingerprint.tsv "$STRICT"; then
        materialize "$tmp/data-fingerprint.tsv"; HAVE_FP=1; ok "데이터 지문 확인"
    fi
    # 데이터가 아니라 답변 조건이라, 없어도 멈추지 않습니다(비교 결과만 남김).
    if need runtime-versions.txt 0; then
        materialize "$tmp/runtime-versions.txt"; HAVE_RT=1
        src_ollama="$(awk '$1=="ollama"{print $2}' "$tmp/runtime-versions.txt")"
        ok "런타임 기록 확인 (원본 Ollama ${src_ollama:-?})"
        # 네이티브 패키지처럼 images.lock 이 없으면 Ollama 만이라도 같은 버전으로 맞춥니다.
        if [ ! -f docker-compose.lock.yml ] && [ -n "$src_ollama" ]; then
            if $DOCKER pull -q "ollama/ollama:${src_ollama}" >/dev/null 2>&1; then
                printf '# deploy.sh 가 원본의 Ollama 버전(runtime-versions.txt)으로 고정했습니다.\nservices:\n  ollama:\n    image: ollama/ollama:%s\n  ollama-init:\n    image: ollama/ollama:%s\n' \
                    "$src_ollama" "$src_ollama" > docker-compose.lock.yml
                ok "Ollama 를 원본과 같은 ${src_ollama} 로 고정"
            else
                warn "ollama/ollama:${src_ollama} 를 받지 못해 latest 로 진행합니다 — 답변 비교 때 변수가 됩니다"
            fi
        fi
    fi

    # --- 이관 비교 기준 -----------------------------------------
    # 없어도 멈추지 않습니다(옛 패키지 · GOLDEN=0). 비교표에서 SKIP 으로 남습니다.
    for f in source-info.json golden.json package-files.tsv; do
        if fetch "${SNAPSHOT_URI%/}/$f" "$tmp/$f" 2>/dev/null; then
            materialize "$tmp/$f"
            if has_sum "$f"; then check_sum "$f" || die "$f 체크섬 불일치 — 전송이 온전하지 않습니다"; fi
        else
            rm -f "$tmp/$f"
        fi
    done
    # 패키지 파일 대조(T1-2) — 지금 합니다. 복원 단계가 $tmp 의 DB 를 지우므로 나중에는 잴 수 없습니다.
    if [ -f "$tmp/package-files.tsv" ] && command -v python3 >/dev/null 2>&1; then
        if [ -d "$SNAPSHOT_URI" ]; then
            cmp_pkg="$(readlink -f "$SNAPSHOT_URI")"
        else
            # 원격 패키지 — 목록에 있는데 아직 받지 않은 작은 파일(MANIFEST 등)을 마저 받습니다.
            cmp_pkg="$tmp"
            while IFS=$'\t' read -r f _ _; do
                [ -n "$f" ] && [ ! -e "$tmp/$f" ] && { fetch "${SNAPSHOT_URI%/}/$f" "$tmp/$f" 2>/dev/null || rm -f "$tmp/$f"; }
            done < "$tmp/package-files.tsv"
        fi
        if python3 "$DEPLOY_DIR/migcompare.py" files-check --package "$cmp_pkg" --out "$tmp/files-rows.tsv"; then
            ok "패키지 파일 $(grep -c . "$tmp/package-files.tsv")개 — 이름 · 바이트 · 해시 원본과 같음"
        else
            warn "패키지 파일 대조 FAIL — 비교표(migration-compare.csv)에 남깁니다"
        fi
    fi

    # --- 기존 설치 확인 ---------------------------------------
    # ★ 이미 LexAI 가 돌던 VM 에 다시 이관하면(A→B→A) 옛 볼륨이 남아 옛 색인 ·
    #   옛 DB 가 그대로 쓰입니다. 예전에는 "사용자가 있으면 복원 건너뜀" 이라
    #   이관한 데이터가 조용히 무시되고, 서비스는 멀쩡해 보였습니다.
    existing=()
    for v in lexai_data opensearch_data; do
        if vol_exists "$v"; then existing+=("볼륨 ${PROJECT}_$v"); fi
    done
    # 고정 container_name 이라 다른 프로젝트(다른 배포 디렉터리)의 컨테이너와도 부딪힙니다.
    others="$( { $DOCKER ps -a --filter 'name=^lexai-' --format '{{.Names}} {{.Label "com.docker.compose.project"}}' \
        | awk -v p="$PROJECT" '$2!=p {print $1" (프로젝트 "($2==""?"없음":$2)")"}'; } 2>/dev/null || true )"
    if [ -n "$others" ]; then
        die "이름이 겹치는 다른 LexAI 컨테이너가 있습니다 — 기동할 수 없습니다
$(printf '%s\n' "$others" | sed 's/^/    /')
  다른 배포 디렉터리의 스택이면 그 디렉터리에서 $DOCKER compose down 후 다시 실행하세요."
    fi

    if [ "${#existing[@]}" -gt 0 ]; then
        if [ "$FORCE_CLEAN" = "1" ]; then
            log "   FORCE_CLEAN=1 — 기존 설치를 비웁니다"
            printf '    %s\n' "${existing[@]}"
            # 1) DB 는 지우지 않고 보관합니다(작고, 되돌릴 길을 남깁니다).
            if vol_exists lexai_data; then
                replaced="$HOME/lexai-replaced/$(date +%Y%m%d-%H%M%S)"
                mkdir -p "$replaced"
                # 이미지가 아직 없으면 run 이 받습니다(태그 또는 lock 기준).
                trun -v "$replaced:/out" "cp -a /var/lib/lexai/. /out/ 2>/dev/null || true; chown -R $(id -u):$(id -g) /out" >/dev/null \
                    || warn "기존 DB 보관에 실패했습니다 — 계속 진행합니다"
                ok "기존 DB 보관: $replaced"
            fi
            # 2) 컨테이너를 내리고 데이터 볼륨만 지웁니다.
            #    ollama_models(5GB) · hf_cache 는 이관 대상이 아니라 남깁니다.
            compose down --remove-orphans >/dev/null 2>&1 || true
            for v in lexai_data opensearch_data; do
                if vol_exists "$v"; then $DOCKER volume rm "${PROJECT}_$v" >/dev/null || die "볼륨 삭제 실패: ${PROJECT}_$v"; fi
            done
            rm -f "$APPLIED_MARK"
            ok "데이터 볼륨 삭제 (모델 볼륨은 유지)"
        elif [ -f "$APPLIED_MARK" ] && [ "$(cat "$APPLIED_MARK")" = "$PKG_ID" ]; then
            PKG_SKIP=1
            ok "이 패키지는 이미 적용됐습니다 — 데이터 단계를 건너뜁니다 (다시 적용하려면 FORCE_CLEAN=1)"
        else
            die "이 VM 에 기존 LexAI 데이터가 있습니다 — 그대로 진행하면 이관한 데이터 대신 옛 데이터가 쓰입니다
$(printf '    %s\n' "${existing[@]}")
  새 VM 으로 이관하거나, 기존 데이터를 비우고 진행하려면 FORCE_CLEAN=1 을 함께 주세요.
  (기존 DB 는 ~/lexai-replaced/<시각> 으로 보관되고, 모델 볼륨은 남습니다.
   이 VM 에서 이전 이관이 중간에 실패해 다시 돌리는 경우도 같습니다)"
        fi
    fi

    if [ "$PKG_SKIP" = "0" ]; then
        # --- 공간 ---------------------------------------------
        # 스냅샷 폴더(풀린 아카이브)와 OpenSearch 볼륨(복원된 색인)이 각각
        # 아카이브의 약 1.2배를 씁니다. 같은 디스크면 합쳐서 봅니다.
        arc_kb=$(( $(stat -L -c %s "$tmp/opensearch-snapshots.tar.gz") / 1024 ))
        need_kb=$(( arc_kb * 12 / 10 ))
        droot="$($DOCKER info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
        free_snap=$(df -Pk "$DEPLOY_DIR" | awk 'NR==2 {print $4}')
        free_dock=$( { sudo df -Pk "$droot" 2>/dev/null || df -Pk /var/lib; } | awk 'NR==2 {print $4}')
        if [ "$( { sudo stat -c %d "$droot" 2>/dev/null || stat -c %d /var/lib; } )" = "$(stat -c %d "$DEPLOY_DIR")" ]; then
            [ "$free_snap" -ge $(( need_kb * 2 )) ] \
                || die "공간이 부족합니다 — 필요 약 $(( need_kb * 2 / 1024 / 1024 ))GB(스냅샷 + 복원 색인) / 여유 $(( free_snap / 1024 / 1024 ))GB (df -h 확인)"
        else
            [ "$free_snap" -ge "$need_kb" ] || die "스냅샷을 풀 공간이 부족합니다 — 필요 약 $(( need_kb / 1024 / 1024 ))GB / 여유 $(( free_snap / 1024 / 1024 ))GB"
            [ "$free_dock" -ge "$need_kb" ] || die "Docker 디스크($droot) 공간이 부족합니다 — 필요 약 $(( need_kb / 1024 / 1024 ))GB / 여유 $(( free_dock / 1024 / 1024 ))GB"
        fi

        # --- 압축 해제 ----------------------------------------
        # ★ 항상 비우고 풉니다. 옛 스냅샷 파일이 섞이면 저장소 세대 정보가
        #   어긋나고, 아래 내용 대조도 깨집니다.
        sudo rm -rf "$SNAP_DIR"
        mkdir -p "$SNAP_DIR"
        tar -xf "$tmp/opensearch-snapshots.tar.gz" -C "$SNAP_DIR" --no-same-owner

        # 압축을 푼 결과가 원본 디렉터리와 같은지 — 개수 · 해시를 대조합니다.
        if [ -f "$SNAP_DIR/contents.tsv" ]; then
            want_n=$(grep -c . "$SNAP_DIR/contents.tsv")
            have_n=$( cd "$SNAP_DIR" && find . -type f ! -name contents.tsv | wc -l )
            [ "$want_n" = "$have_n" ] || die "스냅샷 파일 수가 다릅니다 — 목록 ${want_n}개 / 풀린 것 ${have_n}개"
            ( cd "$SNAP_DIR" && awk -F'\t' '{print $3"  "$1}' contents.tsv | sha256sum -c --quiet ) >/dev/null 2>&1 \
                || die "스냅샷 파일 내용이 목록(contents.tsv)과 다릅니다 — 아카이브가 온전하지 않습니다"
            ok "색인 스냅샷 배치 — 파일 ${have_n}개 해시 일치 ($(du -sh "$SNAP_DIR" | cut -f1))"
        else
            [ "$STRICT" = "1" ] && die "아카이브 안에 contents.tsv 가 없습니다 — 압축 해제 결과를 대조할 수 없습니다"
            warn "contents.tsv 가 없어 압축 해제 결과 대조를 건너뜁니다"
        fi
    fi
fi
own_snapdir
sync_compose_file_env


# -----------------------------------------------------------
# 7. 이미지
# -----------------------------------------------------------
if [ "$NO_START" = "1" ]; then
    echo
    status_set state=prepared phase=compose:prepared finished_at="$(now_iso)"
    log "준비 완료 (NO_START=1 — 기동은 하지 않았습니다)"
    echo "  기동: cd $DEPLOY_DIR && $DOCKER compose up -d --no-build   (.env 의 COMPOSE_FILE 사용)"
    exit 0
fi

# -----------------------------------------------------------
# 여기부터는 네이티브 up.sh 와 같은 모양으로 출력합니다.
#   ━━ 설치 ━━ → ━━ 데이터 준비 ━━ → (━━ 데이터 보존 확인 ━━) → ━━ 기동 ━━ → ━━ 검증 ━━ → ━━ 요약 ━━
# 줄마다 시각을 붙이고, 마지막 요약에 단계별 소요 시간을 남깁니다. 리뷰어가 두 형태의
# 로그를 나란히 놓고 같은 단계끼리 비교할 수 있게 하려는 것입니다.
# 단계 이름은 status.json 의 phase · failed_phase 에도 그대로 들어갑니다(네이티브와 같음).
# -----------------------------------------------------------
logt() { printf '%s[%s]%s %s\n' "$C_INFO" "$(date +%H:%M:%S)" "$C_OFF" "$*"; }
declare -a PHASE_NAMES=()
declare -a PHASE_SECS=()
_PH_NAME=""; _PH_START=0
phase_end() {
    if [ -n "$_PH_NAME" ]; then
        PHASE_NAMES+=("$_PH_NAME"); PHASE_SECS+=($(( $(date +%s) - _PH_START )))
        _PH_NAME=""
    fi
}
phase_begin() {  # phase_begin <단계 이름>
    phase_end
    _PH_NAME="$1"; _PH_START=$(date +%s)
    echo
    printf '%s━━ %s ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$C_HEAD" "$1" "$C_OFF"
    phase "$1"
}
UP_START=$(date +%s)

phase_begin "설치"
if [ -f docker-compose.lock.yml ] && grep -q '@sha256:' docker-compose.lock.yml; then
    logt "이미지 받기 — 원본과 같은 digest (docker-compose.lock.yml)"
elif [ -f docker-compose.lock.yml ]; then
    logt "이미지 받기 — Ollama 는 원본 버전, 나머지는 ${REGISTRY_PREFIX}/lexai-*:${IMAGE_TAG}"
else
    logt "이미지 받기 — ${REGISTRY_PREFIX}/lexai-{frontend,tomcat,ai}:${IMAGE_TAG}"
fi
# ★ digest 로 고정한 경우에는 이미 있는 이미지를 다시 받지 않습니다(같은 digest 는
#   같은 내용). Docker Hub 익명 받기 제한(429)에 걸릴 여지도 줄어듭니다.
#   태그 기준이면 같은 태그가 다시 푸시됐을 수 있어 매번 확인합니다.
pull_args=()
if [ -f docker-compose.lock.yml ]; then pull_args=(--policy missing); fi
pulled=0
for try in 1 2 3; do
    if compose pull "${pull_args[@]}"; then pulled=1; break; fi
    if [ "$try" -lt 3 ]; then warn "이미지 받기 실패 — $((try * 30))초 뒤 다시 시도합니다 (${try}/3)"; sleep $((try * 30)); fi
done
[ "$pulled" = "1" ] || die "이미지를 받지 못했습니다 — 레지스트리 접근 · 태그(또는 lock 의 digest)를 확인하세요
  429 Too Many Requests 면 Docker Hub 익명 받기 제한입니다: docker login 후 다시 실행하거나 잠시 뒤 재시도하세요."
ok "이미지 받기 완료"


# -----------------------------------------------------------
# 8. SQLite DB
#
# ★ 기동 "전"에 볼륨에 넣습니다. 예전에는 띄운 뒤 docker cp 로 덮고 tomcat 만
#   재시작했는데, 열려 있는 DB 를 바꿔치기하는 것이라 옛 -wal/-shm 이 새 파일에
#   덧씌워질 수 있었고, 그 사이 들어온 쓰기가 섞일 수도 있었습니다.
#   tomcat 이미지로 일회성 컨테이너를 띄워 볼륨에 직접 넣습니다.
# -----------------------------------------------------------
phase_begin "데이터 준비"
logt "SQLite DB"
DB_IN="/var/lib/lexai/lexai.db"
if [ "$HAVE_DB" = "1" ] && [ "$PKG_SKIP" = "0" ]; then
    compose stop frontend tomcat >/dev/null 2>&1 || true
    out="$(trun -v "$RESTORE_DIR:/in:ro" "set -e
        mkdir -p /var/lib/lexai
        rm -f $DB_IN $DB_IN-wal $DB_IN-shm $DB_IN-journal
        cp /in/lexai.db $DB_IN
        sqlite3 $DB_IN 'PRAGMA integrity_check;'
        echo users=\$(sqlite3 $DB_IN 'SELECT COUNT(*) FROM users;')")" \
        || die "DB 를 볼륨에 넣지 못했습니다"
    printf '%s\n' "$out" | grep -qx 'ok' || die "DB 무결성 검사 실패:
$out"
    ok "DB 배치 — 무결성 ok · 사용자 $(printf '%s\n' "$out" | sed -n 's/^users=//p')명"
elif [ "$PKG_SKIP" = "1" ]; then
    ok "이미 적용한 패키지 — 건너뜀"
else
    ok "이관 DB 없음 — 볼륨에 DB 가 없으면 entrypoint 가 빈 스키마로 만듭니다"
fi


# -----------------------------------------------------------
# 9. 색인
#
# OpenSearch 만 먼저 띄워 복원합니다. ai 까지 같이 띄우면 ai 가 빈 색인을
# 먼저 만들어 복원이 이름 충돌로 막히는 경쟁이 생깁니다.
# -----------------------------------------------------------
logt "색인 — OpenSearch 만 먼저 기동"
compose up -d --no-build opensearch >/dev/null \
    || die "OpenSearch 를 띄우지 못했습니다 — $DOCKER compose logs opensearch"
wait_healthy opensearch 600 || die "OpenSearch 가 10분 안에 준비되지 않았습니다 — $DOCKER compose logs opensearch"
# ★ 헬스체크(응답만 오면 통과)보다 보안 플러그인 초기화가 늦습니다. 그 사이의
#   요청은 "OpenSearch Security not initialized"(503)로 거절되므로 200 을 기다립니다.
os_up=0
for _ in $(seq 1 60); do
    if [ "$( { os -o /dev/null -w '%{http_code}' "$OS_BASE/_cluster/health"; } 2>/dev/null || true)" = "200" ]; then os_up=1; break; fi
    sleep 3
done
[ "$os_up" = "1" ] || die "OpenSearch 가 요청을 받지 않습니다(보안 플러그인 초기화 · 인증) — $DOCKER compose logs opensearch"
ok "OpenSearch 준비됨"

if [ "$HAVE_PKG" = "1" ] && [ "$PKG_SKIP" = "0" ]; then
    resp="$(os -X PUT "$OS_BASE/_snapshot/${SNAPSHOT_REPO}" -H 'Content-Type: application/json' \
        -d '{"type":"fs","settings":{"location":"/mnt/snapshots","compress":true}}')"
    printf '%s' "$resp" | grep -q '"acknowledged":true' \
        || die "스냅샷 저장소 등록 실패: $(printf '%s' "$resp" | head -c 500)"
    ok "스냅샷 저장소 등록"

    # 패키지마다 스냅샷 이름이 달라(legal-<타임스탬프>) SUCCESS 중 가장 최근 것을 고릅니다.
    snap=$( { os "$OS_BASE/_cat/snapshots/${SNAPSHOT_REPO}?h=id,status,endEpoch" \
        | awk '$2=="SUCCESS"' | sort -k3 -n | tail -1 | awk '{print $1}'; } || true )
    [ -n "$snap" ] || die "복원할 스냅샷이 없습니다 — deploy/snapshots 내용을 확인하세요"

    # ★ 문서가 0건인 껍데기 색인만 지웁니다. 예전에는 "HTTP 200 이면 삭제" 라,
    #   경쟁 상황에서 내용이 있는 색인까지 지울 수 있었습니다.
    if [ "$(os_code)" = "200" ]; then
        c="$(os_count)"
        if [ "${c:-0}" = "0" ]; then
            os -X DELETE "$OS_BASE/${INDEX_NAME}" >/dev/null
            ok "빈 색인 삭제 — 복원 자리를 비웁니다"
        else
            die "이미 ${c}건이 든 색인이 있습니다 — 덮어쓰지 않습니다 (FORCE_CLEAN=1 로 다시 실행)"
        fi
    fi

    logt "색인 복원 중: $snap (수 분 걸립니다)"
    started=$(date +%s)
    resp=$(os -X POST "$OS_BASE/_snapshot/${SNAPSHOT_REPO}/${snap}/_restore?wait_for_completion=true" \
        -H 'Content-Type: application/json' -d "{\"indices\":\"${INDEX_NAME}\"}")
    shards="$(printf '%s' "$resp" | python3 -c 'import json,sys
d=json.load(sys.stdin)["snapshot"]["shards"]; print(d["total"], d["failed"], d["successful"])' 2>/dev/null || true)"
    if [ -z "$shards" ] || [ "$(echo "$shards" | awk '{print $2}')" != "0" ] || [ "$(echo "$shards" | awk '{print $1}')" = "0" ]; then
        die "색인 복원 실패 (샤드 total/failed/successful: ${shards:-?}):
$(printf '%s' "$resp" | head -c 700)"
    fi
    os "$OS_BASE/_cluster/health/${INDEX_NAME}?wait_for_status=yellow&timeout=120s" >/dev/null || true
    count="$(os_count)"
    [ "${count:-0}" -gt 0 ] 2>/dev/null || die "복원 후에도 색인이 비어 있습니다 (df -h · $DOCKER compose logs opensearch)"
    ok "복원 완료 — ${count}건 ($(( $(date +%s) - started ))초)"
    status_set index_docs="$count"
elif [ "$PKG_SKIP" = "1" ]; then
    ok "이미 적용한 패키지 — 색인 $(os_count)건"
fi

# 데이터 보존 확인 — 기동 전에 잽니다. verify.sh 가 verify 계정과 채팅을
# 더하므로 그 뒤에 세면 원본과 항상 달라 보입니다.
DATA_RESULT="해당 없음"
if [ "$HAVE_FP" = "1" ] && [ "$PKG_SKIP" = "0" ]; then
    phase_begin "데이터 보존 확인"
    logt "원본 패키지 ↔ 이 VM"
    mkdir -p "$RUN_DIR"
    REPORT="$RUN_DIR/data-check.txt"
    if trun -v "$RESTORE_DIR:/in:ro" -v "$DEPLOY_DIR/datacheck.sh:/opt/datacheck.sh:ro" \
            "bash /opt/datacheck.sh check $DB_IN /in/data-fingerprint.tsv" | tee "$REPORT.tmp"; then
        result=PASS
    else
        result=FAIL
    fi
    { echo "데이터 보존 확인 : $result"; echo "시각 : $(date '+%Y-%m-%d %H:%M:%S %Z')"; echo "형태 : compose (${PROJECT}_lexai_data:$DB_IN)"; echo; cat "$REPORT.tmp"; } > "$REPORT"
    rm -f "$REPORT.tmp"
    status_set data_check="$result" data_check_report="$REPORT"
    [ "$result" = "PASS" ] || die "데이터 보존 FAIL — 원본과 다른 테이블이 있습니다 (기록: $REPORT)"
    ok "데이터 보존 PASS — 모든 테이블의 행 수와 내용이 원본과 같습니다 (기록: $REPORT)"
    DATA_RESULT="PASS"
elif [ "$HAVE_DB" = "1" ] && [ "$PKG_SKIP" = "0" ]; then
    warn "패키지에 data-fingerprint.tsv 가 없어 데이터 보존을 판정하지 못합니다"
fi

# 데이터 단계 완료 표시 — 이후 단계에서 실패해 다시 돌려도 데이터는 건드리지 않습니다.
if [ "$HAVE_PKG" = "1" ] && [ "$PKG_SKIP" = "0" ]; then
    printf '%s\n' "$PKG_ID" > "$APPLIED_MARK"
    rm -f "$RESTORE_DIR/lexai.db"
fi


# -----------------------------------------------------------
# 10. 기동
# -----------------------------------------------------------
phase_begin "기동"
# ollama-init 이 모델(약 5GB)을 받는 동안 up 이 기다립니다(ai 의 depends_on).
logt "서비스 기동 (최초에는 모델 다운로드로 수 분 걸립니다)"
compose up -d --no-build \
    || die "기동 실패 — $DOCKER compose logs ollama-init · $DOCKER compose ps -a 를 확인하세요"

wait_healthy ai 1200 || die "ai 가 20분 안에 준비되지 않았습니다 — $DOCKER compose logs ai"
ok "ai 준비됨"
wait_healthy tomcat 300 || die "tomcat 이 5분 안에 준비되지 않았습니다 — $DOCKER compose logs tomcat"
ok "tomcat 준비됨"
code=000
for _ in $(seq 1 24); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${FRONTEND_PORT}/" || true)
    if [ "$code" = "200" ]; then break; fi
    sleep 5
done
[ "$code" = "200" ] || die "프론트엔드가 응답하지 않습니다 (HTTP $code, 포트 ${FRONTEND_PORT}) — $DOCKER compose logs frontend"
ok "프론트엔드 HTTP 200 (포트 ${FRONTEND_PORT})"

# 이관 없이 기동만 하는 경우 — 색인이 아예 없으면 검색이 404 로 떨어져 채팅이
# 에러가 나므로, 매핑만 갖춘 빈 색인을 만들어 둡니다(근거 문서만 0건).
if [ "$HAVE_PKG" = "0" ] && [ "$(os_code)" = "404" ]; then
    warn "색인이 없습니다 — 빈 색인으로 진행합니다 (기동 검증 전용)"
    # ★ index_builder 는 생성에 실패해도 0 으로 끝납니다(디스크 워터마크 차단 등).
    #   종료 코드가 아니라 색인이 실제로 생겼는지로 판정합니다.
    compose exec -T ai python -m indexing.index_builder </dev/null || true
    if [ "$(os_code)" = "200" ]; then
        ok "빈 색인 생성 (매핑만)"
    else
        warn "빈 색인 생성 실패 — 채팅이 에러가 날 수 있습니다 ($DOCKER compose logs ai)"
    fi
fi

# 런타임 비교 (경고만) — 원본과 같은 Ollama 버전 · 모델로 떴는지.
# 데이터가 아니라 "같은 조건에서 답하는가" 의 문제라 실패로 보지 않습니다.
if [ "$HAVE_RT" = "1" ] && [ -f "$RESTORE_DIR/runtime-versions.txt" ]; then
    logt "런타임 비교 (원본 ↔ 이 VM)"
    RT="$RESTORE_DIR/runtime-versions.txt"
    rt_ok=yes
    want_v="$(awk '$1=="ollama"{print $2}' "$RT")"
    have_v="$( { compose exec -T ollama ollama --version </dev/null 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1; } || true )"
    if [ "$want_v" = "$have_v" ]; then ok "Ollama ${have_v} (원본과 같음)"
    else warn "Ollama 버전 다름 — 원본 ${want_v:-?} / 이 VM ${have_v:-?}"; rt_ok=no; fi
    have_models="$( { compose exec -T ollama ollama list </dev/null 2>/dev/null | awk 'NR>1 {print $1" "$2}'; } || true )"
    while read -r _ name id; do
        [ -n "$name" ] || continue
        got="$(printf '%s\n' "$have_models" | awk -v n="$name" '$1==n {print $2}')"
        if [ "$got" = "$id" ]; then ok "모델 $name ($id)"
        else warn "모델 $name 다름 — 원본 $id / 이 VM ${got:-없음}"; rt_ok=no; fi
    done < <(awk '$1=="model"' "$RT")
    status_set runtime_match="$rt_ok"
    mv "$RT" "$RESTORE_DIR/runtime-versions.checked-$(date +%Y%m%d-%H%M%S).txt"
fi

# 모델 예열
# ★ 첫 질문 때 Ollama 가 모델(약 4.5GB)을 디스크에서 GPU 로 처음 올립니다.
#   새 EBS 의 첫 읽기는 느려 이것만 3~5분 걸리고, 백엔드 타임아웃(180초)을
#   넘겨 첫 질문이 실패합니다(네이티브 1차 실행의 검증 FAIL 원인).
#   옵션을 실제 호출과 같게 num_ctx 4096 으로 맞춥니다 — 다르면 다시 올립니다.
#   실패해도 기동은 성공으로 둡니다 — 첫 질문이 느릴 뿐 서비스는 정상입니다.
if [ "${SKIP_WARMUP:-0}" != "1" ]; then
    logt "모델 예열"
    WARM_PY='import json,os,sys,urllib.request
m, t = sys.argv[1], int(sys.argv[2])
base = os.environ.get("OLLAMA_BASE_URL", "http://ollama:11434").rstrip("/")
body = json.dumps({"model": m, "prompt": "", "keep_alive": "24h", "options": {"num_ctx": 4096}}).encode()
req = urllib.request.Request(base + "/api/generate", data=body, headers={"Content-Type": "application/json"})
urllib.request.urlopen(req, timeout=t).read()'
    WARM_MAIN="${OLLAMA_MODEL:-$(_env_from_file OLLAMA_MODEL)}"
    WARM_REWRITE="${OLLAMA_REWRITE_MODEL:-$(_env_from_file OLLAMA_REWRITE_MODEL)}"
    for m in "${WARM_MAIN:-legal-gemma}" "${WARM_REWRITE:-gemma3:1b}"; do
        t0=$(date +%s)
        if compose exec -T ai python -c "$WARM_PY" "$m" "${WARMUP_TIMEOUT:-900}" </dev/null >/dev/null 2>&1; then
            ok "$m GPU 적재 ($(( $(date +%s) - t0 ))초)"
        else
            warn "$m 예열 실패 — 첫 질문이 느릴 수 있습니다"
        fi
    done
fi


# -----------------------------------------------------------
# 10-1. 이관 동등성 비교
#
# backup.sh 가 패키지에 남긴 기준(source-info.json · golden.json · package-files.tsv)과
# 이 VM 을 대조해 ~/lexai-run/migration-compare.csv(WidgetRAG 와 같은 형식)에 누적하고,
# 증적을 ~/lexai-run/migration-<시각>/ 에 남깁니다. FAIL 이어도 멈추지 않습니다 —
# 판정은 오케스트레이터가 비교표로 합니다(status.json compare 에도 적습니다).
# AI 서버에 직접 묻습니다 — 대화가 DB 에 남지 않습니다. 검증(verify.sh)과 같은 시각(RUN_TS)을
# 써서 결과표 · 비교표의 같은 회차가 묶이게 합니다.
#   COMPARE=0  이 단계를 건너뜁니다 (기본: 패키지로 이관했으면 실행)
# -----------------------------------------------------------
export RUN_TS="${RUN_TS:-$(date '+%Y-%m-%d %H:%M:%S')}"
COMPARE_RESULT="건너뜀"
if [ "$HAVE_PKG" = "1" ] && [ "${COMPARE:-1}" != "0" ] && command -v python3 >/dev/null 2>&1; then
    phase_begin "이관 동등성 비교"
    EVI="$RUN_DIR/migration-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$EVI"
    # 이 VM 의 런타임 — 원본 runtime-versions.txt 와 같은 형식
    {
        echo "ollama $( { compose exec -T ollama ollama --version </dev/null 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1; } || true )"
        { compose exec -T ollama ollama list </dev/null 2>/dev/null | awk 'NR>1 {print "model "$1" "$2}'; } || true
    } > "$EVI/target-runtime.txt"
    [ -f "$RUN_DIR/data-check.txt" ] && cp "$RUN_DIR/data-check.txt" "$EVI/" 2>/dev/null || true
    case "$DATA_RESULT" in PASS) dc=PASS ;; *) dc=NA ;; esac
    cmp_svcs="$( { compose ps --status running --services 2>/dev/null | sort | tr '\n' ' '; } || true )"
    AI_HOST_PORT="${AI_HOST_PORT:-$(_env_from_file AI_HOST_PORT)}"
    crc=0
    OLLAMA_MODEL="${OLLAMA_MODEL:-$(_env_from_file OLLAMA_MODEL)}" EMBEDDING_DEVICE="${EMBEDDING_DEVICE:-$(_env_from_file EMBEDDING_DEVICE)}" \
    python3 "$DEPLOY_DIR/migcompare.py" compare --package "$RESTORE_DIR" \
        --url "${AI_URL:-http://127.0.0.1:${AI_HOST_PORT:-8000}}" --evidence "$EVI" --form "${FORM:-docker-compose}" \
        --docs "$(os_count)" --services "$cmp_svcs" --data-check "$dc" --data-check-report "$RUN_DIR/data-check.txt" \
        --runtime "$EVI/target-runtime.txt" --csv "$RUN_DIR/migration-compare.csv" --timestamp "$RUN_TS" \
        $([ -f "$RESTORE_DIR/files-rows.tsv" ] && printf -- '--files-rows %s' "$RESTORE_DIR/files-rows.tsv") || crc=$?
    COMPARE_RESULT="$(cat "$EVI/verdict.txt" 2>/dev/null || echo ERROR)"
    [ "$crc" -le 1 ] || COMPARE_RESULT="ERROR"
    status_set compare="$COMPARE_RESULT" compare_dir="$EVI"
    case "$COMPARE_RESULT" in
        PASS) ok "이관 동등성 PASS (증적: $EVI)" ;;
        WARN) warn "이관 동등성 WARN — 이관과 무관하거나 환경 차이인 항목이 있습니다 (증적: $EVI/summary.txt)" ;;
        *)    warn "이관 동등성 ${COMPARE_RESULT} — $EVI/summary.txt 를 확인하세요" ;;
    esac
fi


# -----------------------------------------------------------
# 11. 검증
#
# ★ verify.sh 는 verify 계정을 가입시키고 실제로 채팅을 보내 DB 에 기록을
#   남깁니다. 이관 모드에서는 원본에 없던 기록이 생기므로 기본으로 건너뜁니다
#   (RUN_VERIFY=1 로 켬). 데이터 보존은 위 지문 비교가 판정합니다.
#   이관 모드에서 켠 경우에도 응답 속도 FAIL 은 이관 실패로 보지 않습니다
#   (VERIFY_GATE=0 — 네이티브 up.sh 와 같음).
# -----------------------------------------------------------
phase_end
VERIFY_GATE="${VERIFY_GATE:-$([ "$STRICT" = "1" ] && echo 0 || echo 1)}"
VERIFY_RESULT="건너뜀"
if [ "$SKIP_VERIFY" = "1" ] || { [ "$STRICT" = "1" ] && [ "$RUN_VERIFY" != "1" ]; }; then
    echo
    ok "검증 건너뜀 — 수동 실행: bash $DEPLOY_DIR/verify.sh (verify 계정 · 채팅이 DB 에 남습니다)"
else
    phase_begin "검증"
    if FORM="${FORM:-docker-compose}" RUNS="${RUNS:-1}" \
       ALLOW_EMPTY_INDEX="${ALLOW_EMPTY_INDEX:-$([ "$HAVE_PKG" = "0" ] && echo 1 || echo 0)}" \
       bash "$DEPLOY_DIR/verify.sh"; then
        VERIFY_RESULT="PASS"
    else
        VERIFY_RESULT="FAIL"
    fi
    phase_end
fi
case "$VERIFY_RESULT" in
    PASS) status_set verify=PASS ;;
    FAIL) status_set verify=FAIL ;;
    *)    status_set verify=SKIPPED ;;
esac

TOTAL=$(( $(date +%s) - UP_START ))

echo
printf '%s━━ 요약 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$C_HEAD" "$C_OFF"
for i in "${!PHASE_NAMES[@]}"; do
    printf '  %-12s %4d초\n' "${PHASE_NAMES[$i]}" "${PHASE_SECS[$i]}"
done
printf '  %-12s %4d초\n' "합계" "$TOTAL"
echo
echo "  데이터 보존 : $DATA_RESULT"
echo "  이관 동등성 : $COMPARE_RESULT"
echo "  검증 결과 : $VERIFY_RESULT"
echo "  Frontend  : http://127.0.0.1:${FRONTEND_PORT}"
echo "  종료      : cd $DEPLOY_DIR && $DOCKER compose down"
status_set total_seconds="$TOTAL"

# 검증 결과 처리는 네이티브 up.sh 와 같습니다 — 이관 모드(VERIFY_GATE=0)에서는
# 응답 검증 FAIL 을 이관 실패로 기록하지 않고 경고만 남깁니다.
if [ "$VERIFY_RESULT" = "FAIL" ] && [ "$VERIFY_GATE" = "0" ]; then
    warn "검증 FAIL — 이관(데이터 보존 · 기동)은 성공으로 끝냅니다. 원인: ~/lexai-run/results.csv"
fi
if [ "$VERIFY_RESULT" = "FAIL" ] && [ "$VERIFY_GATE" = "1" ]; then
    die "검증 FAIL — 위 항목과 $DOCKER compose logs 를 확인하세요"
fi
status_set state=success phase=done exit_code=0 finished_at="$(now_iso)"
