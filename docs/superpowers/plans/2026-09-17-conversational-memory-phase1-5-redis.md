# 읽기 캐시 — Redis (Phase 1.5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 세션 목록(`GET /api/chat/sessions`)과 대화 컨텍스트(매 턴 `ChatService.chat()`이 읽는 최근 이력·롤링 요약) 조회를 Redis로 캐싱한다 — cache-aside, 원본은 항상 MySQL, Redis가 죽어도 기능은 그대로(느려지기만) 동작해야 한다.

**Architecture:** 순수 읽기 캐시. 세션/인증 저장소나 `@Async` 작업 큐로 쓰지 않는다. 제네릭 `ChatCacheService.getOrLoad(key, type, loader)` 하나가 두 캐시 키(`chat:sessions:{userId}`, `chat:ctx:{sessionId}`)를 모두 처리 — Redis 조회/쓰기/삭제를 전부 try/catch로 감싸 실패 시 로그만 남기고 loader(=MySQL 원본)로 폴백한다. 쓰기 경로(세션 생성·제목수정·삭제·턴 저장·요약 갱신)가 끝난 직후 해당 캐시 키를 명시적으로 삭제한다 — TTL(5분)은 무효화를 놓쳤을 때의 안전망일 뿐이다.

**Tech Stack:** 이 프로젝트는 **plain Spring MVC 5.3.30이지 Spring Boot가 아니다** — `spring-boot-starter-data-redis`(자동 구성)는 쓸 수 없다. `spring-data-redis` + `lettuce-core`를 일반 의존성으로 추가하고, `root-context.xml`에 `webClient` 빈과 같은 방식으로 `RedisConnectionFactory`/`StringRedisTemplate` 빈을 XML로 직접 정의한다. JSON 직렬화는 `ChatMessagePersistenceService`가 이미 쓰는 패턴(`private static final ObjectMapper OBJECT_MAPPER = new ObjectMapper();`, 별도 빈 없음)을 그대로 따른다.

**Spec:** [docs/superpowers/specs/2026-09-11-conversational-memory-design.md](../specs/2026-09-11-conversational-memory-design.md) §7.5(D10) — 이 계획은 그 설계를 실제 구현으로 옮긴다. §7.5의 예시 코드는 개념 스케치이고, 이 계획의 코드가 실제 계약이다(예: §7.5는 `getSessions`/`getContext` 개별 메서드로 스케치했지만, 이 계획은 제네릭 `getOrLoad` 하나로 통합해 Redis try/catch 로직이 한 곳에만 있게 한다 — Phase 1 최종 리뷰의 M1 발견[동일 로직 중복]을 처음부터 피하기 위함).

## Global Constraints

- **범위:** `backend_spring/`만 수정한다. `ai/`·`backend/`는 무관.
- **캐시 대상은 정확히 2개 키만:** `chat:sessions:{userId}`(세션 목록), `chat:ctx:{sessionId}`(`{history, summary}` 묶음). 메시지 원문 전체·`user_memory`는 캐싱하지 않는다.
- **TTL = 5분.** 무효화는 쓰기 시 명시적으로 하는 게 주(主) 메커니즘이고 TTL은 안전망일 뿐이다.
- **Redis 장애는 절대 요청을 실패시키면 안 된다** — 모든 Redis 호출은 try/catch로 감싸고, 실패 시 `log.warn` + MySQL 폴백(조회) 또는 무시(쓰기/삭제, 다음 조회가 자연히 다시 채움). Redis 커넥션 팩토리 빈 자체도 **애플리케이션 부팅 시점에 Redis에 연결을 시도해 실패하면 안 된다** — 지연 연결(lazy)이어야 한다. Task 5에서 "Redis 컨테이너를 내린 채로 앱이 정상 부팅되고 기능이 동작하는지"를 반드시 라이브로 확인한다(가정하지 않는다 — Phase 1 최종 리뷰의 C1이 바로 이런 종류의, "컴파일은 되지만 부팅 시점에만 터지는" 결함이었다).
- **`getOrLoad`는 제네릭 하나로 통합.** Redis get/set/delete의 try/catch 로직이 여러 메서드에 중복되지 않게 한다.
- **실행 환경(Java):** `mvn`이 PATH에 없다 — `C:\Users\SMT21\.m2\wrapper\dists\apache-maven-3.9.16-bin\5grr65jo27hi51sujmtcldfovl\apache-maven-3.9.16\bin`을 PATH 앞에 추가해서 쓴다. 콘솔 인코딩이 MS949라 `MAVEN_OPTS=-Dfile.encoding=UTF-8`을 항상 같이 설정한다.
- **라이브 인프라:** Task 5는 `docker compose`로 이 브랜치 기준 이미지를 띄워야 완전히 검증 가능하다(Task 1~4는 `mvn compile`/`mvn test`만으로 대부분 검증 가능 — Redis 없이도 컴파일·단위 테스트는 통과해야 한다).
- **`ChatContextCache` DTO:** 기존 DTO 스타일(`ChatRequest` 등)을 따라 Lombok `@Getter @Setter` 사용. `@NoArgsConstructor`(Jackson 역직렬화용)와 편의 생성자 둘 다 둔다.

