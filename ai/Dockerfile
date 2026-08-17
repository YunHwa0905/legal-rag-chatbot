# ===========================================================
# AI 서버 — FastAPI + 하이브리드 RAG
#
# 의존성은 requirements.txt(학습용) 가 아니라 requirements_server.txt 를 씁니다.
# 학습 패키지(peft/trl/bitsandbytes/datasets)가 빠져 이미지가 수 GB 작아집니다.
#
# torch 는 CPU 빌드를 명시적으로 먼저 설치합니다:
#   - LLM 추론은 Ollama 컨테이너(GPU)가 담당하므로 이 컨테이너에 CUDA 가 불필요
#   - 여기서 torch 가 쓰이는 곳은 질문 1건 임베딩뿐이고 CPU 로 50ms 수준
#   - CUDA 빌드는 약 2.5GB 더 큽니다 (디스크 절약)
# 임베딩까지 GPU 로 돌리고 싶다면 아래 --index-url 을 지우고
# compose 의 ai 서비스에도 GPU 예약을 추가한 뒤 EMBEDDING_DEVICE=cuda 로 두세요.
# ===========================================================

FROM python:3.11-slim

WORKDIR /app

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    HF_HOME=/root/.cache/huggingface

COPY requirements_server.txt .

RUN pip install --no-cache-dir \
        --index-url https://download.pytorch.org/whl/cpu \
        torch==2.4.1 \
 && pip install --no-cache-dir -r requirements_server.txt

# 서버 구동에 필요한 모듈만 복사합니다.
# (학습 스크립트 01~04, gguf/, data/raw 는 .dockerignore 로 제외)
COPY main.py ./
COPY api ./api
COPY core ./core
COPY rag ./rag
COPY prompt ./prompt
COPY indexing ./indexing
COPY data ./data

EXPOSE 8000

# reload 없이 단일 프로세스로 구동합니다.
# lifespan 에서 임베딩 모델을 미리 로드하므로 워커를 늘리면 메모리가 배로 듭니다.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
