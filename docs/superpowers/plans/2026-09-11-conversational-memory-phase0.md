# 대화 저장·세션 UI 기반(Phase 0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `/api/chat`가 대화를 기억하지 못하는 stateless 구조에, 대화 저장·다중 세션 목록·"새 대화"·개인 메모리 열람의 기반(Phase 0)을 놓는다. 답변 생성 로직 자체는 이번 단계에서 바꾸지 않는다 — 그건 Phase 1(멀티턴)·Phase 2(장기 메모리)의 범위다.

**Architecture:** Spring(`backend_spring`)이 세션/메시지/메모리를 MySQL에 소유·영속화한다. FastAPI(`ai/`)는 이번 Phase에서 전혀 바뀌지 않는다 — Spring이 기존과 똑같이 `question`/`age`/`law_category`만 넘긴다. 스키마는 Flyway로 관리한다.

**Tech Stack:** Java 11, Spring MVC 5.3.30(XML 설정, Boot 아님), MyBatis 3.5.13, HikariCP, MySQL 8, Flyway 9.x, JUnit 5 + Mockito(이번 스펙에서 신규 도입), jQuery(프론트, 기존 그대로).

**Spec:** [docs/superpowers/specs/2026-09-11-conversational-memory-design.md](../specs/2026-09-11-conversational-memory-design.md) — 이 계획은 스펙의 §4, §5, §7, §9, §12(Phase 0)를 구현한다. FastAPI 변경(§8)과 Spring `@Async` 실사용(§7.4의 `ChatMemoryAsyncService`)은 Phase 1 계획에서 다룬다.

## Global Constraints

- 백엔드 수정은 `backend_spring`만. `backend/`(소스 없는 레거시 Eclipse 셸)는 절대 건드리지 않는다.
- FastAPI(`ai/`)는 이번 계획에서 수정하지 않는다.
- 새 테이블은 Flyway 마이그레이션(`baselineOnMigrate(true)`)으로만 만든다 — `deploy/init.sql`을 고치지 않는다.
- 신규 JWT는 `uid`(숫자 `user_id`) 클레임을 갖는다. 기존 발급 토큰과의 하위호환은 고려하지 않는다(로컬 개발, 재로그인으로 해결).
- 이 코드베이스에는 지금 자동화 테스트가 전혀 없다(JUnit/Mockito 의존성 없음, `src/test`도 비어있음). 이번 계획에서 JUnit 5 + Mockito를 처음 도입하되, **실제 로직 분기가 있는 부분만** 단위 테스트하고, DB·HTTP를 직접 건드리는 부분은 로컬 MySQL(docker-compose로 이미 띠워져 있음)에 대한 수동 curl 검증으로 확인한다 — MyBatis 매퍼용 H2/Testcontainers 인프라를 새로 구축하는 건 이번 Phase 범위 밖이다(YAGNI: 그 인프라가 필요할 만큼 SQL이 복잡해지면 그때 별도로 도입).
- 타임스탬프는 DTO에서 항상 `String`(ISO-8601)으로 내려준다. `LocalDateTime`을 Jackson으로 직접 직렬화하면 `jackson-datatype-jsr310`이 없어(pom.xml에 없음, 지금 코드베이스 어디에도 없음) 런타임 예외가 난다 — 반드시 서비스 계층에서 `DateTimeFormatter.ISO_LOCAL_DATE_TIME`으로 문자열로 바꾼 뒤 DTO에 담는다.
- MyBatis DAO 메서드에 파라미터가 2개 이상이면 반드시 `@Param`을 붙인다 — 이 프로젝트의 기존 DAO(`UserDao`)는 전부 파라미터 1개뿐이라 이 문제를 아직 겪은 적이 없다. `-parameters` 컴파일러 옵션이 없어서 안 붙이면 "Parameter 'x' not found" 런타임 에러가 난다.

---

### Task 1: Flyway 도입 + 스키마 마이그레이션

**Files:**
- Modify: `backend_spring/pom.xml`
- Create: `backend_spring/src/main/java/com/legal/backend/config/FlywayConfig.java`
- Create: `backend_spring/src/main/resources/db/migration/V1__chat_tables.sql`

**Interfaces:**
- Produces: `chat_session`, `chat_message`, `chat_session_summary`, `user_memory`, `chat_async_job` 테이블. 이후 모든 태스크가 이 테이블에 의존한다.

- [ ] **Step 1: pom.xml에 Flyway 의존성 추가**

`backend_spring/pom.xml`의 `<dependencies>` 블록 끝(로깅 의존성 다음)에 추가:

```xml
        <!-- Flyway — 스키마 마이그레이션 -->
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

        <!-- 테스트 -->
        <dependency>
            <groupId>org.junit.jupiter</groupId>
            <artifactId>junit-jupiter</artifactId>
            <version>5.10.1</version>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.mockito</groupId>
            <artifactId>mockito-junit-jupiter</artifactId>
            <version>5.8.0</version>
            <scope>test</scope>
        </dependency>
```

`<build><plugins>`에 surefire가 없으면 JUnit5를 못 찾을 수 있다 — 확인 후 없으면 추가:

```xml
            <plugin>
                <groupId>org.apache.maven.plugins</groupId>
                <artifactId>maven-surefire-plugin</artifactId>
                <version>3.2.5</version>
            </plugin>
```

- [ ] **Step 2: 마이그레이션 SQL 작성**

`backend_spring/src/main/resources/db/migration/V1__chat_tables.sql`:

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
    standalone_query  TEXT         NULL,
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
    mem_key            VARCHAR(50)  NOT NULL,
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

- [ ] **Step 3: Flyway 마이그레이션 빈 작성**

`backend_spring/src/main/java/com/legal/backend/config/FlywayConfig.java` (신규):

```java
package com.legal.backend.config;

import org.flywaydb.core.Flyway;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import javax.sql.DataSource;

@Configuration
public class FlywayConfig {

    /**
     * initMethod="migrate" — 이 빈이 생성되는 시점(앱 시작)에 자동으로 migrate() 실행.
     * baselineOnMigrate: 이미 users 테이블이 있는(= deploy/init.sql로 만들어진) 기존 DB에도
     * "스키마가 비어있지 않다"는 에러 없이 안전하게 V1부터 적용한다.
     */
    @Bean(initMethod = "migrate")
    public Flyway flyway(DataSource dataSource) {
        return Flyway.configure()
                .dataSource(dataSource)
                .baselineOnMigrate(true)
                .locations("classpath:db/migration")
                .load();
    }
}
```

이 빈은 `dataSource`를 생성자 인자로 받는데, `root-context.xml`의 `dataSource` 빈 이름과 일치해야 한다 — `<bean id="dataSource" ...>`이 이미 있으므로(root-context.xml:18) 타입 매칭으로 자동 주입된다. `@Configuration` 클래스는 `com.legal.backend.config` 패키지에 두면 `root-context.xml`의 `<context:component-scan base-package="com.legal.backend">`(exclude는 `@Controller`뿐)에 자동으로 걸린다 — XML에 빈을 따로 등록할 필요 없다.

- [ ] **Step 4: 빌드 확인**

Run: `cd backend_spring && mvn -q compile`
Expected: BUILD SUCCESS (Flyway 의존성 버전이 실제로 Maven Central에 있는지 이 시점에 확인됨 — 없으면 `mvn`이 바로 에러를 낸다. 만약 9.22.3이 없으면 그 시점의 최신 9.x 패치로 조정한다).

