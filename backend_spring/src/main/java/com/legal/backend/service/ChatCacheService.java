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