---

### Task 1: Redis 의존성 + Docker 인프라 + 설정 배선

**Files:**
- Modify: `backend_spring/pom.xml`
- Modify: `backend_spring/src/main/webapp/WEB-INF/spring/root-context.xml`
- Modify: `backend_spring/src/main/resources/db.properties`
- Modify: `backend_spring/docker-entrypoint.sh`
- Modify: `docker-compose.yml` (저장소 루트)
- Modify: `.env.example` (저장소 루트)

**Interfaces:**
- Produces: 빈 `redisConnectionFactory`(`RedisConnectionFactory`), `stringRedisTemplate`(`StringRedisTemplate`) — Task 2의 `ChatCacheService`가 `@Autowired StringRedisTemplate redis`로 주입받아 쓴다.

- [ ] **Step 1: `pom.xml`에 의존성 추가**

`<dependencies>` 블록에 (기존 `spring-webflux` 의존성 블록 근처에) 추가:

```xml
<!-- Redis 읽기 캐시 (Phase 1.5, D10) -->
<dependency>
    <groupId>org.springframework.data</groupId>
    <artifactId>spring-data-redis</artifactId>
    <version>2.7.18</version>
    <exclusions>
        <exclusion>
            <groupId>io.lettuce</groupId>
            <artifactId>lettuce-core</artifactId>
        </exclusion>
    </exclusions>
</dependency>
<dependency>
    <groupId>io.lettuce</groupId>
    <artifactId>lettuce-core</artifactId>
    <version>6.2.6.RELEASE</version>
</dependency>
```

(spring-data-redis 2.7.x가 끌어오는 기본 lettuce-core 버전과 명시적으로 지정한 6.2.6.RELEASE가 다를 수 있어 `exclusions`로 내부 전이 버전을 빼고 명시 버전을 쓴다 — netty 버전 충돌 예방.)

- [ ] **Step 2: 컴파일 + 의존성 트리 확인 (Redis 인프라 불필요)**

Run:
```bash
cd backend_spring && export PATH="/c/Users/SMT21/.m2/wrapper/dists/apache-maven-3.9.16-bin/5grr65jo27hi51sujmtcldfovl/apache-maven-3.9.16/bin:$PATH" && export MAVEN_OPTS="-Dfile.encoding=UTF-8" && mvn -q compile 2>&1 | tail -60
```
Expected: `BUILD SUCCESS`. 실패하면(주로 netty 버전 충돌) 에러 메시지를 그대로 보고 — 지어내지 말고 `mvn dependency:tree -Dincludes=io.netty` 결과를 첨부해 어떤 버전이 충돌하는지 확인한 뒤, `spring-webflux`(reactor-netty)가 이미 가져오는 netty 버전에 맞춰 `<dependencyManagement>`로 고정하는 방법을 시도한다.

- [ ] **Step 3: `root-context.xml`에 Redis 빈 추가**

`<beans>` 안, 기존 `webClient` 빈 바로 뒤에 추가(파일 끝, `</beans>` 앞):

```xml
    <!--
        Redis는 순수 읽기 캐시(cache-aside)다 — 세션/인증 저장소가 아니다.
        연결은 지연(lazy)이어야 한다: 이 빈 생성 시점에 Redis가 안 떠 있어도
        애플리케이션 부팅이 실패하면 안 된다(ChatCacheService가 모든 호출을
        try/catch로 감싸 장애 시 MySQL로 폴백하는 게 전제다).
    -->
    <bean id="redisStandaloneConfiguration"
          class="org.springframework.data.redis.connection.RedisStandaloneConfiguration">
        <constructor-arg index="0" value="${redis.host}"/>
        <constructor-arg index="1" value="${redis.port}" type="int"/>
    </bean>

    <bean id="redisConnectionFactory"
          class="org.springframework.data.redis.connection.lettuce.LettuceConnectionFactory">
        <constructor-arg ref="redisStandaloneConfiguration"/>
    </bean>

    <bean id="stringRedisTemplate" class="org.springframework.data.redis.core.StringRedisTemplate">
        <constructor-arg ref="redisConnectionFactory"/>
    </bean>
```

- [ ] **Step 4: `db.properties`(로컬 개발 기본값)에 Redis 설정 추가**

`backend_spring/src/main/resources/db.properties`의 `fastapi.url=http://localhost:8000` 줄 바로 아래에 추가:

```properties
# 로컬에서 Redis를 직접 띄웠을 때의 주소 (없어도 앱은 뜬다 — 캐시만 안 될 뿐)
redis.host=localhost
redis.port=6379
```

- [ ] **Step 5: `docker-entrypoint.sh`에 Redis 환경변수 배선**

`backend_spring/docker-entrypoint.sh`의 `cat > "$PROPS" <<EOF ... EOF` 블록 안, `fastapi.url=${FASTAPI_URL:-http://ai:8000}` 줄 바로 아래에 추가:

```
redis.host=${REDIS_HOST:-redis}
redis.port=${REDIS_PORT:-6379}
```

