# 멀티턴 RAG (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 후속 질문이 앞선 대화 맥락을 이어받아 더 견고하게 답하도록 — 질문 재작성(게이트+경량 모델), 이중 채널 검색, 최근 이력 2턴 + 롤링 요약을 `/api/chat` 파이프라인에 배선한다.

**Architecture:** FastAPI(`ai/`)는 이번에도 무상태 순수 함수로 남는다 — `history`/`summary`를 요청으로 받아 `standalone_query`/`rewrite_applied`를 응답으로 돌려줄 뿐, 자신은 아무것도 저장하지 않는다. Spring(`backend_spring`)이 대화 상태(최근 이력·요약)를 MySQL에서 읽어 FastAPI에 넘기고, 응답 후 `ChatMemoryAsyncService`(Phase 0에서 만들어 둔 `chatMemoryExecutor`를 이제 처음 실제로 사용)가 비동기로 FastAPI의 `/summary/update`를 호출해 롤링 요약을 갱신한다.

**Tech Stack:** FastAPI/Pydantic v2(`ai/`, 기존 그대로 — 이 단계에서 신규 의존성 없음), Java 11 · Spring MVC 5.3.30 · MyBatis · JUnit 5 + Mockito(`backend_spring`, Phase 0에서 이미 도입됨).

**Spec:** [docs/superpowers/specs/2026-09-11-conversational-memory-design.md](../specs/2026-09-11-conversational-memory-design.md) — 이 계획은 스펙의 §8(FastAPI 설계 중 재작성·검색·프롬프트·요약 부분), §11(평가 계획), §12(Phase 1 로드맵)를 구현한다. §8.4의 `user_memory`/`MEMORY_PRIORITY_RULE`과 §8.5의 `/memory/extract`, §8.6은 스펙 §12가 명시적으로 Phase 2 항목으로 분리해 둔 것이므로 이 계획 범위 밖이다(아래 Global Constraints 참고).

## Global Constraints

- **범위:** `ai/`와 `backend_spring/` 둘 다 수정한다(Phase 0은 `backend_spring`만 수정했다 — 이번엔 FastAPI도 손댄다). `backend/`(소스 없는 레거시 Eclipse 셸)는 이번에도 무관.
- **HISTORY_WINDOW_TURNS = 2** → 프롬프트/재작성에 원문으로 주입되는 건 최근 4개 메시지(user+assistant 2턴).
- **SUMMARY_TRIGGER_TURNS = 2** → 마지막 요약(`through_message_id`) 이후 아직 요약에 안 접힌 턴이 2턴(4메시지)을 넘을 때만(3턴째 질문부터) 요약을 갱신한다.
- **프롬프트 하드 캡(코드 레벨, 추정 아님):** `summary` 300자 초과 시 `[:300] + "..."`, `history` 최근 2턴·각 턴 250자 초과 시 컷(오래된 턴부터 버림), `context`는 기존 나이대별 `CONTEXT_MAX_LEN` 그대로 유지.
- **재작성 게이트(규칙 기반, LLM 0회):** 이력이 없으면 항상 재작성 안 함. 지시어(`그거,그건,그것,이거,이건,저거,위에서,아까,방금,거기,그럼,그러면`) 포함 시 재작성. 질문이 12자(`MIN_STANDALONE_LEN`) 미만이면 재작성.
- **이중 채널 검색:** 재작성이 실행된 경우 원본 질문 + 재작성 질문 둘 다로 검색해 융합한다. 재작성을 안 했으면 원본 질문 하나로만 검색해 기존 `search()`와 동일하게 동작한다(하위 호환).
- **재작성 전용 경량 모델:** `OLLAMA_REWRITE_MODEL` 설정값은 `gemma3:1b`(가칭)로 둔다 — 실제 로컬 Ollama에 받아져 있는 모델인지 Task 1에서 확인·pull한다. 답변 생성은 계속 `OLLAMA_MODEL`(`legal-gemma`)이 담당, 재작성만 이 경량 모델을 쓴다.
- **`user_memory`/`MEMORY_PRIORITY_RULE`/`/memory/extract`는 이 계획에 없다** — Phase 2 범위. `ChatRequest`에 `user_memory` 필드를 추가하지 않는다.
- **Python 테스트 관례:** `ai/`에는 pytest 등 테스트 프레임워크가 없다(확인 완료 — `requirements*.txt`에도 없고 `ai/tests/`도 없음). 기존 모듈들(`pipeline.py`, `retriever.py`, `template.py`)의 관례를 그대로 따른다: 각 모듈 하단에 `def test():` + `if __name__ == "__main__": test()`. 순수 로직(예: `needs_rewrite`)은 그 안에서 `assert`로 실제 검증한다. LLM/OpenSearch 호출이 필요한 부분은 해당 서비스가 떠 있어야 함을 각 Step에 명시한다.
- **실행 환경(Python):** `ai/.venv`가 이미 있다(Python 3.12.10, FastAPI 0.136.1, Pydantic 2.13.4). 모든 `python` 실행은 `ai/.venv/Scripts/python.exe`를 쓰고, 모든 모듈 실행은 `ai/` 디렉터리에서 한다(각 모듈이 `sys.path.append(부모디렉터리)`로 `ai/`를 기준으로 임포트하기 때문).
- **실행 환경(Java):** `mvn`이 PATH에 없다 — `C:\Users\SMT21\.m2\wrapper\dists\apache-maven-3.9.16-bin\5grr65jo27hi51sujmtcldfovl\apache-maven-3.9.16\bin`을 PATH 앞에 추가해서 쓴다. 콘솔 인코딩이 MS949라 `MAVEN_OPTS=-Dfile.encoding=UTF-8`을 항상 같이 설정한다(Phase 0 SDD 워크스페이스에서 확인된 환경 룰링, 재사용).
- **라이브 인프라(OpenSearch·Ollama·MySQL):** 이 계획을 실행하는 시점에 셋 다 떠 있어야 완전히 검증 가능하다(`docker compose up -d opensearch ollama mysql`, 최초 1회는 `bash deploy/ollama-init.sh`도). 떠 있지 않으면 해당 Step은 "실행 불가 — 라이브 인프라 필요"로 보고하고 지어내지 않는다(Phase 0에서 이미 쓴 규칙, 재사용). 순수 로직(`needs_rewrite`, 프롬프트 캡 함수, 재작성 게이트) 검증은 인프라 없이도 전부 가능하다.
- **DTO 필드명:** FastAPI(Python, snake_case) ↔ Spring(Java, camelCase) 경계는 기존과 동일하게 Jackson `@JsonProperty`로 명시 매핑한다(예: `age_group_label` → `ageGroupLabel`의 기존 패턴을 그대로 따름).

---

### Task 1: 경량 재작성 모델 설정 + `generate()` 확장

**Files:**
- Modify: `ai/core/config.py`
- Modify: `ai/core/model.py`

**Interfaces:**
- Produces: `settings.OLLAMA_REWRITE_MODEL: str`. `generate(system_prompt, user_message, model=None, max_tokens=None, temperature=None) -> str` — Task 2(`rewrite.py`)와 Task 6(`summarize.py`)가 이 확장된 시그니처를 쓴다. 기존 호출부(`pipeline.py`의 `generate(system_prompt=..., user_message=...)`)는 새 파라미터를 생략하면 기존과 동일하게 동작해야 한다(하위 호환).

- [ ] **Step 1: 로컬 Ollama에 경량 모델이 있는지 확인 — 없으면 pull**

Run (Docker/Ollama가 떠 있어야 함 — `docker compose up -d ollama`):
```bash
docker exec lexai-ollama ollama list
```
`gemma3:1b`가 목록에 없으면:
```bash
docker exec lexai-ollama ollama pull gemma3:1b
```
Expected: `ollama list`에 `gemma3:1b`가 보임. **이 Step이 실행 불가(Ollama 컨테이너 미기동)면 "실행 불가 — 라이브 인프라 필요"로 보고하고 Step 2로 진행** — 설정값 자체는 인프라 없이도 넣을 수 있다. `gemma3:1b`가 실제로 이 환경에서 받아지지 않는 모델명이면(Ollama 라이브러리 목록이 바뀌었을 수 있음), `ollama pull gemma3:1b` 실패 메시지를 보고 그 시점에 실제 존재하는 가장 작은 gemma3 태그(예: `gemma3:1b-it-qat` 등)로 Step 2의 값을 교체한다.

- [ ] **Step 2: `config.py`에 설정 추가**

`ai/core/config.py`의 Ollama 설정 블록(`OLLAMA_MODEL: str = "legal-gemma"` 바로 아래)에 추가:

```python
    OLLAMA_REWRITE_MODEL: str = "gemma3:1b"
```

- [ ] **Step 3: `generate()` 시그니처 확장**

`ai/core/model.py`의 `generate` 함수 전체를 교체:

```python
def generate(
    system_prompt: str,
    user_message: str,
    model: str = None,
    max_tokens: int = None,
    temperature: float = None,
) -> str:
    target_model = model or OLLAMA_MODEL

    if not check_ollama():
        raise RuntimeError(
            f"Ollama 서버에 연결할 수 없습니다: {OLLAMA_BASE_URL}\n"
            f"'ollama run {target_model}' 명령어로 모델을 먼저 실행해주세요."
        )

    # Gemma는 system role 미지원 → user 메시지에 합쳐서 전달
    combined = system_prompt + "\n\n" + user_message

    response = requests.post(
        f"{OLLAMA_BASE_URL}/api/chat",
        json={
            "model": target_model,
            "messages": [
                {"role": "user", "content": combined},
            ],
            "stream": False,
            "options": {
                "temperature":    temperature if temperature is not None else settings.TEMPERATURE,
                "top_p":          settings.TOP_P,
                "num_predict":    max_tokens if max_tokens is not None else settings.MAX_NEW_TOKENS,
                "repeat_penalty": 1.1,
                "num_ctx":        4096,
            },
        },
        timeout=300,
    )

    if response.status_code != 200:
        raise RuntimeError(
            f"Ollama API 오류 ({response.status_code}): {response.text}"
        )

    return response.json()["message"]["content"].strip()
```

기존 `generate(system_prompt=prompt["system"], user_message=prompt["user"])` 호출부(`pipeline.py`)는 `model`/`max_tokens`/`temperature`를 생략하므로 `target_model = OLLAMA_MODEL`, 기존 `settings.TEMPERATURE`/`settings.MAX_NEW_TOKENS`로 동작 — 동작 변화 없음.

- [ ] **Step 4: 임포트 확인 및 수동 검증**

Run (`ai/` 디렉터리에서):
```bash
.venv/Scripts/python.exe -c "from core.config import settings; print(settings.OLLAMA_REWRITE_MODEL)"
```
Expected: `gemma3:1b` 출력, 에러 없음.

Ollama가 떠 있으면 추가로:
```bash
.venv/Scripts/python.exe -c "from core.model import generate; print(generate('', '2+2는?', model='gemma3:1b', max_tokens=20, temperature=0.0))"
```
Expected: 짧은 답변 문자열 출력. 떠 있지 않으면 "실행 불가 — 라이브 인프라 필요"로 보고.

- [ ] **Step 5: Commit**

```bash
git add ai/core/config.py ai/core/model.py
git commit -m "feat: 재작성 전용 경량 Ollama 모델 설정 + generate() 모델/파라미터 지정 지원"
```

---

### Task 2: 질문 재작성 게이트·재작성 함수

**Files:**
- Create: `ai/rag/rewrite.py`

**Interfaces:**
- Consumes: Task 1의 `generate(system_prompt, user_message, model, max_tokens, temperature)`, `settings.OLLAMA_REWRITE_MODEL`.
- Produces: `needs_rewrite(question: str, history: list) -> bool`, `rewrite_query(question: str, history: list, summary: str = None) -> str`. `history`는 `[{"role": "user"|"assistant", "content": str}, ...]` 형태의 plain dict 리스트(Pydantic 모델이 아님 — Task 5에서 라우터가 변환해서 넘긴다). Task 6(`pipeline.py`)이 `import rag.rewrite as rewrite`로 모듈째 임포트해서 `rewrite.needs_rewrite(...)`/`rewrite.rewrite_query(...)`로 호출한다(함수를 직접 `from rag.rewrite import needs_rewrite`로 임포트하지 않는다 — Task 11의 eval 스크립트가 `rewrite.needs_rewrite`를 몽키패치해서 재작성 켬/끔 비교를 하기 때문에, pipeline.py가 모듈 참조로 호출해야 패치가 실제로 걸린다).

