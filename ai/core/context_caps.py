"""
요약·이력 하드 캡 + 새니타이즈 — template.py/rewrite.py/summarize.py가 공유한다.

이전엔 이 상수·헬퍼가 세 파일에 각각 따로 있었다(같은 SUMMARY_MAX_LEN=300이
Python 안에서 두 번, 화자 포맷 헬퍼가 세 벌). 여기 하나로 모아 그 드리프트를
없앤다. 또 하나: 대화 이력/요약은 사용자·모델이 만든 텍스트이고, 이게 프롬프트에
[참고 내용]/[질문] 같은 섹션 헤더보다 앞쪽(주입 취약 위치)에 그대로 꽂힌다 —
그 헤더 문자열을 사용자가 자기 질문/답변 안에 그대로 써서 다음 턴에 위조된
섹션으로 재생되는 걸 막기 위해 대괄호를 전각으로 치환한다(완전한 방어는 아니고
값싼 완화책).

HISTORY_TURNS_MAX=2 는 Spring 쪽 ChatService.HISTORY_WINDOW_MESSAGES=4 와
쌍을 이루는 값이다(2턴 = 메시지 4개) — 한쪽만 바꾸면 롤링 요약과 최근 이력
사이에 갭 또는 이중 카운트가 생기니 두 값은 항상 함께 바꿔야 한다.
"""

SUMMARY_MAX_LEN = 300
HISTORY_TURNS_MAX = 2
HISTORY_TURN_MAX_LEN = 250


def sanitize(text: str) -> str:
    """프롬프트가 섹션 구분에 쓰는 대괄호를 전각(［］)으로 치환 — 대화 내용이
    [참고 내용]/[질문] 같은 헤더를 위조하지 못하게 한다."""
    if not text:
        return text
    return text.replace("[", "［").replace("]", "］")


def cap_summary(summary: str) -> str:
    if not summary:
        return None
    summary = sanitize(summary)
    return summary if len(summary) <= SUMMARY_MAX_LEN else summary[:SUMMARY_MAX_LEN] + "..."


def cap_history(
    history: list,
    turns_max: int = HISTORY_TURNS_MAX,
    turn_max_len: int = HISTORY_TURN_MAX_LEN,
) -> list:
    if not history:
        return []
    # 오래된 턴부터 버림 → 최근 turns_max*2 메시지만 유지
    recent = history[-(turns_max * 2):]
    capped = []
    for turn in recent:
        content = sanitize(turn["content"])
        if len(content) > turn_max_len:
            content = content[:turn_max_len] + "..."
        capped.append({"role": turn["role"], "content": content})
    return capped


def format_turns(turns: list) -> str:
    lines = []
    for turn in turns:
        speaker = "사용자" if turn["role"] == "user" else "챗봇"
        lines.append(f"{speaker}: {turn['content']}")
    return "\n".join(lines)
