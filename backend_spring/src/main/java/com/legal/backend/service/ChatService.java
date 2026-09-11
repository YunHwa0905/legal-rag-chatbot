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

        if (response == null) {
            throw new IllegalStateException("FastAPI 응답이 비어 있습니다.");
        }

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
