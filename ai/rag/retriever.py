"""
RAG 검색 모듈 (개선버전)

변경사항:
- BM25 가중치 0.3 → 0.5
- multi_match 검색으로 품질 향상
- 컨텍스트 300자 → 500자
- min_score 조건 완화
- 문서 제목-질문 매칭 보너스 추가 (제목이 다른데 점수만 높은 문서가 1위로 올라오는 문제 완화)
"""

import re
import sys
import os
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from opensearchpy import OpenSearch
from opensearchpy.exceptions import NotFoundError
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
# 제목-질문 매칭 보너스
#
# 문제: admin-teen 케이스에서 정답 문서(정보공개법 유권해석, 3위 0.9746점)가
# 이미 검색됐는데도, 제목이 다른 법(개인정보 보호법, 1위 1.0점)인 오답 문서가
# 더 높은 점수로 1위에 올라 LLM이 그걸 근거로 답변함. kNN/BM25 점수만으로는
# "제목이 질문의 법률 분야와 실제로 일치하는지"를 반영하지 못해서 생긴 문제.
#
# 문서 본문은 "[법률명 또는 사건명] Q: ... A: ..." 형식으로 시작하므로,
# 이 대괄호 제목과 질문 단어가 얼마나 겹치는지를 점수에 더해 보정한다.
# ===========================
TITLE_MATCH_WEIGHT = 0.6

_PARTICLES = sorted([
    "으로써", "으로서", "이라서", "에서도", "에게서",
    "까지", "부터", "한테", "이나", "이며", "이고",
    "으로", "이라", "이란", "이는", "이가", "이의", "이을", "이를", "이에",
    "은", "는", "이", "가", "을", "를", "도", "의", "에", "로", "과", "와", "만", "랑", "나", "요",
], key=len, reverse=True)


def _extract_title(text: str) -> str:
    """문서 본문 맨 앞 대괄호 제목을 추출: '[개인정보 보호법]\\nQ: ...' → '개인정보 보호법'"""
    match = re.match(r"^\s*\[(.*?)\]", text or "")
    return match.group(1) if match else ""


def _strip_particle(word: str) -> str:
    """'정보공개청구를' → '정보공개청구' 처럼 흔한 조사만 간단히 제거"""
    for particle in _PARTICLES:
        if word.endswith(particle) and len(word) > len(particle) + 1:
            return word[: -len(particle)]
    return word


def _title_match_score(query: str, title: str) -> float:
    """질문 단어(2글자 이상, 조사 제거)가 문서 제목에 그대로 포함된 비율(0~1)"""
    if not title:
        return 0.0
    title_flat = re.sub(r"[^가-힣0-9a-zA-Z]", "", title)
    words = re.findall(r"[가-힣]{2,}", query)
    if not words:
        return 0.0
    hits = sum(1 for w in words if _strip_particle(w) in title_flat and len(_strip_particle(w)) >= 2)
    return hits / len(words)


# ===========================
# 임베딩 디바이스 결정
#
# 배포 이미지는 디스크 절약을 위해 CPU 전용 torch 를 설치합니다(LLM 추론은
# Ollama 컨테이너가 GPU 로 담당). EMBEDDING_DEVICE=cuda 로 설정됐는데 CUDA 를
# 쓸 수 없는 환경이면 여기서 예외가 나 서버가 아예 뜨지 않으므로,
# 조용히 CPU 로 내려가고 경고만 남깁니다.
# ===========================
def _resolve_device(requested: str) -> str:
    device = (requested or "cpu").strip().lower()

    if device.startswith("cuda"):
        try:
            import torch
            if not torch.cuda.is_available():
                print("[WARN] CUDA 를 사용할 수 없어 임베딩을 CPU 로 실행합니다.")
                return "cpu"
        except ImportError:
            print("[WARN] torch 를 불러올 수 없어 임베딩을 CPU 로 실행합니다.")
            return "cpu"

    return device


# ===========================
# Retriever 클래스
# ===========================
class LegalRetriever:

    def __init__(self):
        print("[INFO] 검색 모듈 초기화 중...")
        self.client = get_client()
        self.model = SentenceTransformer(
            settings.EMBEDDING_MODEL,
            device=_resolve_device(settings.EMBEDDING_DEVICE),
        )
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

        # 제목-질문 매칭 보너스: 제목이 질문과 실제로 겹치는 문서를 우선시
        for doc_id in scores:
            title = _extract_title(docs[doc_id].get("text", ""))
            scores[doc_id] += _title_match_score(query_text, title) * TITLE_MATCH_WEIGHT

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
    # 문서 원문 단건 조회 (참고 문서 클릭 시 사용)
    #
    # 색인 시 _id 를 doc_id 로 지정했으므로(loader.py make_action) 검색 없이
    # 바로 get 으로 가져올 수 있음 — 임베딩 계산도 필요 없어 매우 가볍다.
    # ===========================
    def get_by_id(self, doc_id: int) -> dict:
        try:
            hit = self.client.get(index=self.index, id=str(doc_id))
        except NotFoundError:
            return None
        return hit["_source"]

    # ===========================
    # 오염 텍스트 정제
    # ===========================
    def _clean_text(self, text: str) -> str:
        print(f"[DEBUG] clean_text 호출됨, 원본 앞 50자: {text[:50]}")

        
        """Q: 로 시작하는 질문 부분 제거, 오염 패턴 필터링"""
        import re
        # Q: 로 시작하는 줄 제거 (질문 자체가 컨텍스트에 섞이는 문제)
        lines = text.split("\n")
        cleaned = []
        for line in lines:
            line = line.strip()
            # Q: 로 시작하는 줄 제거
            if line.startswith("Q:"):
                continue
            # 오염 패턴 제거
            noise_patterns = [
                "쉽게 설명해주세요", "예시를 들어", "일상생활에서 어떻게",
                "간단히 설명", "쉽고 간단한", "_PAGEVIEW_COUNT_",
            ]
            if any(p in line for p in noise_patterns):
                continue
            cleaned.append(line)
        return "\n".join(cleaned).strip()

    # ===========================
    # 컨텍스트 텍스트 생성
    # ===========================
    def get_context(self, query: str, law_category: str = None) -> str:
        results = self.search(query, law_category)

        if not results:
            return "관련 법률 문서를 찾을 수 없습니다."

        context_parts = []
        for i, doc in enumerate(results, 1):
            # 오염 텍스트 정제 후 500자 제한
            clean = self._clean_text(doc['text'])[:500]
            context_parts.append(
                f"[문서 {i}] ({doc['law_category']} - {doc['doc_type']})\n"
                f"{clean}\n"
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