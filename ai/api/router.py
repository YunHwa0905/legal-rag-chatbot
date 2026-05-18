"""
FastAPI 라우터

엔드포인트:
- POST /chat   → 법률 QA 챗봇 답변
- GET  /health → 서버 상태 확인
"""

import sys
import os
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from fastapi import APIRouter, HTTPException
from api.schemas import ChatRequest, ChatResponse, HealthResponse, SourceDocument
from rag.pipeline import get_pipeline

router = APIRouter()


# ===========================
# Health Check
# ===========================
@router.get("/health", response_model=HealthResponse)
async def health_check():
    return HealthResponse(
        status="ok",
        message="Legal RAG Chatbot API is running"
    )


# ===========================
# 법률 QA 챗봇
# ===========================
@router.post("/chat", response_model=ChatResponse)
async def chat(request: ChatRequest):
    try:
        pipeline = get_pipeline()

        result = pipeline.run(
            question=request.question,
            age=request.age,
            law_category=request.law_category,
        )

        sources = [
            SourceDocument(
                doc_id=src["doc_id"],
                law_category=src["law_category"],
                doc_type=src["doc_type"],
                source=src["source"],
                score=src["score"],
                preview=src["preview"],
            )
            for src in result["sources"]
        ]

        return ChatResponse(
            answer=result["answer"],
            sources=sources,
            age_group_label=result["age_group_label"],
            question=request.question,
            age=request.age,
        )

    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))