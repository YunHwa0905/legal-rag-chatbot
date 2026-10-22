#!/usr/bin/env bash
# ===========================================================
# 이관 패키지 생성 — Docker Compose 형태
#
#   bash ~/lexai-compose/backup.sh                  # 무중지 (연습 · 사전 전송용)
#   STOP_WRITES=1 bash ~/lexai-compose/backup.sh    # 전환용 — 쓰기를 멈추고 뜹니다
#
# 네이티브의 deploy/native/backup.sh 와 **같은 형식의 산출물**을 만듭니다.
# 그래야 어느 형태에서 뜬 패키지든 어느 형태로든 복원됩니다 —
# 컴포즈에서 뜬 것을 bootstrap.sh 로 네이티브에 복원하는 식으로요.
# 컴포즈 전용 파일(images.lock · deploy-files.sha256)이 더 있고, 네이티브는
# 모르는 파일을 무시합니다.
#
# STOP_WRITES=1 은 frontend · tomcat 을 멈춘 뒤 패키지를 만들고, 멈춘 상태로
# 둡니다(DB 에 쓰는 것은 tomcat 뿐). 다시 켜면 그 뒤의 쓰기는 패키지에 없으므로
# 이관을 취소할 때만 켜세요:  cd ~/lexai-compose && docker compose start frontend tomcat
#
# ★ 이 스크립트는 저장소와 독립적으로 동작합니다. 컨테이너 형태의 타겟에는
#   소스가 없으므로 common.sh 를 쓰지 않고 필요한 것을 직접 갖습니다.
#   deploy.sh 가 이 파일을 함께 받아 배포 디렉터리에 둡니다.
#
# 환경변수 (전부 선택)
#   OUT_DIR           산출물 위치      기본 ~/lexai-backup/latest (고정 — Beetle 경로용)
#   STOP_WRITES=1     쓰기 중지 후 패키징
#   KEEP_SNAPSHOTS    남길 스냅샷 수   기본 2
#   ARCHIVE_COMPRESS  none 이면 압축 생략
#
# 진행 상황(오케스트레이터용): ~/lexai-run/backup-status.json
# ===========================================================

set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$PWD"

export TZ="${TZ:-$( { grep -E '^TZ=' .env 2>/dev/null | tail -1 | cut -d= -f2-; } || true )}"
export TZ="${TZ:-Asia/Seoul}"

_env() { { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2-; } || true; }

# 초까지 넣습니다. 분 단위면 같은 분에 두 번 뜰 때 스냅샷 이름이 겹쳐 거부됩니다.
STAMP="$(date +%Y%m%d-%H%M%S)"
# 고정 경로입니다. Beetle 데이터 마이그레이션처럼 전송 경로와 후처리 명령을
# 미리 적어 두는 도구가 매번 같은 위치를 가리킬 수 있어야 합니다.
OUT_DIR="${OUT_DIR:-$HOME/lexai-backup/latest}"
SNAPSHOT_REPO="${SNAPSHOT_REPO:-lexai}"
SNAPSHOT_NAME="${SNAPSHOT_NAME:-legal-$STAMP}"
INDEX_NAME="${INDEX_NAME:-legal_documents}"
KEEP_SNAPSHOTS="${KEEP_SNAPSHOTS:-2}"
SNAP_DIR="$PWD/deploy/snapshots"
MANIFEST_NAME="contents.tsv"
FRONTEND_PORT="${FRONTEND_PORT:-$(_env FRONTEND_PORT)}"; FRONTEND_PORT="${FRONTEND_PORT:-80}"
STOP_WRITES="${STOP_WRITES:-0}"
DEPLOY_FILES="docker-compose.yml docker-compose.registry.yml deploy/schema.sqlite.sql deploy.sh backup.sh verify.sh datacheck.sh"
PKG_FILES="opensearch-snapshots.tar.gz lexai.db source-commit.txt data-fingerprint.tsv runtime-versions.txt images.lock deploy-files.sha256"

if [ -t 1 ]; then
    C_HEAD=$'\033[1;35m'; C_OK=$'\033[0;32m'
    C_WARN=$'\033[0;33m'; C_ERR=$'\033[0;31m'; C_OFF=$'\033[0m'
else
    C_HEAD=""; C_OK=""; C_WARN=""; C_ERR=""; C_OFF=""
