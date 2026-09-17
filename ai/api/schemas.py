"""
API Request/Response 스키마 정의
"""

from pydantic import BaseModel, Field
from typing import List, Optional, Literal


# ===========================
# 대화 이력 한 턴
# ===========================
class HistoryTurn(BaseModel):
    role: Literal["user", "assistant"]
    content: str


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
    history: List[HistoryTurn] = Field(
        default_factory=list,
        description="최근 대화 이력(최근 2턴). 세션이 없거나 첫 질문이면 빈 리스트",
    )
    summary: Optional[str] = Field(
        None,
        description="이전 대화 롤링 요약. 없으면 null",
    )

    class Config:
        json_schema_extra = {
            "example": {
                "question": "계약서에 도장 안 찍으면 어떻게 되나요?",
                "age": 8,
                "law_category": None,
                "history": [],
                "summary": None,
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
    standalone_query: Optional[str] = Field(
        None, description="재작성된 질문. 재작성이 실행되지 않았으면 null"
    )
    rewrite_applied: bool = Field(False, description="재작성이 실행됐는지 여부")


# ===========================
# 대화 요약 갱신
# ===========================
class SummaryUpdateRequest(BaseModel):
    session_id: int
    prev_summary: Optional[str] = None
    turns_to_fold: List[HistoryTurn]
    through_message_id: int


class SummaryUpdateResponse(BaseModel):
    summary: str
    through_message_id: int


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