**`REDIS_HOST`/`REDIS_PORT`를 스크립트 상단의 필수 환경변수 검증 목록(`DB_URL DB_USERNAME DB_PASSWORD JWT_SECRET`)에 추가하지 않는다** — Redis는 선택적 인프라이므로 없어도 컨테이너가 뜨고, 기본값(`redis`/`6379`, docker-compose 서비스 이름)으로 충분하다.

로그 출력부(`echo "[INFO]   fastapi.url = ..."` 다음 줄)에 추가:
```
echo "[INFO]   redis       = ${REDIS_HOST:-redis}:${REDIS_PORT:-6379} (선택적 — 없어도 기능은 동작)"
```

- [ ] **Step 6: `docker-compose.yml`에 `redis` 서비스 추가 + `tomcat`에 환경변수 연결**

저장소 루트 `docker-compose.yml`의 `services:` 아래, `tomcat` 서비스 정의보다 앞(또는 `ollama`/`opensearch`와 같은 위치)에 새 서비스 추가:

```yaml
  # ---------------------------------------------------------
  # 읽기 캐시 (Phase 1.5) — 세션 목록·대화 컨텍스트만 캐싱.
  # 데이터 유실을 걱정할 필요 없는 순수 캐시라 영속 볼륨을 안 둔다
  # (컨테이너 재시작 = 캐시 전체 미스, MySQL이 다시 채움 — 무해).
  # ---------------------------------------------------------
  redis:
    image: redis:7-alpine
    container_name: lexai-redis
    restart: unless-stopped
    expose:
      - "6379"
```

`tomcat` 서비스의 `environment:` 블록(`CORS_ALLOWED_ORIGIN` 줄 근처)에 추가:

```yaml
      REDIS_HOST: ${REDIS_HOST:-redis}
      REDIS_PORT: ${REDIS_PORT:-6379}
```

`tomcat` 서비스의 `depends_on:`은 이미 맵 형태다(`mysql: condition: service_healthy`, `ai: condition: service_started`) — 거기에 `redis` 항목을 추가하되, **health-condition을 걸지 않는다**(Redis가 안 떠도 tomcat은 떠야 하므로 `service_started`만):

```yaml
    depends_on:
      mysql:
        condition: service_healthy
      ai:
        condition: service_started
      redis:
        condition: service_started
```

- [ ] **Step 7: `.env.example`에 문서화(선택, 기본값으로 충분)**

`.env.example`의 `OLLAMA_MODEL=legal-gemma` 아래 어딘가에 추가:

```
# Redis 읽기 캐시 (선택 — 컨테이너 이름 기반 기본값으로 충분, 보통 수정 불필요)
REDIS_HOST=redis
REDIS_PORT=6379
```

- [ ] **Step 8: Commit**

```bash
git add backend_spring/pom.xml backend_spring/src/main/webapp/WEB-INF/spring/root-context.xml backend_spring/src/main/resources/db.properties backend_spring/docker-entrypoint.sh docker-compose.yml .env.example
git commit -m "feat: Redis 읽기 캐시 인프라 배선 — 의존성, 커넥션 빈, docker-compose 서비스"
```

---

### Task 2: `ChatCacheService` (제네릭 cache-aside) + 세션 목록 캐싱

**Files:**
- Create: `backend_spring/src/main/java/com/legal/backend/service/ChatCacheService.java`
- Test: `backend_spring/src/test/java/com/legal/backend/service/ChatCacheServiceTest.java`
- Modify: `backend_spring/src/main/java/com/legal/backend/service/ChatSessionService.java`

**Interfaces:**
- Produces: `ChatCacheService.getOrLoad(String key, TypeReference<T> type, Supplier<T> loader) -> T`, `ChatCacheService.invalidate(String key)`, `ChatCacheService.sessionsKey(Long userId) -> String`, `ChatCacheService.ctxKey(Long sessionId) -> String` (static). Task 3이 `ctxKey`/`getOrLoad`/`invalidate`를 그대로 재사용한다.
- Consumes: Task 1의 `stringRedisTemplate` 빈.

- [ ] **Step 1: 실패하는 테스트 작성**

`backend_spring/src/test/java/com/legal/backend/service/ChatCacheServiceTest.java` (신규):

