package com.legal.backend.service;

import com.legal.backend.dao.ChatMessageDao;
import com.legal.backend.dao.ChatSessionSummaryDao;
import com.legal.backend.entity.ChatMessage;
import com.legal.backend.entity.ChatSessionSummary;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.scheduling.annotation.Async;
import org.springframework.stereotype.Service;
import org.springframework.web.reactive.function.client.WebClient;

import java.time.Duration;
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

    // chatMemoryExecutor는 core=2/max=4/queue=50 — FastAPI 호출에 타임아웃이 없으면
    // 응답 없는 FastAPI/Ollama 하나가 이 풀의 스레드를 무기한 붙잡아 큐가 꽉 차고,
    // 다음 updateSummaryIfNeeded(...) 호출이 호출자(ChatService, 요청 스레드)에서
    // RejectedExecutionException으로 즉시 터진다 — 이미 턴이 저장된 뒤라 사용자에게는
    // "성공했는데 실패로 보이는" 응답이 나간다. 이 타임아웃이 그 시나리오를 막는다.
    private static final Duration FASTAPI_CALL_TIMEOUT = Duration.ofSeconds(60);

    @Autowired
    private WebClient webClient;
    @Autowired
    private ChatMessageDao chatMessageDao;
    @Autowired
    private ChatSessionSummaryDao chatSessionSummaryDao;
    @Autowired
    private ChatCacheService chatCacheService;

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
                .block(FASTAPI_CALL_TIMEOUT);

        if (result == null) {
            throw new IllegalStateException("요약 갱신: FastAPI 응답이 비어 있습니다. sessionId=" + sessionId);
        }

        String newSummary = (String) result.get("summary");
        chatSessionSummaryDao.upsertIfNewer(sessionId, newSummary, newThroughId);
        chatCacheService.invalidate(ChatCacheService.ctxKey(sessionId));
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
