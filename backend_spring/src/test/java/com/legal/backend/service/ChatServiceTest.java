package com.legal.backend.service;

import com.legal.backend.dao.ChatMessageDao;
import com.legal.backend.dao.ChatSessionDao;
import com.legal.backend.dto.ChatRequest;
import com.legal.backend.dto.ChatResponse;
import com.legal.backend.entity.ChatSession;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Answers;
import org.mockito.ArgumentCaptor;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.web.reactive.function.client.WebClient;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class ChatServiceTest {

    @Mock
    private ChatSessionDao chatSessionDao;
    @Mock
    private ChatMessageDao chatMessageDao;
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
        ChatSession mine = new ChatSession(5L, 7L, "내 대화", null, null, null);
        when(chatSessionDao.findById(5L)).thenReturn(mine);

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

        verify(chatMessageDao, never()).insert(any());
    }
}