- [ ] **Step 1: 파일 작성**

`ai/rag/rewrite.py` (신규):

```python
"""
질문 재작성 — 후속 질문이 이전 대화를 가리킬 때(대명사·지시어, 너무 짧은 질문)
검색 전에 독립적으로 완결된 질문으로 다시 쓴다.

게이트는 규칙 기반(LLM 호출 없음)이라 대부분의 턴에서 재작성 자체를 건너뛴다.
재작성이 실행되는 경우엔 legal-gemma가 아니라 별도의 경량 모델
(OLLAMA_REWRITE_MODEL)을 쓴다 — 법률 지식이 필요 없는 일반 NLU 작업이라
작은 모델로도 충분하고, 지연을 크게 줄인다.
"""

import sys
import os
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from core.model import generate
from core.config import settings


_DEMONSTRATIVES = [
    "그거", "그건", "그것", "이거", "이건", "저거",
    "위에서", "아까", "방금", "거기", "그럼", "그러면",
]
MIN_STANDALONE_LEN = 12


def needs_rewrite(question: str, history: list) -> bool:
    """이력이 없으면 재작성할 이유가 없다. 지시어가 있거나 질문이 너무 짧으면
    이전 대화를 가리키는 후속 질문일 가능성이 높다고 보고 재작성한다."""
    if not history:
        return False
    if any(d in question for d in _DEMONSTRATIVES):
        return True
    return len(question.strip()) < MIN_STANDALONE_LEN


def _format_history(history: list) -> str:
    lines = []
    for turn in history:
        speaker = "사용자" if turn["role"] == "user" else "챗봇"
        lines.append(f"{speaker}: {turn['content']}")
    return "\n".join(lines)


def rewrite_query(question: str, history: list, summary: str = None) -> str:
    prompt = f"""다음은 이전 대화 요약과 최근 대화, 그리고 사용자의 새 질문이다.
새 질문을 이전 대화 없이도 이해할 수 있는 완전한 질문 하나로 다시 써라.
새로운 정보를 추가하지 말고, 이전 대화에 없는 단어를 넣지 마라. 재작성한 질문만 출력하라.

[요약]
{summary or '없음'}

[최근 대화]
{_format_history(history)}

[새 질문]
{question}
"""
    return generate(
        system_prompt="",
        user_message=prompt,
        model=settings.OLLAMA_REWRITE_MODEL,
        max_tokens=80,
        temperature=0.0,
    ).strip()


# ===========================
# 테스트
# ===========================
def test():
    # --- 순수 로직: assert로 즉시 검증(인프라 불필요) ---
    history = [{"role": "user", "content": "가압류가 뭔가요?"},
               {"role": "assistant", "content": "가압류는 ..."}]

    assert needs_rewrite("그건 어떻게 하나요?", history) is True, "지시어 포함 → 재작성해야 함"
    assert needs_rewrite("괜찮아요", []) is False, "이력 없으면 항상 재작성 안 함"
    assert needs_rewrite(
        "전세보증금을 돌려받지 못하고 있는데 어떻게 대응해야 하나요?", history
    ) is False, "지시어 없고 12자 이상 → 재작성 안 함"
    assert needs_rewrite("짧은질문", history) is True, "12자 미만 → 재작성해야 함"
    print("[PASS] needs_rewrite 로직 4건 검증 완료")

    # --- LLM 호출: Ollama + gemma3:1b가 떠 있어야 함 ---
    conv_history = [
        {"role": "user", "content": "전세 계약 갱신을 거부당했어요"},
        {"role": "assistant", "content": "임대인은 정당한 사유 없이 갱신을 거부할 수 없습니다. 계약갱신요구권 행사 여부를 확인해야 합니다."},
    ]
    standalone = rewrite_query("그럼 계약금은 어떻게 되나요?", conv_history, summary=None)
    print(f"[재작성 결과] {standalone}")


if __name__ == "__main__":
    test()
```

- [ ] **Step 2: 순수 로직만 우선 실행해서 확인**

Run (`ai/` 디렉터리에서, Ollama 없이도 실행 가능 — `test()`가 assert 구간을 먼저 통과해야 그 다음 LLM 호출로 넘어간다):
```bash
.venv/Scripts/python.exe rag/rewrite.py
```
Expected: `[PASS] needs_rewrite 로직 4건 검증 완료`가 먼저 출력됨. 그 직후 Ollama가 안 떠 있으면 `RuntimeError: Ollama 서버에 연결할 수 없습니다`로 종료 — 이 경우 위 PASS 줄까지 나온 것으로 순수 로직 검증은 충분하다("실행 불가 — 라이브 인프라 필요"로 나머지 보고). Ollama가 떠 있으면 `[재작성 결과] ...`까지 출력되고, 원본 질문의 "그럼"·"계약금"이 "전세 계약금"처럼 구체화된 독립 질문으로 나오는지 눈으로 확인한다.

- [ ] **Step 3: Commit**

```bash
git add ai/rag/rewrite.py
git commit -m "feat: 질문 재작성 게이트·재작성 함수 추가"
```

---

### Task 3: 이중 채널 검색

**Files:**
- Modify: `ai/rag/retriever.py`

**Interfaces:**
- Produces: `LegalRetriever.search_multi(queries: list[str], law_category: str = None) -> list` — Task 6(`pipeline.py`)이 재작성 여부에 따라 `[question]` 또는 `[question, standalone_query]`를 넘긴다. `LegalRetriever.format_context(results: list) -> str` — 기존 `get_context()`가 내부적으로 이걸 쓰도록 리팩터링되고, Task 6이 `search_multi`의 결과를 직접 이 함수에 넘겨 컨텍스트를 만든다(지금처럼 검색을 두 번 하지 않기 위해).
- 기존 `search()`/`get_context()`의 동작(단일 질문 입력 시 반환값)은 이 Task 이후에도 완전히 동일해야 한다 — 리팩터링이지 동작 변경이 아니다.

- [ ] **Step 1: 공유 헬퍼로 리팩터링 — `_hybrid_search`를 그대로 유지한 채 내부 로직만 함수로 추출**

`ai/rag/retriever.py`의 `_hybrid_search` 메서드(현재 212-262행)를 아래로 교체하고, 클래스 밖에 모듈 레벨 헬퍼 3개를 새로 추가한다. `_extract_title`/`_title_match_score` 정의 바로 아래(현재 86행 부근, `_resolve_device` 함수 앞)에 헬퍼들을 넣는다:

```python
# ===========================
# 채널 정규화·합산 헬퍼 — _hybrid_search와 search_multi가 공유
# ===========================
def _accumulate_channel(hits: list, scores: dict, docs: dict) -> None:
    """한 채널(kNN 또는 BM25)의 검색 결과를 자체 최고점 기준으로 정규화해서
    scores/docs 딕셔너리에 제자리(in-place)로 합산한다."""
    max_score = max((h["_score"] for h in hits), default=1)
    for hit in hits:
        doc_id = hit["_source"]["doc_id"]
        normalized = hit["_score"] / max_score if max_score > 0 else 0
        scores[doc_id] = scores.get(doc_id, 0) + normalized
        docs[doc_id] = hit["_source"]


def _apply_title_bonus(query_text: str, scores: dict, docs: dict) -> None:
    """제목-질문 매칭 보너스를 scores에 제자리로 더한다."""
    for doc_id in scores:
        title = _extract_title(docs[doc_id].get("text", ""))
        scores[doc_id] += _title_match_score(query_text, title) * TITLE_MATCH_WEIGHT


def _finalize(scores: dict, docs: dict, top_k: int, min_score: float) -> list:
    sorted_docs = sorted(scores.items(), key=lambda x: x[1], reverse=True)
    results = []
    for doc_id, score in sorted_docs[:top_k]:
        if score >= min_score:
            results.append({
                "doc_id": doc_id,
                "score": round(score, 4),
                "text": docs[doc_id]["text"],
                "law_category": docs[doc_id].get("law_category", ""),
                "doc_type": docs[doc_id].get("doc_type", ""),
                "source": docs[doc_id].get("source", ""),
            })
    return results
```

이제 `LegalRetriever._hybrid_search`를 교체(가중치는 기존과 동일하게 kNN·BM25 둘 다 1.0 — 동작 변화 없음):

```python
    def _hybrid_search(self, query_text: str, query_vector: list, law_category: str = None) -> list:
        pool_size = max(self.top_k * 5, 30)
        knn_results = self._knn_search(query_vector, law_category, size=pool_size)
        bm25_results = self._bm25_search(query_text, law_category, size=pool_size)

        scores = {}
        docs = {}
        _accumulate_channel(knn_results, scores, docs)
        _accumulate_channel(bm25_results, scores, docs)
        _apply_title_bonus(query_text, scores, docs)

        return _finalize(scores, docs, self.top_k, self.min_score)
```

- [ ] **Step 2: 리팩터링이 동작을 안 바꿨는지 수동 확인**

Run (OpenSearch가 떠 있어야 함 — `docker compose up -d opensearch`, 색인이 이미 돼 있어야 함):
```bash
cd /f/workspce/legal-rag-chatbot/ai && .venv/Scripts/python.exe rag/retriever.py
```
Expected: 기존과 동일한 3개 질의에 대한 검색 결과가 출력됨(리팩터링 전과 점수·문서가 같아야 함 — 로직을 함수로 옮겼을 뿐 계산 순서·가중치는 그대로이므로 동일해야 정상). 떠 있지 않으면 "실행 불가 — 라이브 인프라 필요"로 보고.

- [ ] **Step 3: `search_multi`와 `format_context` 추가**

`_hybrid_search` 바로 아래, `search` 메서드(현재 267행) 앞에 추가:

```python
    # ===========================
    # 다중 질문 검색 (원본 + 재작성 질문을 함께 검색해 융합)
    #
    # 재작성이 틀려도 원본 채널이 정답 후보를 살려둔다 — kNN/BM25 두 채널을
    # 합산해 온 것과 같은 원리를 재작성/원본 두 질의에도 적용.
    # queries가 원소 1개면 _hybrid_search와 완전히 동일하게 동작한다.
    # ===========================
    def search_multi(self, queries: list, law_category: str = None) -> list:
        pool_size = max(self.top_k * 5, 30)
        scores = {}
        docs = {}

        for query_text in queries:
            query_vector = self._embed_query(query_text)
            knn_results = self._knn_search(query_vector, law_category, size=pool_size)
            bm25_results = self._bm25_search(query_text, law_category, size=pool_size)
            _accumulate_channel(knn_results, scores, docs)
            _accumulate_channel(bm25_results, scores, docs)
            _apply_title_bonus(query_text, scores, docs)

        return _finalize(scores, docs, self.top_k, self.min_score)
```

이제 `get_context`(현재 315-331행)를 교체해 포맷팅 로직을 공개 메서드 `format_context`로 뽑는다:

```python
    # ===========================
    # 검색 결과 → 컨텍스트 텍스트 변환 (search()/search_multi() 결과 둘 다 받음)
    # ===========================
    def format_context(self, results: list) -> str:
        if not results:
            return "관련 법률 문서를 찾을 수 없습니다."

        context_parts = []
        for i, doc in enumerate(results, 1):
            # 오염 텍스트 정제 후 500자 제한
            clean = self._clean_text(doc['text'])[:500]
            context_parts.append(
                f"[문서 {i}] ({doc['law_category']} - {doc['doc_type']})\n"
                f"{clean}\n"
                f"출처: {doc['source']}"
            )

        return "\n\n".join(context_parts)

    # ===========================
    # 컨텍스트 텍스트 생성 (단일 질문 편의 메서드 — 내부적으로 search() + format_context())
    # ===========================
    def get_context(self, query: str, law_category: str = None) -> str:
        results = self.search(query, law_category)
        return self.format_context(results)
```

- [ ] **Step 4: 새 메서드 동작 확인**

Run (`ai/` 디렉터리에서, OpenSearch 필요):
```bash
.venv/Scripts/python.exe -c "
from rag.retriever import LegalRetriever
r = LegalRetriever()
single = r.search('가압류가 뭔가요?')
multi = r.search_multi(['가압류가 뭔가요?'])
assert [d['doc_id'] for d in single] == [d['doc_id'] for d in multi], '질의 1개면 search()와 결과 동일해야 함'
print('[PASS] search_multi(단일 질의) == search()')
print(r.format_context(multi)[:200])
"
```
Expected: `[PASS] search_multi(단일 질의) == search()` 출력 후 컨텍스트 앞부분 출력. `get_context()`가 기존과 동일한 텍스트를 반환하는지도 눈으로 확인(기존 `retriever.py` 실행 결과와 비교). 떠 있지 않으면 "실행 불가 — 라이브 인프라 필요"로 보고.