```java
package com.legal.backend.service;

import com.fasterxml.jackson.core.type.TypeReference;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;

import java.util.List;
import java.util.function.Supplier;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class ChatCacheServiceTest {

    @Mock
    private StringRedisTemplate redis;
    @Mock
    private ValueOperations<String, String> valueOps;

    @InjectMocks
    private ChatCacheService chatCacheService;

    @Test
    void getOrLoad_캐시_미스면_loader를_호출하고_결과를_캐시에_쓴다() {
        when(redis.opsForValue()).thenReturn(valueOps);
        when(valueOps.get("k")).thenReturn(null);
        Supplier<List<String>> loader = () -> List.of("a", "b");

        List<String> result = chatCacheService.getOrLoad("k", new TypeReference<List<String>>() {}, loader);

        assertEquals(List.of("a", "b"), result);
        verify(valueOps).set(eq("k"), anyString(), any());
    }

    @Test
    void getOrLoad_캐시_히트면_loader를_호출하지_않는다() {
        when(redis.opsForValue()).thenReturn(valueOps);
        when(valueOps.get("k")).thenReturn("[\"a\",\"b\"]");
        Supplier<List<String>> loader = mock(Supplier.class);

        List<String> result = chatCacheService.getOrLoad("k", new TypeReference<List<String>>() {}, loader);

        assertEquals(List.of("a", "b"), result);
        verifyNoInteractions(loader);
    }

    @Test
    void getOrLoad_Redis_조회가_예외를_던져도_loader로_폴백한다() {
        when(redis.opsForValue()).thenReturn(valueOps);
        when(valueOps.get("k")).thenThrow(new RuntimeException("연결 실패"));
        Supplier<List<String>> loader = () -> List.of("fallback");

        List<String> result = chatCacheService.getOrLoad("k", new TypeReference<List<String>>() {}, loader);

        assertEquals(List.of("fallback"), result);
    }

    @Test
    void getOrLoad_Redis_쓰기가_예외를_던져도_loader_결과는_정상_반환한다() {
        when(redis.opsForValue()).thenReturn(valueOps);
        when(valueOps.get("k")).thenReturn(null);
        doThrow(new RuntimeException("쓰기 실패")).when(valueOps).set(anyString(), anyString(), any());

        List<String> result = chatCacheService.getOrLoad("k", new TypeReference<List<String>>() {}, () -> List.of("x"));

        assertEquals(List.of("x"), result);
    }

    @Test
    void invalidate_Redis_삭제가_예외를_던져도_전파하지_않는다() {
        when(redis.delete("k")).thenThrow(new RuntimeException("삭제 실패"));

        assertDoesNotThrow(() -> chatCacheService.invalidate("k"));
    }

    @Test
    void sessionsKey_ctxKey_형식_확인() {
        assertEquals("chat:sessions:7", ChatCacheService.sessionsKey(7L));
        assertEquals("chat:ctx:5", ChatCacheService.ctxKey(5L));
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run:
```bash
cd backend_spring && export PATH="/c/Users/SMT21/.m2/wrapper/dists/apache-maven-3.9.16-bin/5grr65jo27hi51sujmtcldfovl/apache-maven-3.9.16/bin:$PATH" && export MAVEN_OPTS="-Dfile.encoding=UTF-8" && mvn -q test -Dtest=ChatCacheServiceTest
```
Expected: FAIL — `ChatCacheService` 클래스가 없어 컴파일 에러.

- [ ] **Step 3: `ChatCacheService` 작성**

`backend_spring/src/main/java/com/legal/backend/service/ChatCacheService.java` (신규):

```java
package com.legal.backend.service;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Service;

import java.time.Duration;
import java.util.function.Supplier;

/**
 * 순수 읽기 캐시(cache-aside). 원본은 항상 MySQL이고, 여기 모든 메서드는
 * Redis 호출을 try/catch로 감싼다 — Redis가 죽어도 예외가 호출자로
 * 전파되지 않는다(조회는 loader로 폴백, 쓰기/삭제는 그냥 무시하고 로그만
 * 남긴다 — 다음 조회가 어차피 MySQL을 다시 읽어 캐시를 채운다).
 */
@Service
public class ChatCacheService {

    private static final Logger log = LoggerFactory.getLogger(ChatCacheService.class);
    private static final ObjectMapper OBJECT_MAPPER = new ObjectMapper();
    private static final Duration TTL = Duration.ofMinutes(5);

    @Autowired
    private StringRedisTemplate redis;

    public <T> T getOrLoad(String key, TypeReference<T> type, Supplier<T> loader) {
        T cached = tryGet(key, type);
        if (cached != null) {
            return cached;
        }
        T fresh = loader.get();
        trySet(key, fresh);
        return fresh;
    }

    public void invalidate(String key) {
        try {
            redis.delete(key);
        } catch (Exception e) {
            log.warn("Redis 무효화 실패(무시 — TTL {}분 뒤 자연 정리): key={}, {}", TTL.toMinutes(), key, e.getMessage());
        }
    }

    private <T> T tryGet(String key, TypeReference<T> type) {
        try {
            String json = redis.opsForValue().get(key);
            return json != null ? OBJECT_MAPPER.readValue(json, type) : null;
        } catch (Exception e) {
            log.warn("Redis 조회 실패 — MySQL로 폴백: key={}, {}", key, e.getMessage());
            return null;
        }
    }

    private void trySet(String key, Object value) {
        try {
            redis.opsForValue().set(key, OBJECT_MAPPER.writeValueAsString(value), TTL);
        } catch (Exception e) {
            log.warn("Redis 쓰기 실패(무시 — 다음 조회가 MySQL을 다시 채움): key={}, {}", key, e.getMessage());
        }
    }

    public static String sessionsKey(Long userId) {
        return "chat:sessions:" + userId;
    }

