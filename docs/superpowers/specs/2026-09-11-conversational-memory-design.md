# 대화형 RAG 전환 설계 스펙

- 상태: 설계 확정, 구현 계획 작성 대기
- 관련 아티팩트(비교·근거 문서): https://claude.ai/code/artifact/9c28cd4b-2c96-443b-b8a1-ff38ae32c756
- 작성일: 2026-09-11

## 1. 배경

`/api/chat`은 현재 완전히 stateless다 — 매 질문이 이전 질문과 아무 관계 없이 독립적으로 처리된다 (`ai/rag/pipeline.py`, `backend_spring/.../ChatService.java`). MySQL에는 `users` 테이블 하나뿐이고(`deploy/init.sql`), 대화나 개인 정보를 저장하는 곳이 없다.

이 스펙은 다음을 추가한다:
1. 대화 기록과 사용자별 지속 정보를 DB에 저장한다.
2. 후속 질문이 앞선 대화 맥락을 이어받아 더 견고하게 답하도록 한다.
3. 여러 개의 대화를 목록으로 관리하고 "새 대화"를 시작할 수 있게 한다.

## 2. 확정 결정

브레인스토밍 단계에서 확정된 4개 결정 + 이후 리스크 검토로 추가된 5개 대응. 번호는 이 문서 전체에서 참조용으로 고정한다.

| # | 결정 | 요지 |
|---|---|---|
| D1 | 후속 질문 처리 = 질문 재작성만 | 분해·멀티쿼리·에이전트형은 이번 스펙 범위 밖 (§12 Phase 3) |
| D2 | 배치 = Spring 오케스트레이션 | Spring이 대화 상태를 소유·영속화. FastAPI는 무상태 순수 함수 |
| D3 | 세션 UI = 다중 대화 목록 + 새 대화 | 사이드바 목록, 새 대화는 빈 화면(세션은 첫 메시지 전송 시 생성) |
| D4 | 비동기 = Spring `@Async` | 응답 후 요약·메모리 갱신을 별도 워커가 처리 |
| D5 | 재작성 안전장치 | 규칙 기반 게이트 + 이중 채널 검색 + 경량 재작성 모델 |
| D6 | 메모리는 근거가 아니라 맥락 | 프롬프트 우선순위 규칙 + 신뢰 만료 + 필수 열람/삭제 화면 |
| D7 | `@Async` 구현 원칙 | 별도 빈, 전용 executor, 예외 핸들러, DB 레벨 동시성 제어 |
| D8 | 스키마 마이그레이션 = Flyway | `backend_spring`에 도입, `init.sql`의 1회성 문제 해결 |
| D9 | 구현 범위 | 백엔드 수정은 `backend_spring`만. `backend/`(소스 없는 레거시 셸)는 무관 |

## 3. 제약

- **모델**: `legal-gemma`(Gemma 3 4B, Ollama), `num_ctx=4096`, system role 미지원 → 프롬프트 전체가 user 메시지 하나에 들어간다. §9.4에서 예산을 하드 캡으로 강제한다.
- **서비스 경계**: Spring(JWT·사용자·MySQL) / FastAPI(검색·생성) 경계를 유지한다. FastAPI는 이번 기능에서도 DB에 직접 연결하지 않는다.
- **검색 인프라**: OpenSearch 하이브리드 검색(`ai/rag/retriever.py`)은 기존 그대로 두고, 재작성된 질문을 추가 채널로만 활용한다.
- **인증**: JWT가 현재 `username`+`age`만 담고 `user_id`(숫자)를 담지 않는다. §4에서 선행 변경으로 추가한다.
- **용어 정의**: "1턴" = 사용자 질문 1개 + 어시스턴트 답변 1개 (메시지 2개). `HISTORY_WINDOW_TURNS = 2` → 프롬프트에 원문으로 주입되는 건 최근 4개 메시지. `SUMMARY_TRIGGER_TURNS = 2` → 요약에 아직 접히지 않은 턴이 2턴(4메시지)을 넘어서면(즉 3턴째 질문부터) 그 이전 턴들을 요약으로 접는다.

