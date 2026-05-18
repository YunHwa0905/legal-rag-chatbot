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
    # Gemma 모델 설정
    # ===========================
    MODEL_NAME: str = "yunhwa/legal_chatbot"
    MODEL_LOCAL_PATH: str = "./models/gemma"
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
    OPENSEARCH_PASSWORD: str = "admin"
    OPENSEARCH_INDEX: str = "legal_documents"
    OPENSEARCH_USE_SSL: bool = False

    # ===========================
    # RAG 설정
    # ===========================
    RAG_TOP_K: int = 3
    RAG_MIN_SCORE: float = 0.7
    CHUNK_SIZE: int = 512
    CHUNK_OVERLAP: int = 50

    # ===========================
    # 모델 추론 설정
    # ===========================
    MAX_NEW_TOKENS: int = 512
    TEMPERATURE: float = 0.1
    TOP_P: float = 0.9
    DO_SAMPLE: bool = True

    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"


@lru_cache()
def get_settings() -> Settings:
    return Settings()


# 전역에서 바로 import해서 쓸 수 있게
settings = get_settings()