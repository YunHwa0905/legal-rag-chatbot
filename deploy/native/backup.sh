#!/usr/bin/env bash
# ===========================================================
# 이관 패키지 생성 — OpenSearch 색인 + SQLite DB
#
#   bash deploy/native/backup.sh
#
# 서비스를 멈추지 않고 실행할 수 있습니다. 다만 실행 시점 이후에 들어온
# 대화는 패키지에 없습니다. 실제 이관(전환)에서는 쓰기를 멈추고 뜨세요:
#
#   STOP_WRITES=1 bash deploy/native/backup.sh
#
#   frontend · tomcat 을 멈춘 뒤 패키지를 만들고, 멈춘 상태로 둡니다.
#   다시 켜면 그 뒤의 쓰기는 패키지에 없으므로, 이관을 취소할 때만 켜세요:
#     sudo systemctl start lexai-tomcat lexai-frontend
#
# 산출물을 대상 환경으로 옮기면 restore.sh 가 나머지를 처리합니다.
# Ollama 모델은 포함하지 않습니다 — 5GB 를 옮기는 것보다 대상 환경에서
# 다시 받는 쪽이 빠릅니다(AWS 회선 기준 약 65초).
# ===========================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# 초까지 넣습니다. 분 단위였을 때 같은 분에 두 번 뜨면 스냅샷 이름이 겹쳐
# 생성이 거부됐는데, 그 오류를 버리고 이전 스냅샷으로 패키지를 만들었습니다.
STAMP="$(date +%Y%m%d-%H%M%S)"
# 고정 경로입니다. Beetle 데이터 마이그레이션처럼 전송 경로(path)와
# 후처리 명령(postCmd)을 미리 적어 두는 도구가 매번 같은 위치를 가리킬 수
# 있어야 합니다. 회차별로 남기고 싶으면 OUT_DIR 로 따로 지정하세요.
OUT_DIR="${OUT_DIR:-$HOME/lexai-backup/latest}"
SNAPSHOT_REPO="${SNAPSHOT_REPO:-lexai}"
SNAPSHOT_NAME="${SNAPSHOT_NAME:-legal-$STAMP}"
INDEX_NAME="${INDEX_NAME:-legal_documents}"

mkdir -p "$OUT_DIR"

# 상태 파일 (오케스트레이터용) — 하위 스크립트(stop.sh 등)의 오류도 여기로 모이게 export
export STATUS_FILE="$RUN_DIR/backup-status.json"
rm -f "$STATUS_FILE"
status_set operation=backup state=running started_at="$(now_iso)" out_dir="$OUT_DIR" \
           stop_writes="${STOP_WRITES:-0}"
trap '_rc=$?; if [ "$_rc" -ne 0 ]; then status_set state=failed exit_code="$_rc" finished_at="$(now_iso)"; fi' EXIT

# 이전 회차 패키지 정리
# ★ 고정 경로라 직전 패키지가 남아 있습니다. 특히 lexai.db 가 있으면
#   아래 VACUUM INTO 가 "output file already exists" 로 실패합니다.
#   또 지난 회차 파일이 섞여 남으면 체크섬이 엉뚱한 파일을 가리킬 수 있어,
#   이 스크립트가 만드는 파일만 골라 지우고 새로 만듭니다.
for f in opensearch-snapshots.tar.gz lexai.db source-commit.txt data-fingerprint.tsv runtime-versions.txt checksums.sha256 MANIFEST.txt; do
    rm -f "$OUT_DIR/$f"
done


