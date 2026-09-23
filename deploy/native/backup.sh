#!/usr/bin/env bash
# ===========================================================
# 이관 패키지 생성 — OpenSearch 색인 + SQLite DB
#
#   bash deploy/native/backup.sh
#
# 서비스를 멈추지 않고 실행할 수 있습니다. 다만 실행 시점 이후에 들어온
# 대화는 패키지에 없습니다. 실제 이관에서는 쓰기를 멈추고 한 번 더 뜨세요.
#
# 산출물을 대상 환경으로 옮기면 restore.sh 가 나머지를 처리합니다.
# Ollama 모델은 포함하지 않습니다 — 5GB 를 옮기는 것보다 대상 환경에서
# 다시 받는 쪽이 빠릅니다(AWS 회선 기준 약 65초).
# ===========================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

STAMP="$(date +%Y%m%d-%H%M)"
OUT_DIR="${OUT_DIR:-$HOME/lexai-backup/$STAMP}"
SNAPSHOT_REPO="${SNAPSHOT_REPO:-lexai}"
SNAPSHOT_NAME="${SNAPSHOT_NAME:-legal-$STAMP}"
INDEX_NAME="${INDEX_NAME:-legal_documents}"

mkdir -p "$OUT_DIR"


log "1. OpenSearch 스냅샷"
# -----------------------------------------------------------
load_opensearch_creds
port_in_use "$OPENSEARCH_PORT" || die "OpenSearch 가 실행 중이 아닙니다"

os_curl -X PUT "$OS_BASE/_snapshot/${SNAPSHOT_REPO}" \
    -H 'Content-Type: application/json' \
    -d "{\"type\":\"fs\",\"settings\":{\"location\":\"${SNAPSHOT_DIR}\",\"compress\":true}}" >/dev/null

docs=$(os_curl "$OS_BASE/${INDEX_NAME}/_count" | grep -o '"count":[0-9]*' | cut -d: -f2)
log "   색인 ${docs}건 — 스냅샷 생성 중 (수 분 걸립니다)"

started=$(date +%s)
# 저장소는 증분 방식이라 두 번째부터는 훨씬 빠릅니다.
os_curl -X PUT "$OS_BASE/_snapshot/${SNAPSHOT_REPO}/${SNAPSHOT_NAME}?wait_for_completion=true" \
    -H 'Content-Type: application/json' \
    -d "{\"indices\":\"${INDEX_NAME}\",\"include_global_state\":false}" >/dev/null
snap_elapsed=$(( $(date +%s) - started ))

state=$(os_curl "$OS_BASE/_cat/snapshots/${SNAPSHOT_REPO}?h=id,status" | grep "^${SNAPSHOT_NAME} " | awk '{print $2}')
[ "$state" = "SUCCESS" ] || die "스냅샷 상태: ${state:-불명}"
ok "${SNAPSHOT_NAME} (${snap_elapsed}초)"

# -----------------------------------------------------------
# 오래된 스냅샷 정리
#
# 저장소는 증분이라 돌릴 때마다 스냅샷이 하나씩 쌓입니다. 용량은 거의
# 안 늘지만 메타데이터가 계속 붙고, 오래된 스냅샷이 세그먼트 파일을
# 붙잡고 있어 실제로 지워지지도 않습니다. 최신 것 몇 개만 남깁니다.
#
# 이전 스냅샷을 남기는 이유는 증분 때문입니다 — 직전 것이 있어야
# 이관 당일의 두 번째 스냅샷이 변경분만 담아 수십 초에 끝납니다.
# -----------------------------------------------------------
KEEP_SNAPSHOTS="${KEEP_SNAPSHOTS:-2}"
all_snaps=$( { os_curl "$OS_BASE/_cat/snapshots/${SNAPSHOT_REPO}?h=id,endEpoch" \
    | sort -k2 -n | awk '{print $1}'; } || true )
total_snaps=$( { printf "%s\n" "$all_snaps" | grep -c . ; } || true )

