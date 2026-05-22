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
# ===========================
OLLAMA_BASE_URL = os.getenv("OLLAMA_BASE_URL", "http://localhost:11434")
OLLAMA_MODEL    = os.getenv("OLLAMA_MODEL", "legal-gemma")


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
) -> str:
    if not check_ollama():
        raise RuntimeError(
            f"Ollama 서버에 연결할 수 없습니다: {OLLAMA_BASE_URL}\n"
            f"'ollama run {OLLAMA_MODEL}' 명령어로 모델을 먼저 실행해주세요."
        )

    # Gemma는 system role 미지원 → user 메시지에 합쳐서 전달
    combined = system_prompt + "\n\n" + user_message

    response = requests.post(
        f"{OLLAMA_BASE_URL}/api/chat",
        json={
            "model": OLLAMA_MODEL,
            "messages": [
                {"role": "user", "content": combined},
            ],
            "stream": False,
            "options": {
                "temperature":    settings.TEMPERATURE,
                "top_p":          settings.TOP_P,
                "num_predict":    settings.MAX_NEW_TOKENS,
                "repeat_penalty": 1.1,
                "num_ctx":        4096,
            },
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