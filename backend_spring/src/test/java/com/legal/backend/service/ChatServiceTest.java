package com.legal.backend.service;

import com.legal.backend.dao.ChatMessageDao;
import com.legal.backend.dao.ChatSessionDao;
import com.legal.backend.dao.ChatSessionSummaryDao;
import com.legal.backend.dto.ChatRequest;
import com.legal.backend.dto.ChatResponse;
import com.legal.backend.entity.ChatMessage;
import com.legal.backend.entity.ChatSession;
import com.legal.backend.entity.ChatSessionSummary;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Answers;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.web.reactive.function.client.WebClient;

import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class ChatServiceTest {

    @Mock
    private ChatSessionDao chatSessionDao;
    @Mock
    private ChatMessageDao chatMessageDao;
    @Mock
    private ChatSessionSummaryDao chatSessionSummaryDao;
    @Mock
    private ChatMessagePersistenceService chatMessagePersistenceService;
    @Mock
    private ChatMemoryAsyncService chatMemoryAsyncService;
    @Mock(answer = Answers.RETURNS_DEEP_STUBS)
    private WebClient webClient;

    @InjectMocks
    private ChatService chatService;

    @Test
    void resolveSession_sessionId가_null이면_새_세션을_만든다() {
        ChatSession created = chatService.resolveSession(null, 7L, "가압류가 뭔가요?");

        ArgumentCaptor<ChatSession> captor = ArgumentCaptor.forClass(ChatSession.class);
        verify(chatSessionDao).insert(captor.capture());
        assertEquals(7L, captor.getValue().getUserId());
        assertEquals("가압류가 뭔가요?", captor.getValue().getTitle());
    }

    @Test
    void resolveSession_남의_세션이면_새_세션으로_대체한다() {
        ChatSession others = new ChatSession(5L, 999L, "다른 사람 대화", null, null, null);
        when(chatSessionDao.findById(5L)).thenReturn(others);

        chatService.resolveSession(5L, 7L, "질문");

        verify(chatSessionDao).insert(any(ChatSession.class));
    }

    @Test
    void resolveSession_내_세션이면_그대로_반환한다() {
        ChatSession mine = new ChatSession(5L, 7L, "내 대화", null, null, null);
        when(chatSessionDao.findById(5L)).thenReturn(mine);

        ChatSession result = chatService.resolveSession(5L, 7L, "질문");

        assertEquals(mine, result);
        verify(chatSessionDao, never()).insert(any());
    }

    @Test
    void buildTitle_긴_질문은_20자로_잘라_말줄임표를_붙인다() {
        String longQuestion = "이 질문은 스무 글자를 훌쩍 넘는 아주 긴 법률 질문입니다";
        String title = ChatService.buildTitle(longQuestion);

        assertEquals(20, title.length() - 1);          // "…" 제외 20자
        assertEquals('…', title.charAt(title.length() - 1));
    }

    @Test
    void buildTitle_짧은_질문은_그대로_쓴다() {
        assertEquals("짧은 질문", ChatService.buildTitle("짧은 질문"));
    }

    @Test
    void chat_FastAPI_응답이_비어있으면_대화턴을_저장하지_않는다() {
        // WebClient의 post().uri().bodyValue().retrieve().bodyToMono(...).block() 체인이
        // 2xx이지만 빈 바디를 돌려주는 상황을 재현 — .block()이 예외 없이 null을 반환한다.
        when(webClient.post()
                .uri(anyString())
                .bodyValue(any())
                .retrieve()
                .bodyToMono(ChatResponse.class)
                .block())
                .thenReturn(null);

        ChatRequest req = new ChatRequest();
        req.setQuestion("질문");
        req.setSessionId(5L);

        assertThrows(IllegalStateException.class, () -> chatService.chat(req, 7L, 20));

        // 응답이 비어있으면 세션 생성·턴 저장이 일어나지 않아야 한다 (Finding 1: 순서 재배치).
        // findById는 이력 조회를 위해 호출될 수 있다(findOwnedSession) — 그건 읽기 전용이라 무해하다.
        verify(chatSessionDao, never()).insert(any());
        verify(chatMessagePersistenceService, never()).persistTurn(any(), any(), any());
        verify(chatMemoryAsyncService, never()).updateSummaryIfNeeded(any());
    }

    @Test
    void chat_기존_세션이면_이력과_요약을_로드하고_응답_후_요약갱신을_트리거한다() {
        ChatSession mine = new ChatSession(5L, 7L, "내 대화", null, null, null);
        when(chatSessionDao.findById(5L)).thenReturn(mine);

        ChatMessage userMsg = new ChatMessage(1L, 5L, "user", "이전 질문", null, null, null);
        ChatMessage botMsg = new ChatMessage(2L, 5L, "assistant", "이전 답변", null, null, null);
        when(chatMessageDao.findRecentMessages(5L, 4)).thenReturn(List.of(userMsg, botMsg));

        ChatSessionSummary summary = new ChatSessionSummary(5L, "요약본", 2L, null);
        when(chatSessionSummaryDao.find(5L)).thenReturn(summary);

        ChatResponse fastApiResponse = new ChatResponse();
        fastApiResponse.setAnswer("답변");
        when(webClient.post()
                .uri(anyString())
                .bodyValue(any())
                .retrieve()
                .bodyToMono(ChatResponse.class)
                .block())
                .thenReturn(fastApiResponse);

        ChatRequest req = new ChatRequest();
        req.setQuestion("그럼 어떻게 되나요?");
        req.setSessionId(5L);

        ChatResponse result = chatService.chat(req, 7L, 30);

        assertEquals(5L, result.getSessionId());
        verify(chatMessageDao).findRecentMessages(5L, 4);
        verify(chatSessionSummaryDao).find(5L);
        verify(chatMessagePersistenceService).persistTurn(5L, "그럼 어떻게 되나요?", fastApiResponse);
        verify(chatSessionDao).touch(5L);
        verify(chatMemoryAsyncService).updateSummaryIfNeeded(5L);
    }

    @Test
    void chat_새_세션이면_이력_조회_없이_빈_이력으로_진행한다() {
        ChatResponse fastApiResponse = new ChatResponse();
        fastApiResponse.setAnswer("답변");
        when(webClient.post()
                .uri(anyString())
                .bodyValue(any())
                .retrieve()
                .bodyToMono(ChatResponse.class)
                .block())
                .thenReturn(fastApiResponse);

        ChatRequest req = new ChatRequest();
        req.setQuestion("가압류가 뭔가요?");
        req.setSessionId(null);

        chatService.chat(req, 7L, 30);

        verify(chatMessageDao, never()).findRecentMessages(any(), anyInt());
        verify(chatSessionSummaryDao, never()).find(any());
        verify(chatSessionDao).insert(any());
        verify(chatMemoryAsyncService).updateSummaryIfNeeded(any());
    }
}
