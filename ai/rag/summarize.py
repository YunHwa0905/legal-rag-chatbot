"""
대화 요약 갱신 — Spring의 ChatMemoryAsyncService가 사용자 응답을 보낸 뒤
비동기로 호출하는 순수 함수. 세션 상태를 전혀 모른다(Spring이 prev_summary와
아직 요약에 안 접힌 턴들을 넘겨주고, 결과를 다시 Spring이 저장한다).
"""

import sys
import os
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from core.model import generate

SUMMARY_MAX_LEN = 300


def _format_turns(turns: list) -> str:
    lines = []
    for turn in turns:
        speaker = "사용자" if turn["role"] == "user" else "챗봇"
        lines.append(f"{speaker}: {turn['content']}")
    return "\n".join(lines)


def update_summary(prev_summary: str, turns_to_fold: list) -> str:
    prompt = f"""다음은 지금까지의 대화 요약과, 아직 요약에 반영되지 않은 최근 대화다.
최근 대화의 핵심만 반영해 전체 요약을 한 문단으로 다시 써라. 요약문만 출력하라.

[기존 요약]
{prev_summary or '없음'}

[최근 대화]
{_format_turns(turns_to_fold)}
"""
    summary = generate(
        system_prompt="",
        user_message=prompt,
        max_tokens=200,
        temperature=0.1,
    ).strip()
    return summary[:SUMMARY_MAX_LEN]


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
