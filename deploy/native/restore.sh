#!/usr/bin/env bash
# ===========================================================
# 데이터 준비 — SQLite 스키마 + Ollama 모델 + OpenSearch 색인
#
#   bash deploy/native/restore.sh
#
# 여러 번 실행해도 안전합니다. 이미 준비된 항목은 건너뜁니다.
#
# 이관 대상 환경에서는 이 스크립트가 "데이터를 가져오는" 단계입니다.
# 색인 스냅샷만 미리 옮겨두면(backup.sh 산출물) 나머지는 자동입니다.
# ===========================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

SNAPSHOT_NAME="${SNAPSHOT_NAME:-legal-v1}"
SNAPSHOT_REPO="${SNAPSHOT_REPO:-lexai}"
INDEX_NAME="${INDEX_NAME:-legal_documents}"
BASE_MODEL="${BASE_MODEL:-gemma3:4b-it-q8_0}"
BASE_MODEL_FALLBACK="${BASE_MODEL_FALLBACK:-gemma3:4b}"
TARGET_MODEL="${OLLAMA_MODEL:-legal-gemma}"
REWRITE_MODEL="${OLLAMA_REWRITE_MODEL:-gemma3:1b}"


log "1. SQLite 스키마"
# -----------------------------------------------------------
mkdir -p "$(dirname "$DB_PATH")"
# PRAGMA journal_mode 문이 결과값을 출력하므로 조용히 적용합니다.
sqlite3 "$DB_PATH" < "$REPO_DIR/deploy/schema.sqlite.sql" > /dev/null

tables=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';")
triggers=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sqlite_master WHERE type='trigger';")
mode=$(sqlite3 "$DB_PATH" "PRAGMA journal_mode;")
[ "$tables" -eq 6 ] || die "테이블이 6개가 아닙니다 (현재 ${tables}개)"
[ "$mode" = "wal" ] || warn "journal_mode 가 wal 이 아닙니다: $mode"
ok "테이블 ${tables} / 트리거 ${triggers} / journal_mode ${mode}"
ok "DB: $DB_PATH"


log "2. Ollama 모델"
# -----------------------------------------------------------
systemctl is-active --quiet ollama || die "Ollama 가 실행 중이 아닙니다 (start.sh ollama)"

if ollama list | grep -q "^${TARGET_MODEL}"; then
    ok "${TARGET_MODEL} 이미 존재 — 건너뜀"
else
    base=""
    for tag in "$BASE_MODEL" "$BASE_MODEL_FALLBACK"; do
        log "   베이스 모델 다운로드 시도: $tag"
        if ollama pull "$tag"; then base="$tag"; break; fi
        warn "$tag 실패 — 다음 후보"
    done
    [ -n "$base" ] || die "베이스 모델을 받지 못했습니다"

    # 컨테이너 구성(deploy/ollama-init.sh)과 같은 파라미터를 씁니다.
    modelfile="$(mktemp)"
    printf 'FROM %s\nPARAMETER temperature 0.1\nPARAMETER top_p 0.9\nPARAMETER num_ctx 4096\nPARAMETER repeat_penalty 1.1\n' "$base" > "$modelfile"
    ollama create "$TARGET_MODEL" -f "$modelfile"
    rm -f "$modelfile"
    ok "${TARGET_MODEL} 생성 (베이스 ${base})"
fi

# 후속 질문 재작성용 경량 모델. 법률 지식이 필요 없는 NLU 전용이라
# 별도 Modelfile 없이 그대로 씁니다.
if ollama list | grep -q "^${REWRITE_MODEL}"; then
    ok "${REWRITE_MODEL} 이미 존재 — 건너뜀"
else
    ollama pull "$REWRITE_MODEL"
    ok "${REWRITE_MODEL} 다운로드"
fi


log "3. OpenSearch 색인"
# -----------------------------------------------------------
load_opensearch_creds

if ! port_in_use "$OPENSEARCH_PORT"; then
    log "   OpenSearch 가 꺼져 있어 먼저 기동합니다"
    bash "$(dirname "${BASH_SOURCE[0]}")/start.sh" opensearch
fi

# 이미 떠 있던 경우에도 복구 중일 수 있으므로 여기서 한 번 더 확인합니다.
# 기동 직후에는 _cluster/health 가 200 을 주면서도 샤드 복구가 끝나지 않아
# _count 가 실패하고, 그걸 "색인 없음"으로 읽으면 멀쩡한 색인을 두고
# 복원을 시도하게 됩니다.
if ! wait_for "클러스터 준비" 180 os_ready; then
    die "클러스터가 준비되지 않았습니다 — $LOG_DIR/opensearch.log 확인"
