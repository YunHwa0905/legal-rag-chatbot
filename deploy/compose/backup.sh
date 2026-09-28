#!/usr/bin/env bash
# ===========================================================
# 이관 패키지 생성 — Docker Compose 형태
#
#   bash ~/lexai-compose/backup.sh
#
# 네이티브의 deploy/native/backup.sh 와 **같은 형식의 산출물**을 만듭니다.
# 그래야 어느 형태에서 뜬 패키지든 어느 형태로든 복원됩니다 —
# 컴포즈에서 뜬 것을 bootstrap.sh 로 네이티브에 복원하는 식으로요.
#
# 서비스를 멈추지 않고 실행할 수 있습니다. 다만 실행 시점 이후에 들어온
# 대화는 패키지에 없습니다. 실제 이관에서는 쓰기를 멈추고 한 번 더 뜨세요.
#
# ★ 이 스크립트는 저장소와 독립적으로 동작합니다. 컨테이너 형태의 타겟에는
#   소스가 없으므로 common.sh 를 쓰지 않고 필요한 것을 직접 갖습니다.
#   deploy.sh 가 이 파일을 함께 받아 배포 디렉터리에 둡니다.
#
# 환경변수 (전부 선택)
#   OUT_DIR           산출물 위치      기본 ~/lexai-backup/<시각>
#   KEEP_SNAPSHOTS    남길 스냅샷 수   기본 2
#   ARCHIVE_COMPRESS  none 이면 압축 생략
# ===========================================================

set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export TZ="${TZ:-$( { grep -E '^TZ=' .env 2>/dev/null | tail -1 | cut -d= -f2-; } || true )}"
export TZ="${TZ:-Asia/Seoul}"

STAMP="$(date +%Y%m%d-%H%M)"
OUT_DIR="${OUT_DIR:-$HOME/lexai-backup/$STAMP}"
SNAPSHOT_REPO="${SNAPSHOT_REPO:-lexai}"
SNAPSHOT_NAME="${SNAPSHOT_NAME:-legal-$STAMP}"
INDEX_NAME="${INDEX_NAME:-legal_documents}"
KEEP_SNAPSHOTS="${KEEP_SNAPSHOTS:-2}"
SNAP_DIR="$PWD/deploy/snapshots"
MANIFEST_NAME="contents.tsv"

if [ -t 1 ]; then
    C_HEAD=$'\033[1;35m'; C_OK=$'\033[0;32m'
    C_WARN=$'\033[0;33m'; C_ERR=$'\033[0;31m'; C_OFF=$'\033[0m'
else
    C_HEAD=""; C_OK=""; C_WARN=""; C_ERR=""; C_OFF=""
fi
log()  { printf '%s[backup]%s %s\n' "$C_HEAD" "$C_OFF" "$*"; }
ok()   { printf '%s  OK%s   %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%s  WARN%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '%s  FATAL%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

if docker info >/dev/null 2>&1; then DOCKER="docker"; else DOCKER="sudo docker"; fi
compose() { $DOCKER compose -f docker-compose.yml -f docker-compose.registry.yml "$@"; }
# ★ </dev/null 은 필수입니다 — docker compose exec 는 -T 여도 stdin 을 읽습니다.
dex() { compose exec -T "$@" </dev/null; }

OS_PW="$( { grep -E '^OPENSEARCH_PASSWORD=' .env | tail -1 | cut -d= -f2-; } || true )"
[ -n "$OS_PW" ] || die ".env 에서 OPENSEARCH_PASSWORD 를 읽지 못했습니다"
os() { dex opensearch curl -sk -u "admin:${OS_PW}" "$@"; }
OS_BASE="https://127.0.0.1:9200"
DB_IN="/var/lib/lexai/lexai.db"

compose ps --format '{{.Service}}' 2>/dev/null | grep -q opensearch \
    || die "컴포즈 스택이 실행 중이 아닙니다 — docker compose up -d 후 다시 실행하세요"

mkdir -p "$OUT_DIR"


# -----------------------------------------------------------
# 무중지 확인
#
# 이 스크립트의 전제가 "서비스를 멈추지 않고 뜰 수 있다" 입니다.
# 스냅샷이 I/O 를 크게 쓰는 구간이라 프론트가 밀려 죽는지를 봅니다.
# -----------------------------------------------------------
front_code() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1/" 2>/dev/null || echo 000
}
SERVING=0
if [ "$(front_code)" = "200" ]; then
    SERVING=1
else
    warn "프론트엔드가 응답하지 않습니다 — 무중지 여부는 확인하지 않습니다"
fi