- [ ] **Step 5: Commit**

```bash
git add ai/rag/retriever.py
git commit -m "feat: 이중 채널 검색(search_multi) 추가 — 하이브리드 검색 정규화 로직을 공유 헬퍼로 추출"
```

---

### Task 4: 프롬프트 예산 하드 캡

**Files:**
- Modify: `ai/prompt/template.py`

**Interfaces:**
- Produces: `build_prompt(question, context, age, summary=None, history=None) -> dict` — 반환 딕셔너리 형태(`system`/`user`/`age_group`/`age_group_label`)는 기존과 동일, `user` 필드 내용만 summary/history가 있을 때 늘어난다. `summary`/`history`가 둘 다 없으면(Task 6 배선 전까지의 기존 호출부 포함) 기존과 완전히 동일한 `user` 문자열을 만든다 — 하위 호환.

- [ ] **Step 1: 하드 캡 상수 + 헬퍼 추가**

`ai/prompt/template.py`의 `CONTEXT_MAX_LEN` 딕셔너리(현재 76-81행) 바로 아래에 추가:

```python
# 이력·요약 하드 캡 — 4096 토큰 예산 안에서 강제로 자른다(추정이 아니라 실제 컷)
SUMMARY_MAX_LEN = 300
HISTORY_TURNS_MAX = 2          # 최근 2턴(user+assistant 페어) = 메시지 4개
HISTORY_TURN_MAX_LEN = 250


def _cap_summary(summary: str) -> str:
    if not summary:
        return None
    return summary if len(summary) <= SUMMARY_MAX_LEN else summary[:SUMMARY_MAX_LEN] + "..."


def _cap_history(history: list) -> list:
    if not history:
        return []
    # 오래된 턴부터 버림 → 최근 HISTORY_TURNS_MAX*2 메시지만 유지
    recent = history[-(HISTORY_TURNS_MAX * 2):]
    capped = []
    for turn in recent:
        content = turn["content"]
        if len(content) > HISTORY_TURN_MAX_LEN:
            content = content[:HISTORY_TURN_MAX_LEN] + "..."
        capped.append({"role": turn["role"], "content": content})
    return capped


def _format_history_block(history: list) -> str:
    if not history:
        return ""
    lines = []
    for turn in history:
        speaker = "사용자" if turn["role"] == "user" else "챗봇"
        lines.append(f"{speaker}: {turn['content']}")
    return "[이전 대화]\n" + "\n".join(lines) + "\n\n"
```

- [ ] **Step 2: `build_prompt` 시그니처 확장**

`build_prompt` 함수(현재 84-108행) 전체를 교체:

```python
def build_prompt(
    question: str,
    context: str,
    age: int,
    summary: str = None,
    history: list = None,
) -> dict:
    age_group = get_age_group(age)
    system_prompt = SYSTEM_PROMPTS[age_group]

    # 나이대별 컨텍스트 길이 제한
    max_len = CONTEXT_MAX_LEN[age_group]
    if len(context) > max_len:
        context = context[:max_len] + "..."

    capped_summary = _cap_summary(summary)
    capped_history = _cap_history(history)

    summary_block = f"[이전 대화 요약]\n{capped_summary}\n\n" if capped_summary else ""
    history_block = _format_history_block(capped_history)

    user_message = f"""{summary_block}{history_block}[참고 내용]
{context}

[질문]
{question}"""

    return {
        "system": system_prompt,
        "user": user_message,
        "age_group": age_group,
        "age_group_label": AGE_GROUP_LABEL[age_group],
    }
```

`summary`/`history`가 둘 다 없으면 `summary_block == ""`, `history_block == ""`이라 `user_message`는 기존 f-string과 글자 하나 다르지 않다(기존: `f"[참고 내용]\n{context}\n\n[질문]\n{question}"`).

- [ ] **Step 3: 하위 호환 + 하드 캡 동작을 assert로 검증**

`test()` 함수(현재 111-122행) 바로 앞에 새 검증 함수를 추가하고, `if __name__ == "__main__":` 블록에서 `test()` 전에 호출하도록 아래로 교체:

```python
def test_backward_compat_and_caps():
    context = "[문서 1] (민사법 - 법령)\n가압류는 ..."

    # 하위 호환: summary/history 없으면 기존과 100% 동일한 user 문자열
    old_style = f"""[참고 내용]
{context}

[질문]
가압류가 뭐야?"""
    prompt = build_prompt("가압류가 뭐야?", context, 25)
    assert prompt["user"] == old_style, "summary/history 없으면 기존 출력과 동일해야 함"
    print("[PASS] 하위 호환 — summary/history 없을 때 기존과 동일한 user 문자열")

    # 요약 300자 컷
    long_summary = "가" * 400
    prompt = build_prompt("질문", context, 25, summary=long_summary)
    assert "..." in prompt["user"]
    assert len(long_summary[:300]) == 300
    assert prompt["user"].count("가") <= 303  # 300자 + "..." 안의 "가" 없음이지만 여유 있게 체크
    print("[PASS] 요약 300자 하드 캡")

    # 이력 최근 2턴만 유지(오래된 턴부터 버림), 각 턴 250자 컷
    history = [
        {"role": "user", "content": "1번째 질문"},
        {"role": "assistant", "content": "1번째 답변"},
        {"role": "user", "content": "2번째 질문"},
        {"role": "assistant", "content": "나" * 300},
    ]
    prompt = build_prompt("질문", context, 25, history=history)
    assert "1번째 질문" not in prompt["user"], "3턴째부터는 최근 2턴만 남아야 함(오래된 턴 버림)"
    assert "2번째 질문" in prompt["user"]
    assert ("나" * 250 + "...") in prompt["user"], "턴당 250자 초과분은 컷돼야 함"
    print("[PASS] 이력 최근 2턴 + 턴당 250자 하드 캡")


def test():
    question = "가압류가 뭐야?"
    context = """[문서 1] (민사법 - 법령)
가압류는 금전채권이나 금전으로 환산할 수 있는 채권에 관하여 장래의 강제집행이 불가능하거나
현저히 곤란할 염려가 있는 경우에 미리 채무자의 재산을 동결시켜 두는 보전처분이다."""

    for age in [8, 15, 25, 55]:
        print(f"\n{'='*50}")
        print(f"나이: {age}세")
        prompt = build_prompt(question, context, age)
        print(f"나이대: {prompt['age_group_label']}")
        print(f"시스템 프롬프트:\n{prompt['system'][:100]}...")


if __name__ == "__main__":
    test_backward_compat_and_caps()
    test()
```

- [ ] **Step 4: 실행해서 확인**

Run (`ai/` 디렉터리에서, 인프라 불필요 — 순수 함수):
```bash
.venv/Scripts/python.exe prompt/template.py
```
Expected: `[PASS]` 3줄이 먼저 출력된 뒤(assert 실패 시 AssertionError로 여기서 바로 멈춤), 기존 `test()`의 나이대별 출력이 이어짐.

- [ ] **Step 5: Commit**

```bash
git add ai/prompt/template.py
git commit -m "feat: build_prompt에 요약·이력 하드 캡 추가"
```

---

### Task 5: `/chat` 스키마 확장

**Files:**
- Modify: `ai/api/schemas.py`

**Interfaces:**
- Produces: `HistoryTurn(role, content)`, `ChatRequest.history: List[HistoryTurn]`(기본값 빈 리스트), `ChatRequest.summary: Optional[str]`, `ChatResponse.standalone_query: Optional[str]`, `ChatResponse.rewrite_applied: bool`, `SummaryUpdateRequest`, `SummaryUpdateResponse`. `ChatRequest.session_id`(현재 미사용 `str` 필드)는 제거한다.

- [ ] **Step 1: 스키마 전체 교체**

`ai/api/schemas.py`를 아래로 전체 교체:

```python
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
```

- [ ] **Step 2: 임포트·검증 확인**

Run (`ai/` 디렉터리에서, 인프라 불필요):
```bash
.venv/Scripts/python.exe -c "
from api.schemas import ChatRequest, ChatResponse, HistoryTurn, SummaryUpdateRequest, SummaryUpdateResponse

req = ChatRequest(question='질문', age=20, history=[{'role': 'user', 'content': '이전 질문'}], summary='요약')
assert req.history[0].role == 'user'
assert not hasattr(req, 'session_id')

resp = ChatResponse(answer='답', sources=[], age_group_label='성인', question='질문', age=20)
assert resp.standalone_query is None
assert resp.rewrite_applied is False

su_req = SummaryUpdateRequest(session_id=1, turns_to_fold=[{'role':'user','content':'a'}], through_message_id=5)
assert su_req.prev_summary is None

print('[PASS] 스키마 5건 검증 완료')
"
```
Expected: `[PASS] 스키마 5건 검증 완료` 출력, 에러 없음.

- [ ] **Step 3: Commit**

```bash
git add ai/api/schemas.py
git commit -m "feat: /chat 스키마에 history/summary/standalone_query 추가, 미사용 session_id 제거, /summary/update 스키마 추가"
```

---

### Task 6: 파이프라인 통합 — 재작성·이중 채널 검색·하드 캡 배선

**Files:**
- Modify: `ai/rag/pipeline.py`

**Interfaces:**
- Consumes: Task 2의 `rewrite` 모듈(`rewrite.needs_rewrite`, `rewrite.rewrite_query`), Task 3의 `retriever.search_multi`/`retriever.format_context`, Task 4의 `build_prompt(..., summary=, history=)`.
- Produces: `LegalRAGPipeline.run(question, age, law_category=None, history=None, summary=None) -> dict` — 반환 딕셔너리에 `standalone_query`(str 또는 None)와 `rewrite_applied`(bool)가 새로 추가된다. 기존 키(`answer`/`sources`/`age_group_label`/`context`/`citation_check`)는 그대로. `history`/`summary`를 생략하면(기존 호출부 포함) 재작성이 걸리지 않아(이력이 없으므로) 기존과 완전히 동일하게 동작한다.

- [ ] **Step 1: 임포트 교체**

`ai/rag/pipeline.py` 상단의 임포트 블록(현재 13-16행)을 교체:

```python
from rag.retriever import LegalRetriever
from rag.citation import verify_citations
import rag.rewrite as rewrite
from prompt.template import build_prompt
from core.model import generate
```

(`rag.rewrite`를 모듈째 임포트하는 이유는 Task 11의 eval 스크립트가 `rewrite.needs_rewrite`를 몽키패치해서 재작성 켬/끔 A/B 비교를 하기 때문 — `from rag.rewrite import needs_rewrite`로 함수를 직접 가져오면 나중에 몽키패치해도 이 모듈에 이미 바인딩된 참조는 안 바뀐다.)

- [ ] **Step 2: `run()` 메서드 교체**

`LegalRAGPipeline.run`(현재 32-128행) 전체를 교체:

