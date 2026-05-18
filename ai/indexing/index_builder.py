"""
OpenSearch 인덱스 생성 스크립트

역할:
- 법률 문서 인덱스 생성 (벡터 + BM25 하이브리드)
- 인덱스 삭제/재생성
- 인덱스 상태 확인
"""

import sys
import os
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from opensearchpy import OpenSearch
from core.config import settings

# ===========================
# OpenSearch 클라이언트 생성
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
# 인덱스 매핑 정의
# ===========================
INDEX_MAPPING = {
    "settings": {
        "index": {
            "knn": True,                  # 벡터 검색 활성화
            "knn.algo_param.ef_search": 100,
        },
        "analysis": {
            "analyzer": {
                "korean_analyzer": {
                    "type": "custom",
                    "tokenizer": "standard",  # 한국어 플러그인 없으면 standard 사용
                    "filter": ["lowercase"]
                }
            }
        }
    },
    "mappings": {
        "properties": {
            # ===========================
            # 벡터 필드 (kNN 검색용)
            # ===========================
            "embedding": {
                "type": "knn_vector",
                "dimension": settings.EMBEDDING_DIMENSION,  # 768
                "method": {
                    "name": "hnsw",
                    "space_type": "cosinesimil",   # 코사인 유사도
                    "engine": "nmslib",
                    "parameters": {
                        "ef_construction": 128,
                        "m": 24
                    }
                }
            },

            # ===========================
            # 텍스트 필드 (BM25 키워드 검색용)
            # ===========================
            "text": {
                "type": "text",
                "analyzer": "korean_analyzer",
            },

            # ===========================
            # 메타데이터 필드 (필터 검색용)
            # ===========================
            "doc_id": {
                "type": "integer"
            },
            "law_category": {
                "type": "keyword"    # 민사법, 형사법, 행정법, 지식재산권법
            },
            "doc_type": {
                "type": "keyword"    # 법령, 판결문, 유권해석, 결정례
            },
            "source": {
                "type": "keyword"    # 원본 파일명
            },
        }
    }
}


# ===========================
# 인덱스 생성
# ===========================
def create_index(client: OpenSearch, index_name: str) -> bool:
    try:
        # 이미 존재하면 스킵
        if client.indices.exists(index=index_name):
            print(f"[INFO] 인덱스 '{index_name}' 이미 존재함")
            return True

        response = client.indices.create(
            index=index_name,
            body=INDEX_MAPPING
        )

        if response.get("acknowledged"):
            print(f"[SUCCESS] 인덱스 '{index_name}' 생성 완료")
            return True
        else:
            print(f"[ERROR] 인덱스 생성 실패: {response}")
            return False

    except Exception as e:
        print(f"[ERROR] 인덱스 생성 중 오류: {e}")
        return False


# ===========================
# 인덱스 삭제
# ===========================
def delete_index(client: OpenSearch, index_name: str) -> bool:
    try:
        if not client.indices.exists(index=index_name):
            print(f"[INFO] 인덱스 '{index_name}' 존재하지 않음")
            return True

        response = client.indices.delete(index=index_name)
        if response.get("acknowledged"):
            print(f"[SUCCESS] 인덱스 '{index_name}' 삭제 완료")
            return True
        return False

    except Exception as e:
        print(f"[ERROR] 인덱스 삭제 중 오류: {e}")
        return False


# ===========================
# 인덱스 상태 확인
# ===========================
def check_index(client: OpenSearch, index_name: str):
    try:
        if not client.indices.exists(index=index_name):
            print(f"[INFO] 인덱스 '{index_name}' 존재하지 않음")
            return

        # 문서 수 확인
        count = client.count(index=index_name)
        doc_count = count.get("count", 0)

        # 인덱스 정보 확인
        stats = client.indices.stats(index=index_name)
        index_stats = stats["indices"][index_name]["total"]
        store_size = index_stats["store"]["size_in_bytes"]
        size_mb = round(store_size / 1024 / 1024, 2)

        print(f"\n[인덱스 상태: {index_name}]")
        print(f"  문서 수  : {doc_count:,}개")
        print(f"  용량     : {size_mb} MB")

    except Exception as e:
        print(f"[ERROR] 인덱스 상태 확인 중 오류: {e}")


# ===========================
# 메인
# ===========================
def run():
    print("=" * 50)
    print("OpenSearch 인덱스 설정")
    print("=" * 50)

    # 클라이언트 연결
    client = get_client()

    # 연결 확인
    try:
        info = client.info()
        print(f"\n[연결 성공] OpenSearch {info['version']['number']}")
    except Exception as e:
        print(f"[연결 실패] {e}")
        print("OpenSearch가 실행 중인지 확인하세요.")
        return

    index_name = settings.OPENSEARCH_INDEX  # legal_documents

    # 인덱스 생성
    create_index(client, index_name)

    # 상태 확인
    check_index(client, index_name)

    print("\n완료. 다음 단계: indexing/loader.py 실행")


if __name__ == "__main__":
    run()