## 4. 선행 변경 — JWT에 user_id 추가

모든 신규 테이블이 `user_id BIGINT`로 `users.id`를 참조하는데, 지금 `JwtUtil`은 `username`만 subject로 넣는다(`backend_spring/src/main/java/com/legal/backend/util/JwtUtil.java:35-43`). 세션·메모리 소유권 검사를 하려면 매 요청마다 `username`으로 `UserDao.findByUsername`을 다시 호출하거나, JWT에 id를 실어야 한다. **JWT에 싣는 쪽을 택한다** — 추가 쿼리 없이 필터에서 바로 꺼낼 수 있다.

변경 범위 (전부 `backend_spring`):

- `JwtUtil.generateToken(Long userId, String username, int age)` — `.claim("uid", userId)` 추가
- `JwtUtil.getUserId(String token)` 신규 메서드
- `JwtFilter.doFilter` — `req.setAttribute("userId", jwtUtil.getUserId(token))` 추가
- `AuthService.login` — `jwtUtil.generateToken(user.getId(), user.getUsername(), user.getAge())`로 호출 변경

로컬 개발 환경이라 기존 발급 토큰과의 하위호환은 고려하지 않는다(재로그인하면 그만).

## 5. 데이터 모델

### 5.1 마이그레이션 — Flyway (D8)

`backend_spring/pom.xml`에 추가:

```xml
<dependency>
  <groupId>org.flywaydb</groupId>
  <artifactId>flyway-core</artifactId>
  <version>9.22.3</version>
</dependency>
<dependency>
  <groupId>org.flywaydb</groupId>
  <artifactId>flyway-mysql</artifactId>
  <version>9.22.3</version>
</dependency>
```

`root-context.xml`에 빈 추가(또는 `@Configuration` 클래스로):

```java
@Configuration
public class FlywayConfig {
    @Bean(initMethod = "migrate")
    public Flyway flyway(DataSource dataSource) {
        return Flyway.configure()
            .dataSource(dataSource)
            .baselineOnMigrate(true)   // 이미 users 테이블이 있는 기존 DB에도 안전
            .locations("classpath:db/migration")
            .load();
    }
}
```

`baselineOnMigrate(true)`가 핵심이다 — 이미 배포된 DB는 `deploy/init.sql`이 만든 `users` 테이블을 Flyway가 모르는 상태로 갖고 있으므로, 베이스라인을 잡지 않으면 "스키마가 비어있지 않다"며 실패한다. `deploy/init.sql`은 그대로 두고(신규 로컬/CI 환경의 최초 부트스트랩용), 이후의 모든 스키마 변경은 Flyway로만 한다.

마이그레이션 파일: `backend_spring/src/main/resources/db/migration/V1__chat_tables.sql`

### 5.2 DDL