- [ ] **Step 5: 마이그레이션 수동 검증**

로컬 MySQL이 떠 있어야 한다: `docker-compose up -d mysql`

Run: `cd backend_spring && mvn tomcat7:run` (또는 기존에 쓰던 실행 방식)

앱이 뜨면 MySQL에 접속해 확인:
```sql
SHOW TABLES;                        -- chat_session, chat_message, chat_session_summary,
                                     -- user_memory, chat_async_job, users, flyway_schema_history 가 보여야 함
SELECT * FROM flyway_schema_history; -- V1 이 success=1로 기록돼 있어야 함
```

Expected: 5개 신규 테이블 + `flyway_schema_history`에 V1 성공 기록.

- [ ] **Step 6: Commit**

```bash
git add backend_spring/pom.xml backend_spring/src/main/java/com/legal/backend/config/FlywayConfig.java backend_spring/src/main/resources/db/migration/V1__chat_tables.sql
git commit -m "feat: Flyway 도입 및 대화·메모리 테이블 마이그레이션 추가"
```

---

### Task 2: JWT에 user_id 싣기

**Files:**
- Modify: `backend_spring/src/main/java/com/legal/backend/util/JwtUtil.java`
- Modify: `backend_spring/src/main/java/com/legal/backend/filter/JwtFilter.java`
- Modify: `backend_spring/src/main/java/com/legal/backend/service/AuthService.java`
- Test: `backend_spring/src/test/java/com/legal/backend/util/JwtUtilTest.java`

**Interfaces:**
- Produces: `JwtUtil.generateToken(Long userId, String username, int age)`, `JwtUtil.getUserId(String token)`. 이후 모든 컨트롤러가 `httpReq.getAttribute("userId")`(타입 `Long`)로 소유자를 읽는다.

- [ ] **Step 1: 실패하는 테스트 작성**

`backend_spring/src/test/java/com/legal/backend/util/JwtUtilTest.java` (신규):

```java
package com.legal.backend.util;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;

import static org.junit.jupiter.api.Assertions.assertEquals;

class JwtUtilTest {

    private JwtUtil jwtUtil;

    @BeforeEach
    void setUp() {
        jwtUtil = new JwtUtil();
        ReflectionTestUtils.setField(jwtUtil, "secret", "test-secret-at-least-32-bytes-long!!");
        ReflectionTestUtils.setField(jwtUtil, "expiration", 3600000L);
        jwtUtil.init();
    }

    @Test
    void generateToken_담은_userId를_getUserId로_그대로_꺼낼_수_있다() {
        String token = jwtUtil.generateToken(42L, "yunhwa", 25);

        assertEquals(42L, jwtUtil.getUserId(token));
        assertEquals("yunhwa", jwtUtil.getUsername(token));
        assertEquals(25, jwtUtil.getAge(token));
    }
}
```

`ReflectionTestUtils`는 `spring-test`에 있다 — pom.xml에 추가:
```xml
        <dependency>
            <groupId>org.springframework</groupId>
            <artifactId>spring-test</artifactId>
            <version>${spring.version}</version>
            <scope>test</scope>
        </dependency>
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd backend_spring && mvn -q test -Dtest=JwtUtilTest`
Expected: FAIL — `generateToken(Long, String, int)`, `getUserId(String)` 메서드가 없어 컴파일 에러.

- [ ] **Step 3: JwtUtil 수정**

`JwtUtil.java`의 `generateToken`, `getUsername` 사이에 있는 기존 메서드를 아래로 교체(`backend_spring/src/main/java/com/legal/backend/util/JwtUtil.java:35-51`):

```java
    public String generateToken(Long userId, String username, int age) {
        return Jwts.builder()
                .setSubject(username)
                .claim("uid", userId)
                .claim("age", age)
                .setIssuedAt(new Date())
                .setExpiration(new Date(System.currentTimeMillis() + expiration))
                .signWith(key, SignatureAlgorithm.HS256)
                .compact();
    }

    public String getUsername(String token) {
        return getClaims(token).getSubject();
    }

    public Long getUserId(String token) {
        return getClaims(token).get("uid", Long.class);
    }

    public int getAge(String token) {
        return getClaims(token).get("age", Integer.class);
    }
```

`jjwt`는 숫자 클레임을 파싱할 때 JSON 숫자 타입에 따라 `Integer`로 돌아올 수 있어(값이 int 범위면) `.get("uid", Long.class)`가 `ClassCastException`을 낼 수 있다 — jjwt의 `Claims.get(key, Long.class)`는 내부적으로 `Number`인지 확인하고 `.longValue()`로 변환해주므로 안전하다(jjwt-impl 0.11.5 기준 `DefaultClaims.get`이 `Number` 캐스팅을 처리함). 이 방식을 그대로 쓴다.

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd backend_spring && mvn -q test -Dtest=JwtUtilTest`
Expected: PASS

- [ ] **Step 5: JwtFilter 수정**

`JwtFilter.java:40-41`을 교체:

```java
        req.setAttribute("userId", jwtUtil.getUserId(token));
        req.setAttribute("username", jwtUtil.getUsername(token));
        req.setAttribute("age", jwtUtil.getAge(token));
```

- [ ] **Step 6: AuthService 수정**

`AuthService.java:31`을 교체:

```java
        String token = jwtUtil.generateToken(user.getId(), user.getUsername(), user.getAge());
```

- [ ] **Step 7: 기존 ChatController 컴파일 확인**

`ChatController.java:24-25`는 지금 `httpReq.getAttribute("username")`만 쓰고 `userId`는 아직 안 쓴다 — 이 태스크에서는 컴파일만 되면 된다(실제로 `userId`를 쓰는 건 Task 5).

Run: `cd backend_spring && mvn -q compile`
Expected: BUILD SUCCESS

- [ ] **Step 8: 전체 테스트 실행**

Run: `cd backend_spring && mvn -q test`
Expected: PASS (JwtUtilTest 포함)

- [ ] **Step 9: Commit**

```bash
git add backend_spring/pom.xml backend_spring/src/main/java/com/legal/backend/util/JwtUtil.java backend_spring/src/main/java/com/legal/backend/filter/JwtFilter.java backend_spring/src/main/java/com/legal/backend/service/AuthService.java backend_spring/src/test/java/com/legal/backend/util/JwtUtilTest.java
git commit -m "feat: JWT에 user_id 클레임 추가"
```

---

### Task 3: 세션 목록·제목수정·삭제 API

**Files:**
- Create: `backend_spring/src/main/java/com/legal/backend/entity/ChatSession.java`
- Create: `backend_spring/src/main/java/com/legal/backend/dao/ChatSessionDao.java`
- Create: `backend_spring/src/main/resources/mybatis/ChatSessionMapper.xml`
- Create: `backend_spring/src/main/java/com/legal/backend/dto/ChatSessionResponse.java`
- Create: `backend_spring/src/main/java/com/legal/backend/dto/RenameSessionRequest.java`
- Create: `backend_spring/src/main/java/com/legal/backend/service/ChatSessionService.java`
- Create: `backend_spring/src/main/java/com/legal/backend/controller/ChatSessionController.java`
- Test: `backend_spring/src/test/java/com/legal/backend/service/ChatSessionServiceTest.java`

**Interfaces:**
- Consumes: Task 1의 `chat_session` 테이블. `httpReq.getAttribute("userId")`(Task 2, `Long`).
- Produces: `ChatSessionService.getOwnedSession(Long id, Long userId)` — Task 5의 메시지 조회/저장 로직이 이 메서드로 소유권을 확인한다.

- [ ] **Step 1: 엔티티 작성**

`backend_spring/src/main/java/com/legal/backend/entity/ChatSession.java` (신규):

```java
package com.legal.backend.entity;

