package com.legal.backend.service;

import com.legal.backend.dao.ChatMessageDao;
import com.legal.backend.dto.ChatResponse;
import com.legal.backend.entity.ChatMessage;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;

@ExtendWith(MockitoExtension.class)
class ChatMessagePersistenceServiceTest {

    @Mock
    private ChatMessageDao chatMessageDao;

    @InjectMocks
    private ChatMessagePersistenceService chatMessagePersistenceService;

    @Test
    void persistTurn_사용자_메시지와_어시스턴트_메시지를_이_순서로_저장한다() {
        ChatResponse response = new ChatResponse();
        response.setAnswer("가압류는 금전채권 보전을 위한 절차입니다.");
        response.setSources(List.of(new ChatResponse.SourceDocument()));

        chatMessagePersistenceService.persistTurn(5L, "가압류가 뭔가요?", response);

        ArgumentCaptor<ChatMessage> captor = ArgumentCaptor.forClass(ChatMessage.class);
        verify(chatMessageDao, times(2)).insert(captor.capture());

        ChatMessage userMsg = captor.getAllValues().get(0);
        assertEquals(5L, userMsg.getSessionId());
        assertEquals("user", userMsg.getRole());
        assertEquals("가압류가 뭔가요?", userMsg.getContent());

        ChatMessage botMsg = captor.getAllValues().get(1);
        assertEquals(5L, botMsg.getSessionId());
        assertEquals("assistant", botMsg.getRole());
        assertEquals("가압류는 금전채권 보전을 위한 절차입니다.", botMsg.getContent());
        assertTrue(botMsg.getSourcesJson().contains("doc_id"));
    }

    @Test
    void persistTurn_sources가_비어있으면_sourcesJson이_빈_배열_문자열이다() {
        ChatResponse response = new ChatResponse();
        response.setAnswer("답변");
        response.setSources(List.of());

        chatMessagePersistenceService.persistTurn(5L, "질문", response);

        ArgumentCaptor<ChatMessage> captor = ArgumentCaptor.forClass(ChatMessage.class);
        verify(chatMessageDao, times(2)).insert(captor.capture());
        assertEquals("[]", captor.getAllValues().get(1).getSourcesJson());
        assertNull(captor.getAllValues().get(0).getSourcesJson());
    }
}