# -----------------------------------------------------------
# 무중지 확인
#
# 이 스크립트의 전제가 "서비스를 멈추지 않고 뜰 수 있다" 입니다.
# 전제를 말로만 두지 않고 시작·끝에 실제로 확인합니다 — 스냅샷이 I/O 를
# 크게 쓰는 구간이라 프론트가 밀려 죽는지를 보는 것이 요점입니다.
# -----------------------------------------------------------
front_code() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        "http://127.0.0.1:${FRONTEND_PORT}/" 2>/dev/null || echo 000
}
SERVING=0
STOP_WRITES="${STOP_WRITES:-0}"
if [ "$STOP_WRITES" = "1" ]; then
    # -----------------------------------------------------------
    # 쓰기 중지 (전환용)
    #
    # ★ 무중지 백업은 패키지를 만든 뒤 전환하기 전까지 원본에 들어온 대화를
    #   놓칩니다. 리뷰어가 그 사이에 채팅하면 이관 후 그 기록이 없어
    #   "데이터가 사라졌다" 로 보입니다. DB 에 쓰는 것은 Tomcat 뿐이라
    #   frontend(입구)와 tomcat(쓰는 쪽)을 멈추면 이후 쓰기가 없습니다.
    #   진행 중이던 요청은 끊깁니다 — 전환 시점이므로 감수합니다.
    # -----------------------------------------------------------
    log "0. 쓰기 중지 (STOP_WRITES=1)"
    HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    bash "$HERE/stop.sh" frontend
    bash "$HERE/stop.sh" tomcat
    if systemctl is-active --quiet lexai-tomcat 2>/dev/null; then
        die "lexai-tomcat 이 아직 실행 중입니다 — 쓰기를 멈추지 못해 중단합니다"
    fi
    ok "쓰기 중지 — 이 시점 이후 DB 변경 없음 (서비스는 멈춘 채로 둡니다)"
elif [ "$(front_code)" = "200" ]; then
    SERVING=1
else
    warn "프론트엔드가 응답하지 않습니다 — 무중지 여부는 확인하지 않습니다"
fi


log "1. OpenSearch 스냅샷"
# -----------------------------------------------------------
load_opensearch_creds
port_in_use "$OPENSEARCH_PORT" || die "OpenSearch 가 실행 중이 아닙니다"

os_curl -X PUT "$OS_BASE/_snapshot/${SNAPSHOT_REPO}" \
    -H 'Content-Type: application/json' \
    -d "{\"type\":\"fs\",\"settings\":{\"location\":\"${SNAPSHOT_DIR}\",\"compress\":true}}" >/dev/null

# ★ || true 가 없으면 색인이 없을 때 pipefail 로 대입문이 실패하고, set -e 가
#   메시지 없이 스크립트를 끝냅니다. 원인을 알 수 있게 직접 멈춥니다.
docs=$( { os_curl "$OS_BASE/${INDEX_NAME}/_count" | grep -o '"count":[0-9]*' | cut -d: -f2; } || true )
[ -n "$docs" ] || die "색인 ${INDEX_NAME} 을 읽지 못했습니다 — OpenSearch 상태와 색인을 확인하세요 (curl -sk -u … $OS_BASE/_cat/indices)"
log "   색인 ${docs}건 — 스냅샷 생성 중 (수 분 걸립니다)"

started=$(date +%s)
# 저장소는 증분 방식이라 두 번째부터는 훨씬 빠릅니다.
os_curl -X PUT "$OS_BASE/_snapshot/${SNAPSHOT_REPO}/${SNAPSHOT_NAME}?wait_for_completion=true" \
    -H 'Content-Type: application/json' \
    -d "{\"indices\":\"${INDEX_NAME}\",\"include_global_state\":false}" > "$RUN_DIR/snapshot-create.json"
# 응답을 버리지 않고 확인합니다. 이름 충돌 · 저장소 권한 오류가 나도 아래의
# 상태 조회가 이전 스냅샷을 SUCCESS 로 읽어 그대로 진행하던 경로를 막습니다.
if grep -q '"error"' "$RUN_DIR/snapshot-create.json"; then
    die "스냅샷 생성 실패: $(head -c 400 "$RUN_DIR/snapshot-create.json")"
