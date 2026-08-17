#!/usr/bin/env bash
# ===========================================================
# Ollama 모델 최초 1회 준비 스크립트
#
#   bash deploy/ollama-init.sh
#
# 왜 필요한가:
#   ai/gguf/gemma_base/Modelfile 은 FROM 이 윈도 절대경로
#   (F:\workspce\...) 라서 서버에서 그대로 쓸 수 없습니다.
#   그리고 현재 legal-gemma 는 파인튜닝 모델이 아니라
#   구글 원본 Gemma 3 4B Instruct + 파라미터 튜닝 조합이므로,
#   서버가 직접 받아오면 학교 PC 의 GGUF 파일과 동일합니다.
#   → 5GB 파일 전송이 필요 없습니다.
#
# 이 스크립트는 여러 번 실행해도 안전합니다(pull 은 캐시됨).
# ===========================================================

set -euo pipefail

CONTAINER="lexai-ollama"
TARGET_MODEL="${OLLAMA_MODEL:-legal-gemma}"

# 원본 Modelfile 의 파라미터를 그대로 옮깁니다.
TEMPERATURE="0.1"
TOP_P="0.9"
NUM_CTX="4096"
REPEAT_PENALTY="1.1"

# Q8_0 을 우선 시도하고, 태그가 없으면 기본 4b(Q4_K_M)로 폴백합니다.
# 원본 Modelfile 이 Q8_0 이었으므로 첫 번째가 성공하는 게 이상적입니다.
CANDIDATES=("gemma3:4b-it-q8_0" "gemma3:4b")

echo "==========================================================="
echo " 1. 컨테이너 확인"
echo "==========================================================="
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo "[FATAL] ${CONTAINER} 가 실행 중이 아닙니다. 먼저 docker compose up -d 하세요." >&2
    exit 1
fi

echo "==========================================================="
echo " 2. GPU 인식 확인  ★ 여기서 실패하면 CPU 로 폴백해 응답이 1~3분이 됩니다"
echo "==========================================================="
if docker exec "$CONTAINER" nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null; then
    echo "[OK] 컨테이너가 GPU 를 인식합니다."
else
    echo "[WARN] 컨테이너에서 nvidia-smi 가 실패했습니다."
    echo "[WARN] docker-compose.yml 의 ollama 서비스 GPU 예약과"
    echo "[WARN] 호스트의 nvidia-container-toolkit 설치를 확인하세요."
    echo "[WARN] 이 상태로 진행하면 추론이 CPU 로 떨어집니다."
fi

echo "==========================================================="
echo " 3. 베이스 모델 다운로드"
echo "==========================================================="
BASE=""
for tag in "${CANDIDATES[@]}"; do
    echo "--- 시도: $tag"
    if docker exec "$CONTAINER" ollama pull "$tag"; then
        BASE="$tag"
        echo "[OK] $tag 다운로드 완료"
        break
    fi
    echo "[WARN] $tag 실패 — 다음 후보로 넘어갑니다."
done

if [ -z "$BASE" ]; then
    echo "[FATAL] 베이스 모델을 받지 못했습니다." >&2
    echo "[FATAL] docker exec ${CONTAINER} ollama pull gemma3:4b 를 직접 실행해 원인을 확인하세요." >&2
    exit 1
fi

echo "==========================================================="
echo " 4. ${TARGET_MODEL} 생성 (베이스: ${BASE})"
echo "==========================================================="
docker exec "$CONTAINER" sh -c "cat > /tmp/Modelfile <<'EOF'
FROM ${BASE}
PARAMETER temperature ${TEMPERATURE}
PARAMETER top_p ${TOP_P}
PARAMETER num_ctx ${NUM_CTX}
PARAMETER repeat_penalty ${REPEAT_PENALTY}
EOF
ollama create ${TARGET_MODEL} -f /tmp/Modelfile"

echo "==========================================================="
echo " 5. 결과"
echo "==========================================================="
docker exec "$CONTAINER" ollama list

echo
echo "[NEXT] 추론이 실제로 도는지 확인하세요 (GPU 면 수 초 내 응답):"
echo "  docker exec -it ${CONTAINER} ollama run ${TARGET_MODEL} \"계약이 무엇인가요?\""
echo
echo "[NEXT] GPU 를 쓰고 있는지 확인 (추론 중에 다른 터미널에서):"
echo "  docker exec ${CONTAINER} nvidia-smi"
