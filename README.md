# LexAI — 나이맞춤형 법률 AI 상담 서비스

> **Lex** (라틴어: 법) + **AI** — 누구나 이해할 수 있는 법률 상담 챗봇

![Python](https://img.shields.io/badge/Python-3.11-3776AB?style=flat-square&logo=python&logoColor=white)
![FastAPI](https://img.shields.io/badge/FastAPI-0.111-009688?style=flat-square&logo=fastapi&logoColor=white)
![Spring](https://img.shields.io/badge/Spring_Legacy-5.x-6DB33F?style=flat-square&logo=spring&logoColor=white)
![Java](https://img.shields.io/badge/Java-17-ED8B00?style=flat-square&logo=openjdk&logoColor=white)
![Node.js](https://img.shields.io/badge/Node.js-18+-339933?style=flat-square&logo=node.js&logoColor=white)
![MySQL](https://img.shields.io/badge/MySQL-8.0-4479A1?style=flat-square&logo=mysql&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-OpenSearch-2496ED?style=flat-square&logo=docker&logoColor=white)
![Ollama](https://img.shields.io/badge/Ollama-Gemma3_4B-000000?style=flat-square&logo=ollama&logoColor=white)

---

## 📌 프로젝트 개요

LexAI는 사용자의 **나이대에 맞는 언어**로 법률 질문에 답변해주는 RAG 기반 AI 챗봇입니다.  
초등학생부터 시니어까지, 어려운 법률 용어를 쉽게 풀어서 설명합니다.

| 항목 | 내용 |
|------|------|
| 서비스명 | LexAI |
| 개발 유형 | LLM RAG 기반 법률 QA 챗봇 |
| 데이터 출처 | AIHub 법률 데이터 (253,207건) |
| 주요 기술 | FastAPI, Spring Legacy, Node.js, OpenSearch, Gemma 3 4B |

---

## 🏗️ 시스템 아키텍처

```
[브라우저]
    │ :3000
    ▼
[Frontend] Node.js + Express (HTML/CSS/jQuery)
  ├─ index.html     (로그인)
  ├─ signup.html    (회원가입)
  └─ chat.html      (채팅 UI)
    │ :8181
    ▼
[Backend] Spring Legacy (STS, MyBatis, MySQL)
  ├─ JWT 인증 (회원가입 / 로그인)
  └─ 채팅 API → FastAPI로 프록시
    │ :8000
    ▼
[AI Server] FastAPI (Python 3.11)
  ├─ 하이브리드 RAG 검색 (BM25 + kNN)
  ├─ Gemma 3 4B / Ollama 추론
  └─ 나이대별 프롬프트 적용
    │
    ▼
[Data Layer]
  ├─ MySQL 8.0       — 사용자 정보
  └─ OpenSearch 2.13 — 법률 문서 벡터 DB (253,207건)
```

---

## 🔧 기술 스택

### AI
| 항목 | 내용 |
|------|------|
| LLM | Gemma 3 4B (4bit QLoRA) |
| 검색 | BM25 + kNN 하이브리드 RAG |
| 벡터 DB | OpenSearch 2.13.0 (Docker) |
| 서버 | FastAPI (Python 3.11) |

### Backend
| 항목 | 내용 |
|------|------|
| 프레임워크 | Spring Legacy (Spring MVC) |
| 포트 | 8181 |
| ORM | MyBatis |
| DB | MySQL 8.0 |
| 인증 | JWT (BCrypt 암호화) |
| CORS | SimpleCorsFilter 직접 구현 |

### Frontend
| 항목 | 내용 |
|------|------|
| 서버 | Node.js + Express |
| 포트 | 3000 |
| UI | HTML / CSS / jQuery |
| 페이지 | 로그인 / 회원가입 / 채팅 |

---

## 🧠 나이대별 응답 전략

사용자의 나이를 JWT에서 추출하여 4단계 프롬프트를 자동 적용합니다.

| 구분 | 나이 | 말투 스타일 | 예시 |
|------|------|------------|------|
| 초등학생 | ~10세 | 쉬운 말, 비유 | "약속을 지키는 거랑 같아요" |
| 청소년 | 11~19세 | 기본 개념, 일상 예시 | "카톡이나 말로도 계약이 될 수 있어요" |
| 성인 | 20~40세 | 법률 용어, 조문 인용 | "민법 제563조에 따르면..." |
| 중장년 | 41세~ | 전문 분석, 판례 참고 | "의사표시의 합치만으로 유효하게 성립합니다" |

---

## 📁 프로젝트 구조

```
legal-rag-chatbot/
├── ai/                             # FastAPI AI 서버
│   ├── main.py                     # 앱 진입점
│   ├── api/
│   │   ├── router.py               # /chat 엔드포인트
│   │   └── schemas.py              # 요청·응답 스키마
│   ├── core/
│   │   ├── config.py               # 환경 설정
│   │   └── model.py                # Ollama 모델 연동
│   ├── rag/
│   │   ├── pipeline.py             # RAG 파이프라인
│   │   └── retriever.py            # BM25 + kNN 하이브리드 검색
│   ├── prompt/
│   │   └── template.py             # 나이대별 프롬프트 분기
│   ├── indexing/
│   │   ├── index_builder.py        # OpenSearch 인덱싱
│   │   └── loader.py               # 데이터 로더
│   ├── data/
│   │   └── preprocess.py           # AIHub 데이터 전처리
│   └── requirements.txt
├── backend_spring/                 # Spring Legacy 백엔드
│   ├── src/main/java/com/legal/backend/
│   │   ├── controller/             # AuthController, ChatController
│   │   ├── service/                # AuthService, ChatService
│   │   ├── dao/                    # UserDao (MyBatis)
│   │   ├── dto/                    # 요청·응답 DTO
│   │   ├── entity/                 # User
│   │   ├── filter/                 # JwtFilter, SimpleCorsFilter
│   │   └── util/                   # JwtUtil
│   └── pom.xml
├── frontend/                       # Node.js + Express 프론트엔드
│   ├── public/
│   │   ├── index.html              # 로그인
│   │   ├── signup.html             # 회원가입
│   │   └── chat.html               # 채팅 UI
│   └── server.js
└── README.md
```

---

## 📁 브랜치 구조

```
main
 └─ develop
      ├─ feature/data-preprocessing
      ├─ feature/opensearch-indexing
      ├─ feature/rag-retriever
      ├─ refactor/rag-retriever-improvement
      ├─ feature/prompt-template
      ├─ feature/gemma-model
      ├─ feature/fastapi-endpoint
      ├─ feature/spring-backend
      ├─ feature/spring-auth
      ├─ feature/spring-chat-api
      ├─ feature/spring-legacy-backend
      └─ feature/nextjs-frontend
```

---

## 🗄️ 데이터 모델

### MySQL — `users` 테이블

| 컬럼 | 타입 | 설명 |
|------|------|------|
| id | BIGINT (PK) | 자동 증가 |
| username | VARCHAR | 사용자 이름 |
| password | VARCHAR | BCrypt 암호화 |
| age | INT | 나이 (프롬프트 분기에 사용) |

### OpenSearch — `legal_docs` 인덱스

| 필드 | 타입 | 설명 |
|------|------|------|
| title | text | 문서 제목 (BM25 검색 대상) |
| content | text | 본문 (BM25 검색 대상) |
| embedding | knn_vector | 임베딩 벡터 (kNN 검색) |
| source | keyword | 데이터 출처 |
| category | keyword | 법률 분야 분류 |
| doc_id | keyword | 문서 고유 ID |

> 데이터 출처: AIHub 법률 데이터 4개 분야 (민사법, 형사법, 행정법, 지식재산권법)

---

## 🚀 실행 방법

### 1. OpenSearch 실행 (Docker)

```bash
docker run -d \
  --name opensearch \
  -p 9200:9200 -p 9600:9600 \
  -e discovery.type=single-node \
  opensearchproject/opensearch:2.13.0
```

### 2. AI 서버 (FastAPI)

```bash
cd ai
pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8000
```

### 3. 백엔드 (Spring Legacy)

```bash
cd backend
# STS에서 서버 실행 또는 WAR 배포
# 포트: 8181
```

### 4. 프론트엔드 (Node.js)

```bash
cd frontend
npm install
node server.js
# 포트: 3000
```

---

## 🖥️ 개발 환경

| 항목 | 버전 / 내용 |
|------|------------|
| OS | Windows 11 / Ubuntu 22.04 (서버 배포) |
| Python | 3.11 |
| JDK | 17 |
| Node.js | 18+ |
| Spring Framework | 5.x (Legacy MVC) |
| Maven | 3.9+ |
| Docker | 24+ |
| OpenSearch | 2.13.0 (Docker) |
| Ollama | 최신 (Gemma3:4b 모델) |
| IDE | STS 4 (Spring), VS Code (AI·Frontend) |
| DB Client | MySQL Workbench 8.0 |

---

## ✅ 구현 완료 목록

- [x] AIHub 법률 데이터 전처리 및 OpenSearch 인덱싱 (253,207건)
- [x] BM25 + kNN 하이브리드 RAG 파이프라인
- [x] 나이대별 맞춤 프롬프트 (4단계)
- [x] Gemma 3 4B 4bit QLoRA 추론 연동
- [x] Spring Legacy JWT 인증 (회원가입 / 로그인)
- [x] FastAPI 연동 채팅 API
- [x] 프론트엔드 3페이지 UI (로그인 / 회원가입 / 채팅)
- [x] 서버 배포 (`168.107.44.47`) 및 포트 오픈

---

## ⚠️ 알려진 이슈

| 이슈 | 상태 | 비고 |
|------|------|------|
| 응답 속도 약 83초 | 해결 | Gemma 3 4B GGUF + Ollama 전환 후 평균 15.5초로 개선 (`ai/eval/run_eval.py` 16문항 측정 기준) |
| 분야 필터/분야일치율 지표 신뢰도 낮음 | 확인됨 | `law_category`가 주제(민사/형사/행정/지식재산권)가 아니라 사건 진행 절차(형사재판/행정소송 등) 기준으로 태깅되어 있음 (예: 상표법 위반은 형사재판이라 `형사법`, 특허 권리범위확인 항고는 `행정법`). 검색 자체는 내용상 정확한 경우가 많으나, 분야 필터·분야일치 지표는 이 구조에서 신뢰하기 어려움 |
| Spring Legacy Context Path | 확인 필요 | `/backend_spring` 경로 수동 수정 |
| 통합 테스트 | 미완료 | FastAPI / Spring / Node.js 전체 연동 테스트 보류 중 |

---

## 📄 산출물

| 문서 | 설명 |
|------|------|
| 요구사항 정의서 | SFR / SNFR 기능 및 비기능 요구사항 |
| 분석모델정의서 | 시스템 구조, RAG 파이프라인, 나이대별 프롬프트 상세 |
| 화면정의서 | 로그인 / 회원가입 / 채팅 화면 UI 명세 |
| 테이블 정의서 | MySQL users 테이블, OpenSearch legal_docs 인덱스 |

---

## 📚 학습 내용

| 분야 | 핵심 학습 내용 |
|------|--------------|
| RAG | BM25 + kNN 하이브리드 검색 구조 설계, OpenSearch 인덱스 매핑 및 쿼리 최적화 |
| LLM 서빙 | Gemma 3 4B GGUF 변환 및 Ollama API 연동, 스트리밍 응답 처리 |
| 파인튜닝 | QLoRA 4bit 파인튜닝, Alpaca 포맷 학습 데이터 구성 (AIHub → finetune JSON) |
| 임베딩 | `jhgan/ko-sroberta-multitask` 한국어 임베딩, 벡터 유사도 검색 |
| Spring Legacy | MyBatis SQL 매핑, JWT 필터 체인, SimpleCorsFilter 직접 구현 |
| 시스템 설계 | Frontend → Spring → FastAPI 3계층 프록시 아키텍처 |
| 배포 | 리눅스 서버 포트 오픈, 멀티 프로세스 동시 실행 (`screen` / `nohup`) |

---

## 👥 팀 구성

> 1인 개발

---