```python
    def run(
        self,
        question: str,
        age: int,
        law_category: str = None,
        history: list = None,
        summary: str = None,
    ) -> dict:
        """
        Args:
            question: 사용자 질문
            age: 사용자 나이
            law_category: 법률 분야 필터 (선택)
            history: 최근 대화 이력 [{"role": "user"|"assistant", "content": str}, ...] (선택)
            summary: 이전 대화 롤링 요약 (선택)

        Returns:
            {
                "answer": 생성된 답변 (미검증 인용이 있으면 경고 문구 추가됨),
                "sources": 참조 문서 목록,
                "age_group_label": 나이대 레이블,
                "context": 검색된 컨텍스트,
                "citation_check": {"citations": [...], "unverified": [...]},
                "standalone_query": 재작성된 질문 (재작성 안 했으면 None),
                "rewrite_applied": 재작성이 실행됐는지 여부
            }
        """
        history = history or []

        # ===========================
        # Step 1. 질문 재작성 게이트 + (필요 시) 재작성
        # ===========================
        rewrite_applied = rewrite.needs_rewrite(question, history)
        standalone_query = None
        if rewrite_applied:
            standalone_query = rewrite.rewrite_query(question, history, summary)
            print(f"[INFO] 질문 재작성: '{question}' → '{standalone_query}'")

        # ===========================
        # Step 2. 이중 채널 검색 (재작성 안 했으면 원본 질문 하나로만 — 기존과 동일)
        # ===========================
        queries = [question, standalone_query] if rewrite_applied else [question]
        print(f"[INFO] 검색 중: {question[:30]}...")
        results = self.retriever.search_multi(queries, law_category)

        if not results:
            return {
                "answer": "관련 법률 문서를 찾을 수 없습니다. 질문을 다시 입력해주세요.",
                "sources": [],
                "age_group_label": "",
                "context": "",
                "citation_check": {"citations": [], "unverified": []},
                "standalone_query": standalone_query,
                "rewrite_applied": rewrite_applied,
            }

        context = self.retriever.format_context(results)

        # ===========================
        # Step 3. 나이대별 프롬프트 구성 (요약·이력 포함, 하드 캡 적용)
        # ===========================
        prompt = build_prompt(
            question=question,
            context=context,
            age=age,
            summary=summary,
            history=history,
        )

        # ===========================
        # Step 4. LLM 추론
        # ===========================
        print(f"[INFO] 답변 생성 중... (나이대: {prompt['age_group_label']})")
        answer = generate(
            system_prompt=prompt["system"],
            user_message=prompt["user"],
        )

        # ===========================
        # Step 5. 인용 조문 검증
        #
        # 컨텍스트에 없는 "OO법 제N조" 인용은 모델이 지어냈을 가능성이 높음
        # (eval에서 반복 확인된 환각 패턴). 못 찾은 인용이 있으면 답변에
        # 경고를 덧붙인다 — 문장을 손대지 않고 뒤에 붙이는 방식이라
        # 답변 자체의 문맥은 그대로 유지된다.
        # ===========================
        citation_check = verify_citations(answer, context)
        if citation_check["unverified"]:
            print(f"[WARN] 미검증 인용 발견: {citation_check['unverified']}")
            answer += (
                "\n\n[알림] 위 답변에 포함된 다음 인용은 제공된 문서에서 확인되지 않았습니다: "
                + ", ".join(citation_check["unverified"])
                + ". 실제 적용 전 원문을 반드시 확인하세요."
            )

        # ===========================
        # Step 6. 출처 정리
        # ===========================
        sources = [
            {
                "doc_id": doc["doc_id"],
                "law_category": doc["law_category"],
                "doc_type": doc["doc_type"],
                "source": doc["source"],
                "score": doc["score"],
                "preview": doc["text"][:100] + "...",
            }
            for doc in results
        ]

        return {
            "answer": answer,
            "sources": sources,
            "age_group_label": prompt["age_group_label"],
            "context": context,
            "citation_check": citation_check,
            "standalone_query": standalone_query,
            "rewrite_applied": rewrite_applied,
        }
```

- [ ] **Step 3: `test()`에 멀티턴 케이스 1건 추가**

`test()` 함수(현재 146-173행)의 `test_cases` 리스트 바로 아래, `for case in test_cases:` 루프 뒤에 멀티턴 케이스를 추가:

```python
def test():
    pipeline = get_pipeline()

    test_cases = [
        {"question": "계약서에 도장 안 찍으면 어떻게 되나요?", "age": 8},
        {"question": "상표권 침해 판단 기준은 무엇인가요?",    "age": 25},
        {"question": "임의동행 요청 시 경찰관이 해야 할 절차는?", "age": 45},
    ]

    for case in test_cases:
        print(f"\n{'='*60}")
        print(f"질문: {case['question']}")
        print(f"나이: {case['age']}세")
        print(f"{'='*60}")

        result = pipeline.run(
            question=case["question"],
            age=case["age"],
        )

        print(f"나이대: {result['age_group_label']}")
        print(f"재작성 적용: {result['rewrite_applied']}")
        print(f"\n[답변]")
        print(result["answer"])
        print(f"\n[참조 문서]")
        for src in result["sources"]:
            print(f"  - {src['law_category']} / {src['doc_type']} (점수: {src['score']})")
            print(f"    {src['preview']}")

    # --- 멀티턴: 재작성 게이트가 실제로 걸리는 케이스 ---
    print(f"\n{'='*60}")
    print("멀티턴 케이스 — 재작성 동작 확인")
    print(f"{'='*60}")
    history = [
        {"role": "user", "content": "전세 계약 갱신을 거부당했어요"},
        {"role": "assistant", "content": "임대인은 정당한 사유 없이 갱신을 거부할 수 없습니다."},
    ]
    result = pipeline.run(
        question="그럼 계약금은 어떻게 되나요?",
        age=28,
        history=history,
    )
    print(f"재작성 적용: {result['rewrite_applied']}")
    print(f"재작성된 질문: {result['standalone_query']}")
    print(f"\n[답변]\n{result['answer']}")


if __name__ == "__main__":
    test()
```

- [ ] **Step 4: 실행 확인**

Run (`ai/` 디렉터리에서, OpenSearch + Ollama(legal-gemma, gemma3:1b) 필요):
```bash
.venv/Scripts/python.exe rag/pipeline.py
```
Expected: 기존 3개 단일턴 케이스가 이전과 동일하게 동작(재작성 적용: False, 이력이 없으므로). 멀티턴 케이스에서 `재작성 적용: True`, `재작성된 질문`이 "그럼 계약금은..." 대신 "전세 계약금은 어떻게 되나요?" 류의 독립 질문으로 나오는지 확인. 라이브 인프라가 없으면 "실행 불가 — 라이브 인프라 필요"로 보고(Task 3·4에서 이미 순수 로직은 검증됐으므로 배선 자체의 정합성만 코드 리뷰로 재확인).

- [ ] **Step 5: Commit**

```bash
git add ai/rag/pipeline.py
git commit -m "feat: 파이프라인에 재작성 게이트·이중 채널 검색·요약/이력 배선"
```

---

### Task 7: 대화 요약 갱신 함수 + `/summary/update` 엔드포인트

**Files:**
- Create: `ai/rag/summarize.py`
- Modify: `ai/api/router.py`

**Interfaces:**
- Consumes: Task 1의 `generate()`, Task 5의 `SummaryUpdateRequest`/`SummaryUpdateResponse`.
- Produces: `update_summary(prev_summary: str, turns_to_fold: list) -> str`(300자 이내로 자름). `POST /summary/update` — Spring의 `ChatMemoryAsyncService`(Task 10)가 이 엔드포인트를 호출한다. FastAPI 라우터 프리픽스는 `main.py`의 `app.include_router(router, prefix="/api/v1")`이므로 최종 경로는 `/api/v1/summary/update`.

- [ ] **Step 1: `summarize.py` 작성**

`ai/rag/summarize.py` (신규):

```python
"""
대화 요약 갱신 — Spring의 ChatMemoryAsyncService가 사용자 응답을 보낸 뒤
비동기로 호출하는 순수 함수. 세션 상태를 전혀 모른다(Spring이 prev_summary와
아직 요약에 안 접힌 턴들을 넘겨주고, 결과를 다시 Spring이 저장한다).
"""

import sys
import os
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from core.model import generate

SUMMARY_MAX_LEN = 300


def _format_turns(turns: list) -> str:
    lines = []
    for turn in turns:
        speaker = "사용자" if turn["role"] == "user" else "챗봇"
        lines.append(f"{speaker}: {turn['content']}")
    return "\n".join(lines)


def update_summary(prev_summary: str, turns_to_fold: list) -> str:
    prompt = f"""다음은 지금까지의 대화 요약과, 아직 요약에 반영되지 않은 최근 대화다.
최근 대화의 핵심만 반영해 전체 요약을 한 문단으로 다시 써라. 요약문만 출력하라.

[기존 요약]
{prev_summary or '없음'}

[최근 대화]
{_format_turns(turns_to_fold)}
"""
    summary = generate(
        system_prompt="",
        user_message=prompt,
        max_tokens=200,
        temperature=0.1,
    ).strip()
    return summary[:SUMMARY_MAX_LEN]


# ===========================
# 테스트
# ===========================
def test():
    turns = [
        {"role": "user", "content": "전세 계약 갱신을 거부당했어요"},
        {"role": "assistant", "content": "임대인은 정당한 사유 없이 갱신을 거부할 수 없습니다. 계약갱신요구권 행사 여부를 확인해야 합니다."},
        {"role": "user", "content": "그럼 계약금은 어떻게 되나요?"},
        {"role": "assistant", "content": "계약이 유효하게 존속하는 한 계약금은 그대로 유지되며, 갱신 거부가 부당하면 반환 의무가 발생하지 않습니다."},
    ]
    summary = update_summary(None, turns)
    print(f"[요약] {summary}")
    assert len(summary) <= SUMMARY_MAX_LEN
    print(f"[PASS] 요약 길이 {len(summary)}자 (<= {SUMMARY_MAX_LEN})")


if __name__ == "__main__":
    test()
```

- [ ] **Step 2: `test()` 실행 확인**

Run (`ai/` 디렉터리에서, Ollama(legal-gemma) 필요):
```bash
.venv/Scripts/python.exe rag/summarize.py
```
Expected: `[요약] ...` 출력 후 `[PASS] 요약 길이 N자 (<= 300)`. 떠 있지 않으면 "실행 불가 — 라이브 인프라 필요"로 보고.

- [ ] **Step 3: 라우터에 엔드포인트 추가**

`ai/api/router.py`의 임포트 블록(현재 13-15행)을 교체:

```python
from fastapi import APIRouter, HTTPException
from api.schemas import (
    ChatRequest, ChatResponse, HealthResponse, SourceDocument, DocumentDetail,
    SummaryUpdateRequest, SummaryUpdateResponse,
)
from rag.pipeline import get_pipeline
from rag.summarize import update_summary
```

`/chat` 핸들러(현재 34-66행)를 교체해 `history`/`summary`를 파이프라인에 넘기고 새 응답 필드를 채운다:

```python
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
```

`@router.get("/documents/{doc_id}", ...)` 핸들러 뒤(파일 끝)에 새 엔드포인트를 추가:

```python
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
```

- [ ] **Step 4: 엔드포인트 수동 검증**

FastAPI 서버를 띄운다(OpenSearch + Ollama 필요):
```bash
cd /f/workspce/legal-rag-chatbot/ai && .venv/Scripts/python.exe main.py
```
다른 터미널에서:
```bash
curl -s -X POST http://localhost:8000/api/v1/summary/update \
  -H "Content-Type: application/json" \
  -d '{"session_id": 1, "prev_summary": null, "turns_to_fold": [{"role":"user","content":"전세 계약 갱신을 거부당했어요"},{"role":"assistant","content":"임대인은 정당한 사유 없이 갱신을 거부할 수 없습니다."}], "through_message_id": 2}'
```
Expected: `{"summary": "...", "through_message_id": 2}` 형태의 JSON 응답, 500 에러 없음.

```bash
curl -s -X POST http://localhost:8000/api/v1/chat \
  -H "Content-Type: application/json" \
  -d '{"question": "그럼 계약금은 어떻게 되나요?", "age": 28, "history": [{"role":"user","content":"전세 계약 갱신을 거부당했어요"},{"role":"assistant","content":"임대인은 정당한 사유 없이 갱신을 거부할 수 없습니다."}]}'
```
Expected: 응답 JSON에 `"rewrite_applied": true`와 채워진 `"standalone_query"`가 보임. 서버 기동이 안 되면(라이브 인프라 미기동) "실행 불가 — 라이브 인프라 필요"로 보고.

- [ ] **Step 5: Commit**

```bash
git add ai/rag/summarize.py ai/api/router.py
git commit -m "feat: 대화 요약 갱신 함수 + POST /summary/update 엔드포인트, /chat에 history/summary 배선"
```

---

### Task 8: Spring — `chat_session_summary` 엔티티·DAO·매퍼

**Files:**
- Create: `backend_spring/src/main/java/com/legal/backend/entity/ChatSessionSummary.java`
- Create: `backend_spring/src/main/java/com/legal/backend/dao/ChatSessionSummaryDao.java`
- Create: `backend_spring/src/main/resources/mybatis/ChatSessionSummaryMapper.xml`
- Test: `backend_spring/src/test/java/com/legal/backend/dao/ChatSessionSummaryDaoTest.java` — 이 Task는 DAO 인터페이스·매퍼 SQL만 다루고 실제 SQL 실행 검증은 라이브 MySQL이 필요해 Step 4에서 수동 검증으로 확인한다(단위 테스트는 만들지 않는다 — Phase 0의 다른 매퍼들도 동일한 이유로 단위 테스트가 없다).

