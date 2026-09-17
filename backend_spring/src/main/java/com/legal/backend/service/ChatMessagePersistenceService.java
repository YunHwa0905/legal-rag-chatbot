package com.legal.backend.service;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.legal.backend.dao.ChatMessageDao;
import com.legal.backend.dto.ChatResponse;
import com.legal.backend.entity.ChatMessage;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * user/assistant 두 행을 한 턴으로 저장한다. ChatService가 아니라 별도 빈으로 둔 이유는
 * @Transactional이 프록시 기반이라 같은 빈 안에서의 self-invocation(this.persistTurn(...))에는
 * 적용되지 않기 때문 — AsyncConfig의 @Async를 별도 빈(ChatMemoryAsyncService)으로 둔 것과 동일한 이유.
 */
@Service
public class ChatMessagePersistenceService {

    private static final Logger log = LoggerFactory.getLogger(ChatMessagePersistenceService.class);
    private static final ObjectMapper OBJECT_MAPPER = new ObjectMapper();

    @Autowired
    private ChatMessageDao chatMessageDao;

    @Transactional
    public void persistTurn(Long sessionId, String question, ChatResponse response) {
        ChatMessage userMsg = new ChatMessage();
        userMsg.setSessionId(sessionId);
        userMsg.setRole("user");
        userMsg.setContent(question);
        chatMessageDao.insert(userMsg);

        ChatMessage botMsg = new ChatMessage();
        botMsg.setSessionId(sessionId);
        botMsg.setRole("assistant");
        botMsg.setContent(response.getAnswer());
        botMsg.setStandaloneQuery(response.getStandaloneQuery());
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
