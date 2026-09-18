package com.legal.backend.service;

import com.fasterxml.jackson.core.type.TypeReference;
import com.legal.backend.dto.ChatSessionResponse;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
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

    @Test
    void getOrLoad_실제_DTO를_캐시에_쓰고_다시_읽으면_역직렬화가_정상_동작한다() {
        when(redis.opsForValue()).thenReturn(valueOps);
        // 캐시 미스로 시작 → loader가 실행되고 결과가 캐시에 쓰임
        when(valueOps.get("dto-key")).thenReturn(null);
        ChatSessionResponse original = new ChatSessionResponse(1L, "제목", "2026-09-18T00:00:00");

        // set()이 실제로 호출한 JSON 문자열을 캡처해서, 다음 호출에서 그 JSON을 다시 읽어보는 식으로
        // "쓴 걸 그대로 다시 읽으면 역직렬화가 되는지"를 실제로 검증한다 (단순히 loader가 반환한
        // 객체를 그대로 비교하는 것만으로는 이 버그를 못 잡는다 — 캐시 미스 경로는 역직렬화를
        // 안 타기 때문. 반드시 "쓰고 → 그 JSON으로 다시 읽기"를 둘 다 exercise해야 한다).
        ArgumentCaptor<String> jsonCaptor = ArgumentCaptor.forClass(String.class);

        ChatSessionResponse fromMiss = chatCacheService.getOrLoad(
                "dto-key", new TypeReference<ChatSessionResponse>() {}, () -> original);
        assertEquals(original.getId(), fromMiss.getId());

        verify(valueOps).set(eq("dto-key"), jsonCaptor.capture(), any());
        String storedJson = jsonCaptor.getValue();

        // 이제 그 저장된 JSON이 실제로 다시 읽힐 때 캐시 히트로 정상 역직렬화되는지 확인
        when(valueOps.get("dto-key")).thenReturn(storedJson);
        ChatSessionResponse fromHit = chatCacheService.getOrLoad(
                "dto-key", new TypeReference<ChatSessionResponse>() {}, () -> {
                    throw new AssertionError("캐시 히트인데 loader가 호출됨");
                });

        assertEquals(original.getId(), fromHit.getId());
        assertEquals(original.getTitle(), fromHit.getTitle());
        assertEquals(original.getUpdatedAt(), fromHit.getUpdatedAt());
    }
}
