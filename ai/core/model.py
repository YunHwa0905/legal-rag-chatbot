"""
Ollama 기반 추론 모듈 (Gemma GGUF)

Ollama 실행 필요:
- ollama run legal-gemma 으로 모델 실행 중이어야 함
- 기본 주소: http://localhost:11434
"""

import sys
import os
import requests
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from core.config import settings


# ===========================
# Ollama 설정
#
# core.config.settings(pydantic-settings)를 거쳐야 .env 파일이 실제로 반영된다.
# 예전엔 여기서 os.getenv()를 직접 썼는데, 그러면 .env 파일 값은 무시되고
# 진짜 프로세스 환경변수(예: docker-compose의 environment: 블록)만 읽혔다 —
# 운영 배포는 그렇게 값을 주입해서 문제가 없었지만, .env 파일로 설정하는
# 모든 환경(이 워크트리 포함)에서는 조용히 기본값으로 떨어지는 버그였다.
# ===========================
OLLAMA_BASE_URL = settings.OLLAMA_BASE_URL
OLLAMA_MODEL    = settings.OLLAMA_MODEL


# ===========================
# Ollama 상태 확인
# ===========================
def check_ollama() -> bool:
    try:
        res = requests.get(f"{OLLAMA_BASE_URL}/api/tags", timeout=3)
        return res.status_code == 200
    except Exception:
        return False


# ===========================
# 추론 함수
# ===========================
def generate(
    system_prompt: str,
    user_message: str,
    model: str = None,
    max_tokens: int = None,
    temperature: float = None,
    seed: int = None,
) -> str:
    target_model = model or OLLAMA_MODEL

    if not check_ollama():
        raise RuntimeError(
            f"Ollama 서버에 연결할 수 없습니다: {OLLAMA_BASE_URL}\n"
            f"'ollama run {target_model}' 명령어로 모델을 먼저 실행해주세요."
        )

    # Gemma는 system role 미지원 → user 메시지에 합쳐서 전달
    combined = system_prompt + "\n\n" + user_message

    options = {
        "temperature":    temperature if temperature is not None else settings.TEMPERATURE,
        "top_p":          settings.TOP_P,
        "num_predict":    max_tokens if max_tokens is not None else settings.MAX_NEW_TOKENS,
        "repeat_penalty": 1.1,
        "num_ctx":        4096,
    }

    # 시드는 지정했을 때만 넘깁니다. Ollama 는 seed 를 받지 않으면 매 호출
    # 무작위로 두는데, 그게 평소 운영에서 원하는 동작입니다. 이관 전후를
    # 비교할 때만 .env 로 고정값을 주입합니다(LLM_SEED).
    resolved_seed = seed if seed is not None else settings.LLM_SEED
    if resolved_seed >= 0:
        options["seed"] = resolved_seed

    response = requests.post(
        f"{OLLAMA_BASE_URL}/api/chat",
        json={
            "model": target_model,
            "messages": [
                {"role": "user", "content": combined},
            ],
            "stream": False,
            "options": options,
        },
        timeout=300,
    )

    if response.status_code != 200:
        raise RuntimeError(
            f"Ollama API 오류 ({response.status_code}): {response.text}"
        )

    return response.json()["message"]["content"].strip()


# ===========================
# 하위 호환성 유지
# ===========================
def load_model():
    if not check_ollama():
        raise RuntimeError(
            f"Ollama 서버 미실행: {OLLAMA_BASE_URL}\n"
            f"'ollama run {OLLAMA_MODEL}' 먼저 실행하세요."
        )
    print(f"[INFO] Ollama 모델 사용 중: {OLLAMA_MODEL} @ {OLLAMA_BASE_URL}")
    return None, None


if __name__ == "__main__":
    print(f"[INFO] Ollama 상태: {'정상' if check_ollama() else '연결 불가'}")
    print(f"[INFO] 사용 모델: {OLLAMA_MODEL}")