fi
log()  { printf '%s[backup]%s %s\n' "$C_HEAD" "$C_OFF" "$*"; }
ok()   { printf '%s  OK%s   %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%s  WARN%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()  {
    printf '%s  FATAL%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2
    status_set "last_error=$*"
    exit 1
}

# 상태 파일 (오케스트레이터용) — 네이티브 backup-status.json 과 같은 형식
RUN_DIR="${RUN_DIR:-$HOME/lexai-run}"
STATUS_FILE="$RUN_DIR/backup-status.json"
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
rm -f "$STATUS_FILE"
status_set operation=backup form=compose state=running started_at="$(now_iso)" out_dir="$OUT_DIR" stop_writes="$STOP_WRITES"
trap '_rc=$?; if [ "$_rc" -ne 0 ]; then status_set state=failed exit_code="$_rc" finished_at="$(now_iso)"; fi' EXIT

if docker info >/dev/null 2>&1; then DOCKER="docker"; else DOCKER="sudo docker"; fi
# deploy.sh 와 같은 파일 목록(lock · override 포함)을 씁니다.
compose_files() {
    local f="docker-compose.yml:docker-compose.registry.yml"
    [ -f docker-compose.lock.yml ] && f="$f:docker-compose.lock.yml"
    [ -f docker-compose.override.yml ] && f="$f:docker-compose.override.yml"
    printf '%s' "$f"
}
compose() {
    local a=() f fs
    IFS=: read -ra fs <<< "$(compose_files)"
    for f in "${fs[@]}"; do a+=(-f "$f"); done
    $DOCKER compose "${a[@]}" "$@"
}
# ★ </dev/null 은 필수입니다 — docker compose exec 는 -T 여도 stdin 을 읽습니다.
dex() { compose exec -T "$@" </dev/null; }
# tomcat 이미지로 lexai_data 볼륨에 일회성 컨테이너를 붙입니다(deploy.sh 와 같음).
# tomcat 이 멈춰 있어도(STOP_WRITES) DB 를 읽을 수 있습니다.
trun() {
    local vols=()
    while [ "$#" -gt 1 ] && [ "$1" = "-v" ]; do vols+=(-v "$2"); shift 2; done
    compose run --rm --no-deps -T "${vols[@]}" --entrypoint bash tomcat -c "$1" </dev/null
}

OS_PW="$(_env OPENSEARCH_PASSWORD)"
[ -n "$OS_PW" ] || die ".env 에서 OPENSEARCH_PASSWORD 를 읽지 못했습니다"
os() { dex opensearch curl -sk -u "admin:${OS_PW}" "$@"; }
OS_BASE="https://127.0.0.1:9200"
DB_IN="/var/lib/lexai/lexai.db"

for f in $DEPLOY_FILES DEPLOY_COMMIT; do
    [ -f "$f" ] || die "배포 디렉터리에 $f 가 없습니다 — deploy.sh 로 배포한 디렉터리에서 실행하세요"
done
[ "$(compose ps -q opensearch 2>/dev/null)" != "" ] \
    || die "OpenSearch 컨테이너가 없습니다 — docker compose up -d 후 다시 실행하세요"

mkdir -p "$OUT_DIR"
# 이전 회차 패키지 정리 — 고정 경로라 지난 파일이 섞이면 체크섬이 엉뚱한 파일을
# 가리킬 수 있습니다. 이 스크립트가 만드는 파일만 골라 지웁니다.
for f in $PKG_FILES checksums.sha256 MANIFEST.txt; do rm -f "$OUT_DIR/$f"; done


# -----------------------------------------------------------
# 쓰기 중지 / 무중지 확인
# -----------------------------------------------------------
front_code() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${FRONTEND_PORT}/" 2>/dev/null || echo 000
}
SERVING=0
if [ "$STOP_WRITES" = "1" ]; then
    # ★ 무중지 백업은 패키지를 만든 뒤 전환하기 전까지 들어온 대화를 놓칩니다.
    #   리뷰어가 그 사이 채팅하면 이관 후 "데이터가 사라졌다" 로 보입니다.
    log "0. 쓰기 중지 (STOP_WRITES=1)"
    compose stop frontend tomcat >/dev/null
    [ -z "$(compose ps -q --status running tomcat 2>/dev/null)" ] || die "tomcat 이 멈추지 않았습니다"
    ok "frontend · tomcat 정지 — 이후 DB 쓰기 없음 (취소하려면: docker compose start frontend tomcat)"
elif [ "$(front_code)" = "200" ]; then
    SERVING=1
