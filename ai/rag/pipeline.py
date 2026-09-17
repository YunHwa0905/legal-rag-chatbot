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
from rag.citation import verify_citations
import rag.rewrite as rewrite
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
        history: list = None,
        summary: str = None,
    ) -> dict:
        """
        Args:
            question: 사용자 질문
            age: 사용자 나이
            law_category: 법률 분야 필터 (선택)
            history: 최근 대화 이력 [{"role": "user"|"assistant", "content": str}, ...] (선택)
            summary: 이전 대화 롤링 요약 (선택)

        Returns:
            {
                "answer": 생성된 답변 (미검증 인용이 있으면 경고 문구 추가됨),
                "sources": 참조 문서 목록,
                "age_group_label": 나이대 레이블,
                "context": 검색된 컨텍스트,
                "citation_check": {"citations": [...], "unverified": [...]},
                "standalone_query": 재작성된 질문 (재작성 안 했으면 None),
                "rewrite_applied": 재작성이 실행됐는지 여부
            }
        """
        history = history or []

        # ===========================
        # Step 1. 질문 재작성 게이트 + (필요 시) 재작성
        # ===========================
        rewrite_applied = rewrite.needs_rewrite(question, history)
        standalone_query = None
        if rewrite_applied:
            # 재작성 모델(OLLAMA_REWRITE_MODEL) 호출은 이 엔드포인트에 새로 추가된
            # 두 번째 LLM 의존성이다. 이게 실패한다고 답변 자체가 막히면 안 된다 —
            # 실패 시 원본 질문 단일 채널로 조용히 저하시킨다(단일턴과 동일 동작).
            try:
                standalone_query = rewrite.rewrite_query(question, history, summary)
                print(f"[INFO] 질문 재작성: '{question}' → '{standalone_query}'")
            except Exception as e:
                print(f"[WARN] 질문 재작성 실패 — 원본 질문으로 진행: {e}")
                rewrite_applied, standalone_query = False, None

        # ===========================
        # Step 2. 이중 채널 검색 (재작성 안 했으면 원본 질문 하나로만 — 기존과 동일)
        # ===========================
        queries = [question, standalone_query] if rewrite_applied else [question]
        print(f"[INFO] 검색 중: {question[:30]}...")
        results = self.retriever.search_multi(queries, law_category)

        if not results:
            return {
                "answer": "관련 법률 문서를 찾을 수 없습니다. 질문을 다시 입력해주세요.",
                "sources": [],
                "age_group_label": "",
                "context": "",
                "citation_check": {"citations": [], "unverified": []},
                "standalone_query": standalone_query,
                "rewrite_applied": rewrite_applied,
            }

        context = self.retriever.format_context(results)

        # ===========================
        # Step 3. 나이대별 프롬프트 구성 (요약·이력 포함, 하드 캡 적용)
        # ===========================
        prompt = build_prompt(
            question=question,
            context=context,
            age=age,
            summary=summary,
            history=history,
        )

        # ===========================
        # Step 4. LLM 추론
        # ===========================
        print(f"[INFO] 답변 생성 중... (나이대: {prompt['age_group_label']})")
        answer = generate(
            system_prompt=prompt["system"],
            user_message=prompt["user"],
        )

        # ===========================
        # Step 5. 인용 조문 검증
        #
        # 컨텍스트에 없는 "OO법 제N조" 인용은 모델이 지어냈을 가능성이 높음
        # (eval에서 반복 확인된 환각 패턴). 못 찾은 인용이 있으면 답변에
        # 경고를 덧붙인다 — 문장을 손대지 않고 뒤에 붙이는 방식이라
        # 답변 자체의 문맥은 그대로 유지된다.
        # ===========================
        citation_check = verify_citations(answer, context)
        if citation_check["unverified"]:
            print(f"[WARN] 미검증 인용 발견: {citation_check['unverified']}")
            answer += (
                "\n\n[알림] 위 답변에 포함된 다음 인용은 제공된 문서에서 확인되지 않았습니다: "
                + ", ".join(citation_check["unverified"])
                + ". 실제 적용 전 원문을 반드시 확인하세요."
            )

        # ===========================
        # Step 6. 출처 정리
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
            "citation_check": citation_check,
            "standalone_query": standalone_query,
            "rewrite_applied": rewrite_applied,
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
        print(f"재작성 적용: {result['rewrite_applied']}")
        print(f"\n[답변]")
        print(result["answer"])
        print(f"\n[참조 문서]")
        for src in result["sources"]:
            print(f"  - {src['law_category']} / {src['doc_type']} (점수: {src['score']})")
            print(f"    {src['preview']}")

    # --- 멀티턴: 재작성 게이트가 실제로 걸리는 케이스 ---
    print(f"\n{'='*60}")
    print("멀티턴 케이스 — 재작성 동작 확인")
    print(f"{'='*60}")
    history = [
        {"role": "user", "content": "전세 계약 갱신을 거부당했어요"},
        {"role": "assistant", "content": "임대인은 정당한 사유 없이 갱신을 거부할 수 없습니다."},
    ]
    result = pipeline.run(
        question="그럼 계약금은 어떻게 되나요?",
        age=28,
        history=history,
    )
    print(f"재작성 적용: {result['rewrite_applied']}")
    print(f"재작성된 질문: {result['standalone_query']}")
    print(f"\n[답변]\n{result['answer']}")


if __name__ == "__main__":
    test()