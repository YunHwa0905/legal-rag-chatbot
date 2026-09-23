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
    # ===========================
    MODEL_NAME: str = "yunhwa/legal_chatbot"
    MODEL_LOCAL_PATH: str = "./models/exaone"
    HF_TOKEN: str = ""

    # ===========================
    # HuggingFace 설정
    # ===========================
    HF_MODEL_REPO: str = "yunhwa/legal_chatbot_exaone"
    HF_DATASET_REPO: str = "yunhwa/legal-rag-train"

    # ===========================
    # Ollama 설정
    # ===========================
    OLLAMA_BASE_URL: str = "http://localhost:11434"
    OLLAMA_MODEL: str = "legal-gemma"
    OLLAMA_REWRITE_MODEL: str = "gemma3:1b"

    # ===========================
    # 임베딩 모델 설정
    # ===========================
    EMBEDDING_MODEL: str = "jhgan/ko-sroberta-multitask"
    EMBEDDING_DIMENSION: int = 768

    # cpu / cuda. 질문 1건 임베딩이라 CPU 로도 수십 ms 수준입니다.
    # cuda 로 두더라도 CUDA 를 못 쓰는 환경이면 자동으로 CPU 로 내려갑니다.
    EMBEDDING_DEVICE: str = "cpu"

    # ===========================
    # OpenSearch 설정
    #
    # 비밀번호는 기본값을 두지 않습니다(코드에 박아두면 git 에 남습니다).
    # 환경변수 OPENSEARCH_PASSWORD 로 주입하세요 — .env.example 참고.
    # ===========================
    OPENSEARCH_HOST: str = "localhost"
    OPENSEARCH_PORT: int = 9200
    OPENSEARCH_USER: str = "admin"
    OPENSEARCH_PASSWORD: str = ""
    OPENSEARCH_INDEX: str = "legal_documents"
    OPENSEARCH_USE_SSL: bool = True

    # ===========================
    # CORS 설정
    #
    # 쉼표로 구분된 허용 오리진 목록.
    # 배포 환경에서는 리버스 프록시가 단일 오리진으로 묶고 이 서버는
    # 브라우저가 직접 호출하지 않으므로 빈 값("")으로 끕니다.
    # ===========================
    CORS_ALLOWED_ORIGINS: str = "http://localhost:3000,http://localhost:8080"

    # ===========================
    # RAG 설정
    # ===========================
    RAG_TOP_K: int = 6
    RAG_MIN_SCORE: float = 0.5
    CHUNK_SIZE: int = 512
    CHUNK_OVERLAP: int = 50

    # ===========================
    # 모델 추론 설정
    # ===========================
    MAX_NEW_TOKENS: int = 768
    TEMPERATURE: float = 0.1
    TOP_P: float = 0.9
    DO_SAMPLE: bool = True

    # ===========================
    # 결정적 추론 (이관 전후 동등성 검증용)
    #
    # 같은 질문에 같은 답이 나와야 "옮기기 전후가 같은 서비스"임을 비교할 수
    # 있습니다. 그러려면 두 가지가 필요합니다.
    #
    #   TEMPERATURE=0   샘플링을 끄고 항상 최고 확률 토큰을 고릅니다.
    #   LLM_SEED=<정수> 남은 무작위성의 시작점을 고정합니다.
    #
    # -1 은 "지정 안 함"이며 이때는 seed 를 Ollama 에 아예 넘기지 않습니다
    # (평소 운영에서는 이 기본값을 씁니다).
    #
    # ★ 결정적 설정이어도 GPU 세대가 다르면 부동소수점 연산 순서가 달라져
    #   완전 일치가 보장되지 않습니다. 검색 결과(top-k 문서)는 결정적이라
    #   그쪽이 더 안정적인 비교 지표입니다.
    # ===========================
    LLM_SEED: int = -1

    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"
        # 배포 시 .env 에는 MySQL·JWT 등 다른 서비스용 값도 함께 들어있으므로
        # 여기서 정의하지 않은 키가 있어도 무시합니다.
        extra = "ignore"


@lru_cache()
def get_settings() -> Settings:
    return Settings()


settings = get_settings()