else
    warn "프론트엔드가 응답하지 않습니다 — 무중지 여부는 확인하지 않습니다"
fi


log "1. OpenSearch 스냅샷"
status_set phase=snapshot
# 컨테이너의 path.repo 는 /mnt/snapshots 이고 호스트 ./deploy/snapshots 가
# 바인드 마운트돼 있습니다. 스냅샷은 컨테이너(uid 1000)가 쓰므로 폴더가
# 그 uid 소유여야 합니다 — 배포 계정이 1000 이 아니면(cb-user 등) 맞춥니다.
if [ -n "$(find "$SNAP_DIR" ! -uid 1000 -print -quit 2>/dev/null)" ]; then
    sudo chown -R 1000:1000 "$SNAP_DIR"
fi
resp=$(os -X PUT "$OS_BASE/_snapshot/${SNAPSHOT_REPO}" -H 'Content-Type: application/json' \
    -d '{"type":"fs","settings":{"location":"/mnt/snapshots","compress":true}}')
printf '%s' "$resp" | grep -q '"acknowledged":true' || die "스냅샷 저장소 등록 실패: $(printf '%s' "$resp" | head -c 500)"

docs=$( { os "$OS_BASE/${INDEX_NAME}/_count" | grep -o '"count":[0-9]*' | cut -d: -f2; } || true )
[ -n "${docs:-}" ] || die "색인 문서 수를 읽지 못했습니다 — 색인이 없는 것 같습니다"
log "   색인 ${docs}건 — 스냅샷 생성 중 (수 분 걸립니다)"

started=$(date +%s)
# 저장소는 증분 방식이라 두 번째부터는 훨씬 빠릅니다.
resp=$(os -X PUT "$OS_BASE/_snapshot/${SNAPSHOT_REPO}/${SNAPSHOT_NAME}?wait_for_completion=true" \
    -H 'Content-Type: application/json' \
    -d "{\"indices\":\"${INDEX_NAME}\",\"include_global_state\":false}")
snap_elapsed=$(( $(date +%s) - started ))
# ★ 오류를 버리면 안 됩니다. 이름 충돌 등으로 거부되면 이전 스냅샷으로
#   패키지가 만들어지고, 그 뒤의 데이터가 빠진 채로 이관됩니다.
if printf '%s' "$resp" | grep -q '"error"'; then
    die "스냅샷 API 오류: $(printf '%s' "$resp" | head -c 700)"
fi
state=$( { os "$OS_BASE/_cat/snapshots/${SNAPSHOT_REPO}?h=id,status" \
    | grep "^${SNAPSHOT_NAME} " | awk '{print $2}'; } || true )
[ "$state" = "SUCCESS" ] || die "스냅샷 상태: ${state:-불명}"
ok "${SNAPSHOT_NAME} (${snap_elapsed}초)"

# 오래된 스냅샷 정리 — 직전 하나는 남겨 증분이 성립하게 합니다.
all_snaps=$( { os "$OS_BASE/_cat/snapshots/${SNAPSHOT_REPO}?h=id,endEpoch" \
    | sort -k2 -n | awk '{print $1}'; } || true )
total_snaps=$( { printf "%s\n" "$all_snaps" | grep -c . ; } || true )
if [ "${total_snaps:-0}" -gt "$KEEP_SNAPSHOTS" ]; then
    drop=$(( total_snaps - KEEP_SNAPSHOTS ))
    log "   오래된 스냅샷 ${drop}개 정리 (최신 ${KEEP_SNAPSHOTS}개 유지)"
    printf "%s\n" "$all_snaps" | head -n "$drop" | while read -r old; do
        [ -n "$old" ] || continue
        os -X DELETE "$OS_BASE/_snapshot/${SNAPSHOT_REPO}/${old}" >/dev/null || true
        ok "삭제: $old"
    done
fi

# 파일 목록 — 네이티브와 같은 형식(경로 · 바이트 · sha256, 탭 구분)
# 폴더가 uid 1000 소유라 호스트 계정이 직접 못 쓸 수 있어 sudo tee 로 씁니다.
log "   파일 목록 생성"
( cd "$SNAP_DIR" && find . -type f ! -name "$MANIFEST_NAME" -print0 \
    | sort -z \
    | while IFS= read -r -d '' f; do
        printf '%s\t%s\t%s\n' "${f#./}" "$(stat -c %s "$f")" "$(sha256sum "$f" | cut -d' ' -f1)"
      done ) > "$OUT_DIR/.contents.tsv"
