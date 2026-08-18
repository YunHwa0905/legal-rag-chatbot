"""
API Request/Response 스키마 정의
"""

from pydantic import BaseModel, Field
from typing import List, Optional


# ===========================
# Request
# ===========================
class ChatRequest(BaseModel):
    question: str = Field(..., description="사용자 질문", min_length=1)
    age: int = Field(..., description="사용자 나이", ge=1, le=120)
    law_category: Optional[str] = Field(
        None,
        description="법률 분야 필터 (민사법/형사법/행정법/지식재산권법)",
    )
    session_id: Optional[str] = Field(None, description="세션 ID")

    class Config:
        json_schema_extra = {
            "example": {
                "question": "계약서에 도장 안 찍으면 어떻게 되나요?",
                "age": 8,
                "law_category": None,
                "session_id": "user_123",
            }
        }


# ===========================
# Response
# ===========================
class SourceDocument(BaseModel):
    doc_id: int
    law_category: str
    doc_type: str
    source: str
    score: float
    preview: str


class ChatResponse(BaseModel):
    answer: str
    sources: List[SourceDocument]
    age_group_label: str
    question: str
    age: int


# ===========================
# 문서 원문 조회 (참고 문서 클릭)
# ===========================
class DocumentDetail(BaseModel):
    doc_id: int
    law_category: str
    doc_type: str
    source: str
    text: str


# ===========================
# Health Check
# ===========================
class HealthResponse(BaseModel):
    status: str
    message: str