if [ "${total_snaps:-0}" -gt "$KEEP_SNAPSHOTS" ]; then
    drop=$(( total_snaps - KEEP_SNAPSHOTS ))
    log "   오래된 스냅샷 ${drop}개 정리 (최신 ${KEEP_SNAPSHOTS}개 유지)"
    printf "%s\n" "$all_snaps" | head -n "$drop" | while read -r old; do
        [ -n "$old" ] || continue
        os_curl -X DELETE "$OS_BASE/_snapshot/${SNAPSHOT_REPO}/${old}" >/dev/null || true
        ok "삭제: $old"
    done
fi

# 파일 목록(개수·용량·해시)을 스냅샷 디렉터리 안에 만들어 tar 에 함께 담습니다.
# 대상 환경에서 압축을 풀면 목록도 같이 나와 그 자리에서 대조할 수 있습니다.
log "   파일 목록 생성"
write_manifest "$SNAPSHOT_DIR"
ok "$(wc -l < "$SNAPSHOT_DIR/$MANIFEST_NAME")개 파일"

# -----------------------------------------------------------
# 패키징
#
# gzip 은 단일 코어만 씁니다. 스냅샷이 수 GB 라 이 단계가 몇 분씩 걸리는데,
# 이관 당일에는 그 시간이 그대로 서비스 중단 시간에 더해집니다.
# pigz 가 있으면 코어 수만큼 병렬로 압축합니다(출력은 같은 gzip 형식이라
# 받는 쪽은 바뀔 게 없습니다).
#
# 참고로 OpenSearch 스냅샷은 이미 압축돼 있어 압축률이 낮습니다.
# 시간이 더 중요하면 ARCHIVE_COMPRESS=none 으로 압축을 끄세요.
# -----------------------------------------------------------
# 여유 공간을 미리 확인합니다. 압축이 몇 분 돌다가 No space left 로 죽으면
# 그 시간이 통째로 날아가고 조각 파일까지 남습니다.
raw_kb=$(du -sk "$SNAPSHOT_DIR" | cut -f1)
free_kb=$(df -Pk "$OUT_DIR" | awk 'NR==2 {print $4}')
if [ "$free_kb" -lt "$raw_kb" ]; then
    warn "여유 공간이 부족할 수 있습니다"
    warn "  필요(최대) : $(numfmt --to=iec $((raw_kb * 1024)) 2>/dev/null || echo "${raw_kb}K")"
    warn "  여유       : $(numfmt --to=iec $((free_kb * 1024)) 2>/dev/null || echo "${free_kb}K")"
    die "공간을 확보한 뒤 다시 실행하세요 (이전 패키지 삭제 · docker builder prune -af 등)"
fi

log "   패키징"
pkg_started=$(date +%s)
archive="$OUT_DIR/opensearch-snapshots.tar.gz"

if [ "${ARCHIVE_COMPRESS:-auto}" = "none" ]; then
    # 이름은 유지합니다 — 받는 쪽은 tar -xf 로 자동 판별합니다.
    tar -cf "$archive" -C "$SNAPSHOT_DIR" .
    ok "압축 없음"
elif command -v pigz >/dev/null 2>&1; then
    tar -cf - -C "$SNAPSHOT_DIR" . | pigz -p "$(nproc)" > "$archive"
    ok "pigz 병렬 압축 ($(nproc) 코어)"
else
    tar -czf "$archive" -C "$SNAPSHOT_DIR" .
    warn "pigz 가 없어 단일 코어로 압축했습니다 — install.sh 를 다시 돌리면 설치됩니다"
fi

raw_bytes=$(du -sb "$SNAPSHOT_DIR" | cut -f1)
pkg_bytes=$(stat -c %s "$archive")
ok "$(du -h "$archive" | cut -f1) ($(( $(date +%s) - pkg_started ))초, 원본 대비 $(( pkg_bytes * 100 / raw_bytes ))%)"