import lombok.*;
import java.time.LocalDateTime;

@Getter @Setter @NoArgsConstructor @AllArgsConstructor
public class ChatSession {
    private Long id;
    private Long userId;
    private String title;
    private LocalDateTime createdAt;
    private LocalDateTime updatedAt;
    private LocalDateTime deletedAt;
}
```

- [ ] **Step 2: 실패하는 서비스 테스트 작성**

`backend_spring/src/test/java/com/legal/backend/service/ChatSessionServiceTest.java` (신규):

```java
package com.legal.backend.service;

import com.legal.backend.dao.ChatSessionDao;
import com.legal.backend.entity.ChatSession;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.time.LocalDateTime;
import java.util.NoSuchElementException;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class ChatSessionServiceTest {

    @Mock
    private ChatSessionDao chatSessionDao;

    @InjectMocks
    private ChatSessionService chatSessionService;

    @Test
    void getOwnedSession_존재하고_내_소유면_반환한다() {
        ChatSession session = new ChatSession(1L, 7L, "제목", LocalDateTime.now(), LocalDateTime.now(), null);
        when(chatSessionDao.findById(1L)).thenReturn(session);

        ChatSession result = chatSessionService.getOwnedSession(1L, 7L);

        assertSame(session, result);
    }

    @Test
    void getOwnedSession_없으면_예외를_던진다() {
        when(chatSessionDao.findById(1L)).thenReturn(null);

        assertThrows(NoSuchElementException.class, () -> chatSessionService.getOwnedSession(1L, 7L));
    }

    @Test
    void getOwnedSession_남의_소유면_예외를_던진다() {
        ChatSession session = new ChatSession(1L, 999L, "제목", LocalDateTime.now(), LocalDateTime.now(), null);
        when(chatSessionDao.findById(1L)).thenReturn(session);

        assertThrows(NoSuchElementException.class, () -> chatSessionService.getOwnedSession(1L, 7L));
    }
}
```

- [ ] **Step 3: 테스트 실패 확인**

Run: `cd backend_spring && mvn -q test -Dtest=ChatSessionServiceTest`
Expected: FAIL — `ChatSessionDao`, `ChatSessionService`가 없어 컴파일 에러.

- [ ] **Step 4: DAO 인터페이스 작성**

`backend_spring/src/main/java/com/legal/backend/dao/ChatSessionDao.java` (신규):

```java
package com.legal.backend.dao;

import com.legal.backend.entity.ChatSession;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

import java.util.List;

@Mapper
public interface ChatSessionDao {
    List<ChatSession> findByUser(@Param("userId") Long userId);
    ChatSession findById(@Param("id") Long id);
    int insert(ChatSession session);
    int updateTitle(@Param("id") Long id, @Param("title") String title);
    int softDelete(@Param("id") Long id);
}
```

- [ ] **Step 5: MyBatis 매퍼 XML 작성**

`backend_spring/src/main/resources/mybatis/ChatSessionMapper.xml` (신규):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE mapper PUBLIC "-//mybatis.org//DTD Mapper 3.0//EN"
        "http://mybatis.org/dtd/mybatis-3-mapper.dtd">
<mapper namespace="com.legal.backend.dao.ChatSessionDao">

    <select id="findByUser" resultType="ChatSession">
        SELECT id, user_id AS userId, title, created_at AS createdAt,
               updated_at AS updatedAt, deleted_at AS deletedAt
        FROM chat_session
        WHERE user_id = #{userId} AND deleted_at IS NULL
        ORDER BY updated_at DESC
    </select>

    <select id="findById" resultType="ChatSession">
        SELECT id, user_id AS userId, title, created_at AS createdAt,
               updated_at AS updatedAt, deleted_at AS deletedAt
        FROM chat_session
        WHERE id = #{id} AND deleted_at IS NULL
    </select>

    <insert id="insert" parameterType="ChatSession" useGeneratedKeys="true" keyProperty="id">
        INSERT INTO chat_session (user_id, title)
        VALUES (#{userId}, #{title})
    </insert>

    <update id="updateTitle">
        UPDATE chat_session SET title = #{title} WHERE id = #{id}
    </update>

    <update id="softDelete">
        UPDATE chat_session SET deleted_at = NOW() WHERE id = #{id}
    </update>

</mapper>
```

- [ ] **Step 6: DTO 작성**

`backend_spring/src/main/java/com/legal/backend/dto/ChatSessionResponse.java` (신규):

```java
package com.legal.backend.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

@Getter
@AllArgsConstructor
public class ChatSessionResponse {
    private Long id;
    private String title;
    private String updatedAt;
}
```

`backend_spring/src/main/java/com/legal/backend/dto/RenameSessionRequest.java` (신규):

```java
package com.legal.backend.dto;

import lombok.Getter;
import lombok.Setter;

@Getter
@Setter
public class RenameSessionRequest {
    private String title;
}
```

- [ ] **Step 7: 서비스 작성**

`backend_spring/src/main/java/com/legal/backend/service/ChatSessionService.java` (신규):

```java
package com.legal.backend.service;

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

    public List<ChatSessionResponse> listSessions(Long userId) {
        return chatSessionDao.findByUser(userId).stream()
                .map(this::toResponse)
                .collect(Collectors.toList());
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
    }

    public void deleteSession(Long id, Long userId) {
        getOwnedSession(id, userId);
        chatSessionDao.softDelete(id);
    }

    private ChatSessionResponse toResponse(ChatSession s) {
        return new ChatSessionResponse(s.getId(), s.getTitle(), s.getUpdatedAt().format(ISO));
    }
}
```

- [ ] **Step 8: 테스트 통과 확인**

Run: `cd backend_spring && mvn -q test -Dtest=ChatSessionServiceTest`
Expected: PASS

- [ ] **Step 9: 컨트롤러 작성**

`backend_spring/src/main/java/com/legal/backend/controller/ChatSessionController.java` (신규):

```java
package com.legal.backend.controller;

import com.legal.backend.dto.ChatSessionResponse;
import com.legal.backend.dto.RenameSessionRequest;
import com.legal.backend.service.ChatSessionService;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import javax.servlet.http.HttpServletRequest;
import java.util.List;
import java.util.NoSuchElementException;

@RestController
@RequestMapping("/api/chat/sessions")
public class ChatSessionController {

    @Autowired
    private ChatSessionService chatSessionService;

    @GetMapping
    public List<ChatSessionResponse> list(HttpServletRequest req) {
        return chatSessionService.listSessions(userId(req));
    }

    @PatchMapping("/{id}")
    public ResponseEntity<?> rename(@PathVariable Long id, @RequestBody RenameSessionRequest req,
                                     HttpServletRequest httpReq) {
        String title = req.getTitle() == null ? "" : req.getTitle().trim();
        if (title.isEmpty()) return ResponseEntity.badRequest().build();
        try {
            chatSessionService.renameSession(id, userId(httpReq), title);
            return ResponseEntity.noContent().build();
        } catch (NoSuchElementException e) {
            return ResponseEntity.notFound().build();
        }
    }

    @DeleteMapping("/{id}")
    public ResponseEntity<?> delete(@PathVariable Long id, HttpServletRequest httpReq) {
        try {
            chatSessionService.deleteSession(id, userId(httpReq));
            return ResponseEntity.noContent().build();
        } catch (NoSuchElementException e) {
            return ResponseEntity.notFound().build();
        }
    }

    private Long userId(HttpServletRequest req) {
        return (Long) req.getAttribute("userId");
    }
}
```

