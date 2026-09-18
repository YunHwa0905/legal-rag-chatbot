package com.legal.backend.service;

import com.legal.backend.dao.ChatSessionDao;
import com.legal.backend.entity.ChatSession;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.time.LocalDateTime;
import java.util.NoSuchElementException;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class ChatSessionServiceTest {

    @Mock
    private ChatSessionDao chatSessionDao;
    @Mock
    private ChatCacheService chatCacheService;

    @InjectMocks
    private ChatSessionService chatSessionService;

    @Test
    void getOwnedSession_존재하고_내_소유면_반환한다() {
        ChatSession session = new ChatSession(1L, 7L, "제목", LocalDateTime.now(), LocalDateTime.now(), null);
        when(chatSessionDao.findById(1L)).thenReturn(session);

        ChatSession result = chatSessionService.getOwnedSession(1L, 7L);

        assertSame(session, result);
    }

    @Test
    void getOwnedSession_없으면_예외를_던진다() {
        when(chatSessionDao.findById(1L)).thenReturn(null);

        assertThrows(NoSuchElementException.class, () -> chatSessionService.getOwnedSession(1L, 7L));
    }

    @Test
    void getOwnedSession_남의_소유면_예외를_던진다() {
        ChatSession session = new ChatSession(1L, 999L, "제목", LocalDateTime.now(), LocalDateTime.now(), null);
        when(chatSessionDao.findById(1L)).thenReturn(session);

        assertThrows(NoSuchElementException.class, () -> chatSessionService.getOwnedSession(1L, 7L));
    }

    @Test
    void renameSession_성공하면_세션_목록_캐시를_무효화한다() {
        ChatSession session = new ChatSession(1L, 7L, "제목", LocalDateTime.now(), LocalDateTime.now(), null);
        when(chatSessionDao.findById(1L)).thenReturn(session);

        chatSessionService.renameSession(1L, 7L, "새 제목");

        verify(chatSessionDao).updateTitle(1L, "새 제목");
        verify(chatCacheService).invalidate(ChatCacheService.sessionsKey(7L));
    }

    @Test
    void deleteSession_성공하면_세션_목록과_대화_컨텍스트_캐시를_모두_무효화한다() {
        ChatSession session = new ChatSession(1L, 7L, "제목", LocalDateTime.now(), LocalDateTime.now(), null);
        when(chatSessionDao.findById(1L)).thenReturn(session);

        chatSessionService.deleteSession(1L, 7L);

        verify(chatSessionDao).softDelete(1L);
        verify(chatCacheService).invalidate(ChatCacheService.sessionsKey(7L));
        verify(chatCacheService).invalidate(ChatCacheService.ctxKey(1L));
    }
}