**Interfaces:**
- Consumes: Phase 0에서 이미 만들어진 `chat_session_summary` 테이블(`V1__chat_tables.sql`, 컬럼: `session_id`, `summary`, `through_message_id`, `updated_at`).
- Produces: `ChatSessionSummaryDao.find(Long sessionId) -> ChatSessionSummary`(없으면 null), `ChatSessionSummaryDao.upsertIfNewer(Long sessionId, String summary, Long throughMessageId) -> int`. Task 10(`ChatMemoryAsyncService`)과 Task 11(`ChatService`)이 둘 다 쓴다.

- [ ] **Step 1: 엔티티 작성**

`backend_spring/src/main/java/com/legal/backend/entity/ChatSessionSummary.java` (신규):

```java
package com.legal.backend.entity;

import lombok.*;
import java.time.LocalDateTime;

@Getter @Setter @NoArgsConstructor @AllArgsConstructor
public class ChatSessionSummary {
    private Long sessionId;
    private String summary;
    private Long throughMessageId;
    private LocalDateTime updatedAt;
}
```

- [ ] **Step 2: DAO 인터페이스 작성**

`backend_spring/src/main/java/com/legal/backend/dao/ChatSessionSummaryDao.java` (신규):

```java
package com.legal.backend.dao;

import com.legal.backend.entity.ChatSessionSummary;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

@Mapper
public interface ChatSessionSummaryDao {
    ChatSessionSummary find(@Param("sessionId") Long sessionId);

    int upsertIfNewer(@Param("sessionId") Long sessionId,
                       @Param("summary") String summary,
                       @Param("throughMessageId") Long throughMessageId);
}
```

- [ ] **Step 3: 매퍼 XML 작성**

`backend_spring/src/main/resources/mybatis/ChatSessionSummaryMapper.xml` (신규). `upsertIfNewer`는 `through_message_id`가 더 새 값일 때만 덮어쓰는 낙관적 갱신이다 — 스펙 §7.3에 정의된 그대로:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE mapper PUBLIC "-//mybatis.org//DTD Mapper 3.0//EN"
        "http://mybatis.org/dtd/mybatis-3-mapper.dtd">
