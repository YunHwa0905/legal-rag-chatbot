"""
RAG 검색 모듈

역할:
- 사용자 질문을 벡터로 변환
- OpenSearch에서 유사 문서 검색 (kNN + BM25 하이브리드)
- 검색 결과 반환
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

        # 법률 분야 필터 (선택)
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
    # BM25 키워드 검색
    # ===========================
    def _bm25_search(self, query_text: str, law_category: str = None) -> list:
        query = {
            "size": self.top_k,
            "query": {
                "match": {
                    "text": {
                        "query": query_text,
                        "operator": "or",
                    }
                }
            },
            "_source": ["doc_id", "text", "law_category", "doc_type", "source"]
        }

        # 법률 분야 필터 (선택)
        if law_category:
            query["query"] = {
                "bool": {
                    "must": [{"match": {"text": {"query": query_text}}}],
                    "filter": [{"term": {"law_category": law_category}}]
                }
            }

        response = self.client.search(index=self.index, body=query)
        return response["hits"]["hits"]

    # ===========================
    # 하이브리드 검색 (kNN + BM25)
    # 중복 제거 후 점수 합산
    # ===========================
    def _hybrid_search(self, query_text: str, query_vector: list, law_category: str = None) -> list:
        knn_results = self._knn_search(query_vector, law_category)
        bm25_results = self._bm25_search(query_text, law_category)

        # doc_id 기준으로 합산
        scores = {}
        docs = {}

        for hit in knn_results:
            doc_id = hit["_source"]["doc_id"]
            scores[doc_id] = scores.get(doc_id, 0) + hit["_score"]
            docs[doc_id] = hit["_source"]

        for hit in bm25_results:
            doc_id = hit["_source"]["doc_id"]
            scores[doc_id] = scores.get(doc_id, 0) + hit["_score"] * 0.3  # BM25 가중치
            docs[doc_id] = hit["_source"]

        # 점수 기준 정렬
        sorted_docs = sorted(scores.items(), key=lambda x: x[1], reverse=True)

        # top_k 반환
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
        """
        Args:
            query: 사용자 질문
            law_category: 법률 분야 필터 (민사법/형사법/행정법/지식재산권법)

        Returns:
            검색된 문서 리스트
        """
        # 질문 임베딩
        query_vector = self._embed_query(query)

        # 하이브리드 검색
        results = self._hybrid_search(query, query_vector, law_category)

        return results

    # ===========================
    # 컨텍스트 텍스트 생성 (LLM 프롬프트용)
    # ===========================
    def get_context(self, query: str, law_category: str = None) -> str:
        """
        검색 결과를 LLM 프롬프트에 넣을 텍스트로 변환
        """
        results = self.search(query, law_category)

        if not results:
            return "관련 법률 문서를 찾을 수 없습니다."

        context_parts = []
        for i, doc in enumerate(results, 1):
            context_parts.append(
                f"[문서 {i}] ({doc['law_category']} - {doc['doc_type']})\n"
                f"{doc['text']}\n"
                f"출처: {doc['source']}"
            )

        return "\n\n".join(context_parts)


# ===========================
# 테스트
# ===========================
def test():
    retriever = LegalRetriever()

    test_queries = [
        "계약 해지하려면 어떻게 해야 하나요?",
        "상표권 침해 판단 기준은 무엇인가요?",
        "임의동행 요청 시 경찰관이 해야 할 절차는?",
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

        print(f"\n[컨텍스트 미리보기]")
        context = retriever.get_context(query)
        print(context[:300] + "...")


if __name__ == "__main__":
    test()