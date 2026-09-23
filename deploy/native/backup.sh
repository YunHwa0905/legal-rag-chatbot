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

# 파일 목록(개수·용량·해시)을 스냅샷 디렉터리 안에 만들어 tar 에 함께 담습니다.
# 대상 환경에서 압축을 풀면 목록도 같이 나와 그 자리에서 대조할 수 있습니다.
log "   파일 목록 생성"
write_manifest "$SNAPSHOT_DIR"
ok "$(wc -l < "$SNAPSHOT_DIR/$MANIFEST_NAME")개 파일"

log "   패키징"
tar -czf "$OUT_DIR/opensearch-snapshots.tar.gz" -C "$SNAPSHOT_DIR" .
ok "$(du -h "$OUT_DIR/opensearch-snapshots.tar.gz" | cut -f1)"


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
     mkdir -p ~/lexai-snapshots && tar -xzf opensearch-snapshots.tar.gz -C ~/lexai-snapshots
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
