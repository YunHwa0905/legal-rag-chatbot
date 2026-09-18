package com.legal.backend.service;

import com.legal.backend.dao.ChatMessageDao;
import com.legal.backend.dao.ChatSessionSummaryDao;
import com.legal.backend.entity.ChatMessage;
import com.legal.backend.entity.ChatSessionSummary;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Answers;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.web.reactive.function.client.WebClient;

import java.time.Duration;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class ChatMemoryAsyncServiceTest {

    @Mock
    private ChatMessageDao chatMessageDao;
    @Mock
    private ChatSessionSummaryDao chatSessionSummaryDao;
    @Mock(answer = Answers.RETURNS_DEEP_STUBS)
    private WebClient webClient;
    @Mock
    private ChatCacheService chatCacheService;

    @InjectMocks
    private ChatMemoryAsyncService chatMemoryAsyncService;

    @Test
    void updateSummaryIfNeeded_미접힌_턴이_2턴_이하면_아무것도_안한다() {
        when(chatSessionSummaryDao.find(5L)).thenReturn(null);
        // 2턴(4메시지) 이하 — 트리거 안 됨
        when(chatMessageDao.findAfterMessageId(5L, 0L)).thenReturn(List.of(
                msg(1L), msg(2L), msg(3L), msg(4L)
        ));

        chatMemoryAsyncService.updateSummaryIfNeeded(5L);

        verify(chatSessionSummaryDao, never()).upsertIfNewer(any(), any(), any());
        verifyNoInteractions(webClient);
    }

    @Test
    void updateSummaryIfNeeded_미접힌_턴이_2턴_초과면_FastAPI를_호출하고_upsert한다() {
        when(chatSessionSummaryDao.find(5L)).thenReturn(null);
        // 3턴(6메시지) — 트리거 됨
        List<ChatMessage> unfolded = List.of(
                msg(1L), msg(2L), msg(3L), msg(4L), msg(5L), msg(6L)
        );
        when(chatMessageDao.findAfterMessageId(5L, 0L)).thenReturn(unfolded);

        when(webClient.post()
                .uri(anyString())
                .bodyValue(any())
                .retrieve()
                .bodyToMono(Map.class)
                .block(any(Duration.class)))
                .thenReturn(Map.of("summary", "새 요약", "through_message_id", 6));

        chatMemoryAsyncService.updateSummaryIfNeeded(5L);

        verify(chatSessionSummaryDao).upsertIfNewer(5L, "새 요약", 6L);
        verify(chatCacheService).invalidate(ChatCacheService.ctxKey(5L));
    }

    @Test
    void updateSummaryIfNeeded_FastAPI_응답이_비어있으면_예외를_던진다() {
        when(chatSessionSummaryDao.find(5L)).thenReturn(null);
        List<ChatMessage> unfolded = List.of(
                msg(1L), msg(2L), msg(3L), msg(4L), msg(5L), msg(6L)
        );
        when(chatMessageDao.findAfterMessageId(5L, 0L)).thenReturn(unfolded);

        when(webClient.post()
                .uri(anyString())
                .bodyValue(any())
                .retrieve()
                .bodyToMono(Map.class)
                .block(any(Duration.class)))
                .thenReturn(null);

        assertThrows(IllegalStateException.class,
                () -> chatMemoryAsyncService.updateSummaryIfNeeded(5L));

        verify(chatSessionSummaryDao, never()).upsertIfNewer(any(), any(), any());
    }

    @Test
    void updateSummaryIfNeeded_기존_요약이_있으면_그_이후_구간만_조회한다() {
        ChatSessionSummary existing = new ChatSessionSummary(5L, "기존 요약", 10L, null);
        when(chatSessionSummaryDao.find(5L)).thenReturn(existing);
        when(chatMessageDao.findAfterMessageId(5L, 10L)).thenReturn(List.of());

        chatMemoryAsyncService.updateSummaryIfNeeded(5L);

        verify(chatMessageDao).findAfterMessageId(5L, 10L);
        verifyNoInteractions(webClient);
    }

    private ChatMessage msg(Long id) {
        ChatMessage m = new ChatMessage();
        m.setId(id);
        m.setSessionId(5L);
        m.setRole(id % 2 == 1 ? "user" : "assistant");
        m.setContent("메시지 " + id);
        return m;
    }
}