<mapper namespace="com.legal.backend.dao.ChatSessionSummaryDao">

    <select id="find" resultType="ChatSessionSummary">
        SELECT session_id AS sessionId, summary,
               through_message_id AS throughMessageId, updated_at AS updatedAt
        FROM chat_session_summary
        WHERE session_id = #{sessionId}
    </select>

    <insert id="upsertIfNewer">
        INSERT INTO chat_session_summary (session_id, summary, through_message_id)
        VALUES (#{sessionId}, #{summary}, #{throughMessageId})
        ON DUPLICATE KEY UPDATE
            summary = IF(through_message_id < #{throughMessageId}, #{summary}, summary),
            through_message_id = IF(through_message_id < #{throughMessageId}, #{throughMessageId}, through_message_id)
    </insert>

</mapper>
```

- [ ] **Step 4: 빌드 확인 + 수동 SQL 검증**

Run:
```bash
cd backend_spring && export PATH="/c/Users/SMT21/.m2/wrapper/dists/apache-maven-3.9.16-bin/5grr65jo27hi51sujmtcldfovl/apache-maven-3.9.16/bin:$PATH" && export MAVEN_OPTS="-Dfile.encoding=UTF-8" && mvn -q compile
```
Expected: BUILD SUCCESS(컴파일만 확인 — `@Mapper` 인터페이스는 `MapperScannerConfigurer`가 앱 기동 시점에 XML과 묶으므로 컴파일 단계에선 SQL 오류를 못 잡는다).

MySQL이 떠 있으면(`docker compose up -d mysql`) 앱을 띄우지 않고도 SQL 자체를 직접 검증할 수 있다:
```bash
docker exec lexai-mysql mysql -u legal -p'<DB_PASSWORD>' legal_chatbot -e "
INSERT INTO chat_session (id, user_id, title) VALUES (999, 1, '테스트') ON DUPLICATE KEY UPDATE title=title;
INSERT INTO chat_session_summary (session_id, summary, through_message_id) VALUES (999, '초기 요약', 2)
ON DUPLICATE KEY UPDATE
  summary = IF(through_message_id < 2, '초기 요약', summary),
  through_message_id = IF(through_message_id < 2, 2, through_message_id);
SELECT * FROM chat_session_summary WHERE session_id=999;
INSERT INTO chat_session_summary (session_id, summary, through_message_id) VALUES (999, '더 새 요약', 5)
ON DUPLICATE KEY UPDATE
  summary = IF(through_message_id < 5, '더 새 요약', summary),
  through_message_id = IF(through_message_id < 5, 5, through_message_id);
SELECT * FROM chat_session_summary WHERE session_id=999;
DELETE FROM chat_session_summary WHERE session_id=999;
DELETE FROM chat_session WHERE id=999;
"
```
Expected: 첫 SELECT는 `('초기 요약', 2)`, 두 번째 SELECT는 `('더 새 요약', 5)` — `through_message_id`가 더 큰 값으로 왔을 때만 갱신됨을 확인. 라이브 MySQL이 없으면 "실행 불가 — 라이브 인프라 필요"로 보고.

- [ ] **Step 5: Commit**

```bash
git add backend_spring/src/main/java/com/legal/backend/entity/ChatSessionSummary.java backend_spring/src/main/java/com/legal/backend/dao/ChatSessionSummaryDao.java backend_spring/src/main/resources/mybatis/ChatSessionSummaryMapper.xml
git commit -m "feat: chat_session_summary 엔티티·DAO·매퍼 추가"
```

---

### Task 9: Spring — `ChatMessageDao`에 이력 조회 메서드 추가

**Files:**
- Modify: `backend_spring/src/main/java/com/legal/backend/dao/ChatMessageDao.java`
- Modify: `backend_spring/src/main/resources/mybatis/ChatMessageMapper.xml`

**Interfaces:**
- Produces: `ChatMessageDao.findRecentMessages(Long sessionId, int limit) -> List<ChatMessage>`(최근 `limit`개, 오래된 순 정렬) — Task 11(`ChatService`)이 이력 로드에 쓴다. `ChatMessageDao.findAfterMessageId(Long sessionId, long afterId) -> List<ChatMessage>`(해당 id보다 큰 메시지 전부, 오래된 순) — Task 10(`ChatMemoryAsyncService`)이 "아직 요약에 안 접힌 턴" 조회에 쓴다.

- [ ] **Step 1: DAO 인터페이스에 메서드 추가**

`backend_spring/src/main/java/com/legal/backend/dao/ChatMessageDao.java` 전체를 교체:

```java
package com.legal.backend.dao;

import com.legal.backend.entity.ChatMessage;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

import java.util.List;

@Mapper
public interface ChatMessageDao {
    List<ChatMessage> findBySession(@Param("sessionId") Long sessionId);
    List<ChatMessage> findRecentMessages(@Param("sessionId") Long sessionId, @Param("limit") int limit);
    List<ChatMessage> findAfterMessageId(@Param("sessionId") Long sessionId, @Param("afterId") long afterId);
    int insert(ChatMessage message);
}
```

- [ ] **Step 2: 매퍼 XML에 쿼리 추가**

`backend_spring/src/main/resources/mybatis/ChatMessageMapper.xml`의 `<select id="findBySession">` 바로 아래에 추가:

```xml
    <!--
        최근 limit개를 id DESC로 뽑은 뒤 다시 ASC로 정렬 — MySQL은 LIMIT 뒤에
        곧바로 다시 정렬할 수 없어 서브쿼리(derived table)로 감싼다.
    -->
    <select id="findRecentMessages" resultType="ChatMessage">
        SELECT id, session_id AS sessionId, role, content,
               standalone_query AS standaloneQuery, sources_json AS sourcesJson,
               created_at AS createdAt
        FROM (
            SELECT id, session_id, role, content, standalone_query, sources_json, created_at
            FROM chat_message
            WHERE session_id = #{sessionId}
            ORDER BY id DESC
            LIMIT #{limit}
        ) recent
        ORDER BY id ASC
    </select>

    <select id="findAfterMessageId" resultType="ChatMessage">
        SELECT id, session_id AS sessionId, role, content,
               standalone_query AS standaloneQuery, sources_json AS sourcesJson,
               created_at AS createdAt
        FROM chat_message
        WHERE session_id = #{sessionId} AND id > #{afterId}
        ORDER BY id ASC
    </select>
```

- [ ] **Step 3: 빌드 확인 + 수동 SQL 검증**

Run:
```bash
cd backend_spring && export PATH="/c/Users/SMT21/.m2/wrapper/dists/apache-maven-3.9.16-bin/5grr65jo27hi51sujmtcldfovl/apache-maven-3.9.16/bin:$PATH" && export MAVEN_OPTS="-Dfile.encoding=UTF-8" && mvn -q compile
```
Expected: BUILD SUCCESS.

MySQL이 떠 있으면:
```bash
docker exec lexai-mysql mysql -u legal -p'<DB_PASSWORD>' legal_chatbot -e "
INSERT INTO chat_session (id, user_id, title) VALUES (998, 1, '테스트') ON DUPLICATE KEY UPDATE title=title;
INSERT INTO chat_message (session_id, role, content) VALUES
  (998,'user','1턴 질문'),(998,'assistant','1턴 답변'),
  (998,'user','2턴 질문'),(998,'assistant','2턴 답변'),
  (998,'user','3턴 질문'),(998,'assistant','3턴 답변');
SELECT id, role, content FROM (
  SELECT id, session_id, role, content FROM chat_message WHERE session_id=998 ORDER BY id DESC LIMIT 4
) recent ORDER BY id ASC;
DELETE FROM chat_message WHERE session_id=998;
DELETE FROM chat_session WHERE id=998;
"
```
Expected: 최근 4개(2턴째 질문부터 3턴째 답변까지) 6건 중 뒤 4건이 오래된 순으로 나옴. 라이브 MySQL이 없으면 "실행 불가 — 라이브 인프라 필요"로 보고.

- [ ] **Step 4: Commit**

```bash
git add backend_spring/src/main/java/com/legal/backend/dao/ChatMessageDao.java backend_spring/src/main/resources/mybatis/ChatMessageMapper.xml
git commit -m "feat: ChatMessageDao에 최근 이력·요약 미반영 구간 조회 메서드 추가"
```

---

### Task 10: Spring — `ChatMemoryAsyncService` (요약 갱신 비동기 워커)

**Files:**
- Create: `backend_spring/src/main/java/com/legal/backend/service/ChatMemoryAsyncService.java`
- Test: `backend_spring/src/test/java/com/legal/backend/service/ChatMemoryAsyncServiceTest.java`

**Interfaces:**
- Consumes: Task 8의 `ChatSessionSummaryDao`, Task 9의 `ChatMessageDao.findAfterMessageId`, Phase 0의 `webClient` 빈(`root-context.xml`에 이미 정의됨), Phase 0의 `chatMemoryExecutor` 빈(`AsyncConfig`, 지금까지 아무도 안 썼음 — 이 Task가 처음 실사용).
- Produces: `ChatMemoryAsyncService.updateSummaryIfNeeded(Long sessionId)` — `@Async("chatMemoryExecutor")`. Task 11(`ChatService`)이 응답 반환 직전에 호출한다(호출 자체는 논블로킹).

이 서비스는 `ChatService`가 아니라 별도 빈이다 — `@Async`가 프록시 기반이라 같은 빈 안에서 self-invocation하면 프록시를 안 타 그냥 동기로 실행돼버린다(Phase 0의 `ChatMessagePersistenceService`를 `@Transactional` 때문에 분리한 것과 동일한 이유).

- [ ] **Step 1: 실패하는 테스트 작성**

`backend_spring/src/test/java/com/legal/backend/service/ChatMemoryAsyncServiceTest.java` (신규). `@Async`가 붙어있어도 단위 테스트에서는 프록시 없이 메서드를 직접 호출하므로 동기적으로 검증 가능하다(이 프로젝트엔 Spring 컨텍스트를 띄우는 테스트가 없다는 기존 제약을 그대로 따른다 — WebClient 체인은 Phase 0의 `ChatServiceTest`와 같은 deep-stub 패턴을 쓴다):

```java
package com.legal.backend.service;

import com.legal.backend.dao.ChatMessageDao;
import com.legal.backend.dao.ChatSessionSummaryDao;
import com.legal.backend.entity.ChatMessage;
import com.legal.backend.entity.ChatSessionSummary;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Answers;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.web.reactive.function.client.WebClient;

import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class ChatMemoryAsyncServiceTest {

    @Mock
    private ChatMessageDao chatMessageDao;
    @Mock
    private ChatSessionSummaryDao chatSessionSummaryDao;
    @Mock(answer = Answers.RETURNS_DEEP_STUBS)
    private WebClient webClient;

    @InjectMocks
    private ChatMemoryAsyncService chatMemoryAsyncService;

    @Test
    void updateSummaryIfNeeded_미접힌_턴이_2턴_이하면_아무것도_안한다() {
        when(chatSessionSummaryDao.find(5L)).thenReturn(null);
        // 2턴(4메시지) 이하 — 트리거 안 됨
        when(chatMessageDao.findAfterMessageId(5L, 0L)).thenReturn(List.of(
                msg(1L), msg(2L), msg(3L), msg(4L)
        ));

        chatMemoryAsyncService.updateSummaryIfNeeded(5L);

        verify(chatSessionSummaryDao, never()).upsertIfNewer(any(), any(), any());
        verifyNoInteractions(webClient);
    }

    @Test
    void updateSummaryIfNeeded_미접힌_턴이_2턴_초과면_FastAPI를_호출하고_upsert한다() {
        when(chatSessionSummaryDao.find(5L)).thenReturn(null);
        // 3턴(6메시지) — 트리거 됨
        List<ChatMessage> unfolded = List.of(
                msg(1L), msg(2L), msg(3L), msg(4L), msg(5L), msg(6L)
        );
        when(chatMessageDao.findAfterMessageId(5L, 0L)).thenReturn(unfolded);

        when(webClient.post()
                .uri(anyString())
                .bodyValue(any())
                .retrieve()
                .bodyToMono(Map.class)
                .block())
                .thenReturn(Map.of("summary", "새 요약", "through_message_id", 6));

        chatMemoryAsyncService.updateSummaryIfNeeded(5L);

        verify(chatSessionSummaryDao).upsertIfNewer(5L, "새 요약", 6L);
    }

    @Test
    void updateSummaryIfNeeded_FastAPI_응답이_비어있으면_예외를_던진다() {
        when(chatSessionSummaryDao.find(5L)).thenReturn(null);
        List<ChatMessage> unfolded = List.of(
                msg(1L), msg(2L), msg(3L), msg(4L), msg(5L), msg(6L)
        );
        when(chatMessageDao.findAfterMessageId(5L, 0L)).thenReturn(unfolded);

        when(webClient.post()
                .uri(anyString())
                .bodyValue(any())
                .retrieve()
                .bodyToMono(Map.class)
                .block())
                .thenReturn(null);

        assertThrows(IllegalStateException.class,
                () -> chatMemoryAsyncService.updateSummaryIfNeeded(5L));

        verify(chatSessionSummaryDao, never()).upsertIfNewer(any(), any(), any());
    }

    @Test
    void updateSummaryIfNeeded_기존_요약이_있으면_그_이후_구간만_조회한다() {
        ChatSessionSummary existing = new ChatSessionSummary(5L, "기존 요약", 10L, null);
        when(chatSessionSummaryDao.find(5L)).thenReturn(existing);
        when(chatMessageDao.findAfterMessageId(5L, 10L)).thenReturn(List.of());

        chatMemoryAsyncService.updateSummaryIfNeeded(5L);

        verify(chatMessageDao).findAfterMessageId(5L, 10L);
        verifyNoInteractions(webClient);
    }

    private ChatMessage msg(Long id) {
        ChatMessage m = new ChatMessage();
        m.setId(id);
        m.setSessionId(5L);
        m.setRole(id % 2 == 1 ? "user" : "assistant");
        m.setContent("메시지 " + id);
        return m;
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run:
```bash
cd backend_spring && export PATH="/c/Users/SMT21/.m2/wrapper/dists/apache-maven-3.9.16-bin/5grr65jo27hi51sujmtcldfovl/apache-maven-3.9.16/bin:$PATH" && export MAVEN_OPTS="-Dfile.encoding=UTF-8" && mvn -q test -Dtest=ChatMemoryAsyncServiceTest
```
Expected: FAIL — `ChatMemoryAsyncService` 클래스가 없어 컴파일 에러.

- [ ] **Step 3: `ChatMemoryAsyncService` 작성**

`backend_spring/src/main/java/com/legal/backend/service/ChatMemoryAsyncService.java` (신규):

```java
package com.legal.backend.service;

import com.legal.backend.dao.ChatMessageDao;
import com.legal.backend.dao.ChatSessionSummaryDao;
import com.legal.backend.entity.ChatMessage;
import com.legal.backend.entity.ChatSessionSummary;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.scheduling.annotation.Async;
import org.springframework.stereotype.Service;
import org.springframework.web.reactive.function.client.WebClient;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * 응답 반환 뒤 실행되는 후속 작업 전용 빈 — ChatService 안에 두지 않는 이유는
 * @Async가 프록시 기반이라 같은 빈 안의 self-invocation에는 적용되지 않기
 * 때문(ChatMessagePersistenceService를 @Transactional 때문에 분리한 것과 동일).
 * 예외는 여기서 삼키지 않는다 — AsyncConfig.getAsyncUncaughtExceptionHandler()가
 * 잡아서 기록하도록 그대로 던진다(Phase 0에서 만들어 두고 아직 안 쓰던 경로).
 */
@Service
public class ChatMemoryAsyncService {

    // 아직 요약에 안 접힌 턴이 2턴(4메시지)을 넘으면(3턴째 질문부터) 요약을 갱신한다.
    private static final int SUMMARY_TRIGGER_TURNS = 2;

    @Autowired
    private WebClient webClient;
    @Autowired
    private ChatMessageDao chatMessageDao;
    @Autowired
    private ChatSessionSummaryDao chatSessionSummaryDao;

    @Async("chatMemoryExecutor")
    public void updateSummaryIfNeeded(Long sessionId) {
        ChatSessionSummary prev = chatSessionSummaryDao.find(sessionId);
        long throughId = prev != null ? prev.getThroughMessageId() : 0L;

        List<ChatMessage> unfolded = chatMessageDao.findAfterMessageId(sessionId, throughId);
        int unfoldedTurns = unfolded.size() / 2;
        if (unfoldedTurns <= SUMMARY_TRIGGER_TURNS) {
            return;
        }

        Map<String, Object> body = new HashMap<>();
        body.put("session_id", sessionId);
        body.put("prev_summary", prev != null ? prev.getSummary() : null);
        body.put("turns_to_fold", toTurnPayload(unfolded));
        long newThroughId = unfolded.get(unfolded.size() - 1).getId();
        body.put("through_message_id", newThroughId);

        Map<?, ?> result = webClient.post()
                .uri("/api/v1/summary/update")
                .bodyValue(body)
                .retrieve()
                .bodyToMono(Map.class)
                .block();

        if (result == null) {
            throw new IllegalStateException("요약 갱신: FastAPI 응답이 비어 있습니다. sessionId=" + sessionId);
        }

        String newSummary = (String) result.get("summary");
        chatSessionSummaryDao.upsertIfNewer(sessionId, newSummary, newThroughId);
    }

    private List<Map<String, String>> toTurnPayload(List<ChatMessage> messages) {
        List<Map<String, String>> payload = new ArrayList<>();
        for (ChatMessage m : messages) {
            Map<String, String> turn = new HashMap<>();
            turn.put("role", m.getRole());
            turn.put("content", m.getContent());
            payload.add(turn);
        }
        return payload;
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run:
```bash
mvn -q test -Dtest=ChatMemoryAsyncServiceTest
```
Expected: PASS(4/4).

- [ ] **Step 5: Commit**

```bash
git add backend_spring/src/main/java/com/legal/backend/service/ChatMemoryAsyncService.java backend_spring/src/test/java/com/legal/backend/service/ChatMemoryAsyncServiceTest.java
git commit -m "feat: ChatMemoryAsyncService 추가 — 응답 후 비동기로 대화 요약 갱신"
```

---

### Task 11: Spring — `ChatService` 통합 배선 (이력·요약 로드 → FastAPI 전달 → 비동기 요약 트리거)

**Files:**
- Modify: `backend_spring/src/main/java/com/legal/backend/service/ChatService.java`
- Modify: `backend_spring/src/main/java/com/legal/backend/service/ChatMessagePersistenceService.java`
- Modify: `backend_spring/src/main/java/com/legal/backend/dto/ChatResponse.java`
- Modify: `backend_spring/src/test/java/com/legal/backend/service/ChatServiceTest.java`

**Interfaces:**
- Consumes: Task 8의 `ChatSessionSummaryDao`, Task 9의 `ChatMessageDao.findRecentMessages`, Task 10의 `ChatMemoryAsyncService.updateSummaryIfNeeded`.
- Produces: `ChatService.chat()`이 기존 세션이면 최근 이력(4메시지)·요약을 로드해 FastAPI에 넘기고, 응답의 `standalone_query`를 assistant 메시지에 저장하고, 저장 뒤 `ChatMemoryAsyncService.updateSummaryIfNeeded`를 논블로킹으로 호출한다.

이 Task는 기존 `resolveSession(Long, Long, String)`(Phase 0에서 만들어 3개 테스트가 이미 검증 중)의 동작·시그니처를 바꾸지 않는다 — FastAPI 호출 이후 세션을 만들거나 재사용하는 기존 로직은 그대로 두고, FastAPI 호출 **이전에** "이 세션이 이미 내 것으로 존재하는가"만 별도로 조회하는 헬퍼(`findOwnedSession`, 신규)를 추가한다. 세션이 존재하면 `chatSessionDao.findById`가 두 번(헬퍼에서 한 번, 이후 `resolveSession`에서 한 번) 불릴 수 있는데, 의도적인 트레이드오프다 — 이미 3개 테스트로 검증된 `resolveSession`의 "응답 실패 시 세션을 만들지 않는다"는 불변조건(Finding 1, Phase 0에서 고침)을 건드리지 않기 위해서다.

- [ ] **Step 1: `ChatResponse.java`에 필드 추가**

`backend_spring/src/main/java/com/legal/backend/dto/ChatResponse.java`를 읽어서 기존 필드 목록 뒤에 추가한다(파일 상단에 `import com.fasterxml.jackson.annotation.JsonProperty;`가 이미 있는지 확인하고 없으면 추가):

```java
    @JsonProperty("standalone_query")
    private String standaloneQuery;

    @JsonProperty("rewrite_applied")
    private boolean rewriteApplied;
```

- [ ] **Step 2: 실패하는 테스트부터 — `ChatServiceTest`에 새 케이스 추가**

`backend_spring/src/test/java/com/legal/backend/service/ChatServiceTest.java`를 아래 전체 내용으로 교체(기존 5개 테스트 유지 + 새 2개 추가 + null-response 테스트의 `findById` 관련 assert 수정):

```java
package com.legal.backend.service;

import com.legal.backend.dao.ChatMessageDao;
import com.legal.backend.dao.ChatSessionDao;
import com.legal.backend.dao.ChatSessionSummaryDao;
import com.legal.backend.dto.ChatRequest;
import com.legal.backend.dto.ChatResponse;
import com.legal.backend.entity.ChatMessage;
import com.legal.backend.entity.ChatSession;
import com.legal.backend.entity.ChatSessionSummary;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Answers;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.web.reactive.function.client.WebClient;

import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class ChatServiceTest {

    @Mock
    private ChatSessionDao chatSessionDao;
    @Mock
    private ChatMessageDao chatMessageDao;
    @Mock
    private ChatSessionSummaryDao chatSessionSummaryDao;
    @Mock
    private ChatMessagePersistenceService chatMessagePersistenceService;
    @Mock
    private ChatMemoryAsyncService chatMemoryAsyncService;
    @Mock(answer = Answers.RETURNS_DEEP_STUBS)
    private WebClient webClient;

    @InjectMocks
    private ChatService chatService;

    @Test
    void resolveSession_sessionId가_null이면_새_세션을_만든다() {
        ChatSession created = chatService.resolveSession(null, 7L, "가압류가 뭔가요?");

        ArgumentCaptor<ChatSession> captor = ArgumentCaptor.forClass(ChatSession.class);
        verify(chatSessionDao).insert(captor.capture());
        assertEquals(7L, captor.getValue().getUserId());
        assertEquals("가압류가 뭔가요?", captor.getValue().getTitle());
    }

    @Test
    void resolveSession_남의_세션이면_새_세션으로_대체한다() {
        ChatSession others = new ChatSession(5L, 999L, "다른 사람 대화", null, null, null);
        when(chatSessionDao.findById(5L)).thenReturn(others);

        chatService.resolveSession(5L, 7L, "질문");

        verify(chatSessionDao).insert(any(ChatSession.class));
    }

    @Test
    void resolveSession_내_세션이면_그대로_반환한다() {
        ChatSession mine = new ChatSession(5L, 7L, "내 대화", null, null, null);
        when(chatSessionDao.findById(5L)).thenReturn(mine);

        ChatSession result = chatService.resolveSession(5L, 7L, "질문");

        assertEquals(mine, result);
        verify(chatSessionDao, never()).insert(any());
    }

    @Test
    void buildTitle_긴_질문은_20자로_잘라_말줄임표를_붙인다() {
        String longQuestion = "이 질문은 스무 글자를 훌쩍 넘는 아주 긴 법률 질문입니다";
        String title = ChatService.buildTitle(longQuestion);

        assertEquals(20, title.length() - 1);          // "…" 제외 20자
        assertEquals('…', title.charAt(title.length() - 1));
    }

    @Test
    void buildTitle_짧은_질문은_그대로_쓴다() {
        assertEquals("짧은 질문", ChatService.buildTitle("짧은 질문"));
    }

    @Test
    void chat_FastAPI_응답이_비어있으면_대화턴을_저장하지_않는다() {
        // WebClient의 post().uri().bodyValue().retrieve().bodyToMono(...).block() 체인이
        // 2xx이지만 빈 바디를 돌려주는 상황을 재현 — .block()이 예외 없이 null을 반환한다.
        when(webClient.post()
                .uri(anyString())
                .bodyValue(any())
                .retrieve()
                .bodyToMono(ChatResponse.class)
                .block())
                .thenReturn(null);

        ChatRequest req = new ChatRequest();
        req.setQuestion("질문");
        req.setSessionId(5L);

        assertThrows(IllegalStateException.class, () -> chatService.chat(req, 7L, 20));

        // 응답이 비어있으면 세션 생성·턴 저장이 일어나지 않아야 한다 (Finding 1: 순서 재배치).
        // findById는 이력 조회를 위해 호출될 수 있다(findOwnedSession) — 그건 읽기 전용이라 무해하다.
        verify(chatSessionDao, never()).insert(any());
        verify(chatMessagePersistenceService, never()).persistTurn(any(), any(), any());
        verify(chatMemoryAsyncService, never()).updateSummaryIfNeeded(any());
    }

    @Test
    void chat_기존_세션이면_이력과_요약을_로드하고_응답_후_요약갱신을_트리거한다() {
        ChatSession mine = new ChatSession(5L, 7L, "내 대화", null, null, null);
        when(chatSessionDao.findById(5L)).thenReturn(mine);

        ChatMessage userMsg = new ChatMessage(1L, 5L, "user", "이전 질문", null, null, null);
        ChatMessage botMsg = new ChatMessage(2L, 5L, "assistant", "이전 답변", null, null, null);
        when(chatMessageDao.findRecentMessages(5L, 4)).thenReturn(List.of(userMsg, botMsg));

        ChatSessionSummary summary = new ChatSessionSummary(5L, "요약본", 2L, null);
        when(chatSessionSummaryDao.find(5L)).thenReturn(summary);

        ChatResponse fastApiResponse = new ChatResponse();
        fastApiResponse.setAnswer("답변");
        when(webClient.post()
                .uri(anyString())
                .bodyValue(any())
                .retrieve()
                .bodyToMono(ChatResponse.class)
                .block())
                .thenReturn(fastApiResponse);

        ChatRequest req = new ChatRequest();
        req.setQuestion("그럼 어떻게 되나요?");
        req.setSessionId(5L);

        ChatResponse result = chatService.chat(req, 7L, 30);

        assertEquals(5L, result.getSessionId());
        verify(chatMessageDao).findRecentMessages(5L, 4);
        verify(chatSessionSummaryDao).find(5L);
        verify(chatMessagePersistenceService).persistTurn(5L, "그럼 어떻게 되나요?", fastApiResponse);
        verify(chatSessionDao).touch(5L);
        verify(chatMemoryAsyncService).updateSummaryIfNeeded(5L);
    }

    @Test
    void chat_새_세션이면_이력_조회_없이_빈_이력으로_진행한다() {
        ChatResponse fastApiResponse = new ChatResponse();
        fastApiResponse.setAnswer("답변");
        when(webClient.post()
                .uri(anyString())
                .bodyValue(any())
                .retrieve()
                .bodyToMono(ChatResponse.class)
                .block())
                .thenReturn(fastApiResponse);

        ChatRequest req = new ChatRequest();
        req.setQuestion("가압류가 뭔가요?");
        req.setSessionId(null);

        chatService.chat(req, 7L, 30);

        verify(chatMessageDao, never()).findRecentMessages(any(), anyInt());
        verify(chatSessionSummaryDao, never()).find(any());
        verify(chatSessionDao).insert(any());
        verify(chatMemoryAsyncService).updateSummaryIfNeeded(any());
    }
}
```

- [ ] **Step 3: 테스트 실패 확인**

Run:
```bash
mvn -q test -Dtest=ChatServiceTest
```
Expected: FAIL — `ChatSessionSummaryDao`/`ChatMemoryAsyncService` 필드가 `ChatService`에 아직 없어 컴파일 에러, 또는 `findRecentMessages`/`chatSessionSummaryDao.find`가 호출 안 돼 verify 실패.

- [ ] **Step 4: `ChatService.java` 교체**

`backend_spring/src/main/java/com/legal/backend/service/ChatService.java` 전체를 교체:

```java
package com.legal.backend.service;

import com.legal.backend.dao.ChatMessageDao;
import com.legal.backend.dao.ChatSessionDao;
import com.legal.backend.dao.ChatSessionSummaryDao;
import com.legal.backend.dto.ChatRequest;
import com.legal.backend.dto.ChatResponse;
import com.legal.backend.entity.ChatMessage;
import com.legal.backend.entity.ChatSession;
import com.legal.backend.entity.ChatSessionSummary;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;
import org.springframework.web.reactive.function.client.WebClient;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

@Service
public class ChatService {

    private static final int TITLE_MAX_LEN = 20;
    // 최근 2턴(user+assistant 페어) = 메시지 4개. 스펙 §3의 HISTORY_WINDOW_TURNS=2.
    private static final int HISTORY_WINDOW_MESSAGES = 4;

    @Autowired
    private WebClient webClient;
    @Autowired
    private ChatSessionDao chatSessionDao;
    @Autowired
    private ChatMessageDao chatMessageDao;
    @Autowired
    private ChatSessionSummaryDao chatSessionSummaryDao;
    @Autowired
    private ChatMessagePersistenceService chatMessagePersistenceService;
    @Autowired
    private ChatMemoryAsyncService chatMemoryAsyncService;

    public ChatResponse chat(ChatRequest req, Long userId, int age) {
        // FastAPI 호출 전: 이미 존재하는 내 세션이면 이력·요약을 실어 보낸다.
        // (세션을 새로 만들지는 않는다 — 그건 FastAPI 성공 후 resolveSession의 몫.
        //  Finding 1: 응답 실패 시 세션이 생기면 안 된다는 불변조건을 유지하기 위함)
        ChatSession existing = findOwnedSession(req.getSessionId(), userId);

        Map<String, Object> body = new HashMap<>();
        body.put("question", req.getQuestion());
        body.put("age", age);
        body.put("law_category", req.getLawCategory());
        body.put("history", existing != null ? historyPayload(existing.getId()) : List.of());
        body.put("summary", existing != null ? summaryText(existing.getId()) : null);

        ChatResponse response = webClient.post()
                .uri("/api/v1/chat")
                .bodyValue(body)
                .retrieve()
                .bodyToMono(ChatResponse.class)
                .block();

        if (response == null) {
            throw new IllegalStateException("FastAPI 응답이 비어 있습니다.");
        }

        ChatSession session = resolveSession(req.getSessionId(), userId, req.getQuestion());
        chatMessagePersistenceService.persistTurn(session.getId(), req.getQuestion(), response);
        chatSessionDao.touch(session.getId());
        chatMemoryAsyncService.updateSummaryIfNeeded(session.getId());

        response.setSessionId(session.getId());
        response.setSessionTitle(session.getTitle());
        return response;
    }

    /** sessionId가 없거나, 있어도 내 것이 아니면 null — 새로 만들지는 않는다(읽기 전용 조회). */
    private ChatSession findOwnedSession(Long sessionId, Long userId) {
        if (sessionId == null) {
            return null;
        }
        ChatSession existing = chatSessionDao.findById(sessionId);
        return (existing != null && existing.getUserId().equals(userId)) ? existing : null;
    }

    private List<Map<String, String>> historyPayload(Long sessionId) {
        List<ChatMessage> recent = chatMessageDao.findRecentMessages(sessionId, HISTORY_WINDOW_MESSAGES);
        List<Map<String, String>> payload = new ArrayList<>();
        for (ChatMessage m : recent) {
            Map<String, String> turn = new HashMap<>();
            turn.put("role", m.getRole());
            turn.put("content", m.getContent());
            payload.add(turn);
        }
        return payload;
    }

    private String summaryText(Long sessionId) {
        ChatSessionSummary summary = chatSessionSummaryDao.find(sessionId);
        return summary != null ? summary.getSummary() : null;
    }

    /**
     * sessionId가 없거나, 있어도 내 것이 아니면 새 세션을 만든다.
     * 남의 세션 id가 온 경우 에러를 내는 대신 새 대화로 대체한다 —
     * 클라이언트 상태가 오래됐거나 잘못된 값이 와도 사용자를 막지 않는다.
     */
    ChatSession resolveSession(Long sessionId, Long userId, String question) {
        if (sessionId != null) {
            ChatSession existing = chatSessionDao.findById(sessionId);
            if (existing != null && existing.getUserId().equals(userId)) {
                return existing;
            }
        }
        ChatSession session = new ChatSession();
        session.setUserId(userId);
        session.setTitle(buildTitle(question));
        chatSessionDao.insert(session);
        return session;
    }

    static String buildTitle(String question) {
        String trimmed = question.trim();
        return trimmed.length() <= TITLE_MAX_LEN ? trimmed : trimmed.substring(0, TITLE_MAX_LEN) + "…";
    }
}
```

- [ ] **Step 5: `ChatMessagePersistenceService`에 `standaloneQuery` 저장 추가**

`backend_spring/src/main/java/com/legal/backend/service/ChatMessagePersistenceService.java`의 `persistTurn` 메서드에서 `botMsg` 생성 블록에 한 줄 추가:

```java
    @Transactional
    public void persistTurn(Long sessionId, String question, ChatResponse response) {
        ChatMessage userMsg = new ChatMessage();
        userMsg.setSessionId(sessionId);
        userMsg.setRole("user");
        userMsg.setContent(question);
        chatMessageDao.insert(userMsg);

        ChatMessage botMsg = new ChatMessage();
        botMsg.setSessionId(sessionId);
        botMsg.setRole("assistant");
        botMsg.setContent(response.getAnswer());
        botMsg.setStandaloneQuery(response.getStandaloneQuery());
        botMsg.setSourcesJson(toJsonOrNull(response.getSources()));
        chatMessageDao.insert(botMsg);
    }
```

(`response.getStandaloneQuery()`는 Step 1에서 `ChatResponse`에 추가한 필드 — 재작성이 실행 안 됐으면 FastAPI가 `null`을 보내므로 `chat_message.standalone_query` 컬럼도 그때는 `NULL`로 저장된다. `ChatMessagePersistenceServiceTest`(Task는 아니지만 Phase 0에서 만든 기존 테스트)는 `response.getStandaloneQuery()`를 세팅하지 않은 상태에서 검증하므로 여전히 통과한다 — `null`이 그대로 들어갈 뿐 예외가 아니다.)

- [ ] **Step 6: 테스트 통과 확인**

Run:
```bash
mvn -q test -Dtest=ChatServiceTest,ChatMessagePersistenceServiceTest,ChatMemoryAsyncServiceTest
```
Expected: PASS 전체.

- [ ] **Step 7: 전체 스위트 + 빌드 확인**

Run:
```bash
mvn test
```
Expected: 전체 PASS(Phase 0의 기존 스위트 16개 + 이 Task에서 늘어난 개수까지 전부 그린). 실패가 있으면 원인을 고치고 다시 실행 — 여기서 멈추지 않는다.

- [ ] **Step 8: Commit**

```bash
git add backend_spring/src/main/java/com/legal/backend/service/ChatService.java backend_spring/src/main/java/com/legal/backend/service/ChatMessagePersistenceService.java backend_spring/src/main/java/com/legal/backend/dto/ChatResponse.java backend_spring/src/test/java/com/legal/backend/service/ChatServiceTest.java
git commit -m "feat: ChatService에 이력·요약 로드·전달과 비동기 요약 갱신 트리거 배선"
```

---

### Task 12: 평가 확장 — 멀티턴 케이스 + 재작성 有/無 비교

**Files:**
- Modify: `ai/eval/eval_set.json`
- Modify: `ai/eval/run_eval.py`

**Interfaces:**
- Consumes: Task 6의 `pipeline.run(history=...)`, Task 2의 `rag.rewrite` 모듈(몽키패치 대상).
- Produces: 없음(최종 산출물 — 이 계획의 마지막 Task). eval 결과 JSON에 `standalone_query`/`rewrite_applied` 필드가 케이스마다 추가된다.

- [ ] **Step 1: 멀티턴 케이스 4건 추가**

`ai/eval/eval_set.json`의 마지막 항목(`ip-senior-2`) 다음, 배열을 닫는 `]` 앞에 콤마를 추가하고 아래 4건을 추가:

```json
  { "id": "ip-senior-2", "expected_category": "지식재산권", "age": 50, "question": "영업비밀 침해가 성립하기 위한 요건은 무엇인가요?" },

  { "id": "mt-civ-1", "expected_category": "민사", "age": 28,
    "history": [
      { "role": "user", "content": "전세 계약 갱신을 거부당했어요" },
      { "role": "assistant", "content": "임대인은 정당한 사유 없이 갱신을 거부할 수 없습니다. 계약갱신요구권 행사 여부와 임대인의 거부 사유를 확인해야 합니다." }
    ],
    "question": "그럼 계약금은 어떻게 되나요?" },

  { "id": "mt-crim-1", "expected_category": "형사", "age": 15,
    "history": [
      { "role": "user", "content": "학교 폭력을 신고하면 가해자는 어떤 처벌을 받나요?" },
      { "role": "assistant", "content": "학교폭력예방법에 따라 교육적 조치를 받고, 피해 정도에 따라 형사처벌도 가능합니다." }
    ],
    "question": "그거 신고는 어디에 하면 돼요?" },

  { "id": "mt-ip-1", "expected_category": "지식재산권", "age": 28,
    "history": [
      { "role": "user", "content": "상표권 침해를 판단하는 기준은 무엇인가요?" },
      { "role": "assistant", "content": "상표의 유사성과 지정상품의 동일·유사성을 종합적으로 고려하여 판단합니다." }
    ],
    "question": "위에서 말한 유사성은 어떻게 판단하나요?" },

  { "id": "mt-admin-1", "expected_category": "행정", "age": 50,
    "history": [
      { "role": "user", "content": "영업정지 처분에 대한 집행정지 신청 요건은 무엇인가요?" },
      { "role": "assistant", "content": "회복하기 어려운 손해 예방의 긴급한 필요성 등이 인정되어야 합니다." }
    ],
    "question": "그럼 신청은 언제까지 해야 하나요?" }
```

(`ip-senior-2` 원래 줄 끝의 `]`는 지우고 위 블록으로 대체 — 즉 `ip-senior-2` 다음에 콤마를 붙이고 4개 케이스를 추가한 뒤 마지막 `mt-admin-1` 다음에 `]`로 배열을 닫는다.)

각 케이스의 `history`는 `_DEMONSTRATIVES`에 포함된 지시어("그럼", "그거", "위에서")를 질문에 넣어 재작성 게이트가 실제로 걸리도록 설계했다.

- [ ] **Step 2: JSON 유효성 확인**

Run:
```bash
cd /f/workspce/legal-rag-chatbot/ai && .venv/Scripts/python.exe -c "
import json
cases = json.load(open('eval/eval_set.json', encoding='utf-8'))
print(f'총 {len(cases)}건')
mt = [c for c in cases if 'history' in c]
print(f'멀티턴 {len(mt)}건: {[c[\"id\"] for c in mt]}')
assert len(cases) == 36, f'기존 32건 + 신규 4건 = 36건이어야 함, 실제 {len(cases)}건'
"
```
Expected: `총 36건`, `멀티턴 4건: ['mt-civ-1', 'mt-crim-1', 'mt-ip-1', 'mt-admin-1']` 출력, AssertionError 없음.

- [ ] **Step 3: `run_eval.py`에 history 전달 + 재작성 비교 모드 추가**

`ai/eval/run_eval.py` 상단 임포트 블록(현재 39-40행)을 교체:

```python
from rag.pipeline import get_pipeline
import rag.rewrite as rewrite
from judge import judge as llm_judge
```

`EVAL_SET_PATH`/`RESULTS_DIR` 선언(현재 42-43행) 바로 아래에 추가:

```python
# EVAL_DISABLE_REWRITE=1 로 실행하면 재작성을 강제로 끈 상태로 같은 eval_set을 돌릴 수 있다.
# 재작성 有/無 결과 파일 두 개를 비교해서 judge 점수·환각율 차이를 본다(스펙 §11).
DISABLE_REWRITE = os.getenv("EVAL_DISABLE_REWRITE") == "1"
```

`run()` 함수 시작 부분(현재 46-51행 근처, `pipeline = get_pipeline()` 다음)에 추가:

```python
def run():
    with open(EVAL_SET_PATH, encoding="utf-8") as f:
        cases = json.load(f)

    pipeline = get_pipeline()

    if DISABLE_REWRITE:
        print("[INFO] EVAL_DISABLE_REWRITE=1 — 재작성을 강제로 끄고 실행합니다.")
        rewrite.needs_rewrite = lambda question, history: False

    results = []
```

`pipeline.run(...)` 호출부(현재 62행)를 교체:

```python
        result = pipeline.run(question=case["question"], age=case["age"], history=case.get("history", []))
```

`record = {...}` 딕셔너리(현재 82-105행)에 두 필드 추가(`"sources": sources,` 다음 줄에):

```python
            "sources": sources,
            "context": result.get("context", ""),
            "standalone_query": result.get("standalone_query"),
            "rewrite_applied": result.get("rewrite_applied", False),
```

(기존에 이미 있던 `"context": result.get("context", ""),`이 다른 자리에 중복으로 있으면 그 줄은 그대로 두고 새로 추가하지 않는다 — 현재 파일의 96행에 이미 `"context": result.get("context", ""),`가 있으므로, 위 교체에서는 `"standalone_query"`/`"rewrite_applied"` 두 줄만 `"sources": sources,` 바로 다음에 추가하면 된다.)

출력 로그 줄(현재 108-113행) 바로 아래에 재작성 여부 표시를 추가:

```python
        flag = f" [미검증 인용 {len(citation_check['unverified'])}건]" if citation_check["unverified"] else ""
        rewrite_flag = f" [재작성: {result['standalone_query']}]" if result.get("rewrite_applied") else ""
        jf = judge_result.get("factual_correctness")
        jt = judge_result.get("age_appropriate_tone")
        jh = judge_result.get("hallucination_free")
        judge_flag = f" [judge: 사실={jf} 말투={jt} 환각없음={jh}]" if jf is not None else " [judge 실패]"
        print(f"  검색결과 {len(sources)}건 / 분야일치율 {record['category_match_rate']:.0%} / {elapsed}s{flag}{rewrite_flag}{judge_flag}")
```

- [ ] **Step 4: 실행 확인 (라이브 인프라 전체 필요 — OpenSearch, Ollama, legal-gemma + gemma3:1b)**

Run:
```bash
.venv/Scripts/python.exe eval/run_eval.py
```
Expected: 36건 전부 처리됨. `mt-*` 4건에서 `[재작성: ...]` 로그가 찍히는지 확인(재작성 게이트가 걸렸다는 뜻). 기존 32건(`history` 없음)은 재작성 로그가 안 찍혀야 함(하위 호환 확인).

비교용으로 재작성 끈 실행도 한 번:
```bash
EVAL_DISABLE_REWRITE=1 .venv/Scripts/python.exe eval/run_eval.py
```
Expected: `[INFO] EVAL_DISABLE_REWRITE=1 — 재작성을 강제로 끄고 실행합니다.` 출력 후, `mt-*` 케이스에서도 재작성 로그가 안 찍힘. 두 실행의 `results/eval_*.json` 파일 중 `mt-*` 케이스들의 `llm_judge`/`unverified_citations`를 비교해서 재작성이 실제로 답변 품질에 도움이 되는지 사람이 직접 읽어본다(스펙 §11: 자동 채점 pass율은 참고용, 사람이 최종 판단).

라이브 인프라가 없으면 "실행 불가 — 라이브 인프라 필요"로 보고 — 이 Task의 Step 1-2(JSON 유효성)와 Step 3(코드 변경 자체)은 인프라 없이도 완료·확인 가능하다.

- [ ] **Step 5: Commit**

```bash
git add ai/eval/eval_set.json ai/eval/run_eval.py
git commit -m "feat: eval에 멀티턴 케이스 4건 추가, 재작성 有/無 비교 모드(EVAL_DISABLE_REWRITE) 추가"
```

---

## Self-Review 결과

- **스펙 커버리지:** §8.1(스키마)→Task 5, §8.2(재작성 게이트+재작성)→Task 1·2, §8.3(이중 채널 검색)→Task 3, §8.4(프롬프트 하드 캡, `user_memory`/`MEMORY_PRIORITY_RULE` 제외)→Task 4, §8.5(`/summary/update`)→Task 7, §11(평가)→Task 12, §12 Phase 1 로드맵 5개 불릿 전부 → Task 1·2(재작성)·3(검색)·5/6(스키마+하드캡)·7/10(요약)·12(eval)로 매핑됨. §8.4의 `user_memory` 배선과 §8.5의 `/memory/extract`, §8.6은 의도적으로 이 계획에 없음 — 스펙 §12가 Phase 2로 명시한 항목이라 Global Constraints에 근거를 남겼다.
- **자리표시자 스캔:** "TBD"/"추후 구현"/"적절히 처리" 없음. 모든 코드 블록이 실제 동작 코드. `OLLAMA_REWRITE_MODEL` 값(`gemma3:1b`)은 스펙 자체가 "가칭"이라고 명시한 자리라 Task 1 Step 1에 실제 확인·pull 절차를 넣어 액션 가능하게 만들었다(값이 안 맞으면 그 자리에서 실제 존재하는 태그로 교체하라는 구체적 지시 포함 — 모호한 TBD가 아니다).
- **타입/시그니처 일관성 확인:** `pipeline.run(question, age, law_category, history, summary)`가 Task 6에서 정의되고 Task 7(router.py)·Task 12(run_eval.py)에서 동일한 키워드로 호출됨. `LegalRetriever.search_multi(queries, law_category)`/`format_context(results)`가 Task 3에서 정의되고 Task 6에서 정확히 그 이름으로 쓰임. `rewrite.needs_rewrite(question, history)`/`rewrite.rewrite_query(question, history, summary)`가 Task 2에서 정의되고 Task 6·12에서 모듈 참조(`rewrite.xxx`)로 일관되게 쓰임 — 몽키패치 요구사항(Task 12)과 맞물려 있어 `from ... import` 방식이 아니라 `import ... as rewrite` 방식으로 Task 6에 명시해 둠. Spring 쪽 `ChatSessionSummaryDao.find`/`upsertIfNewer`가 Task 8에서 정의되고 Task 10·11에서 동일 시그니처로 쓰임. `ChatMessageDao.findRecentMessages`/`findAfterMessageId`가 Task 9에서 정의되고 Task 10·11에서 정확한 인자 순서(`sessionId, limit`/`sessionId, afterId`)로 쓰임. `ChatResponse.standaloneQuery`/`rewriteApplied`가 Task 11 Step 1에서 추가되고 같은 Task의 Step 5(`ChatMessagePersistenceService`)에서 바로 소비됨.
- **하위 호환 확인:** `build_prompt`(Task 4)·`pipeline.run`(Task 6)·`_hybrid_search`/`get_context`(Task 3) 전부 기존 호출부(인자 생략 시)가 리팩터링 전과 100% 동일한 결과를 내도록 설계하고, 각 Task의 검증 Step에 assert 또는 수동 비교로 명시했다. `ChatService.resolveSession`(Phase 0에서 이미 테스트된 메서드)은 시그니처·동작을 전혀 바꾸지 않았다.
