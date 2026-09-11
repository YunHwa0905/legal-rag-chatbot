"""
LLM 채점 모듈 (로컬 Ollama, legal-exaone-official)

legal-gemma로 생성한 답변을 다른 모델 계열(EXAONE)로 채점한다.
같은 계열 모델이 자기 답변을 채점하면 자기가 만든 실수를 못 잡아내는
자기 편향(self-bias) 위험이 있어서, 계열이 다른 모델로 채점을 분리했다.

실행 필요: legal-exaone-official 모델이 로컬 Ollama에 설치되어 있어야 함
(`ollama list`로 확인. 없으면 채점은 실패하고 이유가 reason에 남는다.)

⚠️ 신뢰도 한계 (32건 평가로 실측 확인됨):
legal-exaone-official은 소형 로컬 모델이라 프롬프트로 명시해도 "설명이 더 자세했으면
좋겠다"는 편향을 완전히 못 버린다. 예: 나이대가 "전문 법률 용어로 설명 중"(senior)인
답변에 실제로 전문 용어를 정확히 썼는데도 "예시가 더 있었으면"이라며 age_appropriate_tone을
fail 처리하는 경우가 반복 확인됨. 그래서 이 모듈이 내는 pass율 숫자 자체는 정확도
지표로 쓰면 안 되고, fail로 나온 케이스를 사람이 다시 확인할 "후보 목록"을 뽑는
용도로만 쓴다. run_eval.py 요약 출력도 이 전제로 구성돼 있다.
"""

import os
import json
import re
import requests

JUDGE_BASE_URL = os.getenv("OLLAMA_BASE_URL", "http://localhost:11434")
JUDGE_MODEL = os.getenv("JUDGE_MODEL", "legal-exaone-official")

JUDGE_SYSTEM_PROMPT = """당신은 법률 RAG 챗봇의 답변 품질을 채점하는 평가자입니다.
아래 [참고 문서], [나이대], [질문], [답변]을 보고 세 가지 기준으로 채점하세요.

[채점 기준]
1. factual_correctness (사실 정확성): 답변에 '틀린 내용'이 있는지만 보세요.
   - pass: 답변 내용이 참고 문서 및 일반 법률 상식과 모순되지 않음
   - fail: 참고 문서나 법률 상식과 명백히 틀리거나 모순되는 내용이 있음
   - 주의: 답변이 짧거나, 해결책이 구체적이지 않거나, 조언이 더 있었으면 좋겠다는 것은
     fail 사유가 아닙니다. 부족함이 아니라 '틀림'만 채점하세요.

2. age_appropriate_tone (나이대 적합성): 답변의 말투/난이도가 [나이대]에 적힌
   '목표 문체'와 일치하는지만 보세요. 아래 목표 문체표를 반드시 따르세요.
   - "초등학생 눈높이로 설명 중" → 목표: 쉬운 말, 일상 비유, 법률 용어 없음.
     이 나이대에서는 어려운 용어를 쓰면 fail입니다.
   - "청소년 눈높이로 설명 중" → 목표: 법률 용어를 쓰되 괄호로 쉽게 풀이함.
     용어를 아예 안 쓰거나(너무 유치함) 풀이 없이 어려운 용어만 쓰면(너무 어려움) fail입니다.
   - "일반 성인 눈높이로 설명 중" → 목표: 법률 용어 사용 + 필요시 부연 설명.
     법률 용어를 쓰는 것 자체는 정상이며 fail 사유가 아닙니다.
   - "전문 법률 용어로 설명 중" → 목표: 정확한 법률 용어와 조문 인용을 그대로 사용.
     **전문 용어를 쓰는 것이 정답입니다. "초등학생이나 이해력이 낮은 사람에게 어렵다"는
     이유로 fail을 주면 안 됩니다** — 이 나이대는 애초에 전문가 수준 설명을 원합니다.
     오히려 전문 용어를 안 쓰고 지나치게 쉽게 풀어썼다면 그게 fail입니다.
   - 핵심: "누구나 이해하기 쉬운가"가 아니라 "그 나이대에 지정된 목표 문체와 실제
     일치하는가"를 채점하세요. 목표 문체와 다르면(너무 쉽거나, 너무 어렵거나) fail입니다.
   - 주의: 답변이 짧거나, 예시가 부족하거나, 더 깊이 있게 설명했으면 좋겠다는 것은
     이 기준의 fail 사유가 아닙니다. 그건 factual_correctness나 다른 문제이지 문체
     문제가 아닙니다. age_appropriate_tone은 오직 '말투/용어 수준'만 보세요.

3. hallucination_free (환각 없음): 참고 문서에 없는 조문 번호, 기관명, 절차를 지어내지 않았는지.
   - pass: 참고 문서 범위 안에서만 답변함
   - fail: 참고 문서에 없는 조문 번호·기관명·절차를 지어냄 (일부만 지어냈어도 fail)

각 항목의 값은 반드시 "pass" 또는 "fail" 둘 중 하나만 쓰세요.
"partial", "true", "false" 같은 다른 값은 절대 쓰지 마세요 — 애매하면 fail로 판단하세요.
반드시 아래 JSON 형식으로만 답하세요. JSON 앞뒤에 다른 설명을 쓰지 마세요.
{"factual_correctness": "pass 또는 fail", "age_appropriate_tone": "pass 또는 fail", "hallucination_free": "pass 또는 fail", "reason": "한 문장 이유"}
"""


