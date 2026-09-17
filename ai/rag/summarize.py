"""
대화 요약 갱신 — Spring의 ChatMemoryAsyncService가 사용자 응답을 보낸 뒤
비동기로 호출하는 순수 함수. 세션 상태를 전혀 모른다(Spring이 prev_summary와
아직 요약에 안 접힌 턴들을 넘겨주고, 결과를 다시 Spring이 저장한다).
"""

import sys
import os
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from core.model import generate
from core.config import settings
from core.context_caps import SUMMARY_MAX_LEN, HISTORY_TURN_MAX_LEN, sanitize, format_turns

# 한 번에 접을 수 있는 턴 수 상한(메시지 기준 = *2). 정상 경로에서는
# SUMMARY_TRIGGER_TURNS(Spring, 2턴)를 넘는 시점에 바로 접히므로 3턴 안팎이지만,
# 비동기 워커가 반복 실패하면 접히지 않은 턴이 무한정 쌓일 수 있다 — 이 캡이
# 없으면 그 백로그가 그대로 프롬프트에 들어가 4096 토큰 예산을 넘기고,
# Ollama가 프롬프트 앞부분(요약 지시문 포함)부터 자르면서 조용히 망가진
# 요약이 chat_session_summary에 영구 저장되는 실패 모드가 있었다.
FOLD_TURNS_MAX = 6


def _cap_turns_to_fold(turns: list) -> list:
    recent = turns[-(FOLD_TURNS_MAX * 2):]
    capped = []
    for turn in recent:
        content = sanitize(turn["content"])
        if len(content) > HISTORY_TURN_MAX_LEN:
            content = content[:HISTORY_TURN_MAX_LEN] + "..."
        capped.append({"role": turn["role"], "content": content})
    return capped


def update_summary(prev_summary: str, turns_to_fold: list) -> str:
    capped_turns = _cap_turns_to_fold(turns_to_fold)
    prompt = f"""다음은 지금까지의 대화 요약과, 아직 요약에 반영되지 않은 최근 대화다.
최근 대화의 핵심만 반영해 전체 요약을 한 문단으로 다시 써라. 요약문만 출력하라.

[기존 요약]
{sanitize(prev_summary) or '없음'}

[최근 대화]
{format_turns(capped_turns)}
"""
    summary = generate(
        system_prompt="",
        user_message=prompt,
        # 요약은 법률 지식이 필요 없는 NLU 작업이다 — legal-gemma(무거운 답변 모델)
        # 대신 재작성과 같은 경량 모델로 라우팅해 foreground 답변 생성과의
        # GPU/Ollama 자원 경합을 줄인다.
        model=settings.OLLAMA_REWRITE_MODEL,
        max_tokens=200,
        temperature=0.1,
    ).strip()
    # _cap_summary(template.py)와 동일한 트렁케이션 표기(...)로 통일 —
    # 예전엔 여기만 말줄임표 없이 잘라서 저장된 요약이 문장 중간에서 그냥 끊겼다.
    return summary if len(summary) <= SUMMARY_MAX_LEN else summary[:SUMMARY_MAX_LEN] + "..."


# ===========================
# 테스트
# ===========================
def test():
    turns = [
        {"role": "user", "content": "전세 계약 갱신을 거부당했어요"},
        {"role": "assistant", "content": "임대인은 정당한 사유 없이 갱신을 거부할 수 없습니다. 계약갱신요구권 행사 여부를 확인해야 합니다."},
        {"role": "user", "content": "그럼 계약금은 어떻게 되나요?"},
        {"role": "assistant", "content": "계약이 유효하게 존속하는 한 계약금은 그대로 유지되며, 갱신 거부가 부당하면 반환 의무가 발생하지 않습니다."},
    ]
    summary = update_summary(None, turns)
    print(f"[요약] {summary}")
    assert len(summary) <= SUMMARY_MAX_LEN
    print(f"[PASS] 요약 길이 {len(summary)}자 (<= {SUMMARY_MAX_LEN})")


if __name__ == "__main__":
    test()