- [ ] **Step 10: 빌드 확인**

Run: `cd backend_spring && mvn -q compile`
Expected: BUILD SUCCESS

- [ ] **Step 11: 수동 curl 검증**

앱 실행 후, 로그인해서 토큰을 받고(`POST /api/auth/login`), 세션이 아직 하나도 없으므로:

```bash
curl -s http://localhost:8181/backend_spring/api/chat/sessions -H "Authorization: Bearer $TOKEN"
```
Expected: `[]`

Task 5가 끝나기 전에는 세션을 만들 방법이 없으므로, 목록이 빈 배열로 오는 것만 이 시점에 확인한다(더 깊은 검증은 Task 5 이후).

- [ ] **Step 12: Commit**

```bash
git add backend_spring/src/main/java/com/legal/backend/entity/ChatSession.java backend_spring/src/main/java/com/legal/backend/dao/ChatSessionDao.java backend_spring/src/main/resources/mybatis/ChatSessionMapper.xml backend_spring/src/main/java/com/legal/backend/dto/ChatSessionResponse.java backend_spring/src/main/java/com/legal/backend/dto/RenameSessionRequest.java backend_spring/src/main/java/com/legal/backend/service/ChatSessionService.java backend_spring/src/main/java/com/legal/backend/controller/ChatSessionController.java backend_spring/src/test/java/com/legal/backend/service/ChatSessionServiceTest.java
git commit -m "feat: 대화 세션 목록·제목수정·삭제 API 추가"
```

---

### Task 4: 개인 메모리 열람·삭제 API

**Files:**
- Create: `backend_spring/src/main/java/com/legal/backend/entity/UserMemory.java`
- Create: `backend_spring/src/main/java/com/legal/backend/dao/UserMemoryDao.java`
- Create: `backend_spring/src/main/resources/mybatis/UserMemoryMapper.xml`
- Create: `backend_spring/src/main/java/com/legal/backend/dto/UserMemoryResponse.java`
- Create: `backend_spring/src/main/java/com/legal/backend/service/UserMemoryService.java`
- Create: `backend_spring/src/main/java/com/legal/backend/controller/UserMemoryController.java`
- Test: `backend_spring/src/test/java/com/legal/backend/service/UserMemoryServiceTest.java`

**Interfaces:**
- Consumes: Task 1의 `user_memory` 테이블(Phase 0에서는 비어 있다 — 채우는 건 Phase 2). Task 2의 `userId` 속성.
- Produces: 없음(이번 Phase에서 다른 태스크가 이 서비스를 쓰진 않는다. Phase 2에서 `insert`/`upsert`를 이 DAO에 추가한다).

이 테이블엔 아직 아무것도 안 들어간다(추출 로직은 Phase 2). 그래도 화면과 API 골격을 지금 만들어 두는 건 스펙 §12 Phase 0 체크리스트에 있는 항목이고, 나중에 Phase 2가 추출 로직만 얹으면 끝나게 하기 위해서다.

- [ ] **Step 1: 엔티티 작성**

`backend_spring/src/main/java/com/legal/backend/entity/UserMemory.java` (신규):

```java
package com.legal.backend.entity;

import lombok.*;
import java.math.BigDecimal;
import java.time.LocalDateTime;

@Getter @Setter @NoArgsConstructor @AllArgsConstructor
public class UserMemory {
    private Long id;
    private Long userId;
    private String memKey;
    private String memValue;
    private Long sourceMessageId;
    private BigDecimal confidence;
    private LocalDateTime confirmedAt;
    private LocalDateTime updatedAt;
}
```

- [ ] **Step 2: 실패하는 서비스 테스트 작성**

`backend_spring/src/test/java/com/legal/backend/service/UserMemoryServiceTest.java` (신규):

```java
package com.legal.backend.service;

import com.legal.backend.dao.UserMemoryDao;
import com.legal.backend.entity.UserMemory;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.NoSuchElementException;

import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class UserMemoryServiceTest {

    @Mock
    private UserMemoryDao userMemoryDao;

    @InjectMocks
    private UserMemoryService userMemoryService;

    @Test
    void deleteMemory_내_소유면_삭제한다() {
        UserMemory memory = new UserMemory(1L, 7L, "role_in_case", "임차인", null,
                new BigDecimal("0.80"), LocalDateTime.now(), LocalDateTime.now());
        when(userMemoryDao.findById(1L)).thenReturn(memory);

        userMemoryService.deleteMemory(1L, 7L);

        verify(userMemoryDao).delete(1L);
    }

    @Test
    void deleteMemory_남의_소유면_예외를_던지고_삭제하지_않는다() {
        UserMemory memory = new UserMemory(1L, 999L, "role_in_case", "임차인", null,
                new BigDecimal("0.80"), LocalDateTime.now(), LocalDateTime.now());
        when(userMemoryDao.findById(1L)).thenReturn(memory);

        assertThrows(NoSuchElementException.class, () -> userMemoryService.deleteMemory(1L, 7L));
        verify(userMemoryDao, never()).delete(anyLong());
    }
}
```

- [ ] **Step 3: 테스트 실패 확인**

Run: `cd backend_spring && mvn -q test -Dtest=UserMemoryServiceTest`
Expected: FAIL — `UserMemoryDao`, `UserMemoryService`가 없어 컴파일 에러.

- [ ] **Step 4: DAO 작성**

`backend_spring/src/main/java/com/legal/backend/dao/UserMemoryDao.java` (신규):

```java
package com.legal.backend.dao;

import com.legal.backend.entity.UserMemory;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

import java.util.List;

@Mapper
public interface UserMemoryDao {
    List<UserMemory> findByUser(@Param("userId") Long userId);
    UserMemory findById(@Param("id") Long id);
    int delete(@Param("id") Long id);
}
```

- [ ] **Step 5: 매퍼 XML 작성**

`backend_spring/src/main/resources/mybatis/UserMemoryMapper.xml` (신규):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE mapper PUBLIC "-//mybatis.org//DTD Mapper 3.0//EN"
        "http://mybatis.org/dtd/mybatis-3-mapper.dtd">
<mapper namespace="com.legal.backend.dao.UserMemoryDao">

    <select id="findByUser" resultType="UserMemory">
        SELECT id, user_id AS userId, mem_key AS memKey, mem_value AS memValue,
               source_message_id AS sourceMessageId, confidence,
               confirmed_at AS confirmedAt, updated_at AS updatedAt
        FROM user_memory
        WHERE user_id = #{userId}
        ORDER BY updated_at DESC
    </select>

    <select id="findById" resultType="UserMemory">
        SELECT id, user_id AS userId, mem_key AS memKey, mem_value AS memValue,
               source_message_id AS sourceMessageId, confidence,
               confirmed_at AS confirmedAt, updated_at AS updatedAt
        FROM user_memory
        WHERE id = #{id}
    </select>

    <delete id="delete">
        DELETE FROM user_memory WHERE id = #{id}
    </delete>

</mapper>
```

- [ ] **Step 6: DTO 작성**

`backend_spring/src/main/java/com/legal/backend/dto/UserMemoryResponse.java` (신규):

```java
package com.legal.backend.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

