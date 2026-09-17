"""
질문 재작성 — 후속 질문이 이전 대화를 가리킬 때(대명사·지시어, 너무 짧은 질문)
검색 전에 독립적으로 완결된 질문으로 다시 쓴다.

게이트는 규칙 기반(LLM 호출 없음)이라 대부분의 턴에서 재작성 자체를 건너뛴다.
재작성이 실행되는 경우엔 legal-gemma가 아니라 별도의 경량 모델
(OLLAMA_REWRITE_MODEL)을 쓴다 — 법률 지식이 필요 없는 일반 NLU 작업이라
작은 모델로도 충분하고, 지연을 크게 줄인다.
"""

import sys
import os
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from core.model import generate
from core.config import settings
from core.context_caps import cap_history, cap_summary, format_turns


_DEMONSTRATIVES = [
    "그거", "그건", "그것", "이거", "이건", "저거",
    "위에서", "아까", "방금", "거기", "그럼", "그러면",
]
MIN_STANDALONE_LEN = 12


def needs_rewrite(question: str, history: list) -> bool:
    """이력이 없으면 재작성할 이유가 없다. 지시어가 있거나 질문이 너무 짧으면
    이전 대화를 가리키는 후속 질문일 가능성이 높다고 보고 재작성한다."""
    if not history:
        return False
    if any(d in question for d in _DEMONSTRATIVES):
        return True
    return len(question.strip()) < MIN_STANDALONE_LEN


def rewrite_query(question: str, history: list, summary: str = None) -> str:
    # I2: history/summary가 여기서도 하드캡 없이 통째로 프롬프트에 들어가면
    # 재작성용 경량 모델의 컨텍스트 예산을 넘길 수 있었다 — build_prompt와
    # 동일한 캡을 적용해 상한을 맞춘다(1턴짜리 재작성 요청이라 캡이 있어도
    # 정상 케이스의 정보 손실은 없다).
    capped_history = cap_history(history)
    capped_summary = cap_summary(summary)
    prompt = f"""다음은 이전 대화 요약과 최근 대화, 그리고 사용자의 새 질문이다.
새 질문을 이전 대화 없이도 이해할 수 있는 완전한 질문 하나로 다시 써라.
새로운 정보를 추가하지 말고, 이전 대화에 없는 단어를 넣지 마라. 재작성한 질문만 출력하라.

[요약]
{capped_summary or '없음'}

[최근 대화]
{format_turns(capped_history)}

[새 질문]
{question}
"""
    return generate(
        system_prompt="",
        user_message=prompt,
        model=settings.OLLAMA_REWRITE_MODEL,
        max_tokens=80,
        temperature=0.0,
    ).strip()


# ===========================
# 테스트
# ===========================
def test():
    # --- 순수 로직: assert로 즉시 검증(인프라 불필요) ---
    history = [{"role": "user", "content": "가압류가 뭔가요?"},
               {"role": "assistant", "content": "가압류는 ..."}]

    assert needs_rewrite("그건 어떻게 하나요?", history) is True, "지시어 포함 → 재작성해야 함"
    assert needs_rewrite("괜찮아요", []) is False, "이력 없으면 항상 재작성 안 함"
    assert needs_rewrite(
        "전세보증금을 돌려받지 못하고 있는데 어떻게 대응해야 하나요?", history
    ) is False, "지시어 없고 12자 이상 → 재작성 안 함"
    assert needs_rewrite("짧은질문", history) is True, "12자 미만 → 재작성해야 함"
    print("[PASS] needs_rewrite 로직 4건 검증 완료")

    # --- LLM 호출: Ollama + gemma3:1b가 떠 있어야 함 ---
    conv_history = [
        {"role": "user", "content": "전세 계약 갱신을 거부당했어요"},
        {"role": "assistant", "content": "임대인은 정당한 사유 없이 갱신을 거부할 수 없습니다. 계약갱신요구권 행사 여부를 확인해야 합니다."},
    ]
    standalone = rewrite_query("그럼 계약금은 어떻게 되나요?", conv_history, summary=None)
    print(f"[재작성 결과] {standalone}")


if __name__ == "__main__":
    test()