```sql
CREATE TABLE chat_session (
    id          BIGINT       NOT NULL AUTO_INCREMENT,
    user_id     BIGINT       NOT NULL,
    title       VARCHAR(100) NOT NULL DEFAULT '새 대화',
    created_at  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    deleted_at  TIMESTAMP    NULL,
    PRIMARY KEY (id),
    KEY idx_chat_session_user (user_id, deleted_at, updated_at),
    CONSTRAINT fk_chat_session_user FOREIGN KEY (user_id) REFERENCES users(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE chat_message (
    id                BIGINT       NOT NULL AUTO_INCREMENT,
    session_id        BIGINT       NOT NULL,
    role              ENUM('user','assistant') NOT NULL,
    content           TEXT         NOT NULL,
    standalone_query  TEXT         NULL,   -- 재작성 결과. assistant 턴에만, eval/디버깅용
    sources_json      JSON         NULL,
    created_at        TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_chat_message_session (session_id, created_at),
    CONSTRAINT fk_chat_message_session FOREIGN KEY (session_id) REFERENCES chat_session(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE chat_session_summary (
    session_id          BIGINT    NOT NULL,
    summary              TEXT      NOT NULL,
    through_message_id   BIGINT    NOT NULL,
    updated_at            TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (session_id),
    CONSTRAINT fk_summary_session FOREIGN KEY (session_id) REFERENCES chat_session(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE user_memory (
    id                 BIGINT       NOT NULL AUTO_INCREMENT,
    user_id            BIGINT       NOT NULL,
    mem_key            VARCHAR(50)  NOT NULL,     -- 예: role_in_case, case_type, key_date
    mem_value          VARCHAR(500) NOT NULL,
    source_message_id  BIGINT       NULL,
    confidence         DECIMAL(3,2) NOT NULL DEFAULT 0.80,
    confirmed_at        TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uk_user_memory (user_id, mem_key),
    CONSTRAINT fk_user_memory_user FOREIGN KEY (user_id) REFERENCES users(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE chat_async_job (
    id            BIGINT       NOT NULL AUTO_INCREMENT,
    job_type      ENUM('summary','memory_extract') NOT NULL,
    session_id    BIGINT       NOT NULL,
    status        ENUM('success','failed') NOT NULL,
    error_message TEXT         NULL,
    created_at    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_async_job_session (session_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

메모: `chat_async_job`은 D7(예외가 조용히 사라지는 문제)의 관측 수단이다. `mem_key`를 열린 문자열이 아니라 **정해진 카테고리** (`role_in_case`, `case_type`, `key_date`, `related_law` 등 소수)로 제한한다 — 추출 프롬프트에 허용 키 목록을 명시해서 무한정 키가 늘어나는 걸 막는다(§9.6).

## 6. 아키텍처 개요

```
Frontend → Spring(JWT 검증·세션 관리·영속화) → FastAPI(무상태: 재작성·검색·생성) → Ollama/OpenSearch
                    │
                    └─ 응답 후 @Async → FastAPI(/summary/update, /memory/extract) → MySQL 갱신
