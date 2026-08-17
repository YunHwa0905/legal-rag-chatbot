"""
인용 조문 검증

이 프로젝트의 eval에서 반복 확인된 환각 패턴: 모델이 "OO법 제N조" 형태의
구체적인 조문을 인용하면서, 실제로는 검색된 컨텍스트 문서에 없는 번호를
그때그때 지어냄 (예: ip-senior 질문을 3번 실행 → 특허법 제96조 / 제203조 /
제58조를 각각 인용, 전부 오답).

이 모듈은 답변에 등장하는 조문 인용을 추출해 컨텍스트에 실제로 있는지
대조한다. 컨텍스트에 없는 인용은 모델이 지어냈을 가능성이 높다고 본다.
"""

import re

CITATION_PATTERN = re.compile(
    r"([가-힣]{1,20}법)\s*제\s*(\d+)\s*조(?:의\s*(\d+))?"
)


def extract_citations(text: str) -> list:
    """답변 텍스트에서 '민법 제639조', '특허법 제58조' 같은 인용을 추출"""
    citations = []
    for law, article, sub in CITATION_PATTERN.findall(text or ""):
        label = f"{law} 제{article}조" + (f"의{sub}" if sub else "")
        citations.append(label)
    return citations


def _normalize(s: str) -> str:
    return re.sub(r"\s+", "", s or "")


def verify_citations(text: str, context: str) -> dict:
    """
    답변에서 인용을 추출해 컨텍스트에 실제로 등장하는지 확인.

    Returns:
        {"citations": [전체 인용 목록], "unverified": [컨텍스트에서 못 찾은 인용]}
    """
    context_flat = _normalize(context)
    citations = sorted(set(extract_citations(text)))

    unverified = [c for c in citations if _normalize(c) not in context_flat]

    return {
        "citations": citations,
        "unverified": unverified,
    }
