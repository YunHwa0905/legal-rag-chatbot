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