@Getter
@AllArgsConstructor
public class UserMemoryResponse {
    private Long id;
    private String memKey;
    private String memValue;
    private String confirmedAt;
}
```

- [ ] **Step 7: 서비스 작성**

`backend_spring/src/main/java/com/legal/backend/service/UserMemoryService.java` (신규):

```java
package com.legal.backend.service;

import com.legal.backend.dao.UserMemoryDao;
import com.legal.backend.dto.UserMemoryResponse;
import com.legal.backend.entity.UserMemory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;

import java.time.format.DateTimeFormatter;
import java.util.List;
import java.util.NoSuchElementException;
import java.util.stream.Collectors;

@Service
public class UserMemoryService {

    private static final DateTimeFormatter ISO = DateTimeFormatter.ISO_LOCAL_DATE_TIME;

    @Autowired
    private UserMemoryDao userMemoryDao;

    public List<UserMemoryResponse> listMemory(Long userId) {
        return userMemoryDao.findByUser(userId).stream()
                .map(this::toResponse)
                .collect(Collectors.toList());
    }

    public void deleteMemory(Long id, Long userId) {
        UserMemory memory = userMemoryDao.findById(id);
        if (memory == null || !memory.getUserId().equals(userId)) {
            throw new NoSuchElementException("메모리를 찾을 수 없습니다: " + id);
        }
        userMemoryDao.delete(id);
    }

    private UserMemoryResponse toResponse(UserMemory m) {
        return new UserMemoryResponse(m.getId(), m.getMemKey(), m.getMemValue(), m.getConfirmedAt().format(ISO));
    }
}
```

- [ ] **Step 8: 테스트 통과 확인**

Run: `cd backend_spring && mvn -q test -Dtest=UserMemoryServiceTest`
Expected: PASS

- [ ] **Step 9: 컨트롤러 작성**

`backend_spring/src/main/java/com/legal/backend/controller/UserMemoryController.java` (신규):

```java
package com.legal.backend.controller;

import com.legal.backend.dto.UserMemoryResponse;
import com.legal.backend.service.UserMemoryService;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import javax.servlet.http.HttpServletRequest;
import java.util.List;
import java.util.NoSuchElementException;

@RestController
@RequestMapping("/api/chat/memory")
public class UserMemoryController {

    @Autowired
    private UserMemoryService userMemoryService;

    @GetMapping
    public List<UserMemoryResponse> list(HttpServletRequest req) {
        return userMemoryService.listMemory((Long) req.getAttribute("userId"));
    }

    @DeleteMapping("/{id}")
    public ResponseEntity<?> delete(@PathVariable Long id, HttpServletRequest req) {
        try {
            userMemoryService.deleteMemory(id, (Long) req.getAttribute("userId"));
            return ResponseEntity.noContent().build();
        } catch (NoSuchElementException e) {
            return ResponseEntity.notFound().build();
        }
    }
}
```

- [ ] **Step 10: 수동 curl 검증**

```bash
curl -s http://localhost:8181/backend_spring/api/chat/memory -H "Authorization: Bearer $TOKEN"
```
Expected: `[]` (Phase 2 전까지는 항상 빈 배열)

- [ ] **Step 11: Commit**

```bash
git add backend_spring/src/main/java/com/legal/backend/entity/UserMemory.java backend_spring/src/main/java/com/legal/backend/dao/UserMemoryDao.java backend_spring/src/main/resources/mybatis/UserMemoryMapper.xml backend_spring/src/main/java/com/legal/backend/dto/UserMemoryResponse.java backend_spring/src/main/java/com/legal/backend/service/UserMemoryService.java backend_spring/src/main/java/com/legal/backend/controller/UserMemoryController.java backend_spring/src/test/java/com/legal/backend/service/UserMemoryServiceTest.java
git commit -m "feat: 개인 메모리 열람·삭제 API 골격 추가"
```

---

### Task 5: 메시지 저장·조회 + `POST /api/chat` 세션 연동

**Files:**
- Create: `backend_spring/src/main/java/com/legal/backend/entity/ChatMessage.java`
- Create: `backend_spring/src/main/java/com/legal/backend/dao/ChatMessageDao.java`
- Create: `backend_spring/src/main/resources/mybatis/ChatMessageMapper.xml`
- Create: `backend_spring/src/main/java/com/legal/backend/dto/ChatMessageResponse.java`
- Modify: `backend_spring/src/main/java/com/legal/backend/dto/ChatRequest.java`
- Modify: `backend_spring/src/main/java/com/legal/backend/dto/ChatResponse.java`
- Modify: `backend_spring/src/main/java/com/legal/backend/service/ChatService.java`
- Modify: `backend_spring/src/main/java/com/legal/backend/controller/ChatController.java`
- Modify: `backend_spring/src/main/java/com/legal/backend/controller/ChatSessionController.java`
- Test: `backend_spring/src/test/java/com/legal/backend/service/ChatServiceTest.java`

**Interfaces:**
- Consumes: Task 3의 `ChatSessionDao`, `ChatSessionService.getOwnedSession`. Task 1의 `chat_message` 테이블.
- Produces: `ChatService.buildTitle(String question)`(static) — Phase 1의 요약 로직이 세션 제목 규칙을 그대로 재사용할 수 있게 public static으로 둔다.

- [ ] **Step 1: 엔티티 작성**

`backend_spring/src/main/java/com/legal/backend/entity/ChatMessage.java` (신규):

```java
package com.legal.backend.entity;

import lombok.*;
import java.time.LocalDateTime;

@Getter @Setter @NoArgsConstructor @AllArgsConstructor
public class ChatMessage {
    private Long id;
    private Long sessionId;
    private String role;             // "user" | "assistant"
    private String content;
    private String standaloneQuery;  // Phase 1부터 값이 채워짐. Phase 0에서는 항상 null
    private String sourcesJson;
    private LocalDateTime createdAt;
}
```

- [ ] **Step 2: 실패하는 서비스 테스트 작성**

`backend_spring/src/test/java/com/legal/backend/service/ChatServiceTest.java` (신규) — `resolveSession`과 `buildTitle`만 단위 테스트한다. WebClient 호출과 실제 DB 저장은 Step 12의 수동 검증으로 확인한다:

```java
package com.legal.backend.service;

import com.legal.backend.dao.ChatMessageDao;
import com.legal.backend.dao.ChatSessionDao;
import com.legal.backend.entity.ChatSession;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class ChatServiceTest {

    @Mock
    private ChatSessionDao chatSessionDao;
    @Mock
    private ChatMessageDao chatMessageDao;

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
}
```

- [ ] **Step 3: 테스트 실패 확인**

Run: `cd backend_spring && mvn -q test -Dtest=ChatServiceTest`
Expected: FAIL — `resolveSession`, `buildTitle`이 아직 없어 컴파일 에러.

- [ ] **Step 4: DAO 작성**

`backend_spring/src/main/java/com/legal/backend/dao/ChatMessageDao.java` (신규):

```java
package com.legal.backend.dao;

import com.legal.backend.entity.ChatMessage;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

import java.util.List;

