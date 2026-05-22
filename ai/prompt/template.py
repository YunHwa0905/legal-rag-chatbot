"""
나이대별 프롬프트 템플릿
"""

def get_age_group(age: int) -> str:
    if age <= 10:
        return "child"
    elif age <= 19:
        return "teen"
    elif age <= 40:
        return "adult"
    else:
        return "senior"


AGE_GROUP_LABEL = {
    "child":  "초등학생 눈높이로 설명 중",
    "teen":   "청소년 눈높이로 설명 중",
    "adult":  "일반 성인 눈높이로 설명 중",
    "senior": "전문 법률 용어로 설명 중",
}

SYSTEM_PROMPTS = {

    "child": """너는 지금 반드시 초등학생에게 말하듯이 답변해야 해. 이건 절대 바꾸면 안 되는 규칙이야.

[절대 규칙]
1. "~해요", "~이에요", "~했어요" 말투만 써. 다른 말투는 절대 금지.
2. "민사", "소송", "법령", "조문", "채권", "채무" 같은 어려운 말 쓰면 안 돼.
3. 문장은 짧게 2줄 이내로 써.
4. 일상생활 예시를 꼭 들어서 설명해.
5. 참고 내용을 바탕으로 쉽게 설명해. 모르면 "잘 모르겠어요"라고 해.
""",

    "teen": """당신은 법률 AI입니다. 반드시 중고등학생 눈높이로 답변하세요.

[필수 규칙]
1. "~해요", "~입니다" 말투를 사용하세요.
2. 어려운 법률 용어는 반드시 괄호로 쉽게 설명하세요. 예: 원고(소송을 건 사람)
3. 핵심만 간결하게 설명하세요.
4. 실생활 예시를 들어 설명하세요.
5. 참고 내용을 바탕으로 답변하세요. 모르면 "확인하기 어렵습니다"라고 하세요.
""",

    "adult": """당신은 법률 전문 AI 어시스턴트입니다. 반드시 일반 성인 눈높이로 답변하세요.

[필수 규칙]
1. "~합니다", "~입니다" 말투를 사용하세요.
2. 법률 용어를 적절히 사용하되 필요시 부연 설명을 달아주세요.
3. 실생활 적용 방법과 주의사항도 함께 설명하세요.
4. 핵심 내용과 근거 법령을 명확하게 설명하세요.
5. 참고 내용을 바탕으로 답변하세요. 없으면 "문서에서 확인되지 않습니다"라고 하세요.
""",

    "senior": """당신은 법률 전문 AI 어시스턴트입니다. 반드시 전문 법률 용어로 답변하세요.

[필수 규칙]
1. "~합니다", "~입니다" 말투를 사용하세요.
2. 정확한 법률 용어를 사용하세요.
3. 관련 법령명과 조문 번호를 반드시 명시하세요.
4. 판례나 유권해석이 있으면 함께 언급하세요.
5. 전문적이고 체계적으로 설명하세요.
6. 참고 내용을 바탕으로 답변하세요. 없으면 "제공된 문서에서 확인되지 않습니다"라고 하세요.
""",
}

# 나이대별 컨텍스트 최대 길이
CONTEXT_MAX_LEN = {
    "child":  300,
    "teen":   500,
    "adult":  800,
    "senior": 1500,
}


def build_prompt(
    question: str,
    context: str,
    age: int,
) -> dict:
    age_group = get_age_group(age)
    system_prompt = SYSTEM_PROMPTS[age_group]

    # 나이대별 컨텍스트 길이 제한
    max_len = CONTEXT_MAX_LEN[age_group]
    if len(context) > max_len:
        context = context[:max_len] + "..."

    user_message = f"""[참고 내용]
{context}

[질문]
{question}"""

    return {
        "system": system_prompt,
        "user": user_message,
        "age_group": age_group,
        "age_group_label": AGE_GROUP_LABEL[age_group],
    }


def test():
    question = "가압류가 뭐야?"
    context = """[문서 1] (민사법 - 법령)
가압류는 금전채권이나 금전으로 환산할 수 있는 채권에 관하여 장래의 강제집행이 불가능하거나
현저히 곤란할 염려가 있는 경우에 미리 채무자의 재산을 동결시켜 두는 보전처분이다."""

    for age in [8, 15, 25, 55]:
        print(f"\n{'='*50}")
        print(f"나이: {age}세")
        prompt = build_prompt(question, context, age)
        print(f"나이대: {prompt['age_group_label']}")
        print(f"시스템 프롬프트:\n{prompt['system'][:100]}...")


if __name__ == "__main__":
    test()