fi

count=$(os_curl "$OS_BASE/${INDEX_NAME}/_count" | grep -o '"count":[0-9]*' | cut -d: -f2 || true)
if [ -n "${count:-}" ] && [ "$count" -gt 0 ] 2>/dev/null; then
    ok "색인이 이미 있습니다 (${count}건) — 복원 건너뜀"
else
    # 스냅샷 파일 확인. 없으면 여기서 멈춰야 합니다 — 복원 없이 서비스를
    # 띄우면 컨테이너는 다 정상인데 답변만 근거 없이 나오는 상태가 됩니다.
    if [ -z "$(ls -A "$SNAPSHOT_DIR" 2>/dev/null | grep -v '^\.gitkeep$')" ]; then
        die "스냅샷이 없습니다: $SNAPSHOT_DIR (backup.sh 산출물을 여기에 풀어두세요)"
    fi

    # 네이티브 OpenSearch 는 ubuntu 로 돌므로 소유권을 맞춥니다.
    # 컨테이너에서 뜬 스냅샷은 uid 1000 이라 대개 그대로 맞지만,
    # sudo cp 로 옮겼다면 root 로 바뀌어 access_denied 가 납니다.
    if [ "$(stat -c %U "$SNAPSHOT_DIR")" != "$(id -un)" ]; then
        sudo chown -R "$(id -un):$(id -gn)" "$SNAPSHOT_DIR"
        ok "스냅샷 디렉터리 소유권 정정"
    fi

    os_curl -X PUT "$OS_BASE/_snapshot/${SNAPSHOT_REPO}" \
        -H 'Content-Type: application/json' \
        -d "{\"type\":\"fs\",\"settings\":{\"location\":\"${SNAPSHOT_DIR}\"}}" >/dev/null
    ok "스냅샷 저장소 등록"

    # ★ || true 가 없으면 grep 이 못 찾았을 때 pipefail 로 대입문 자체가 실패하고,
    #   set -e 가 die 를 실행하기도 전에 스크립트를 죽입니다. 원인 메시지 없이
    #   종료되는 가장 나쁜 실패 방식이라 반드시 막아둡니다.
    state=$( { os_curl "$OS_BASE/_cat/snapshots/${SNAPSHOT_REPO}?h=id,status" \
        | grep "^${SNAPSHOT_NAME} " | awk '{print $2}'; } || true )
    if [ "$state" != "SUCCESS" ]; then
        warn "저장소에 있는 스냅샷 목록:"
        os_curl "$OS_BASE/_cat/snapshots/${SNAPSHOT_REPO}?v" || true
        die "스냅샷 '${SNAPSHOT_NAME}' 의 상태가 SUCCESS 가 아닙니다: ${state:-없음}"
    fi

    log "   복원 중 (수 분 걸립니다)"
    started=$(date +%s)
    os_curl -X POST "$OS_BASE/_snapshot/${SNAPSHOT_REPO}/${SNAPSHOT_NAME}/_restore?wait_for_completion=true" \
        -H 'Content-Type: application/json' \
        -d "{\"indices\":\"${INDEX_NAME}\"}" >/dev/null
    elapsed=$(( $(date +%s) - started ))

    count=$(os_curl "$OS_BASE/${INDEX_NAME}/_count" | grep -o '"count":[0-9]*' | cut -d: -f2)
    [ "${count:-0}" -gt 0 ] || die "복원 후에도 색인이 비어 있습니다"
    ok "복원 완료 — ${count}건 (${elapsed}초)"
fi

# 벡터 필드까지 온전한지 확인합니다. 매핑이 깨지면 BM25 는 되는데
# kNN 만 실패하는 상태가 되어 증상이 늦게 드러납니다.
dim=$(os_curl "$OS_BASE/${INDEX_NAME}/_search?size=1" \
    | python3 -c "import sys,json;h=json.load(sys.stdin)['hits']['hits'];print(len(h[0]['_source'].get('embedding',[])) if h else 0)" 2>/dev/null || echo 0)
[ "$dim" -eq 768 ] || warn "임베딩 차원이 768 이 아닙니다: $dim"
ok "임베딩 차원 ${dim}"


echo
log "데이터 준비 완료"
echo "  다음: bash deploy/native/start.sh"