@Mapper
public interface ChatMessageDao {
    List<ChatMessage> findBySession(@Param("sessionId") Long sessionId);
    int insert(ChatMessage message);
}
```

- [ ] **Step 5: 매퍼 XML 작성**

`backend_spring/src/main/resources/mybatis/ChatMessageMapper.xml` (신규). 정렬은 `id ASC` 기준이다 — `created_at`은 초 단위 정밀도라 같은 트랜잭션에서 저장되는 user/assistant 두 행이 같은 값을 가질 수 있어 시간만으로는 순서를 보장 못 한다:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE mapper PUBLIC "-//mybatis.org//DTD Mapper 3.0//EN"
        "http://mybatis.org/dtd/mybatis-3-mapper.dtd">
<mapper namespace="com.legal.backend.dao.ChatMessageDao">

    <select id="findBySession" resultType="ChatMessage">
        SELECT id, session_id AS sessionId, role, content,
               standalone_query AS standaloneQuery, sources_json AS sourcesJson,
               created_at AS createdAt
        FROM chat_message
        WHERE session_id = #{sessionId}
        ORDER BY id ASC
    </select>

    <insert id="insert" parameterType="ChatMessage" useGeneratedKeys="true" keyProperty="id">
        INSERT INTO chat_message (session_id, role, content, standalone_query, sources_json)
        VALUES (#{sessionId}, #{role}, #{content}, #{standaloneQuery}, #{sourcesJson})
    </insert>

</mapper>
```

- [ ] **Step 6: 메시지 응답 DTO 작성**

`backend_spring/src/main/java/com/legal/backend/dto/ChatMessageResponse.java` (신규). 참고 문서(sources)는 v1에서 이력 재로드 화면에는 노출하지 않는다 — 매 턴 응답에는 이미 담겨 오지만, 지난 대화를 다시 열었을 때까지 보여주는 건 YAGNI로 보류:

```java
package com.legal.backend.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

@Getter
@AllArgsConstructor
public class ChatMessageResponse {
    private Long id;
    private String role;
    private String content;
    private String createdAt;
}
```

- [ ] **Step 7: ChatRequest/ChatResponse 수정**

`backend_spring/src/main/java/com/legal/backend/dto/ChatRequest.java` 전체 교체:

```java
package com.legal.backend.dto;

import lombok.*;

@Getter @Setter
public class ChatRequest {
    private String question;
    private String lawCategory;
    private Long sessionId;   // null = 새 세션
}
```

`ChatResponse.java`에 필드 2개 추가(클래스 상단, `answer` 필드 위나 아래 어디든):

```java
    private Long sessionId;
    private String sessionTitle;
```

- [ ] **Step 8: ChatService 수정**

`backend_spring/src/main/java/com/legal/backend/service/ChatService.java` 전체 교체:

```java
package com.legal.backend.service;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.legal.backend.dao.ChatMessageDao;
import com.legal.backend.dao.ChatSessionDao;
import com.legal.backend.dto.ChatRequest;
import com.legal.backend.dto.ChatResponse;
import com.legal.backend.entity.ChatMessage;
import com.legal.backend.entity.ChatSession;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;
import org.springframework.web.reactive.function.client.WebClient;

import java.util.HashMap;
import java.util.Map;

@Service
public class ChatService {

    private static final Logger log = LoggerFactory.getLogger(ChatService.class);
    private static final int TITLE_MAX_LEN = 20;
    private static final ObjectMapper OBJECT_MAPPER = new ObjectMapper();

    @Autowired
    private WebClient webClient;
    @Autowired
    private ChatSessionDao chatSessionDao;
    @Autowired
    private ChatMessageDao chatMessageDao;

    public ChatResponse chat(ChatRequest req, Long userId, int age) {
        ChatSession session = resolveSession(req.getSessionId(), userId, req.getQuestion());

        Map<String, Object> body = new HashMap<>();
        body.put("question", req.getQuestion());
        body.put("age", age);
        body.put("law_category", req.getLawCategory());

        ChatResponse response = webClient.post()
                .uri("/api/v1/chat")
                .bodyValue(body)
                .retrieve()
                .bodyToMono(ChatResponse.class)
                .block();

        persistTurn(session.getId(), req.getQuestion(), response);

        response.setSessionId(session.getId());
        response.setSessionTitle(session.getTitle());
        return response;
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

    private void persistTurn(Long sessionId, String question, ChatResponse response) {
        ChatMessage userMsg = new ChatMessage();
        userMsg.setSessionId(sessionId);
        userMsg.setRole("user");
        userMsg.setContent(question);
        chatMessageDao.insert(userMsg);

        ChatMessage botMsg = new ChatMessage();
        botMsg.setSessionId(sessionId);
        botMsg.setRole("assistant");
        botMsg.setContent(response.getAnswer());
        botMsg.setSourcesJson(toJsonOrNull(response.getSources()));
        chatMessageDao.insert(botMsg);
    }

    private String toJsonOrNull(Object value) {
        try {
            return OBJECT_MAPPER.writeValueAsString(value);
        } catch (JsonProcessingException e) {
            log.warn("sources JSON 직렬화 실패 — sources_json을 null로 저장", e);
            return null;
        }
    }
}
```

`resolveSession`과 `buildTitle`을 패키지 전용(default) 접근자로 둔 건 테스트가 같은 패키지(`com.legal.backend.service`)에 있어서다 — Lombok 없이 그대로 컴파일된다.

- [ ] **Step 9: 테스트 통과 확인**

Run: `cd backend_spring && mvn -q test -Dtest=ChatServiceTest`
Expected: PASS

- [ ] **Step 10: ChatController 수정**

`backend_spring/src/main/java/com/legal/backend/controller/ChatController.java:20-32`를 교체:

```java
    @PostMapping
    public ResponseEntity<ChatResponse> chat(
            @RequestBody ChatRequest req,
            HttpServletRequest httpReq) {
        try {
            Long userId = (Long) httpReq.getAttribute("userId");
            int age      = (int)  httpReq.getAttribute("age");
            ChatResponse response = chatService.chat(req, userId, age);
            return ResponseEntity.ok(response);
        } catch (Exception e) {
            return ResponseEntity.internalServerError().build();
        }
    }
```

- [ ] **Step 11: ChatSessionController에 메시지 조회 엔드포인트 추가**

`ChatSessionController.java`에 의존성과 메서드 추가:

```java
    @Autowired
    private ChatMessageDao chatMessageDao;   // import com.legal.backend.dao.ChatMessageDao; 추가

    @GetMapping("/{id}/messages")
    public ResponseEntity<?> messages(@PathVariable Long id, HttpServletRequest httpReq) {
        try {
            chatSessionService.getOwnedSession(id, userId(httpReq));   // 소유권 검사, 없으면 예외
        } catch (NoSuchElementException e) {
            return ResponseEntity.notFound().build();
        }
        List<ChatMessageResponse> messages = chatMessageDao.findBySession(id).stream()
                .map(m -> new ChatMessageResponse(
                        m.getId(), m.getRole(), m.getContent(),
                        m.getCreatedAt().format(java.time.format.DateTimeFormatter.ISO_LOCAL_DATE_TIME)))
                .collect(java.util.stream.Collectors.toList());
        return ResponseEntity.ok(messages);
    }
```

(`import com.legal.backend.dto.ChatMessageResponse;`도 파일 상단에 추가.)

- [ ] **Step 12: 빌드 + 전체 테스트**

Run: `cd backend_spring && mvn -q test`
Expected: PASS 전체

- [ ] **Step 13: 수동 curl 검증**

FastAPI(`ai/`)와 MySQL이 로컬에 떠 있어야 한다(`docker-compose up -d mysql opensearch ollama` 등 기존 실행 방식 그대로).

