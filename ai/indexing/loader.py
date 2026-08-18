"""
OpenSearch 데이터 적재 스크립트

역할:
- rag_documents.json 읽기 (ijson 스트리밍 — 253,207건을 한 번에 메모리에 올리지 않음)
- 임베딩 모델로 텍스트 벡터 변환
- OpenSearch에 bulk 적재

메모리 노트:
    처음엔 json.load() 로 파일 전체(1.9GB)를 리스트로 올렸는데, RAM 16GB 서버에서
    OpenSearch·Ollama 등 다른 컨테이너와 같이 뜬 상태로는 5~8GB까지 치솟다가
    OOM killer 에 죽었습니다(스왑 4GB를 붙여도 마찬가지). ijson 으로 문서 단위
    스트리밍 + 배치(BATCH_SIZE)만큼만 들고 처리하도록 바꿔서 항상 메모리에는
    배치 하나 분량만 남도록 했습니다.
"""

import sys
import os
import time
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import ijson
from opensearchpy import OpenSearch
from opensearchpy.helpers import bulk
from sentence_transformers import SentenceTransformer
from tqdm import tqdm
from core.config import settings
from rag.retriever import _resolve_device

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
    device = _resolve_device(settings.EMBEDDING_DEVICE)
    print(f"[INFO] 임베딩 모델 로드 중: {settings.EMBEDDING_MODEL} (device={device})")
    model = SentenceTransformer(settings.EMBEDDING_MODEL, device=device)
    print(f"[SUCCESS] 임베딩 모델 로드 완료")
    return model


# ===========================
# 문서 데이터 스트리밍 로드
# ===========================
def iter_documents(path: str):
    """파일 전체를 리스트로 올리지 않고, 문서를 하나씩 스트리밍으로 yield"""
    with open(path, "rb") as f:
        yield from ijson.items(f, "item")


def count_documents(path: str) -> int:
    """진행률 표시용 총 개수 — 값만 세므로 메모리에 거의 안 남음"""
    print(f"[INFO] 문서 수 확인 중: {path}")
    count = sum(1 for _ in iter_documents(path))
    print(f"[SUCCESS] {count:,}개 문서 확인됨")
    return count


def batched(iterable, batch_size: int):
    """이터레이터를 batch_size 크기 리스트로 묶어서 순서대로 yield"""
    batch = []
    for item in iterable:
        batch.append(item)
        if len(batch) == batch_size:
            yield batch
            batch = []
    if batch:
        yield batch


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

    # 4. 문서 개수 확인 (진행률 표시용, 스트리밍이라 메모리엔 안 쌓임)
    total = count_documents(RAG_DOCUMENTS_PATH)
    total_batches = (total + BATCH_SIZE - 1) // BATCH_SIZE

    # 5. 배치 처리 & 적재 — 문서는 배치 단위로만 메모리에 올라옴
    success_count = 0
    error_count = 0

    print(f"\n[INFO] 총 {total:,}개 문서 적재 시작 (배치 크기: {BATCH_SIZE})")
    start_time = time.time()

    for batch_docs in tqdm(
        batched(iter_documents(RAG_DOCUMENTS_PATH), BATCH_SIZE),
        total=total_batches,
        desc="적재 중",
    ):
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
            first_id = valid_docs[0].get("doc_id", "?")
            last_id = valid_docs[-1].get("doc_id", "?")
            print(f"\n[ERROR] 배치(doc_id {first_id}~{last_id}) 처리 중 오류: {e}")
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