if [ -w "$SNAP_DIR" ]; then cp "$OUT_DIR/.contents.tsv" "$SNAP_DIR/$MANIFEST_NAME"
else sudo tee "$SNAP_DIR/$MANIFEST_NAME" < "$OUT_DIR/.contents.tsv" >/dev/null; fi
rm -f "$OUT_DIR/.contents.tsv"
ok "$(wc -l < "$SNAP_DIR/$MANIFEST_NAME")개 파일"

# 여유 공간 — 압축이 몇 분 돌다가 No space left 로 죽으면 그 시간이 날아갑니다.
raw_kb=$(du -sk "$SNAP_DIR" | cut -f1)
free_kb=$(df -Pk "$OUT_DIR" | awk 'NR==2 {print $4}')
if [ "$free_kb" -lt "$raw_kb" ]; then
    die "공간이 부족합니다 — 필요(최대) $(numfmt --to=iec $((raw_kb * 1024)) 2>/dev/null || echo "${raw_kb}K") / 여유 $(numfmt --to=iec $((free_kb * 1024)) 2>/dev/null || echo "${free_kb}K")"
fi

log "   패키징"
pkg_started=$(date +%s)
archive="$OUT_DIR/opensearch-snapshots.tar.gz"
if [ "${ARCHIVE_COMPRESS:-auto}" = "none" ]; then
    tar -cf "$archive" -C "$SNAP_DIR" .
    ok "압축 없음"
elif command -v pigz >/dev/null 2>&1; then
    tar -cf - -C "$SNAP_DIR" . | pigz -p "$(nproc)" > "$archive"
    ok "pigz 병렬 압축 ($(nproc) 코어)"
else
    tar -czf "$archive" -C "$SNAP_DIR" .
    warn "pigz 가 없어 단일 코어로 압축했습니다 — sudo apt-get install -y pigz"
fi
raw_bytes=$(du -sb "$SNAP_DIR" | cut -f1)
pkg_bytes=$(stat -c %s "$archive")
ok "$(du -h "$archive" | cut -f1) ($(( $(date +%s) - pkg_started ))초, 원본 대비 $(( pkg_bytes * 100 / (raw_bytes > 0 ? raw_bytes : 1) ))%)"


log "2. SQLite"
status_set phase=sqlite
# -----------------------------------------------------------
# ★ 볼륨의 .db 를 그대로 복사하면 안 됩니다. 쓰기 중간 상태가 섞여 깨질 수
#   있습니다. VACUUM INTO 는 일관된 시점의 단일 파일을 만들어 줍니다.
#   일회성 컨테이너가 볼륨을 직접 열어 결과를 OUT_DIR 에 바로 씁니다 —
#   tomcat 이 멈춰 있어도 됩니다. 데이터 지문도 같은 컨테이너에서 계산합니다
#   (호스트에 sqlite3 가 없어도 되고, 네이티브와 같은 알고리즘: datacheck.sh).
# -----------------------------------------------------------
out="$(trun -v "$OUT_DIR:/out" -v "$DEPLOY_DIR/datacheck.sh:/opt/datacheck.sh:ro" "set -e
    sqlite3 $DB_IN \"VACUUM INTO '/out/lexai.db';\"
    bash /opt/datacheck.sh write /out/lexai.db /out/data-fingerprint.tsv
    echo users=\$(sqlite3 /out/lexai.db 'SELECT COUNT(*) FROM users;')
    echo msgs=\$(sqlite3 /out/lexai.db 'SELECT COUNT(*) FROM chat_message;')
    echo uv=\$(sqlite3 /out/lexai.db 'PRAGMA user_version;')
    chown $(id -u):$(id -g) /out/lexai.db /out/data-fingerprint.tsv")" \
    || die "VACUUM INTO · 데이터 지문 실패 — docker compose logs tomcat 과 볼륨을 확인하세요"
[ -s "$OUT_DIR/lexai.db" ] || die "DB 사본이 비어 있습니다"
[ -s "$OUT_DIR/data-fingerprint.tsv" ] || die "데이터 지문이 비어 있습니다"
users="$(printf '%s\n' "$out" | sed -n 's/^users=//p')"
msgs="$(printf '%s\n' "$out" | sed -n 's/^msgs=//p')"
uv="$(printf '%s\n' "$out" | sed -n 's/^uv=//p')"
ok "$(du -h "$OUT_DIR/lexai.db" | cut -f1) — 사용자 ${users} · 메시지 ${msgs}"
ok "데이터 지문 ($(wc -l < "$OUT_DIR/data-fingerprint.tsv")개 테이블)"