log "1. OpenSearch 스냅샷"
# -----------------------------------------------------------
# 컨테이너의 path.repo 는 /mnt/snapshots 이고, 호스트의
# ./deploy/snapshots 가 거기에 바인드 마운트돼 있습니다. 그래서
# 스냅샷은 컨테이너가 만들고 압축은 호스트가 바로 할 수 있습니다.
# -----------------------------------------------------------
os -X PUT "$OS_BASE/_snapshot/${SNAPSHOT_REPO}" \
    -H 'Content-Type: application/json' \
    -d '{"type":"fs","settings":{"location":"/mnt/snapshots","compress":true}}' >/dev/null

docs=$( { os "$OS_BASE/${INDEX_NAME}/_count" | grep -o '"count":[0-9]*' | cut -d: -f2; } || true )
[ -n "${docs:-}" ] || die "색인 문서 수를 읽지 못했습니다 — 색인이 없는 것 같습니다"
log "   색인 ${docs}건 — 스냅샷 생성 중 (수 분 걸립니다)"

started=$(date +%s)
# 저장소는 증분 방식이라 두 번째부터는 훨씬 빠릅니다.
resp=$(os -X PUT "$OS_BASE/_snapshot/${SNAPSHOT_REPO}/${SNAPSHOT_NAME}?wait_for_completion=true" \
    -H 'Content-Type: application/json' \
    -d "{\"indices\":\"${INDEX_NAME}\",\"include_global_state\":false}")
snap_elapsed=$(( $(date +%s) - started ))

if printf '%s' "$resp" | grep -q '"error"'; then
    warn "스냅샷 API 오류:"
    printf '%s\n' "$resp" | head -c 700 >&2; echo >&2
fi

state=$( { os "$OS_BASE/_cat/snapshots/${SNAPSHOT_REPO}?h=id,status" \
    | grep "^${SNAPSHOT_NAME} " | awk '{print $2}'; } || true )
[ "$state" = "SUCCESS" ] || die "스냅샷 상태: ${state:-불명}"
ok "${SNAPSHOT_NAME} (${snap_elapsed}초)"

# -----------------------------------------------------------
# 오래된 스냅샷 정리
#
# 저장소는 증분이라 돌릴 때마다 스냅샷이 쌓입니다. 용량은 거의 안 늘지만
# 오래된 스냅샷이 세그먼트 파일을 붙잡고 있어 실제로 지워지지도 않습니다.
#
# 직전 하나는 남깁니다 — 증분이 성립해야 이관 당일의 두 번째 스냅샷이
# 변경분만 담아 수십 초에 끝납니다.
# -----------------------------------------------------------
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

# -----------------------------------------------------------
# 파일 목록 — 네이티브와 같은 형식이어야 합니다
#
# 탭 구분으로 경로 · 바이트 · sha256 을 적습니다. 복원 쪽(restore.sh ·
# deploy.sh)이 이 형식으로 개수 · 총 용량 · 해시를 대조하므로, 한 글자라도
# 다르면 그쪽에서 대조가 깨집니다.
#
# 스냅샷 파일은 컨테이너가 썼지만 바인드 마운트라 호스트에서 그대로 읽힙니다.
# -----------------------------------------------------------
log "   파일 목록 생성"
[ -d "$SNAP_DIR" ] || die "스냅샷 디렉터리가 없습니다: $SNAP_DIR"
( cd "$SNAP_DIR" && find . -type f ! -name "$MANIFEST_NAME" -print0 \
    | sort -z \
    | while IFS= read -r -d '' f; do
        printf '%s\t%s\t%s\n' "${f#./}" "$(stat -c %s "$f")" "$(sha256sum "$f" | cut -d' ' -f1)"
      done ) > "$SNAP_DIR/$MANIFEST_NAME"
ok "$(wc -l < "$SNAP_DIR/$MANIFEST_NAME")개 파일"