```

FastAPI는 이번 기능 전체에서 MySQL을 모른다. `/chat`, `/summary/update`, `/memory/extract` 세 엔드포인트 모두 입력을 받아 결과를 반환하는 순수 함수로 유지한다 — `ai/eval` 하네스가 계속 직접 호출로 테스트 가능해야 한다는 게 이 경계의 존재 이유다.

## 7. Spring 설계 (`backend_spring`)

### 7.1 신규 엔드포인트

세션은 **지연 생성**한다 — "새 대화" 버튼은 서버 호출 없이 프론트 상태만 초기화하고, 실제 `chat_session` 행은 `sessionId=null`로 첫 질문을 보낼 때 만들어진다. 그래서 별도의 `POST /sessions` 생성 엔드포인트는 두지 않는다.

| 메서드 | 경로 | 설명 |
|---|---|---|
| GET | `/api/chat/sessions` | 내 대화 목록. `deleted_at IS NULL`, `updated_at DESC` |
| GET | `/api/chat/sessions/{id}/messages` | 세션의 메시지 전체. **소유자 검사 필수** |
| PATCH | `/api/chat/sessions/{id}` | 제목 수정 |
| DELETE | `/api/chat/sessions/{id}` | soft delete (`deleted_at`) |
| GET | `/api/chat/memory` | 내 메모리 목록 (D6 필수 화면) |
| DELETE | `/api/chat/memory/{id}` | 메모리 항목 삭제 |

전부 `JwtFilter` 뒤에서 `req.getAttribute("userId")`로 소유자를 확인한다 — 세션/메모리 id가 요청자의 것이 아니면 404 (403이 아니라 404로, 존재 여부를 노출하지 않는다).

### 7.2 기존 `POST /api/chat` 변경

`ChatRequest.java`에 `sessionId` 추가:

```java
@Getter @Setter
public class ChatRequest {
    private String question;
    private String lawCategory;
    private Long sessionId;   // null = 새 세션
}
```

`ChatService.chat()` 처리 순서:

1. `userId`, `age` = JWT 속성에서.
2. `sessionId == null`이면 `chat_session` 생성(`title`은 임시로 "새 대화", 첫 응답 후 질문 앞부분으로 갱신).
3. `ChatMessageDao`에서 해당 세션의 최근 2턴(`HISTORY_WINDOW_TURNS=2`), `ChatSessionSummaryDao`에서 요약, `UserMemoryDao`에서 `confirmed_at`이 만료되지 않은 메모리를 조회.
4. FastAPI `POST /chat` 호출 (§8.1 스키마).
5. 응답을 받으면 **동기**로 `chat_message`에 user·assistant 두 행 저장(트랜잭션 하나). 이때 `standalone_query`, `sources_json`도 같이 저장.
6. `title`이 아직 "새 대화"면 질문 앞부분(20자)으로 갱신.
7. `ChatMemoryAsyncService`에 요약·메모리 갱신을 위임(§7.4) — **응답 반환을 막지 않는다.**
8. 프론트에 `ChatResponse` 반환.

응답 DTO에 `sessionId`, (세션이 새로 만들어졌다면) `sessionTitle` 추가.

### 7.3 MyBatis 매퍼

`ChatSessionDao`, `ChatMessageDao`, `ChatSessionSummaryDao`, `UserMemoryDao`, `ChatAsyncJobDao` 5개를 `UserDao`와 같은 패턴(`com.legal.backend.dao`, `resources/mybatis/*.xml`)으로 추가한다. 눈여겨볼 것 두 개:

- **요약 낙관적 갱신** (D7 경합 방지):
  ```xml
  <update id="upsertIfNewer">
    INSERT INTO chat_session_summary (session_id, summary, through_message_id)
    VALUES (#{sessionId}, #{summary}, #{throughMessageId})
    ON DUPLICATE KEY UPDATE
      summary = IF(through_message_id < #{throughMessageId}, #{summary}, summary),
      through_message_id = IF(through_message_id < #{throughMessageId}, #{throughMessageId}, through_message_id)
  </update>
  ```
- **메모리 upsert** (동시성은 UNIQUE 키 + `ON DUPLICATE KEY UPDATE`로 DB가 직렬화):
  ```xml
  <insert id="upsert">
    INSERT INTO user_memory (user_id, mem_key, mem_value, source_message_id, confidence, confirmed_at)
    VALUES (#{userId}, #{memKey}, #{memValue}, #{sourceMessageId}, #{confidence}, NOW())
    ON DUPLICATE KEY UPDATE
      mem_value = #{memValue}, source_message_id = #{sourceMessageId},
      confidence = #{confidence}, confirmed_at = NOW()
  </insert>
  ```

### 7.4 `@Async` 설계 (D4, D7)

```java
@Configuration
@EnableAsync
public class AsyncConfig implements AsyncConfigurer {

    @Bean(name = "chatMemoryExecutor")
    public Executor chatMemoryExecutor() {
        ThreadPoolTaskExecutor executor = new ThreadPoolTaskExecutor();
        executor.setCorePoolSize(2);
        executor.setMaxPoolSize(4);
        executor.setQueueCapacity(50);
        executor.setThreadNamePrefix("chat-memory-");
        executor.initialize();
        return executor;
    }

    @Override
    public Executor getAsyncExecutor() { return chatMemoryExecutor(); }

    @Override
    public AsyncUncaughtExceptionHandler getAsyncUncaughtExceptionHandler() {
        return (ex, method, params) -> {
            log.error("비동기 작업 실패: {}", method.getName(), ex);
            // ChatAsyncJobDao.insertFailure(...) — 별도 동기 DAO 호출로 관측 가능하게 남긴다
        };
    }
}
```

```java
@Service
public class ChatMemoryAsyncService {   // ChatService와 분리된 별도 빈 — 자기 호출 프록시 우회 문제 회피

    @Async("chatMemoryExecutor")
    public void updateSummaryIfNeeded(Long sessionId) {
        int unfoldedTurns = chatMessageDao.countSinceLastSummary(sessionId);   // 메시지 수 / 2
        if (unfoldedTurns <= SUMMARY_TRIGGER_TURNS) return;   // 기본값 2 — 윈도우 초과 시만
        var prevSummary = chatSessionSummaryDao.find(sessionId);
        var turns = chatMessageDao.findUnfolded(sessionId);
        var result = fastApiClient.updateSummary(sessionId, prevSummary, turns);   // POST /summary/update
        chatSessionSummaryDao.upsertIfNewer(sessionId, result.summary(), result.throughMessageId());
    }

    @Async("chatMemoryExecutor")
    public void extractMemoryIfNeeded(Long userId, String question, String answer, Long messageId) {
        if (!shouldExtract(question)) return;   // 휴리스틱: 1인칭 표현 포함 또는 질문 길이 임계 이상
        var existing = userMemoryDao.findByUser(userId);
        var facts = fastApiClient.extractMemory(userId, question, answer, existing);   // POST /memory/extract
        facts.forEach(f -> userMemoryDao.upsert(userId, f.memKey(), f.memValue(), messageId, f.confidence()));
    }
}
```

## 8. FastAPI 설계 (`ai/`)

### 8.1 `/chat` 스키마 변경 (`ai/api/schemas.py`)

요청에 추가:

```python
class HistoryTurn(BaseModel):
    role: Literal["user", "assistant"]
    content: str

class ChatRequest(BaseModel):
    question: str
    age: int
    law_category: Optional[str] = None
    history: list[HistoryTurn] = []
    summary: Optional[str] = None
    user_memory: dict[str, str] = {}
```

응답에 추가: `standalone_query: str`, `rewrite_applied: bool`. `session_id`는 FastAPI가 다루지 않으므로 스키마에서 제거한다(지금 있는 미사용 필드를 정리).

### 8.2 재작성 게이트 + 재작성 (D1, D5)

`ai/rag/rewrite.py` 신규:

```python
_DEMONSTRATIVES = ["그거", "그건", "그것", "이거", "이건", "저거", "위에서", "아까", "방금", "거기", "그럼", "그러면"]
MIN_STANDALONE_LEN = 12

def needs_rewrite(question: str, history: list) -> bool:
    if not history:
        return False
    if any(d in question for d in _DEMONSTRATIVES):
        return True
    return len(question.strip()) < MIN_STANDALONE_LEN

def rewrite_query(question: str, history: list, summary: str | None) -> str:
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
    return generate(system_prompt="", user_message=prompt, model=settings.OLLAMA_REWRITE_MODEL,
                     max_tokens=80, temperature=0.0).strip()
```

`ai/core/model.py`의 `generate()`에 `model` 파라미터를 추가해 호출마다 모델을 지정할 수 있게 한다(지금은 `OLLAMA_MODEL` 고정). `ai/core/config.py`에 `OLLAMA_REWRITE_MODEL: str = "gemma3:1b"`(가칭, 배포 시 실제 사용 가능한 경량 모델로 확정) 추가.

### 8.3 이중 채널 검색 (D5)

`LegalRetriever`에 메서드 추가(`ai/rag/retriever.py`):

```python
def search_multi(self, queries: list[str], law_category: str = None) -> list:
    """여러 질문으로 각각 검색한 뒤 _hybrid_search와 같은 정규화·합산 방식으로 융합한다."""
    pool_size = max(self.top_k * 5, 30)
    scores, docs = {}, {}
    for q in queries:
        vec = self._embed_query(q)
        knn = self._knn_search(vec, law_category, size=pool_size)
        bm25 = self._bm25_search(q, law_category, size=pool_size)
        for hit, base_max in _score_channels(knn, bm25):
            ...  # 기존 _hybrid_search 내부 정규화·합산 로직을 공유 함수로 뽑아 재사용
    return _finalize(scores, docs, self.top_k, self.min_score)
```

파이프라인에서:

```python
queries = [question]
if rewrite.needs_rewrite(question, history):
    standalone = rewrite.rewrite_query(question, history, summary)
    queries.append(standalone)
results = retriever.search_multi(queries, law_category)
```

재작성을 안 했으면 `queries == [question]`이라 `search_multi`는 지금의 `search()`와 동일하게 동작한다 — 기존 단일 채널 경로를 깨지 않는다.

### 8.4 프롬프트 조립과 예산 하드 캡 (§9.4/#7 대응)

`build_prompt()`(`ai/prompt/template.py`) 시그니처 확장:

```python
def build_prompt(question, context, age, summary=None, user_memory=None, history=None) -> dict:
```

각 구성요소에 코드로 강제하는 상한(추정이 아니라 실제 컷):

| 구성 | 상한 | 방식 |
|---|---|---|
| `summary` | 300자 | 초과 시 `[:300] + "..."` |
| `user_memory` | 6개 항목 | `confirmed_at` 최신순 상위 6개만, 각 값 60자 컷 |
| `history` | 2턴, 각 턴 250자 | 오래된 턴부터 버림 |
| `context` | 나이대별 (기존 `CONTEXT_MAX_LEN`) | 기존 로직 유지 |

시스템 프롬프트에 공통 규칙 블록 추가(D6):

```python
MEMORY_PRIORITY_RULE = """
[메모리 사용 규칙]
사용자 메모리는 배경 참고용일 뿐이다. 법률적 판단이나 조문 인용의 근거로 쓰지 마라.
메모리와 [참고 내용]이 다르면 [참고 내용]을 따르라.
"""
```
`user_memory`가 비어 있지 않을 때만 각 `SYSTEM_PROMPTS[age_group]` 뒤에 붙인다.

### 8.5 신규 엔드포인트

**`POST /summary/update`**
```json
// 요청
{ "session_id": 42, "prev_summary": "...", "turns_to_fold": [{"role":"user","content":"..."}], "through_message_id": 118 }
// 응답
{ "summary": "...", "through_message_id": 118 }
```

**`POST /memory/extract`**
```json
// 요청
{ "user_id": 7, "question": "...", "answer": "...", "existing_memory": {"role_in_case": "임차인"} }
// 응답
{ "facts": [{"mem_key": "case_type", "mem_value": "임대차분쟁", "confidence": 0.86}] }
```

두 엔드포인트 모두 입력→출력 순수 함수. `ai/api/router.py`에 추가.

### 8.6 추출 프롬프트의 키 제한

```python
ALLOWED_MEM_KEYS = ["role_in_case", "case_type", "key_date", "related_law"]
```
추출 프롬프트에 이 목록을 명시하고, 응답을 파싱할 때 목록 밖의 키는 버린다 — `mem_key`가 무한정 늘어나는 걸 막는다.

## 9. 프론트엔드 설계

- `frontend/public/chat.html`을 좌측 사이드바(대화 목록 + "새 대화" 버튼) + 우측 메시지 영역으로 2분할.
- 상태: `currentSessionId`(없으면 null) — "새 대화" 클릭 시 서버 호출 없이 `null`로 리셋, 메시지 영역만 비움.
- 세션 클릭 시 `GET /api/chat/sessions/{id}/messages`로 로드.
- 첫 메시지 전송 응답에 담긴 `sessionId`를 `currentSessionId`에 저장 + 목록에 새 항목 추가.
- 메모리 열람 화면(D6 필수): 설정/프로필 메뉴에 `GET /api/chat/memory` 목록 + 삭제 버튼. 새 페이지보다 `chat.html` 내 모달로 충분.

## 10. 리스크 대응 요약

상세 근거는 아티팩트 참고. 이 스펙에 반영된 대응만 표로 정리:

| 리스크 | 대응 | 위치 |
|---|---|---|
| 배포 시 스키마 누락 | Flyway + `baselineOnMigrate` | §5.1 |
| 재작성 드리프트 | 게이트 + 이중 채널 검색 | §8.2, §8.3 |
| 메모리가 법률 결론의 근거가 됨 | 프롬프트 우선순위 규칙 + 만료 + 필수 열람 화면 | §8.4, §9 |
| 지연 2배 | 게이트로 대부분 스킵 + 경량 재작성 모델 | §8.2 |
| `@Async` 함정 | 별도 빈·전용 executor·예외 핸들러·DB 레벨 동시성 | §7.4 |
| 예산 초과가 조용히 안전규칙을 자름 | 코드 레벨 하드 캡 | §8.4 |

## 11. 평가 계획

`ai/eval/eval_set.json`에 멀티턴 케이스 추가:

```json
{
  "history": [{"role": "user", "content": "전세 계약 갱신 거부당했어요"}, {"role": "assistant", "content": "..."}],
  "question": "그럼 계약금은 어떻게 되나요?",
  "expected_topic": "전세 계약금 반환"
}
```

`ai/eval/run_eval.py`가 `pipeline.run()`에 `history`/`summary`/`user_memory`를 (기본값 있는) 선택 인자로 전달하도록 확장 — 기존 단일 턴 케이스는 그대로 통과해야 한다. 측정: 재작성 有/無 judge 점수 비교, 게이트가 스킵/실행을 얼마나 정확히 판단하는지(수동 라벨 20건 정도로 샘플 체크), 메모리 주입 전후 회귀(앞 턴 사실을 뒤 턴이 반영하는지).

## 12. 단계별 로드맵

**Phase 0 — 기반**
- [ ] Flyway 도입 + `V1__chat_tables.sql`
- [ ] JWT에 `uid` 클레임 추가
- [ ] 세션 CRUD + 메모리 열람 엔드포인트
- [ ] `chatMemoryExecutor` + `AsyncUncaughtExceptionHandler` 골격(아직 아무것도 안 돌림)
- [ ] 프론트 사이드바 개편
- [ ] 모든 턴을 `chat_message`에 저장 — **답변 로직은 그대로**

**Phase 1 — 멀티턴**
- [ ] `ai/rag/rewrite.py` (게이트 + 재작성) + `OLLAMA_REWRITE_MODEL` 설정
- [ ] `search_multi` (이중 채널 검색)
- [ ] `/chat` 스키마에 `history`/`summary` 추가, `build_prompt` 확장 + 하드 캡
- [ ] `/summary/update` + `ChatMemoryAsyncService.updateSummaryIfNeeded`
- [ ] eval에 멀티턴 케이스 추가, 재작성 有/無 비교

**Phase 2 — 장기 메모리**
- [ ] `/memory/extract` + `ChatMemoryAsyncService.extractMemoryIfNeeded`
- [ ] `MEMORY_PRIORITY_RULE` 프롬프트 반영
- [ ] `confirmed_at` 만료 처리
- [ ] 메모리 열람·삭제 프론트 화면 (필수)

**Phase 3 — 관찰 대상, 이 스펙 범위 밖**
- 조건부 분해, 멀티쿼리 융합 — eval에서 재작성만으로 부족한 지표가 나올 때만 별도 스펙으로 진행.

**Phase 4 — 보류**
- 크로스세션 벡터 회상 — 실제 요구가 생기면 별도 스펙.

## 13. 이 스펙에 포함하지 않은 것

- 메모리 값 수정(현재는 삭제만 — 틀린 값은 지우고 다시 말하게 함)
- 세션 공유·협업 기능
- Rate limiting / 남용 방지
- 관리자용 대화 열람 도구
- `OLLAMA_REWRITE_MODEL`의 정확한 모델명(로컬 환경에서 실제 사용 가능한 경량 모델 확인 후 확정)
