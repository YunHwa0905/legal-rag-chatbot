from pydantic_settings import BaseSettings
from functools import lru_cache


class Settings(BaseSettings):

    # ===========================
    # 서버 설정
    # ===========================
    APP_HOST: str = "0.0.0.0"
    APP_PORT: int = 8000
    APP_ENV: str = "development"

    # ===========================
    # EXAONE 모델 설정
    # 파인튜닝 완료 후: yunhwa/legal_chatbot_exaone 으로 변경
    # ===========================
    MODEL_NAME: str = "LGAI-EXAONE/EXAONE-3.5-7.8B-Instruct"
    MODEL_LOCAL_PATH: str = "./models/exaone"
    HF_TOKEN: str = ""

    # ===========================
    # 임베딩 모델 설정
    # ===========================
    EMBEDDING_MODEL: str = "jhgan/ko-sroberta-multitask"
    EMBEDDING_DIMENSION: int = 768

    # ===========================
    # OpenSearch 설정
    # ===========================
    OPENSEARCH_HOST: str = "localhost"
    OPENSEARCH_PORT: int = 9200
    OPENSEARCH_USER: str = "admin"
    OPENSEARCH_PASSWORD: str = "Legal@Rag2024!"
    OPENSEARCH_INDEX: str = "legal_documents"
    OPENSEARCH_USE_SSL: bool = True

    # ===========================
    # RAG 설정
    # MIN_SCORE: 0.7 → 0.5 (너무 높으면 검색 결과 0건 빈번)
    # TOP_K: 3 → 5 (법률은 관련 조문 여러 개 필요)
    # ===========================
    RAG_TOP_K: int = 5
    RAG_MIN_SCORE: float = 0.5
    CHUNK_SIZE: int = 512
    CHUNK_OVERLAP: int = 50

    # ===========================
    # 모델 추론 설정
    # MAX_NEW_TOKENS: 512 → 768 (법률 설명이 중간에 끊기는 문제 방지)
    # DO_SAMPLE: True (EXAONE은 샘플링이 더 자연스러운 답변 생성)
    # ===========================
    MAX_NEW_TOKENS: int = 768
    TEMPERATURE: float = 0.1
    TOP_P: float = 0.9
    DO_SAMPLE: bool = True

    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"


@lru_cache()
def get_settings() -> Settings:
    return Settings()


settings = get_settings()