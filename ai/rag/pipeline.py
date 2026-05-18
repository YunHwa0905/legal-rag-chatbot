"""
RAG 파이프라인 통합 모듈

역할:
- 검색(retriever) + 프롬프트(template) + 추론(model) 전체 흐름 연결
- 사용자 질문 + 나이 입력 → 최종 답변 반환
"""

import sys
import os
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from rag.retriever import LegalRetriever
from prompt.template import build_prompt
from core.model import generate


# ===========================
# RAG 파이프라인 클래스
# ===========================
class LegalRAGPipeline:

    def __init__(self):
        print("[INFO] RAG 파이프라인 초기화 중...")
        self.retriever = LegalRetriever()
        print("[SUCCESS] RAG 파이프라인 초기화 완료")

    # ===========================
    # 메인 실행 함수
    # ===========================
    def run(
        self,
        question: str,
        age: int,
        law_category: str = None,
    ) -> dict:
        """
        Args:
            question: 사용자 질문
            age: 사용자 나이
            law_category: 법률 분야 필터 (선택)

        Returns:
            {
                "answer": 생성된 답변,
                "sources": 참조 문서 목록,
                "age_group_label": 나이대 레이블,
                "context": 검색된 컨텍스트
            }
        """

        # ===========================
        # Step 1. RAG 검색
        # ===========================
        print(f"[INFO] 검색 중: {question[:30]}...")
        results = self.retriever.search(question, law_category)

        if not results:
            return {
                "answer": "관련 법률 문서를 찾을 수 없습니다. 질문을 다시 입력해주세요.",
                "sources": [],
                "age_group_label": "",
                "context": "",
            }

        # 검색 결과 → 컨텍스트 텍스트 변환
        context = self.retriever.get_context(question, law_category)

        # ===========================
        # Step 2. 나이대별 프롬프트 구성
        # ===========================
        prompt = build_prompt(
            question=question,
            context=context,
            age=age,
        )

        # ===========================
        # Step 3. LLM 추론
        # ===========================
        print(f"[INFO] 답변 생성 중... (나이대: {prompt['age_group_label']})")
        answer = generate(
            system_prompt=prompt["system"],
            user_message=prompt["user"],
        )

        # ===========================
        # Step 4. 출처 정리
        # ===========================
        sources = [
            {
                "doc_id": doc["doc_id"],
                "law_category": doc["law_category"],
                "doc_type": doc["doc_type"],
                "source": doc["source"],
                "score": doc["score"],
                "preview": doc["text"][:100] + "...",
            }
            for doc in results
        ]

        return {
            "answer": answer,
            "sources": sources,
            "age_group_label": prompt["age_group_label"],
            "context": context,
        }


# ===========================
# 싱글톤 인스턴스 관리
# ===========================
_pipeline = None

def get_pipeline() -> LegalRAGPipeline:
    global _pipeline
    if _pipeline is None:
        _pipeline = LegalRAGPipeline()
    return _pipeline


# ===========================
# 테스트
# ===========================
def test():
    pipeline = get_pipeline()

    test_cases = [
        {"question": "계약서에 도장 안 찍으면 어떻게 되나요?", "age": 8},
        {"question": "상표권 침해 판단 기준은 무엇인가요?",    "age": 25},
        {"question": "임의동행 요청 시 경찰관이 해야 할 절차는?", "age": 45},
    ]

    for case in test_cases:
        print(f"\n{'='*60}")
        print(f"질문: {case['question']}")
        print(f"나이: {case['age']}세")
        print(f"{'='*60}")

        result = pipeline.run(
            question=case["question"],
            age=case["age"],
        )

        print(f"나이대: {result['age_group_label']}")
        print(f"\n[답변]")
        print(result["answer"])
        print(f"\n[참조 문서]")
        for src in result["sources"]:
            print(f"  - {src['law_category']} / {src['doc_type']} (점수: {src['score']})")
            print(f"    {src['preview']}")


if __name__ == "__main__":
    test()