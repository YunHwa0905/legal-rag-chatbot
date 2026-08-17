"""
FastAPI 앱 진입점

실행:
    python main.py
    또는
    uvicorn main:app --host 0.0.0.0 --port 8000 --reload
"""

import sys
import os
sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from contextlib import asynccontextmanager

from api.router import router
from core.config import settings


# ===========================
# 앱 시작 시 파이프라인 초기화
# ===========================
@asynccontextmanager
async def lifespan(app: FastAPI):
    print("[INFO] 서버 시작 중...")
    from rag.pipeline import get_pipeline
    get_pipeline()   # 모델 미리 로드
    print("[SUCCESS] 서버 준비 완료")
    yield
    print("[INFO] 서버 종료")


# ===========================
# FastAPI 앱 생성
# ===========================
app = FastAPI(
    title="Legal RAG Chatbot API",
    description="나이대별 맞춤 법률 QA 챗봇",
    version="1.0.0",
    lifespan=lifespan,
)


# ===========================
# CORS 설정
#
# 허용 오리진은 환경변수 CORS_ALLOWED_ORIGINS (쉼표 구분) 로 지정합니다.
# 배포 환경에서는 이 서버를 브라우저가 직접 호출하지 않고 Spring 이
# 서버 사이드로 호출하므로 빈 값으로 두어 미들웨어를 끕니다.
# ===========================
allowed_origins = [
    origin.strip()
    for origin in settings.CORS_ALLOWED_ORIGINS.split(",")
    if origin.strip()
]

if allowed_origins:
    print(f"[INFO] CORS 허용 오리진: {allowed_origins}")
    app.add_middleware(
        CORSMiddleware,
        allow_origins=allowed_origins,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )
else:
    print("[INFO] CORS 비활성화 (동일 오리진 프록시 구성)")


# ===========================
# 라우터 등록
# ===========================
app.include_router(router, prefix="/api/v1")


# ===========================
# 직접 실행
# ===========================
if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "main:app",
        host=settings.APP_HOST,
        port=settings.APP_PORT,
        reload=False,
    )