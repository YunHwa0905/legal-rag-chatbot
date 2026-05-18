"""
OpenSearch 데이터 적재 스크립트

역할:
- rag_documents.json 읽기
- 임베딩 모델로 텍스트 벡터 변환
- OpenSearch에 bulk 적재
"""

import sys
import os
import json
import time
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from opensearchpy import OpenSearch
from opensearchpy.helpers import bulk
from sentence_transformers import SentenceTransformer
from tqdm import tqdm
from core.config import settings

# ===========================
# 상수
# ===========================
RAG_DOCUMENTS_PATH = "./data/processed/rag_documents.json"
BATCH_SIZE = 64  # 한번에 임베딩할 문서 수


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
# 임베딩 모델 로드
# ===========================
def load_embedding_model() -> SentenceTransformer:
    print(f"[INFO] 임베딩 모델 로드 중: {settings.EMBEDDING_MODEL}")
    model = SentenceTransformer(settings.EMBEDDING_MODEL)
    print(f"[SUCCESS] 임베딩 모델 로드 완료")
    return model


# ===========================
# 문서 데이터 로드
# ===========================
def load_documents(path: str) -> list:
    print(f"[INFO] 문서 로드 중: {path}")
    with open(path, "r", encoding="utf-8") as f:
        documents = json.load(f)
    print(f"[SUCCESS] {len(documents):,}개 문서 로드 완료")
    return documents


# ===========================
# 텍스트 전처리
# ===========================
def preprocess_text(text: str) -> str:
    if not text:
        return ""
    # 너무 긴 텍스트는 자르기 (임베딩 모델 최대 토큰 제한)
    return text[:512]


# ===========================
# 배치 임베딩
# ===========================
def embed_batch(model: SentenceTransformer, texts: list) -> list:
    embeddings = model.encode(
        texts,
        batch_size=BATCH_SIZE,
        show_progress_bar=False,
        normalize_embeddings=True,  # 코사인 유사도 최적화
    )
    return embeddings.tolist()


# ===========================
# OpenSearch bulk 적재용 액션 생성
# ===========================
def make_action(doc: dict, embedding: list) -> dict:
    return {
        "_index": settings.OPENSEARCH_INDEX,
        "_id": doc["doc_id"],
        "_source": {
            "doc_id": doc["doc_id"],
            "text": doc["text"],
            "embedding": embedding,
            "law_category": doc.get("law_category", ""),
            "doc_type": doc.get("doc_type", ""),
            "source": doc.get("source", ""),
        }
    }


# ===========================
# 메인 적재 함수
# ===========================
def run():
    print("=" * 50)
    print("OpenSearch 데이터 적재 시작")
    print("=" * 50)

    # 1. 클라이언트 연결
    client = get_client()
    try:
        info = client.info()
        print(f"\n[연결 성공] OpenSearch {info['version']['number']}")
    except Exception as e:
        print(f"[연결 실패] {e}")
        return

    # 2. 인덱스 존재 확인
    if not client.indices.exists(index=settings.OPENSEARCH_INDEX):
        print(f"[ERROR] 인덱스 '{settings.OPENSEARCH_INDEX}' 없음")
        print("index_builder.py 먼저 실행하세요.")
        return

    # 3. 임베딩 모델 로드
    model = load_embedding_model()

    # 4. 문서 로드
    documents = load_documents(RAG_DOCUMENTS_PATH)

    # 5. 배치 처리 & 적재
    total = len(documents)
    success_count = 0
    error_count = 0

    print(f"\n[INFO] 총 {total:,}개 문서 적재 시작 (배치 크기: {BATCH_SIZE})")
    start_time = time.time()

    for i in tqdm(range(0, total, BATCH_SIZE), desc="적재 중"):
        batch_docs = documents[i:i + BATCH_SIZE]

        # 텍스트 추출 & 전처리
        texts = [preprocess_text(doc["text"]) for doc in batch_docs]

        # 빈 텍스트 필터링
        valid_indices = [j for j, t in enumerate(texts) if t.strip()]
        if not valid_indices:
            continue

        valid_texts = [texts[j] for j in valid_indices]
        valid_docs = [batch_docs[j] for j in valid_indices]

        try:
            # 임베딩 생성
            embeddings = embed_batch(model, valid_texts)

            # bulk 액션 생성
            actions = [
                make_action(doc, emb)
                for doc, emb in zip(valid_docs, embeddings)
            ]

            # OpenSearch bulk 적재
            success, errors = bulk(
                client,
                actions,
                raise_on_error=False,
                request_timeout=60,
            )
            success_count += success
            error_count += len(errors) if errors else 0

        except Exception as e:
            print(f"\n[ERROR] 배치 {i}~{i+BATCH_SIZE} 처리 중 오류: {e}")
            error_count += len(valid_docs)

    # 6. 결과 출력
    elapsed = round(time.time() - start_time, 1)
    print("\n" + "=" * 50)
    print("적재 완료")
    print("=" * 50)
    print(f"성공      : {success_count:,}개")
    print(f"실패      : {error_count:,}개")
    print(f"소요 시간 : {elapsed}초")

    # 7. 최종 문서 수 확인
    time.sleep(2)  # OpenSearch 인덱싱 대기
    count = client.count(index=settings.OPENSEARCH_INDEX)
    print(f"인덱스 내 총 문서 수: {count['count']:,}개")


if __name__ == "__main__":
    run()