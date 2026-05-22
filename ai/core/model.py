"""
Ollama 기반 추론 모듈

변경사항:
- 기존: transformers로 모델 직접 로드 (16GB VRAM 점유)
- 변경: Ollama API 호출 방식 (메모리 효율, 빠른 시작)

Ollama 실행 필요:
- ollama run legal-exaone 으로 모델 실행 중이어야 함
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
OLLAMA_MODEL    = os.getenv("OLLAMA_MODEL", "legal-exaone")


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

    response = requests.post(
        f"{OLLAMA_BASE_URL}/api/chat",
        json={
            "model": OLLAMA_MODEL,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user",   "content": user_message},
            ],
            "stream": False,
            "options": {
                "temperature":      settings.TEMPERATURE,
                "top_p":            settings.TOP_P,
                "num_predict":      settings.MAX_NEW_TOKENS,
                "repeat_penalty":   1.1,
                "num_ctx":          4096,
            },
        },
        timeout=300,  # 법률 답변은 길 수 있으므로 5분 타임아웃
    )

    if response.status_code != 200:
        raise RuntimeError(
            f"Ollama API 오류 ({response.status_code}): {response.text}"
        )

    return response.json()["message"]["content"].strip()


# ===========================
# 하위 호환성 유지
# (기존 load_model() 호출 코드가 있을 경우 대비)
# ===========================
def load_model():
    if not check_ollama():
        raise RuntimeError(
            f"Ollama 서버 미실행: {OLLAMA_BASE_URL}\n"
            f"'ollama run {OLLAMA_MODEL}' 먼저 실행하세요."
        )
    print(f"[INFO] Ollama 모델 사용 중: {OLLAMA_MODEL} @ {OLLAMA_BASE_URL}")
    return None, None


# ===========================
# 테스트
# ===========================
def test():
    from prompt.template import build_prompt

    question = "계약서에 도장 안 찍으면 어떻게 되나요?"
    context = """[문서 1] (민사법 - 법령)
민법 제563조에 따르면 매매계약은 당사자 일방이 재산권을 상대방에게 이전할 것을 약정하고,
상대방이 그 대금을 지급할 것을 약정함으로써 효력이 생긴다.
계약은 원칙적으로 당사자 간의 합의만으로 성립하며, 서면이나 날인이 필수 요건은 아니다."""

    print(f"[INFO] Ollama 상태: {'정상' if check_ollama() else '연결 불가'}")
    print(f"[INFO] 사용 모델: {OLLAMA_MODEL}")

    for age in [8, 25, 55]:
        print(f"\n{'='*50}")
        print(f"나이: {age}세")
        print(f"{'='*50}")
        prompt = build_prompt(question, context, age)
        answer = generate(prompt["system"], prompt["user"])
        print(f"나이대: {prompt['age_group_label']}")
        print(f"\n[답변]\n{answer}")


if __name__ == "__main__":
    test()