def _extract_json(text: str) -> dict:
    match = re.search(r"\{.*\}", text, re.DOTALL)
    if not match:
        raise ValueError(f"JSON 형식을 찾을 수 없음: {text[:200]}")
    return json.loads(match.group(0))


# exaone이 가끔 키 이름을 오타 냄 (예: "hallucination_free" -> "hallulation_free").
# 정확한 키가 없으면 부분 문자열로 찾아서 매칭한다.
_KEY_HINTS = {
    "factual_correctness": ["fact"],
    "age_appropriate_tone": ["age", "tone"],
    "hallucination_free": ["hallu"],
}


def _get_field(result: dict, field: str):
    if field in result:
        return result[field]
    hints = _KEY_HINTS[field]
    for key, value in result.items():
        if any(hint in key.lower() for hint in hints):
            return value
    return None


# exaone이 "pass"/"fail" 대신 "faill", "false", "partial", "partial fail (...)" 같은
# 규격 밖 값을 낼 때가 있어서, 정확히 "pass"/"fail"이 아니면 문자열에 fail/partial이
# 섞여 있는지로 보정한다. 법률 도메인이라 애매하면 fail 쪽으로 판단(보수적으로 처리).
def _normalize_verdict(value):
    if value is None:
        return None
    v = str(value).strip().lower()
    if v == "pass" or v == "true":
        return "pass"
    if v == "fail" or v == "false":
        return "fail"
    if "fail" in v or "partial" in v:
        return "fail"
    if "pass" in v:
        return "pass"
    return None  # 어느 쪽도 알 수 없으면 채점 실패로 취급


def judge(question: str, age_group_label: str, context: str, answer: str) -> dict:
    """
    Returns:
        {
            "factual_correctness": "pass" | "fail" | None,
            "age_appropriate_tone": "pass" | "fail" | None,
            "hallucination_free": "pass" | "fail" | None,
            "reason": str,
        }
        채점 자체가 실패하면(Ollama 연결 실패, JSON 파싱 실패 등) 세 항목은 None,
        reason에 실패 원인이 남는다.
    """
    user_message = f"""[참고 문서]
{context}

[나이대]
{age_group_label}

[질문]
{question}

[답변]
{answer}"""

    # exaone도 legal-gemma와 마찬가지로 system role을 안정적으로 안 쓸 수 있어서
    # core/model.py의 generate()와 동일하게 하나의 user 메시지로 합쳐서 보낸다.
    combined = JUDGE_SYSTEM_PROMPT + "\n\n" + user_message

    try:
        response = requests.post(
            f"{JUDGE_BASE_URL}/api/chat",
            json={
                "model": JUDGE_MODEL,
                "messages": [{"role": "user", "content": combined}],
                "stream": False,
                "options": {"temperature": 0.0, "num_ctx": 4096},
            },
            timeout=120,
        )
        response.raise_for_status()
        content = response.json()["message"]["content"]
        result = _extract_json(content)
        return {
            "factual_correctness": _normalize_verdict(_get_field(result, "factual_correctness")),
            "age_appropriate_tone": _normalize_verdict(_get_field(result, "age_appropriate_tone")),
            "hallucination_free": _normalize_verdict(_get_field(result, "hallucination_free")),
            "reason": result.get("reason", ""),
        }
    except Exception as e:
        return {
            "factual_correctness": None,
            "age_appropriate_tone": None,
            "hallucination_free": None,
            "reason": f"채점 실패: {e}",
        }