# -----------------------------------------------------------
# 패키징
#
# 여유 공간을 미리 확인합니다. 압축이 몇 분 돌다가 No space left 로 죽으면
# 그 시간이 통째로 날아가고 조각 파일까지 남습니다.
# -----------------------------------------------------------
raw_kb=$(du -sk "$SNAP_DIR" | cut -f1)
free_kb=$(df -Pk "$OUT_DIR" | awk 'NR==2 {print $4}')
if [ "$free_kb" -lt "$raw_kb" ]; then
    warn "여유 공간이 부족할 수 있습니다"
    warn "  필요(최대) : $(numfmt --to=iec $((raw_kb * 1024)) 2>/dev/null || echo "${raw_kb}K")"
    warn "  여유       : $(numfmt --to=iec $((free_kb * 1024)) 2>/dev/null || echo "${free_kb}K")"
    rmdir "$OUT_DIR" 2>/dev/null || true
    if [ -d "$(dirname "$OUT_DIR")" ]; then
        warn "  이전 패키지:"
        du -sh "$(dirname "$OUT_DIR")"/* 2>/dev/null | sed 's/^/    /' >&2 || true
    fi
    die "공간을 확보한 뒤 다시 실행하세요"
fi

log "   패키징"
pkg_started=$(date +%s)
archive="$OUT_DIR/opensearch-snapshots.tar.gz"

if [ "${ARCHIVE_COMPRESS:-auto}" = "none" ]; then
    # 이름은 유지합니다 — 받는 쪽은 tar -xf 로 자동 판별합니다.
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
ok "$(du -h "$archive" | cut -f1) ($(( $(date +%s) - pkg_started ))초, 원본 대비 $(( pkg_bytes * 100 / raw_bytes ))%)"


log "2. SQLite"
# -----------------------------------------------------------
# ★ 볼륨의 .db 를 그대로 복사하면 안 됩니다. 쓰기 중간 상태가 섞여 깨질 수
#   있습니다. VACUUM INTO 는 일관된 시점의 단일 파일을 만들어 줍니다
#   (-wal / -shm 을 따로 챙길 필요도 없어집니다).
#
#   컨테이너 안에서 만든 뒤 호스트로 꺼냅니다.
# -----------------------------------------------------------
dex tomcat sh -c "rm -f /tmp/lexai-backup.db && sqlite3 '$DB_IN' \"VACUUM INTO '/tmp/lexai-backup.db';\"" \
    || die "VACUUM INTO 실패 — tomcat 컨테이너와 DB 경로를 확인하세요"
compose cp tomcat:/tmp/lexai-backup.db "$OUT_DIR/lexai.db" >/dev/null
dex tomcat rm -f /tmp/lexai-backup.db || true

[ -s "$OUT_DIR/lexai.db" ] || die "DB 사본이 비어 있습니다"
users=$(sqlite3 "$OUT_DIR/lexai.db" "SELECT COUNT(*) FROM users;" 2>/dev/null \
    || dex tomcat sqlite3 "$DB_IN" "SELECT COUNT(*) FROM users;" | tr -d '\r')
msgs=$(sqlite3 "$OUT_DIR/lexai.db" "SELECT COUNT(*) FROM chat_message;" 2>/dev/null \
    || dex tomcat sqlite3 "$DB_IN" "SELECT COUNT(*) FROM chat_message;" | tr -d '\r')
ok "$(du -h "$OUT_DIR/lexai.db" | cut -f1) — 사용자 ${users} · 메시지 ${msgs}"


log "3. 체크섬"
# 전송 중 손상을 대상 환경에서 곧바로 잡기 위한 아카이브 단위 해시입니다.
# (압축을 푼 뒤의 내용 대조는 tar 안의 목록 파일이 담당합니다)
( cd "$OUT_DIR" && sha256sum opensearch-snapshots.tar.gz lexai.db > checksums.sha256 )
ok "checksums.sha256"

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

log "4. 매니페스트"
cat > "$OUT_DIR/MANIFEST.txt" <<EOF
LexAI 이관 패키지 (Docker Compose 형태에서 생성)
생성 시각   : $(date '+%Y-%m-%d %H:%M:%S %Z')
생성 호스트 : $(hostname)
이미지      : ${REGISTRY_PREFIX:-yunhwa0905}/lexai-*:${IMAGE_TAG:-v2}

내용
  opensearch-snapshots.tar.gz  색인 ${docs}건 (스냅샷 ${SNAPSHOT_NAME}, 생성 ${snap_elapsed}초)
                               파일 ${snap_files}개 / ${snap_bytes} bytes (압축 전)
  lexai.db                     사용자 ${users} · 메시지 ${msgs}
  checksums.sha256             위 두 파일의 SHA-256

정합성 확인
  전송 직후   sha256sum -c checksums.sha256
  복원 직후   진입물이 압축 해제된 파일의 개수·총 용량·해시를 대조합니다
              (목록 파일 ${MANIFEST_NAME} 가 아카이브 안에 함께 들어 있습니다)

포함하지 않은 것
  Ollama 모델   대상 환경에서 자동으로 받습니다
  임베딩 모델   AI 서버가 기동 시 자동으로 받습니다
  .env          비밀값이라 제외. 대상 환경에서 진입물이 새로 발급합니다

대상 환경에서 — 어느 형태로든 복원됩니다
  컨테이너 : curl -fsSL <deploy.sh>    | SNAPSHOT_URI=<이 디렉터리> bash
  네이티브 : curl -fsSL <bootstrap.sh> | SNAPSHOT_URI=<이 디렉터리> bash
EOF
ok "MANIFEST.txt"


echo
log "패키지 완료: $OUT_DIR"
du -h "$OUT_DIR"/* | sed 's/^/  /'
echo
echo "  네이티브로 복원하려면(형태 간 이관):"
echo "    curl -fsSL <bootstrap.sh 주소> | SNAPSHOT_URI=$OUT_DIR bash"