fi
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

    # 대개 범인은 이전 회차 패키지입니다. 지울 대상을 바로 보여 줍니다.
    rmdir "$OUT_DIR" 2>/dev/null || true      # 이번 회차의 빈 디렉터리는 남기지 않습니다
    if [ -d "$(dirname "$OUT_DIR")" ]; then
        warn "  이전 패키지:"
        du -sh "$(dirname "$OUT_DIR")"/* 2>/dev/null | sed 's/^/    /' >&2 || true
    fi
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

# 테이블별 행 수 · 내용 해시. 대상에서 복원 직후 같은 값을 다시 계산해
# "데이터가 그대로 왔는가" 를 자동으로 판정합니다(check-data.sh).
write_data_fingerprint "$OUT_DIR/lexai.db" "$OUT_DIR/data-fingerprint.tsv"

# 런타임 기록 — 대상이 같은 Ollama 버전으로 설치하고(bootstrap → install.sh),
# 모델 ID 가 같은지 비교합니다(check-data.sh, 다르면 경고).
{
    echo "ollama $(ollama_version)"
    ollama list 2>/dev/null | awk 'NR>1 {print "model "$1" "$2}' || true
} > "$OUT_DIR/runtime-versions.txt"
ok "런타임 기록 (Ollama $(ollama_version), 모델 $(grep -c '^model ' "$OUT_DIR/runtime-versions.txt" || true)개)"
ok "데이터 지문 ($(wc -l < "$OUT_DIR/data-fingerprint.tsv")개 테이블)"


log "3. 소스 커밋"
# -----------------------------------------------------------
# 저장소 디렉터리를 통째로 옮기는 이관(Beetle 데이터 마이그레이션 등)에서는
# 대상 VM 이 GitHub 에서 새로 받지 않고 옮겨온 소스를 그대로 씁니다
# (bootstrap.sh NO_UPDATE=1). 옮겨온 소스가 이 패키지를 만든 시점의 소스와
# 같은지 대상에서 대조할 수 있도록 전체 해시를 남기고 체크섬에도 넣습니다.
#
# ★ 커밋 해시는 커밋되지 않은 수정을 담지 못합니다. 그래서 추적 파일에
#   수정이 있으면 경고합니다. 실행 권한(chmod +x) 변경은 bootstrap 이 매번
#   하므로 core.fileMode=false 로 무시합니다.
# -----------------------------------------------------------
commit_full="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null)" \
    || die "저장소 커밋을 읽지 못했습니다: $REPO_DIR"
echo "$commit_full" > "$OUT_DIR/source-commit.txt"

dirty="$(git -C "$REPO_DIR" -c core.fileMode=false status --porcelain --untracked-files=no 2>/dev/null || true)"
if [ -n "$dirty" ]; then
    warn "커밋되지 않은 수정이 있습니다 — 커밋 해시만으로는 소스 동일성을 보장하지 못합니다"
    printf '%s\n' "$dirty" | sed 's/^/    /' >&2
fi
ok "${commit_full:0:7} ($(git -C "$REPO_DIR" branch --show-current 2>/dev/null || echo '-'))"


log "4. 체크섬"
# 전송 중 손상을 대상 환경에서 곧바로 잡기 위한 파일 단위 해시입니다.
# (압축을 푼 뒤의 내용 대조는 tar 안의 목록 파일이 담당합니다)
( cd "$OUT_DIR" && sha256sum opensearch-snapshots.tar.gz lexai.db source-commit.txt data-fingerprint.tsv runtime-versions.txt > checksums.sha256 )
ok "checksums.sha256"

snap_files=$(wc -l < "$SNAPSHOT_DIR/$MANIFEST_NAME")
snap_bytes=$(awk -F'	' '{s+=$2} END {print s+0}' "$SNAPSHOT_DIR/$MANIFEST_NAME")

if [ "$SERVING" = "1" ]; then
    code="$(front_code)"
    if [ "$code" = "200" ]; then
        ok "무중지 확인 — 패키징 내내 프론트엔드 HTTP 200"
    else
        warn "패키징 중 프론트엔드가 HTTP ${code} 가 됐습니다 — 무중지가 아닙니다"
    fi
fi


log "5. 매니페스트"
# -----------------------------------------------------------
cat > "$OUT_DIR/MANIFEST.txt" <<EOF
LexAI 이관 패키지
생성 시각   : $(date '+%Y-%m-%d %H:%M:%S %Z')
생성 호스트 : $(hostname)
저장소 커밋 : ${commit_full} ($(git -C "$REPO_DIR" branch --show-current 2>/dev/null || echo '-'))
쓰기 중지   : $( [ "$STOP_WRITES" = "1" ] && echo '예 — 패키지 이후 원본 변경 없음' || echo '아니요 — 무중지 백업, 이후 원본 변경분은 없음')
스키마 버전 : v$(sqlite3 "$OUT_DIR/lexai.db" "PRAGMA user_version;")

내용
  opensearch-snapshots.tar.gz  색인 ${docs}건 (스냅샷 ${SNAPSHOT_NAME}, 생성 ${snap_elapsed}초)
                               파일 ${snap_files}개 / ${snap_bytes} bytes (압축 전)
  lexai.db                     사용자 ${users} · 메시지 ${msgs}
  source-commit.txt            패키지를 만든 시점의 저장소 커밋 (전체 해시)
  data-fingerprint.tsv         테이블별 행 수 · 내용 해시 (대상에서 자동 비교)
  runtime-versions.txt         Ollama 버전 · 모델 ID (대상이 같은 버전으로 설치, 모델 비교)
  checksums.sha256             위 다섯 파일의 SHA-256

정합성 확인
  전송 직후   sha256sum -c checksums.sha256
  복원 직후   restore.sh 가 압축 해제된 파일의 개수·총 용량·해시를 대조합니다
              (목록 파일 contents.tsv 가 아카이브 안에 함께 들어 있습니다)

포함하지 않은 것
  Ollama 모델   대상 환경에서 restore.sh 가 자동으로 받습니다
  임베딩 모델   AI 서버가 기동 시 자동으로 받습니다
  .env          비밀값이라 패키지에는 넣지 않습니다. 저장소째 옮기면 함께 옮겨지고,
                없으면 대상의 bootstrap 이 새로 발급합니다(이 경우 기존 로그인 토큰만 무효)

저장소째 옮기는 이관 (Beetle 데이터 마이그레이션 등)
  옮길 것  ~/legal-rag-chatbot  (.env 포함)  +  이 패키지 디렉터리
  제외     ai/.venv  frontend/node_modules  backend_spring/target
           (대상에서 install.sh 가 다시 만듭니다 — 경로·파이썬 버전에 묶여 있습니다)
  실행     NO_UPDATE=1 SNAPSHOT_URI=$OUT_DIR \\
             bash ~/legal-rag-chatbot/deploy/native/bootstrap.sh
           NO_UPDATE=1 이면 GitHub 에서 갱신하지 않고, 체크섬과 소스 커밋이
           이 패키지와 하나라도 다르면 멈춥니다. 이미 LexAI 가 깔린 VM 이면
           FORCE_CLEAN=1 을 함께 줍니다. 진행 상황: ~/lexai-run/status.json

대상 환경에서 (저장소를 새로 받는 경우)
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
status_set state=success exit_code=0 finished_at="$(now_iso)" package="$OUT_DIR" \
           commit="$commit_full" snapshot="$SNAPSHOT_NAME" users="$users" messages="$msgs"
if [ "$STOP_WRITES" = "1" ]; then
    warn "frontend · tomcat 은 멈춘 상태입니다. 이관을 취소할 때만 다시 켜세요:"
    warn "  sudo systemctl start lexai-tomcat lexai-frontend"
fi
du -h "$OUT_DIR"/* | sed 's/^/  /'
echo
echo "  전송 예:"
echo "    aws s3 cp --recursive $OUT_DIR s3://<버킷>/lexai/$STAMP/"