    public static String ctxKey(Long sessionId) {
        return "chat:ctx:" + sessionId;
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run:
```bash
mvn -q test -Dtest=ChatCacheServiceTest
```
Expected: PASS(6/6).

- [ ] **Step 5: `ChatSessionService.listSessions`를 캐시 경유로 전환 + 쓰기 경로에 무효화 연결**

`backend_spring/src/main/java/com/legal/backend/service/ChatSessionService.java` 전체를 교체:

```java
package com.legal.backend.service;

import com.fasterxml.jackson.core.type.TypeReference;
import com.legal.backend.dao.ChatSessionDao;
import com.legal.backend.dto.ChatSessionResponse;
import com.legal.backend.entity.ChatSession;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;

import java.time.format.DateTimeFormatter;
import java.util.List;
import java.util.NoSuchElementException;
import java.util.stream.Collectors;

@Service
public class ChatSessionService {

    private static final DateTimeFormatter ISO = DateTimeFormatter.ISO_LOCAL_DATE_TIME;

    @Autowired
    private ChatSessionDao chatSessionDao;
    @Autowired
    private ChatCacheService chatCacheService;

    public List<ChatSessionResponse> listSessions(Long userId) {
        return chatCacheService.getOrLoad(
                ChatCacheService.sessionsKey(userId),
                new TypeReference<List<ChatSessionResponse>>() {},
                () -> chatSessionDao.findByUser(userId).stream()
                        .map(this::toResponse)
                        .collect(Collectors.toList())
        );
    }

    /** 소유자가 아니거나 존재하지 않는 세션이면 예외 — 컨트롤러에서 404로 변환한다. */
    public ChatSession getOwnedSession(Long id, Long userId) {
        ChatSession session = chatSessionDao.findById(id);
        if (session == null || !session.getUserId().equals(userId)) {
            throw new NoSuchElementException("세션을 찾을 수 없습니다: " + id);
        }
        return session;
    }

    public void renameSession(Long id, Long userId, String newTitle) {
        getOwnedSession(id, userId);
        chatSessionDao.updateTitle(id, newTitle);
        chatCacheService.invalidate(ChatCacheService.sessionsKey(userId));
    }

    public void deleteSession(Long id, Long userId) {
        getOwnedSession(id, userId);
        chatSessionDao.softDelete(id);
        chatCacheService.invalidate(ChatCacheService.sessionsKey(userId));
    }

    private ChatSessionResponse toResponse(ChatSession s) {
        return new ChatSessionResponse(s.getId(), s.getTitle(), s.getUpdatedAt().format(ISO));
    }
}
```

(변경: `getOwnedSession`/`toResponse`는 원래 그대로. `listSessions`가 `chatCacheService.getOrLoad`를 거치도록, `renameSession`/`deleteSession`이 끝에 무효화 호출을 하도록 바뀐 것뿐.)

- [ ] **Step 6: 기존 `ChatSessionServiceTest`가 깨지지 않는지 확인**

현재 `ChatSessionServiceTest`는 `getOwnedSession`만 테스트한다(`listSessions`/`renameSession`/`deleteSession`은 테스트가 없다) — `getOwnedSession`은 `chatCacheService`를 전혀 쓰지 않으므로, `@InjectMocks`가 그 필드를 채우지 못해 `null`로 남아도(Mockito는 매칭 안 되는 필드를 조용히 null로 둔다) 기존 3개 테스트는 그대로 통과해야 한다 — **테스트 파일을 수정할 필요가 없다.** 다음 명령으로 그냥 확인만 한다:

```bash
mvn -q test -Dtest=ChatSessionServiceTest
```
Expected: PASS(3/3), 코드 변경 없이. 만약 실패한다면(예상 밖 컴파일 에러 등) 그때 가서 `@Mock private ChatCacheService chatCacheService;` 필드를 추가하고 원인을 재확인한다 — 미리 추측해서 넣지 않는다.

(선택, 권장) `listSessions`/`renameSession`/`deleteSession`에 대한 새 테스트를 여기서 추가해도 좋다 — 필수는 아니고, Task 2가 추가하는 새 동작이라 커버리지 공백으로 남아도 이 계획 완료를 막지는 않는다.

- [ ] **Step 7: 전체 회귀 확인**

Run:
```bash
mvn test 2>&1 | tail -20
```
Expected: 기존 29개 + 이번에 추가한 6개(ChatCacheServiceTest) = 35개 전부 PASS, BUILD SUCCESS.

- [ ] **Step 8: Commit**

```bash
git add backend_spring/src/main/java/com/legal/backend/service/ChatCacheService.java backend_spring/src/test/java/com/legal/backend/service/ChatCacheServiceTest.java backend_spring/src/main/java/com/legal/backend/service/ChatSessionService.java backend_spring/src/test/java/com/legal/backend/service/ChatSessionServiceTest.java
git commit -m "feat: ChatCacheService(제네릭 cache-aside) 추가, 세션 목록 캐싱+무효화 연결"
```

---

### Task 3: 대화 컨텍스트 캐싱 — `ChatContextCache` DTO + `ChatService.chat()` 배선

**Files:**
- Create: `backend_spring/src/main/java/com/legal/backend/dto/ChatContextCache.java`
- Modify: `backend_spring/src/main/java/com/legal/backend/service/ChatService.java`
- Modify: `backend_spring/src/test/java/com/legal/backend/service/ChatServiceTest.java`

**Interfaces:**
- Produces: `ChatContextCache{history, summary}` — Task 4의 `ChatMemoryAsyncService`가 무효화할 캐시 키(`ChatCacheService.ctxKey`)를 공유한다.
- Consumes: Task 2의 `ChatCacheService.getOrLoad`/`invalidate`/`ctxKey`/`sessionsKey`.

- [ ] **Step 1: `ChatContextCache` DTO**

`backend_spring/src/main/java/com/legal/backend/dto/ChatContextCache.java` (신규):

```java
package com.legal.backend.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.util.List;
import java.util.Map;

@Getter @Setter @NoArgsConstructor @AllArgsConstructor
public class ChatContextCache {
    private List<Map<String, String>> history;
    private String summary;
}
```

- [ ] **Step 2: `ChatService.chat()`을 캐시 경유로 전환**

`backend_spring/src/main/java/com/legal/backend/service/ChatService.java`에서 아래 두 지점을 수정한다.

(a) import 추가:
```java
import com.fasterxml.jackson.core.type.TypeReference;
import com.legal.backend.dto.ChatContextCache;
```

(b) 필드 추가 (`chatMemoryAsyncService` 필드 바로 아래):
```java
    @Autowired
    private ChatCacheService chatCacheService;
```

(c) `chat()` 메서드에서 이력·요약을 읽는 부분을 교체 — 현재:
```java
        ChatSession existing = findOwnedSession(req.getSessionId(), userId);

        Map<String, Object> body = new HashMap<>();
        body.put("question", req.getQuestion());
        body.put("age", age);
        body.put("law_category", req.getLawCategory());
        body.put("history", existing != null ? historyPayload(existing.getId()) : List.of());
        body.put("summary", existing != null ? summaryText(existing.getId()) : null);
```
다음으로 교체:
```java
        ChatSession existing = findOwnedSession(req.getSessionId(), userId);
        ChatContextCache ctx = existing != null ? loadContext(existing.getId()) : new ChatContextCache(List.of(), null);

        Map<String, Object> body = new HashMap<>();
        body.put("question", req.getQuestion());
        body.put("age", age);
        body.put("law_category", req.getLawCategory());
        body.put("history", ctx.getHistory());
        body.put("summary", ctx.getSummary());
```

(d) `historyPayload`/`summaryText` 사이(또는 바로 위)에 새 private 메서드 추가:
```java
    private ChatContextCache loadContext(Long sessionId) {
        return chatCacheService.getOrLoad(
                ChatCacheService.ctxKey(sessionId),
                new TypeReference<ChatContextCache>() {},
                () -> new ChatContextCache(historyPayload(sessionId), summaryText(sessionId))
        );
    }
```

(e) 턴 저장·세션 목록 갱신 직후 무효화 — 현재:
```java
        ChatSession session = resolveSession(req.getSessionId(), userId, req.getQuestion());
        chatMessagePersistenceService.persistTurn(session.getId(), req.getQuestion(), response);
        chatSessionDao.touch(session.getId());
        triggerSummaryUpdate(session.getId());
```
다음으로 교체:
```java
        ChatSession session = resolveSession(req.getSessionId(), userId, req.getQuestion());
        chatMessagePersistenceService.persistTurn(session.getId(), req.getQuestion(), response);
        chatCacheService.invalidate(ChatCacheService.ctxKey(session.getId()));   // 이력이 방금 바뀜
        chatSessionDao.touch(session.getId());
        chatCacheService.invalidate(ChatCacheService.sessionsKey(userId));      // updated_at 바뀌어 목록 정렬도 바뀜
        triggerSummaryUpdate(session.getId());
```

`historyPayload`/`summaryText` private 메서드 자체는 그대로 둔다(이제 `loadContext`의 loader 안에서만 호출됨).

- [ ] **Step 3: 기존 `ChatServiceTest`에 `chatCacheService` 스텁 추가 — 딱 필요한 곳에만**

`backend_spring/src/test/java/com/legal/backend/service/ChatServiceTest.java`에 필드 추가:
```java
    @Mock
    private ChatCacheService chatCacheService;
```

Step 2의 코드는 `existing != null`일 때만 `loadContext` → `chatCacheService.getOrLoad(...)`를 호출한다. `existing`은 `findOwnedSession(req.getSessionId(), userId)`의 결과이므로, 기존 4개 테스트 중 실제로 이 경로를 타는 건 **`chat_기존_세션이면_이력과_요약을_로드하고_응답_후_요약갱신을_트리거한다`** 하나뿐이다(이 테스트만 `chatSessionDao.findById(5L)`를 존재하는 내 세션으로 스텁해 두었다). 나머지 세 개(`chat_FastAPI_응답이_비어있으면...`, `chat_새_세션이면...`, `chat_요약갱신_트리거가_실패해도...`)는 `sessionId`가 없거나 `findById`가 스텁 안 돼 있어 `existing`이 항상 `null`이라 `chatCacheService`를 아예 안 탄다 — **이 세 개는 손댈 필요 없다.**

`chat_기존_세션이면...` 테스트의 맨 앞(다른 `when(...)` 스텁들과 함께)에 추가:

```java
        when(chatCacheService.getOrLoad(anyString(), any(), any()))
                .thenAnswer(inv -> ((java.util.function.Supplier<?>) inv.getArgument(2)).get());
```

이 스텁은 캐시를 항상 미스로 만들어 loader(=`historyPayload`/`summaryText` 호출)를 그대로 실행시키므로, 기존 `verify(chatMessageDao).findRecentMessages(5L, 4)` / `verify(chatSessionSummaryDao).find(5L)` 어서션은 손대지 않아도 그대로 통과한다.

실제로 `mvn test`를 돌려서(Step 4) 이 판단이 맞는지 확인한다 — 만약 다른 테스트도 실패한다면 그건 이 판단이 틀렸다는 신호이니, 해당 테스트가 왜 `existing != null` 경로를 타는지 다시 추적한다(추측으로 스텁을 더 넣지 않는다).

- [ ] **Step 4: 전체 회귀 확인**

Run:
```bash
mvn test 2>&1 | tail -20
```
Expected: 이전 35개 전부 PASS, BUILD SUCCESS(이번 Task는 새 테스트를 추가하지 않음 — 기존 `ChatServiceTest`의 스텁만 보강).

- [ ] **Step 5: Commit**

```bash
git add backend_spring/src/main/java/com/legal/backend/dto/ChatContextCache.java backend_spring/src/main/java/com/legal/backend/service/ChatService.java backend_spring/src/test/java/com/legal/backend/service/ChatServiceTest.java
git commit -m "feat: 대화 컨텍스트(이력+요약) 캐싱을 ChatService.chat()에 배선, 쓰기 후 무효화"
```

---

### Task 4: 요약 갱신 후 컨텍스트 캐시 무효화

**Files:**
- Modify: `backend_spring/src/main/java/com/legal/backend/service/ChatMemoryAsyncService.java`
- Modify: `backend_spring/src/test/java/com/legal/backend/service/ChatMemoryAsyncServiceTest.java`

**Interfaces:**
- Consumes: Task 2의 `ChatCacheService.invalidate`/`ctxKey`.

왜 필요한가: Task 3에서 `chat()`이 턴 저장 직후 `chat:ctx:{sessionId}`를 무효화하지만, 비동기 요약 갱신(`updateSummaryIfNeeded`)은 그 *이후에* 별도 스레드에서 실행돼 `chat_session_summary`를 갱신한다 — 이 갱신이 끝난 시점엔 캐시가 이미 (턴 저장 때 지워졌다가) 다음 조회로 다시 채워져 있을 수 있는데, 그 다시 채워진 캐시는 **아직 요약이 안 붙은 상태**로 채워졌을 수 있다. 요약 upsert가 성공한 직후 한 번 더 무효화해서, 다음 턴이 확실히 최신 요약을 읽게 한다.

- [ ] **Step 1: `ChatMemoryAsyncService`에 무효화 추가**

`backend_spring/src/main/java/com/legal/backend/service/ChatMemoryAsyncService.java`에서:

(a) 필드 추가:
```java
    @Autowired
    private ChatCacheService chatCacheService;
```

(b) `chatSessionSummaryDao.upsertIfNewer(sessionId, newSummary, newThroughId);` 바로 다음 줄에 추가:
```java
        chatCacheService.invalidate(ChatCacheService.ctxKey(sessionId));
```

- [ ] **Step 2: `ChatMemoryAsyncServiceTest`에 검증 추가**

`updateSummaryIfNeeded_미접힌_턴이_2턴_초과면_FastAPI를_호출하고_upsert한다` 테스트에 `@Mock private ChatCacheService chatCacheService;` 필드를 추가하고(다른 3개 테스트도 `@InjectMocks`가 이 필드를 요구하면 컴파일 위해 필요), 이 테스트 끝에 어서션 추가:

```java
        verify(chatCacheService).invalidate(ChatCacheService.ctxKey(5L));
```

- [ ] **Step 3: 전체 회귀 확인**

Run:
```bash
mvn test 2>&1 | tail -20
```
Expected: 전부 PASS(신규 어서션 1개 강화, 신규 테스트 개수 변화 없음), BUILD SUCCESS.

- [ ] **Step 4: Commit**

```bash
git add backend_spring/src/main/java/com/legal/backend/service/ChatMemoryAsyncService.java backend_spring/src/test/java/com/legal/backend/service/ChatMemoryAsyncServiceTest.java
git commit -m "feat: 요약 갱신 직후 대화 컨텍스트 캐시 무효화"
```

---

### Task 5: 라이브 검증 — 캐시 히트/미스, 무효화, Redis 장애 시 폴백(부팅 포함)

**Files:** 없음(검증 전용 Task, 코드 변경 없음)

**Interfaces:** 없음.

이 Task는 이전 4개 Task에서 세운 가정 — "Redis 빈은 지연 연결이라 부팅을 막지 않는다", "Redis가 죽어도 요청은 정상 처리된다" — 을 실제로 증명한다. Phase 1 최종 리뷰의 교훈(컴파일·단위 테스트만으로는 부팅 시점 결함을 못 잡는다)을 그대로 적용한다.

- [ ] **Step 1: 이 브랜치 기준으로 이미지 재빌드 + 기동**

```bash
docker compose -p legal-rag-chatbot build tomcat
docker compose -p legal-rag-chatbot up -d --no-deps redis tomcat
docker logs lexai-tomcat --tail 30
```
Expected: Redis 관련 예외 없이 정상 부팅(`Server startup in [...] milliseconds`).

- [ ] **Step 2: 캐시 히트 확인**

회원가입·로그인 후 `GET /api/chat/sessions`를 두 번 연속 호출. 두 번째 호출 직전에:
```bash
docker exec lexai-redis redis-cli GET "chat:sessions:<실제_userId>"
```
Expected: 첫 호출 뒤 이 키에 JSON이 들어있음(캐시가 채워짐). `docker logs lexai-tomcat`에 두 번째 호출에서 `chatSessionDao.findByUser` MyBatis 로그가 **안 찍히는지** 확인(캐시 히트라 DAO를 안 탐).

- [ ] **Step 3: 무효화 확인**

세션 제목을 `PATCH /api/chat/sessions/{id}`로 변경한 직후 `GET /api/chat/sessions`를 호출 — TTL(5분)을 기다리지 않고 즉시 새 제목이 보여야 한다.

- [ ] **Step 4: Redis 장애 시 폴백 확인 (핵심 — 반드시 실행)**

```bash
docker stop lexai-redis
```
그 상태에서:
- `GET /api/chat/sessions` — 여전히 200과 정상 목록을 반환해야 한다(로그에 `Redis 조회 실패 — MySQL로 폴백` warn이 찍힘).
- `POST /api/chat`으로 새 질문 전송(기존 세션에) — 여전히 200과 정상 답변을 반환해야 한다(캐시 실패가 `chat()`을 막지 않음).

Expected: 둘 다 정상 동작, 5xx 없음.

```bash
docker start lexai-redis
```
재기동 후 `GET /api/chat/sessions`가 다시 캐시를 쓰는지(Step 2와 동일한 방식으로) 확인.

- [ ] **Step 5: `mvn test` 최종 재확인**

```bash
cd backend_spring && export PATH="/c/Users/SMT21/.m2/wrapper/dists/apache-maven-3.9.16-bin/5grr65jo27hi51sujmtcldfovl/apache-maven-3.9.16/bin:$PATH" && export MAVEN_OPTS="-Dfile.encoding=UTF-8" && mvn test 2>&1 | tail -20
```
Expected: 전부 PASS, BUILD SUCCESS.

- [ ] **Step 6: Commit (검증 결과만 — 코드 변경 없으면 커밋 불필요, 리포트만 작성)**

이 Task는 보통 커밋할 코드가 없다. 라이브 검증 결과를 리포트에 실제 출력(로그 발췌, `redis-cli` 출력)과 함께 남긴다 — "확인함"이라고만 쓰지 않는다.

---

## Self-Review 결과

- **스펙 커버리지:** §7.5(D10) 전체 — 캐시 키 2개(Task 2·3), 무효화 규칙(Task 2·3·4), 장애 시 MySQL 폴백(Task 2, Task 5에서 라이브 검증), docker-compose `redis` 서비스(Task 1) 전부 매핑됨.
- **자리표시자 스캔:** "TBD"/"추후 구현" 없음. 모든 코드 블록이 실제 동작 코드.
- **타입/시그니처 일관성:** `ChatCacheService.getOrLoad(String, TypeReference<T>, Supplier<T>) -> T`가 Task 2에서 정의되고 Task 3(`ChatContextCache`)·Task 2 자신(`List<ChatSessionResponse>`)에서 동일하게 쓰임. `ChatCacheService.ctxKey`가 Task 3(쓰기)과 Task 4(요약 갱신 후 무효화)에서 같은 키 포맷으로 쓰임.
- **하위 호환:** `ChatSessionService.listSessions`/`ChatService.chat()`의 외부 시그니처·반환 타입은 전혀 안 바뀐다 — 내부 구현만 캐시를 경유하도록 바뀐다. Redis가 없는 환경(예: 로컬 STS 실행, `db.properties`의 기본값이 `localhost:6379`인데 로컬에 Redis가 없는 경우)에서도 앱은 정상 동작해야 한다(모든 Redis 호출이 try/catch).
- **Plain Spring MVC 주의사항 재확인:** `spring-boot-starter-data-redis`가 아니라 `spring-data-redis` + `lettuce-core`를 직접 의존성으로 추가하고, 빈도 XML로 직접 정의한다 — Spring Boot 자동 구성이 없는 이 프로젝트에서 Boot 스타터를 추가하면 아무 빈도 자동 생성되지 않아 `@Autowired StringRedisTemplate`이 그냥 실패한다.
