"""
FastAPI 라우터

엔드포인트:
- POST /chat                    → 법률 QA 챗봇 답변
- GET  /health                  → 서버 상태 확인
- GET  /documents/{doc_id}      → 참조 문서 원문 조회
- POST /summary/update          → 대화 롤링 요약 갱신(Spring이 비동기로 호출)
"""

import sys
import os
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from fastapi import APIRouter, HTTPException
from api.schemas import (
    ChatRequest, ChatResponse, HealthResponse, SourceDocument, DocumentDetail,
    SummaryUpdateRequest, SummaryUpdateResponse,
)
from rag.pipeline import get_pipeline
from rag.summarize import update_summary

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

        history = [{"role": h.role, "content": h.content} for h in request.history]
        result = pipeline.run(
            question=request.question,
            age=request.age,
            law_category=request.law_category,
            history=history,
            summary=request.summary,
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
            standalone_query=result.get("standalone_query"),
            rewrite_applied=result.get("rewrite_applied", False),
        )

    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ===========================
# 참고 문서 원문 조회
# ===========================
@router.get("/documents/{doc_id}", response_model=DocumentDetail)
async def get_document(doc_id: int):
    pipeline = get_pipeline()
    doc = pipeline.retriever.get_by_id(doc_id)

    if doc is None:
        raise HTTPException(status_code=404, detail="문서를 찾을 수 없습니다.")

    return DocumentDetail(
        doc_id=doc_id,
        law_category=doc.get("law_category", ""),
        doc_type=doc.get("doc_type", ""),
        source=doc.get("source", ""),
        text=doc.get("text", ""),
    )


# ===========================
# 대화 요약 갱신 (Spring @Async 전용, 무상태 순수 함수)
# ===========================
@router.post("/summary/update", response_model=SummaryUpdateResponse)
async def update_summary_endpoint(request: SummaryUpdateRequest):
    try:
        turns = [{"role": t.role, "content": t.content} for t in request.turns_to_fold]
        summary = update_summary(request.prev_summary, turns)
        return SummaryUpdateResponse(
            summary=summary,
            through_message_id=request.through_message_id,
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))