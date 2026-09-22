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
 * 순수 읽기 캐시(cache-aside). 원본은 항상 DB이고, 여기 모든 메서드는
 * Redis 호출을 try/catch로 감싼다 — Redis가 죽어도 예외가 호출자로
 * 전파되지 않는다(조회는 loader로 폴백, 쓰기/삭제는 그냥 무시하고 로그만
 * 남긴다 — 다음 조회가 어차피 DB를 다시 읽어 캐시를 채운다).
 *
 * ★ 2026-09 현재 Redis는 꺼져 있다(root-context.xml의 빈 3개를 주석 처리).
 *   CSP 이관에서 옮겨야 할 미들웨어를 줄이는 게 목적이고, 원래도 없어도
 *   되는 캐시라 기능에는 영향이 없다 — 전부 캐시 미스가 될 뿐이다.
 *
 *   그래서 템플릿 주입을 required = false 로 바꾸고 null 가드를 뒀다.
 *   빈만 주석 처리하면 주입 실패로 애플리케이션이 아예 뜨지 않는다.
 *   다시 켤 때는 빈 주석을 풀기만 하면 이 클래스는 그대로 동작한다.
 */
@Service
public class ChatCacheService {

    private static final Logger log = LoggerFactory.getLogger(ChatCacheService.class);
    private static final ObjectMapper OBJECT_MAPPER = new ObjectMapper();
    private static final Duration TTL = Duration.ofMinutes(5);

    // required = false — 빈이 없으면 null 이 들어오고, 아래 가드가 캐시를 건너뛴다.
    @Autowired(required = false)
    private StringRedisTemplate redis;

    private boolean disabled() {
        return redis == null;
    }

    public <T> T getOrLoad(String key, TypeReference<T> type, Supplier<T> loader) {
        if (disabled()) {
            return loader.get();
        }
        T cached = tryGet(key, type);
        if (cached != null) {
            return cached;
        }
        T fresh = loader.get();
        trySet(key, fresh);
        return fresh;
    }

    public void invalidate(String key) {
        if (disabled()) {
            return;
        }
        try {
            redis.delete(key);
        } catch (Exception e) {
            // e.getMessage()가 아니라 e.toString()을 남긴다 — 클래스명이 로그에 그대로
            // 보여야 "Redis 장애"와 "역직렬화 버그"를 구분할 수 있다(Task 2의 Critical이
            // InvalidDefinitionException을 이 catch-all이 그냥 "Redis 조회 실패"로 뭉뚱그려
            // 놓쳤던 바로 그 문제 — 최종 리뷰 M2).
            log.warn("Redis 무효화 실패(무시 — TTL {}분 뒤 자연 정리): key={}, {}", TTL.toMinutes(), key, e.toString());
        }
    }

    private <T> T tryGet(String key, TypeReference<T> type) {
        try {
            String json = redis.opsForValue().get(key);
            return json != null ? OBJECT_MAPPER.readValue(json, type) : null;
        } catch (Exception e) {
            log.warn("Redis 조회 실패 — DB로 폴백: key={}, {}", key, e.toString());
            return null;
        }
    }

    private void trySet(String key, Object value) {
        try {
            redis.opsForValue().set(key, OBJECT_MAPPER.writeValueAsString(value), TTL);
        } catch (Exception e) {
            log.warn("Redis 쓰기 실패(무시 — 다음 조회가 DB를 다시 채움): key={}, {}", key, e.toString());
        }
    }

    public static String sessionsKey(Long userId) {
        return "chat:sessions:" + userId;
    }

    public static String ctxKey(Long sessionId) {
        return "chat:ctx:" + sessionId;
    }
}