```bash
# 새 대화로 질문 (sessionId 없음)
curl -s http://localhost:8181/backend_spring/api/chat \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"question":"가압류가 뭔가요?","lawCategory":null,"sessionId":null}'
# 응답에 sessionId, sessionTitle 이 채워져 있어야 함 — 그 값을 $SID 에 저장

# 같은 세션에 후속 질문
curl -s http://localhost:8181/backend_spring/api/chat \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"question\":\"그럼 신청은 어떻게 하나요?\",\"lawCategory\":null,\"sessionId\":$SID}"

# 목록에 방금 만든 세션이 보여야 함
curl -s http://localhost:8181/backend_spring/api/chat/sessions -H "Authorization: Bearer $TOKEN"

# 세션의 메시지 4개(질문2+답변2)가 순서대로 보여야 함
curl -s http://localhost:8181/backend_spring/api/chat/sessions/$SID/messages -H "Authorization: Bearer $TOKEN"
```

MySQL에서 직접 확인:
```sql
SELECT id, session_id, role, LEFT(content, 30), created_at FROM chat_message ORDER BY id;
SELECT id, title, updated_at FROM chat_session;
```

Expected: `chat_session` 1행, `chat_message` 4행(질문 2 + 답변 2), 두 번째 curl이 첫 번째와 같은 `session_id`로 저장됨.

- [ ] **Step 14: Commit**

```bash
git add backend_spring/src/main/java/com/legal/backend/entity/ChatMessage.java backend_spring/src/main/java/com/legal/backend/dao/ChatMessageDao.java backend_spring/src/main/resources/mybatis/ChatMessageMapper.xml backend_spring/src/main/java/com/legal/backend/dto/ChatMessageResponse.java backend_spring/src/main/java/com/legal/backend/dto/ChatRequest.java backend_spring/src/main/java/com/legal/backend/dto/ChatResponse.java backend_spring/src/main/java/com/legal/backend/service/ChatService.java backend_spring/src/main/java/com/legal/backend/controller/ChatController.java backend_spring/src/main/java/com/legal/backend/controller/ChatSessionController.java backend_spring/src/test/java/com/legal/backend/service/ChatServiceTest.java
git commit -m "feat: 대화 턴을 세션에 저장하고 sessionId로 이어가기"
```

---

### Task 6: `@Async` 실행기 골격

**Files:**
- Create: `backend_spring/src/main/java/com/legal/backend/config/AsyncConfig.java`
- Test: `backend_spring/src/test/java/com/legal/backend/config/AsyncConfigTest.java`

**Interfaces:**
- Produces: `chatMemoryExecutor` 빈(이름으로 참조), `AsyncConfig.getAsyncUncaughtExceptionHandler()`. Phase 1의 `ChatMemoryAsyncService`가 `@Async("chatMemoryExecutor")`로 이 실행기를 쓴다. 이번 Phase 0에서는 **아무도 이 실행기를 실제로 쓰지 않는다** — 골격만 준비한다.

- [ ] **Step 1: 실패하는 테스트 작성**

`backend_spring/src/test/java/com/legal/backend/config/AsyncConfigTest.java` (신규). Spring 컨텍스트를 띄우지 않고(DB 연결이 필요 없게) 클래스를 직접 인스턴스화해서 순수 단위로 검증한다:

```java
package com.legal.backend.config;

import org.junit.jupiter.api.Test;
import org.springframework.scheduling.concurrent.ThreadPoolTaskExecutor;

import java.lang.reflect.Method;
import java.util.concurrent.Executor;

import static org.junit.jupiter.api.Assertions.*;

class AsyncConfigTest {

    private final AsyncConfig asyncConfig = new AsyncConfig();

    @Test
    void chatMemoryExecutor는_경계가_있는_스레드풀이다() {
        Executor executor = asyncConfig.chatMemoryExecutor();

        assertInstanceOf(ThreadPoolTaskExecutor.class, executor);
        ThreadPoolTaskExecutor pool = (ThreadPoolTaskExecutor) executor;
        assertEquals(2, pool.getCorePoolSize());
        assertEquals(4, pool.getMaxPoolSize());
    }

    @Test
    void 예외_핸들러는_예외를_삼키기만_하고_다시_던지지_않는다() throws Exception {
        Method dummyMethod = Object.class.getMethod("toString");

        assertDoesNotThrow(() ->
                asyncConfig.getAsyncUncaughtExceptionHandler()
                        .handleUncaughtException(new RuntimeException("테스트 예외"), dummyMethod));
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd backend_spring && mvn -q test -Dtest=AsyncConfigTest`
Expected: FAIL — `AsyncConfig`가 없어 컴파일 에러.

- [ ] **Step 3: AsyncConfig 작성**

`backend_spring/src/main/java/com/legal/backend/config/AsyncConfig.java` (신규):

```java
package com.legal.backend.config;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.aop.interceptor.AsyncUncaughtExceptionHandler;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.scheduling.annotation.AsyncConfigurer;
import org.springframework.scheduling.annotation.EnableAsync;
import org.springframework.scheduling.concurrent.ThreadPoolTaskExecutor;

import java.lang.reflect.Method;
import java.util.concurrent.Executor;

/**
 * 요약·메모리 추출처럼 응답을 막지 않아야 하는 작업 전용 실행기.
 * 기본 SimpleAsyncTaskExecutor(호출마다 무제한 스레드 생성)를 쓰지 않기 위해 직접 구성한다.
 * Phase 0에서는 아무도 이 빈을 쓰지 않는다 — Phase 1의 ChatMemoryAsyncService가 사용한다.
 */
@Configuration
@EnableAsync
public class AsyncConfig implements AsyncConfigurer {

    private static final Logger log = LoggerFactory.getLogger(AsyncConfig.class);

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
    public Executor getAsyncExecutor() {
        return chatMemoryExecutor();
    }

    @Override
    public AsyncUncaughtExceptionHandler getAsyncUncaughtExceptionHandler() {
        return this::handleUncaught;
    }

    private void handleUncaught(Throwable ex, Method method, Object... params) {
        // Phase 1에서 ChatAsyncJobDao로 chat_async_job 테이블에도 기록한다.
        log.error("비동기 작업 실패: {} — {}", method.getName(), ex.getMessage(), ex);
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd backend_spring && mvn -q test -Dtest=AsyncConfigTest`
Expected: PASS

- [ ] **Step 5: 전체 빌드 + 테스트**

Run: `cd backend_spring && mvn -q test`
Expected: PASS 전체 (`@Configuration`+`@EnableAsync` 클래스가 `com.legal.backend.config` 패키지에 있어 `root-context.xml`의 component-scan에 자동으로 걸린다 — XML 수정 불필요. 앱을 실제로 띄워서 정상 기동하는지도 Step 6에서 확인한다.)

- [ ] **Step 6: 앱 기동 확인**

Run: `cd backend_spring && mvn tomcat7:run` (몇 초 후 Ctrl+C로 중단해도 됨)
Expected: 에러 없이 기동. `@EnableAsync`가 CGLIB 프록시를 만들 때 문제가 있으면 여기서 기동 시점에 예외가 난다.

- [ ] **Step 7: Commit**

```bash
git add backend_spring/src/main/java/com/legal/backend/config/AsyncConfig.java backend_spring/src/test/java/com/legal/backend/config/AsyncConfigTest.java
git commit -m "feat: 대화 메모리용 @Async 실행기 골격 추가"
```

---

### Task 7: 프론트엔드 — 대화 목록 사이드바 + 새 대화

**Files:**
- Modify: `frontend/public/chat.html`