log "2. SQLite"
# -----------------------------------------------------------
# ★ cp 로 복사하면 안 됩니다. 쓰기 중간 상태가 섞여 깨질 수 있습니다.
#   VACUUM INTO 는 일관된 시점의 단일 파일을 만들어 줍니다
#   (-wal / -shm 을 따로 챙길 필요도 없어집니다).
[ -f "$DB_PATH" ] || die "DB 파일이 없습니다: $DB_PATH"
sqlite3 "$DB_PATH" "VACUUM INTO '$OUT_DIR/lexai.db';"

users=$(sqlite3 "$OUT_DIR/lexai.db" "SELECT COUNT(*) FROM users;")
msgs=$(sqlite3 "$OUT_DIR/lexai.db" "SELECT COUNT(*) FROM chat_message;")
ok "$(du -h "$OUT_DIR/lexai.db" | cut -f1) — 사용자 ${users} · 메시지 ${msgs}"


log "3. 체크섬"
# 전송 중 손상을 대상 환경에서 곧바로 잡기 위한 아카이브 단위 해시입니다.
# (압축을 푼 뒤의 내용 대조는 tar 안의 목록 파일이 담당합니다)
( cd "$OUT_DIR" && sha256sum opensearch-snapshots.tar.gz lexai.db > checksums.sha256 )
ok "checksums.sha256"

snap_files=$(wc -l < "$SNAPSHOT_DIR/$MANIFEST_NAME")
snap_bytes=$(awk -F'	' '{s+=$2} END {print s+0}' "$SNAPSHOT_DIR/$MANIFEST_NAME")

log "4. 매니페스트"
# -----------------------------------------------------------
cat > "$OUT_DIR/MANIFEST.txt" <<EOF
LexAI 이관 패키지
생성 시각   : $(date '+%Y-%m-%d %H:%M:%S %Z')
생성 호스트 : $(hostname)
저장소 커밋 : $(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo '불명') ($(git -C "$REPO_DIR" branch --show-current 2>/dev/null || echo '-'))

내용
  opensearch-snapshots.tar.gz  색인 ${docs}건 (스냅샷 ${SNAPSHOT_NAME}, 생성 ${snap_elapsed}초)
                               파일 ${snap_files}개 / ${snap_bytes} bytes (압축 전)
  lexai.db                     사용자 ${users} · 메시지 ${msgs}
  checksums.sha256             위 두 파일의 SHA-256

정합성 확인
  전송 직후   sha256sum -c checksums.sha256
  복원 직후   restore.sh 가 압축 해제된 파일의 개수·총 용량·해시를 대조합니다
              (목록 파일 contents.tsv 가 아카이브 안에 함께 들어 있습니다)

포함하지 않은 것
  Ollama 모델   대상 환경에서 restore.sh 가 자동으로 받습니다
  임베딩 모델   AI 서버가 기동 시 자동으로 받습니다
  .env          비밀값이라 제외. 대상 환경에서 직접 작성하세요

대상 환경에서
  1) git clone <repo> && cd legal-rag-chatbot
  2) cp .env.example .env  후 시크릿 작성 (OPENSEARCH_PASSWORD, JWT_SECRET)
  3) bash deploy/native/install.sh
  4) sha256sum -c checksums.sha256
     mkdir -p ~/lexai-snapshots && tar -xf opensearch-snapshots.tar.gz -C ~/lexai-snapshots   # -xf: 형식 자동 판별
     mkdir -p ~/lexai-data && cp lexai.db ~/lexai-data/lexai.db
  5) bash deploy/native/restore.sh
  6) bash deploy/native/start.sh
  7) bash deploy/native/verify.sh

  ※ OPENSEARCH_PASSWORD 는 이 패키지를 만든 환경과 같은 값을 쓰세요.
     스냅샷 복원 자체는 비밀번호와 무관하지만, AI 서버 설정을 그대로
     재사용하려면 맞춰두는 편이 편합니다.
EOF
ok "MANIFEST.txt"


echo
log "패키지 완료: $OUT_DIR"
du -h "$OUT_DIR"/* | sed 's/^/  /'
echo
echo "  전송 예:"
echo "    aws s3 cp --recursive $OUT_DIR s3://<버킷>/lexai/$STAMP/"
