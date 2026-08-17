"""
최소 RAG 평가 스크립트

사용법:
    cd ai
    python eval/run_eval.py

자동으로 측정되는 것 (검색 품질):
    - category_match_rate : 검색된 문서의 law_category가 질문의 기대 분야와 일치하는 비율
        주의: law_category는 주제(민사/형사/행정/지식재산권)가 아니라 사건 진행 절차
        기준으로 태깅되어 있어(예: 상표법 위반=형사법, 특허 권리범위확인 항고=행정법),
        내용상 검색이 정확해도 이 지표는 낮게 나올 수 있음. 참고용 신호일 뿐 정답 지표 아님.
    - avg_retrieval_score : 하이브리드 검색 점수 평균 (쿼리별 자체 최고점 대비 정규화라 절대 품질 지표 아님)
    - latency_sec         : 질문당 응답 시간
    - unverified_citations : 답변에 나온 "OO법 제N조" 인용 중 컨텍스트에서 확인 안 되는 것
        (rag/citation.py로 자동 검증. 16건 평가에서 가장 자주 나온 환각 유형이라 자동화함)

자동으로 측정되지 않는 것 (results/*.json에 answer로 남겨두고 사람이 채점):
    - 답변의 사실 정확성
    - 나이대에 맞는 말투/난이도 준수 여부
    - (조문 번호가 아닌 형태의) 환각 — 절차명 오적용, 다른 법 혼동 등
"""

import sys
import os
import json
import time
from datetime import datetime

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from rag.pipeline import get_pipeline

EVAL_SET_PATH = os.path.join(os.path.dirname(__file__), "eval_set.json")
RESULTS_DIR = os.path.join(os.path.dirname(__file__), "results")


def run():
    with open(EVAL_SET_PATH, encoding="utf-8") as f:
        cases = json.load(f)

    pipeline = get_pipeline()
    results = []

    os.makedirs(RESULTS_DIR, exist_ok=True)
    out_path = os.path.join(
        RESULTS_DIR, f"eval_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
    )

    for case in cases:
        print(f"\n[{case['id']}] {case['question']} (age={case['age']})")

        start = time.time()
        result = pipeline.run(question=case["question"], age=case["age"])
        elapsed = round(time.time() - start, 2)

        sources = result["sources"]
        category_hits = sum(
            1 for s in sources if case["expected_category"] in s["law_category"]
        )
        category_match_rate = (category_hits / len(sources)) if sources else 0.0
        avg_score = (sum(s["score"] for s in sources) / len(sources)) if sources else 0.0

        citation_check = result.get("citation_check", {"citations": [], "unverified": []})

        record = {
            "id": case["id"],
            "question": case["question"],
            "age": case["age"],
            "expected_category": case["expected_category"],
            "age_group_label": result["age_group_label"],
            "answer": result["answer"],
            "num_sources": len(sources),
            "category_match_rate": round(category_match_rate, 2),
            "avg_retrieval_score": round(avg_score, 4),
            "latency_sec": elapsed,
            "citations": citation_check["citations"],
            "unverified_citations": citation_check["unverified"],
            "sources": sources,
            # 사람이 채점해서 채워 넣는 칸 (1~5점 또는 pass/fail)
            "manual_score": {
                "factual_correctness": None,
                "age_appropriate_tone": None,
                "hallucination_free": None,
            },
        }
        results.append(record)

        flag = f" [미검증 인용 {len(citation_check['unverified'])}건]" if citation_check["unverified"] else ""
        print(f"  검색결과 {len(sources)}건 / 분야일치율 {record['category_match_rate']:.0%} / {elapsed}s{flag}")

        # 중간 저장 — 도중에 죽어도 여기까지는 남음
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump(results, f, ensure_ascii=False, indent=2)

    n = len(results)
    unverified_cases = [r for r in results if r["unverified_citations"]]
    print(f"\n{'=' * 50}")
    print(f"총 {n}건 평가 완료 → {out_path}")
    print(f"평균 분야일치율: {sum(r['category_match_rate'] for r in results) / n:.0%}")
    print(f"평균 검색점수:   {sum(r['avg_retrieval_score'] for r in results) / n:.4f}")
    print(f"평균 응답시간:   {sum(r['latency_sec'] for r in results) / n:.1f}s")
    print(f"미검증 인용:     {len(unverified_cases)}/{n}건에서 발견")
    for r in unverified_cases:
        print(f"  - [{r['id']}] {', '.join(r['unverified_citations'])}")
    print(f"{'=' * 50}")
    print("→ 결과 파일의 manual_score 항목을 채워서 나머지 답변 품질을 사람이 채점하세요.")


if __name__ == "__main__":
    run()
