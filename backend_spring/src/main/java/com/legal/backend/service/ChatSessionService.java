package com.legal.backend.service;

import com.fasterxml.jackson.core.type.TypeReference;
import com.legal.backend.dao.ChatSessionDao;
import com.legal.backend.dto.ChatSessionResponse;
import com.legal.backend.entity.ChatSession;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;

import java.time.format.DateTimeFormatter;
import java.util.List;
import java.util.NoSuchElementException;
import java.util.stream.Collectors;

@Service
public class ChatSessionService {

    private static final DateTimeFormatter ISO = DateTimeFormatter.ISO_LOCAL_DATE_TIME;

    @Autowired
    private ChatSessionDao chatSessionDao;
    @Autowired
    private ChatCacheService chatCacheService;

    public List<ChatSessionResponse> listSessions(Long userId) {
        return chatCacheService.getOrLoad(
                ChatCacheService.sessionsKey(userId),
                new TypeReference<List<ChatSessionResponse>>() {},
                () -> chatSessionDao.findByUser(userId).stream()
                        .map(this::toResponse)
                        .collect(Collectors.toList())
        );
    }

    /** 소유자가 아니거나 존재하지 않는 세션이면 예외 — 컨트롤러에서 404로 변환한다. */
    public ChatSession getOwnedSession(Long id, Long userId) {
        ChatSession session = chatSessionDao.findById(id);
        if (session == null || !session.getUserId().equals(userId)) {
            throw new NoSuchElementException("세션을 찾을 수 없습니다: " + id);
        }
        return session;
    }

    public void renameSession(Long id, Long userId, String newTitle) {
        getOwnedSession(id, userId);
        chatSessionDao.updateTitle(id, newTitle);
        chatCacheService.invalidate(ChatCacheService.sessionsKey(userId));
    }

    public void deleteSession(Long id, Long userId) {
        getOwnedSession(id, userId);
        chatSessionDao.softDelete(id);
        chatCacheService.invalidate(ChatCacheService.sessionsKey(userId));
        // 삭제된 세션의 대화 내용(이력+요약)이 캐시에 최대 5분간 남아있지 않게 함께 비운다.
        // findById가 deleted_at을 걸러 어차피 재조회는 안 되지만(정확성 문제는 아님),
        // 법률 상담 내용을 삭제 요청 후에도 캐시에 남겨둘 이유가 없다.
        chatCacheService.invalidate(ChatCacheService.ctxKey(id));
    }

    private ChatSessionResponse toResponse(ChatSession s) {
        return new ChatSessionResponse(s.getId(), s.getTitle(), s.getUpdatedAt().format(ISO));
    }
}