**Interfaces:**
- Consumes: Task 3의 `GET /api/chat/sessions`, `GET /api/chat/sessions/{id}/messages`. Task 5의 `POST /api/chat` 응답 `sessionId`/`sessionTitle`.

이 저장소엔 프론트 테스트 프레임워크가 전혀 없다(순수 정적 HTML + jQuery, 빌드 스텝도 없음) — 지금 있는 기능들(로그인, 문서 원문 모달)도 전부 수동 브라우저 검증으로만 확인돼 있다. 이 태스크도 같은 방식으로 검증한다.

- [ ] **Step 1: 사이드바에 대화 목록 마크업 추가**

`frontend/public/chat.html:498-499`(`<div class="sidebar">` 바로 다음, `예시 질문` 타이틀 앞)에 삽입:

```html
            <div class="sidebar-title">대화</div>
            <button class="example-btn" id="newChatBtn" style="font-weight:600;">
                <span class="example-icon">➕</span>
                <span>새 대화</span>
            </button>
            <div id="sessionList"></div>

            <div class="sidebar-divider"></div>

```

(이 블록이 기존 `<div class="sidebar-title">예시 질문</div>` 바로 앞에 들어간다 — 예시 질문 섹션은 그대로 둔다.)

- [ ] **Step 2: 세션 목록 아이템 스타일 추가**

`frontend/public/chat.html`의 `<style>` 블록(475번째 줄 `.input-hint` 규칙) 다음에 추가:

```css
        .session-item {
            display: flex;
            align-items: center;
            gap: 8px;
            width: 100%;
            padding: 10px 12px;
            margin-bottom: 4px;
            border: none;
            background: transparent;
            border-radius: 8px;
            font-size: 13px;
            text-align: left;
            cursor: pointer;
            color: #374151;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
        }
        .session-item:hover { background: #f3f4f6; }
        .session-item.active { background: #e0e7ff; color: #4338ca; font-weight: 600; }
```

- [ ] **Step 3: JS — 세션 목록 로드·선택·새 대화**

`frontend/public/chat.html:564-576`(`<script>` 시작부, `$('#logoutBtn').click(...)` 다음)에 삽입:

```javascript
        let currentSessionId = null;

        function renderSessionList(sessions) {
            const html = sessions.map(s => `
                <button type="button" class="session-item ${s.id === currentSessionId ? 'active' : ''}"
                        data-session-id="${s.id}">${s.title}</button>
            `).join('');
            $('#sessionList').html(html);
        }

        function loadSessions() {
            $.ajax({
                url: '/api/chat/sessions',
                type: 'GET',
                headers: { 'Authorization': 'Bearer ' + token },
                success: renderSessionList,
                error: function (err) {
                    if (err.status === 401) { localStorage.clear(); window.location.href = '/'; }
                }
            });
        }

        function openSession(sessionId) {
            currentSessionId = sessionId;
            $('#welcome').hide();
            $('#msgGroup').empty();

            $.ajax({
                url: '/api/chat/sessions/' + sessionId + '/messages',
                type: 'GET',
                headers: { 'Authorization': 'Bearer ' + token },
                success: function (messages) {
                    messages.forEach(m => {
                        if (m.role === 'user') addUserMsg(m.content);
                        else addBotMsg(m.content, [], null);
                    });
                    loadSessions();   // active 표시 갱신
                }
            });
        }

        function startNewChat() {
            currentSessionId = null;
            $('#msgGroup').empty();
            $('#welcome').show();
            loadSessions();   // active 표시 해제
        }

        $('#newChatBtn').click(startNewChat);

        $('#sessionList').on('click', '.session-item', function () {
            openSession($(this).data('session-id'));
        });

        loadSessions();
```

- [ ] **Step 4: `sendMessage()`가 sessionId를 보내고 응답을 반영하도록 수정**

`frontend/public/chat.html:667-684`의 `$.ajax` 호출을 교체:

```javascript
            $.ajax({
                url: '/api/chat',
                type: 'POST',
                contentType: 'application/json',
                headers: { 'Authorization': 'Bearer ' + token },
                data: JSON.stringify({ question, lawCategory: null, sessionId: currentSessionId }),
                success: function (res) {
                    $('#loadingRow').remove();
                    addBotMsg(res.answer, res.sources, res.age);
                    $('#sendBtn').prop('disabled', false);
                    if (res.sessionId !== currentSessionId) {
                        currentSessionId = res.sessionId;
                    }
                    loadSessions();
                },
                error: function (err) {
                    $('#loadingRow').remove();
                    if (err.status === 401) { localStorage.clear(); window.location.href = '/'; }
                    else addBotMsg('오류가 발생했습니다. 다시 시도해주세요.');
                    $('#sendBtn').prop('disabled', false);
                }
            });
```

- [ ] **Step 5: 수동 브라우저 검증**

브라우저로 로그인 후 `chat.html` 접속:

1. 좌측 사이드바 상단에 "새 대화" 버튼과(처음엔 비어 있는) 대화 목록 영역이 보이는지 확인.
2. 질문을 하나 보낸다 — 답변이 오고 나면 사이드바에 그 질문 앞부분으로 된 대화 항목이 하나 생기고 강조(active) 표시되는지 확인.
3. 후속 질문을 하나 더 보낸다 — 같은 대화 항목 안에서 이어지는지(새 항목이 안 생기는지) 확인.
4. "새 대화"를 누른다 — 메시지 영역이 비워지고, 이전 대화 항목의 강조가 풀리는지 확인.
5. 이전 대화 항목을 클릭한다 — 아까 나눈 질문·답변이 순서대로 다시 로드되는지 확인.
6. 새로고침(F5) 후에도 사이드바에 대화 목록이 남아있는지 확인(서버 저장 확인).

Expected: 위 6가지가 전부 관찰대로 동작.

- [ ] **Step 6: Commit**

```bash
git add frontend/public/chat.html
git commit -m "feat: 대화 목록 사이드바와 새 대화 기능 추가"
```

---

## Self-Review 결과

- **스펙 커버리지**: §4(JWT)→Task 2, §5.1(Flyway)→Task 1, §5.2(DDL)→Task 1, §7.1(세션 API)→Task 3, §7.1(메모리 API)→Task 4, §7.2(POST /chat 변경)→Task 5, §7.4(@Async 골격)→Task 6, §9(프론트)→Task 7. §7.4의 `ChatMemoryAsyncService`, §8 전체(FastAPI), §10 표의 D5(재작성 안전장치)는 이 계획에 포함하지 않음 — Phase 1 계획에서 다룬다. 의도적 범위 제한이며 스펙 §12 로드맵과 일치.
- **자리표시자 스캔**: "TODO"/"추후 구현" 없음. 모든 코드 블록이 실제 동작 코드.
- **타입 일관성 확인**: `ChatSession`/`ChatMessage`/`UserMemory` 필드명이 엔티티→매퍼 resultMap 별칭→서비스→DTO까지 동일하게 유지됨. `ChatService.resolveSession`/`buildTitle`이 Task 5 테스트가 기대하는 시그니처(패키지 전용 접근자)와 일치.
- **Phase 1로 넘기는 것**: `ChatMemoryAsyncService`, `/summary/update`·`/memory/extract` FastAPI 엔드포인트, 재작성 게이트·이중 채널 검색, 프롬프트 하드 캡, `chat_async_job`에 실제로 쓰는 로직(테이블은 이미 Task 1에서 생성됨).
