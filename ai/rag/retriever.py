"""
RAG 검색 모듈 (개선버전)

변경사항:
- BM25 가중치 0.3 → 0.5
- multi_match 검색으로 품질 향상
- 컨텍스트 300자 → 500자
- min_score 조건 완화
"""

import sys
import os
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from opensearchpy import OpenSearch
from sentence_transformers import SentenceTransformer
from core.config import settings


# ===========================
# OpenSearch 클라이언트
# ===========================
def get_client() -> OpenSearch:
    return OpenSearch(
        hosts=[{
            "host": settings.OPENSEARCH_HOST,
            "port": settings.OPENSEARCH_PORT,
        }],
        http_auth=(settings.OPENSEARCH_USER, settings.OPENSEARCH_PASSWORD),
        use_ssl=settings.OPENSEARCH_USE_SSL,
        verify_certs=False,
        ssl_show_warn=False,
    )


# ===========================
# Retriever 클래스
# ===========================
class LegalRetriever:

    def __init__(self):
        print("[INFO] 검색 모듈 초기화 중...")
        self.client = get_client()
        self.model = SentenceTransformer(settings.EMBEDDING_MODEL)
        self.index = settings.OPENSEARCH_INDEX
        self.top_k = settings.RAG_TOP_K
        self.min_score = settings.RAG_MIN_SCORE
        print("[SUCCESS] 검색 모듈 초기화 완료")

    # ===========================
    # 질문 임베딩
    # ===========================
    def _embed_query(self, query: str) -> list:
        embedding = self.model.encode(
            query,
            normalize_embeddings=True,
        )
        return embedding.tolist()

    # ===========================
    # kNN 벡터 검색
    # ===========================
    def _knn_search(self, query_vector: list, law_category: str = None) -> list:
        query = {
            "size": self.top_k,
            "query": {
                "knn": {
                    "embedding": {
                        "vector": query_vector,
                        "k": self.top_k,
                    }
                }
            },
            "_source": ["doc_id", "text", "law_category", "doc_type", "source"]
        }

        if law_category:
            query["query"] = {
                "bool": {
                    "must": [
                        {"knn": {"embedding": {"vector": query_vector, "k": self.top_k}}}
                    ],
                    "filter": [
                        {"term": {"law_category": law_category}}
                    ]
                }
            }

        response = self.client.search(index=self.index, body=query)
        return response["hits"]["hits"]

    # ===========================
    # BM25 키워드 검색 (multi_match로 개선)
    # ===========================
    def _bm25_search(self, query_text: str, law_category: str = None) -> list:
        # multi_match: text + source 필드 동시 검색
        must_query = {
            "multi_match": {
                "query": query_text,
                "fields": ["text^2", "source"],  # text 가중치 2배
                "type": "best_fields",
                "operator": "or",
                "minimum_should_match": "30%"     # 30% 이상 단어 매칭
            }
        }

        query = {
            "size": self.top_k,
            "query": must_query if not law_category else {
                "bool": {
                    "must": [must_query],
                    "filter": [{"term": {"law_category": law_category}}]
                }
            },
            "_source": ["doc_id", "text", "law_category", "doc_type", "source"]
        }

        response = self.client.search(index=self.index, body=query)
        return response["hits"]["hits"]

    # ===========================
    # 하이브리드 검색 (kNN + BM25)
    # BM25 가중치 0.3 → 0.5로 상향
    # ===========================
    def _hybrid_search(self, query_text: str, query_vector: list, law_category: str = None) -> list:
        knn_results = self._knn_search(query_vector, law_category)
        bm25_results = self._bm25_search(query_text, law_category)

        scores = {}
        docs = {}

        # kNN 점수 정규화 후 합산
        knn_max = max((h["_score"] for h in knn_results), default=1)
        for hit in knn_results:
            doc_id = hit["_source"]["doc_id"]
            normalized = hit["_score"] / knn_max if knn_max > 0 else 0
            scores[doc_id] = scores.get(doc_id, 0) + normalized
            docs[doc_id] = hit["_source"]

        # BM25 점수 정규화 후 합산 (가중치 0.5)
        bm25_max = max((h["_score"] for h in bm25_results), default=1)
        for hit in bm25_results:
            doc_id = hit["_source"]["doc_id"]
            normalized = hit["_score"] / bm25_max if bm25_max > 0 else 0
            scores[doc_id] = scores.get(doc_id, 0) + normalized * 0.5
            docs[doc_id] = hit["_source"]

        # 점수 기준 정렬
        sorted_docs = sorted(scores.items(), key=lambda x: x[1], reverse=True)

        results = []
        for doc_id, score in sorted_docs[:self.top_k]:
            if score >= self.min_score:
                results.append({
                    "doc_id": doc_id,
                    "score": round(score, 4),
                    "text": docs[doc_id]["text"],
                    "law_category": docs[doc_id].get("law_category", ""),
                    "doc_type": docs[doc_id].get("doc_type", ""),
                    "source": docs[doc_id].get("source", ""),
                })

        return results

    # ===========================
    # 메인 검색 함수
    # ===========================
    def search(self, query: str, law_category: str = None) -> list:
        query_vector = self._embed_query(query)
        results = self._hybrid_search(query, query_vector, law_category)
        return results

    # ===========================
    # 컨텍스트 텍스트 생성 (300자 → 500자)
    # ===========================
    def get_context(self, query: str, law_category: str = None) -> str:
        results = self.search(query, law_category)

        if not results:
            return "관련 법률 문서를 찾을 수 없습니다."

        context_parts = []
        for i, doc in enumerate(results, 1):
            context_parts.append(
                f"[문서 {i}] ({doc['law_category']} - {doc['doc_type']})\n"
                f"{doc['text'][:500]}\n"
                f"출처: {doc['source']}"
            )

        return "\n\n".join(context_parts)


# ===========================
# 테스트
# ===========================
def test():
    retriever = LegalRetriever()

    test_queries = [
        "가압류가 무엇인가요?",
        "민사소송은 어떻게 시작하나요?",
        "임의동행 거부할 수 있나요?",
    ]

    for query in test_queries:
        print(f"\n{'='*50}")
        print(f"질문: {query}")
        print(f"{'='*50}")

        results = retriever.search(query)

        if not results:
            print("검색 결과 없음")
            continue

        for i, doc in enumerate(results, 1):
            print(f"\n[결과 {i}] 점수: {doc['score']}")
            print(f"분야: {doc['law_category']} / 유형: {doc['doc_type']}")
            print(f"내용: {doc['text'][:150]}...")


if __name__ == "__main__":
    test()