log "3. 배포 기록"
status_set phase=records
# 커밋 — 대상의 deploy.sh(NO_UPDATE=1)가 옮겨 온 배포 디렉터리의 DEPLOY_COMMIT 과 대조합니다.
commit="$(tr -d '[:space:]' < DEPLOY_COMMIT)"
printf '%s\n' "$commit" > "$OUT_DIR/source-commit.txt"
[ "$commit" = "unknown" ] && warn "DEPLOY_COMMIT 이 unknown 입니다 — 커밋 대조는 의미가 없고 배포 파일 해시만 대조됩니다"

# 배포 파일 해시 — 커밋이 같아도 옮겨 온 디렉터리의 파일이 바뀌면 커밋은 모릅니다.
sha256sum $DEPLOY_FILES DEPLOY_COMMIT > "$OUT_DIR/deploy-files.sha256"

# 이미지 digest — 태그가 다시 푸시돼도 원본과 같은 것을 받도록 실제로 돌던 것을 적습니다.
DOCKER="$DOCKER" CF="$(compose_files)" python3 - <<'PY' > "$OUT_DIR/.images" || die "compose 정의를 읽지 못했습니다"
import json, subprocess, sys, os
cmd = os.environ.get("DOCKER", "docker").split() + ["compose"]
for f in os.environ["CF"].split(":"):
    cmd += ["-f", f]
d = json.loads(subprocess.check_output(cmd + ["config", "--format", "json"], stderr=subprocess.DEVNULL))
for name, s in sorted(d["services"].items()):
    print(name, s.get("image", ""))
PY
: > "$OUT_DIR/images.lock"
lock_missing=""
while read -r svc img; do
    [ -n "$svc" ] && [ -n "$img" ] || continue
    repo="${img%@*}"
    case "${repo##*/}" in *:*) repo="${repo%:*}" ;; esac
    cid="$( { compose ps -a -q "$svc" 2>/dev/null | head -1; } || true )"
    iid=""
    [ -n "$cid" ] && iid="$($DOCKER inspect -f '{{.Image}}' "$cid" 2>/dev/null || true)"
    [ -n "$iid" ] || iid="$($DOCKER image inspect -f '{{.Id}}' "$img" 2>/dev/null || true)"
    dig=""
    if [ -n "$iid" ]; then
        dig="$( { $DOCKER image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$iid" 2>/dev/null \
            | awk -v r="$repo" '{ s=$0; sub(/^docker\.io\//,"",s); rr=r; sub(/^docker\.io\//,"",rr); if (index(s, rr"@")==1) {print s; exit} }'; } || true )"
    fi
    if [ -n "$dig" ]; then
        printf '%s %s\n' "$svc" "$dig" >> "$OUT_DIR/images.lock"
    else
        lock_missing="$lock_missing $svc"
    fi
done < "$OUT_DIR/.images"
rm -f "$OUT_DIR/.images"
if [ -n "$lock_missing" ]; then
    warn "레지스트리 digest 가 없는 이미지:${lock_missing} — 로컬 빌드 이미지는 대상이 같은 것을 받을 수 없습니다"
    warn "  이 패키지로는 이관 모드(NO_UPDATE=1)가 멈춥니다. 레지스트리에 푸시한 이미지로 배포하세요"
fi
ok "커밋 ${commit:0:7} · 배포 파일 $(wc -l < "$OUT_DIR/deploy-files.sha256")개 · 이미지 digest $(grep -c . "$OUT_DIR/images.lock" || true)개"

# 런타임 기록 — 네이티브와 같은 형식(ollama <버전> / model <이름> <ID>)
ollama_v="$( { dex ollama ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1; } || true )"
{
    echo "ollama ${ollama_v}"
    { dex ollama ollama list 2>/dev/null | awk 'NR>1 {print "model "$1" "$2}'; } || true
} > "$OUT_DIR/runtime-versions.txt"
ok "런타임 기록 (Ollama ${ollama_v:-?}, 모델 $(grep -c '^model ' "$OUT_DIR/runtime-versions.txt" || true)개)"


log "4. 체크섬"
( cd "$OUT_DIR" && sha256sum $PKG_FILES > checksums.sha256 )
ok "checksums.sha256 ($(wc -l < "$OUT_DIR/checksums.sha256")개 파일)"

