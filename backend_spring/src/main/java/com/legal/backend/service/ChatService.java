package com.legal.backend.service;

import com.legal.backend.dao.ChatMessageDao;
import com.legal.backend.dao.ChatSessionDao;
import com.legal.backend.dao.ChatSessionSummaryDao;
import com.legal.backend.dto.ChatRequest;
import com.legal.backend.dto.ChatResponse;
import com.legal.backend.entity.ChatMessage;
import com.legal.backend.entity.ChatSession;
import com.legal.backend.entity.ChatSessionSummary;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;
import org.springframework.web.reactive.function.client.WebClient;

import java.time.Duration;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

@Service
public class ChatService {

    private static final Logger log = LoggerFactory.getLogger(ChatService.class);

    private static final int TITLE_MAX_LEN = 20;
    // 최근 2턴(user+assistant 페어) = 메시지 4개. 스펙 §3의 HISTORY_WINDOW_TURNS=2.
    private static final int HISTORY_WINDOW_MESSAGES = 4;

    // N4: 응답 없는 FastAPI/Ollama 하나가 요청 스레드를 무기한 붙잡는 걸 막는다.
    // Caddy read_timeout(300s)보다 넉넉히 짧게 잡아, 정상적인 느린 생성(장문 답변)은
    // 통과시키되 진짜로 멈춘 연결은 여기서 먼저 끊는다.
    private static final Duration FASTAPI_CALL_TIMEOUT = Duration.ofSeconds(180);

    @Autowired
    private WebClient webClient;
    @Autowired
    private ChatSessionDao chatSessionDao;
    @Autowired
    private ChatMessageDao chatMessageDao;
    @Autowired
    private ChatSessionSummaryDao chatSessionSummaryDao;
    @Autowired
    private ChatMessagePersistenceService chatMessagePersistenceService;
    @Autowired
    private ChatMemoryAsyncService chatMemoryAsyncService;

    public ChatResponse chat(ChatRequest req, Long userId, int age) {
        // FastAPI 호출 전: 이미 존재하는 내 세션이면 이력·요약을 실어 보낸다.
        // (세션을 새로 만들지는 않는다 — 그건 FastAPI 성공 후 resolveSession의 몫.
        //  Finding 1: 응답 실패 시 세션이 생기면 안 된다는 불변조건을 유지하기 위함)
        ChatSession existing = findOwnedSession(req.getSessionId(), userId);

        Map<String, Object> body = new HashMap<>();
        body.put("question", req.getQuestion());
        body.put("age", age);
        body.put("law_category", req.getLawCategory());
        body.put("history", existing != null ? historyPayload(existing.getId()) : List.of());
        body.put("summary", existing != null ? summaryText(existing.getId()) : null);

        ChatResponse response = webClient.post()
                .uri("/api/v1/chat")
                .bodyValue(body)
                .retrieve()
                .bodyToMono(ChatResponse.class)
                .block(FASTAPI_CALL_TIMEOUT);

        if (response == null) {
            throw new IllegalStateException("FastAPI 응답이 비어 있습니다.");
        }

        ChatSession session = resolveSession(req.getSessionId(), userId, req.getQuestion());
        chatMessagePersistenceService.persistTurn(session.getId(), req.getQuestion(), response);
        chatSessionDao.touch(session.getId());
        triggerSummaryUpdate(session.getId());

        response.setSessionId(session.getId());
        response.setSessionTitle(session.getTitle());
        return response;
    }

    /**
     * 이 시점에 턴은 이미 저장·commit돼 있다. 큐가 꽉 차 chatMemoryExecutor가
     * RejectedExecutionException을 던지더라도(코어 2/최대 4/큐 50 — FastAPI가 느려지면
     * 스레드가 오래 묶여 채워질 수 있다) 사용자에게는 정상 응답을 돌려준다 — 이미 성공한
     * 턴을 요약 갱신 실패로 되돌릴 이유가 없다. 놓친 요약 갱신은 다음 트리거에서
     * findAfterMessageId가 안 접힌 턴을 그대로 다시 잡아내 자연히 따라잡는다.
     */
    private void triggerSummaryUpdate(Long sessionId) {
        try {
            chatMemoryAsyncService.updateSummaryIfNeeded(sessionId);
        } catch (RuntimeException e) {
            log.warn("요약 갱신 트리거 실패(턴은 이미 저장됨, 다음 트리거에서 재시도됨): sessionId={}", sessionId, e);
        }
    }

    /** sessionId가 없거나, 있어도 내 것이 아니면 null — 새로 만들지는 않는다(읽기 전용 조회). */
    private ChatSession findOwnedSession(Long sessionId, Long userId) {
        if (sessionId == null) {
            return null;
        }
        ChatSession existing = chatSessionDao.findById(sessionId);
        return (existing != null && existing.getUserId().equals(userId)) ? existing : null;
    }

    private List<Map<String, String>> historyPayload(Long sessionId) {
        List<ChatMessage> recent = chatMessageDao.findRecentMessages(sessionId, HISTORY_WINDOW_MESSAGES);
        List<Map<String, String>> payload = new ArrayList<>();
        for (ChatMessage m : recent) {
            Map<String, String> turn = new HashMap<>();
            turn.put("role", m.getRole());
            turn.put("content", m.getContent());
            payload.add(turn);
        }
        return payload;
    }

    private String summaryText(Long sessionId) {
        ChatSessionSummary summary = chatSessionSummaryDao.find(sessionId);
        return summary != null ? summary.getSummary() : null;
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
}
