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