if [ "$SERVING" = "1" ]; then
    code="$(front_code)"
    if [ "$code" = "200" ]; then
        ok "무중지 확인 — 패키징 내내 프론트엔드 HTTP 200"
    else
        warn "패키징 중 프론트엔드가 HTTP ${code} 가 됐습니다 — 무중지가 아닙니다"
    fi
fi

snap_files=$(wc -l < "$SNAP_DIR/$MANIFEST_NAME")
snap_bytes=$(awk -F'\t' '{s+=$2} END {print s+0}' "$SNAP_DIR/$MANIFEST_NAME")

log "5. 매니페스트"
cat > "$OUT_DIR/MANIFEST.txt" <<EOF
LexAI 이관 패키지 (Docker Compose 형태에서 생성)
생성 시각   : $(date '+%Y-%m-%d %H:%M:%S %Z')
생성 호스트 : $(hostname)
배포 커밋   : ${commit}
쓰기 중지   : $( [ "$STOP_WRITES" = "1" ] && echo '예 — 패키지 이후 원본 변경 없음' || echo '아니요 — 무중지 백업, 이후 원본 변경분은 없음')
스키마 버전 : v${uv:-0}

내용
  opensearch-snapshots.tar.gz  색인 ${docs}건 (스냅샷 ${SNAPSHOT_NAME}, 생성 ${snap_elapsed}초)
                               파일 ${snap_files}개 / ${snap_bytes} bytes (압축 전)
  lexai.db                     사용자 ${users} · 메시지 ${msgs}
  source-commit.txt            원본 배포의 커밋 (DEPLOY_COMMIT)
  deploy-files.sha256          원본 배포 디렉터리의 정의 · 스크립트 해시
  images.lock                  원본에서 돌던 이미지 digest (대상이 같은 digest 로 받음)
  data-fingerprint.tsv         테이블별 행 수 · 내용 해시 (대상에서 자동 비교)
  runtime-versions.txt         Ollama 버전 · 모델 ID (대상에서 비교, 다르면 경고)
  checksums.sha256             위 파일 전부의 SHA-256

포함하지 않은 것
  Ollama 모델 · 임베딩 모델    대상에서 자동으로 받습니다
  .env                         비밀값이라 패키지에는 넣지 않습니다. 배포 디렉터리째 옮기면
                               함께 옮겨지고, 없으면 대상이 새로 발급합니다(기존 로그인 토큰만 무효)

배포 디렉터리째 옮기는 이관 (Beetle 데이터 마이그레이션 등)
  ★ 데이터(DB · 색인)는 Docker 볼륨(/var/lib/docker) 안에 있어 홈 디렉터리 전송으로는
    옮겨지지 않습니다. 반드시 이 패키지로 옮깁니다.
  옮길 것  ${DEPLOY_DIR}   (.env 포함)
           ${OUT_DIR}
  제외     deploy/snapshots   .restore   (수 GB 이고 OpenSearch(uid 1000) 소유라 전송이 실패합니다.
                                         대상에서 패키지로 다시 만듭니다)
  실행     NO_UPDATE=1 SNAPSHOT_URI=${OUT_DIR} bash ${DEPLOY_DIR}/deploy.sh
           GitHub 에서 다시 받지 않고, 커밋 · 배포 파일 · 이미지 digest · 체크섬 ·
           데이터 지문이 하나라도 다르면 멈춥니다. 이미 LexAI 가 돌던 VM 이면
           FORCE_CLEAN=1 을 함께 줍니다. 진행 상황: ~/lexai-run/status.json

다른 형태로 (형태 간 이관 — 일반 배포 + 패키지)
  네이티브 : curl -fsSL <bootstrap.sh> | SNAPSHOT_URI=<이 디렉터리> bash
EOF
ok "MANIFEST.txt"

status_set state=success phase=done exit_code=0 finished_at="$(now_iso)" docs="$docs" users="$users" msgs="$msgs"

echo
log "패키지 완료: $OUT_DIR"
du -h "$OUT_DIR"/* | sed 's/^/  /'
if [ "$STOP_WRITES" = "1" ]; then
    echo
    warn "frontend · tomcat 은 멈춘 상태입니다. 이관을 취소할 때만 다시 켜세요:"
    warn "  cd $DEPLOY_DIR && docker compose start frontend tomcat"
fi
