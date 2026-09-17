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
        // 현재는 로그만 남긴다 — chat_async_job 테이블(스키마엔 있음)에 기록하는 건
        // 아직 구현되지 않았다. Phase 1은 이 실행기에 처음으로 실제 트래픽(요약 갱신)을
        // 태우는 릴리스라 관측 가능성이 로그 한 줄뿐이라는 점을 명확히 남겨둔다.
        log.error("비동기 작업 실패: {} — {}", method.getName(), ex.getMessage(), ex);
    }
}
