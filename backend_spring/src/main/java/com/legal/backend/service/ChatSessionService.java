package com.legal.backend.service;

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

    public List<ChatSessionResponse> listSessions(Long userId) {
        return chatSessionDao.findByUser(userId).stream()
                .map(this::toResponse)
                .collect(Collectors.toList());
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
    }

    public void deleteSession(Long id, Long userId) {
        getOwnedSession(id, userId);
        chatSessionDao.softDelete(id);
    }

    private ChatSessionResponse toResponse(ChatSession s) {
        return new ChatSessionResponse(s.getId(), s.getTitle(), s.getUpdatedAt().format(ISO));
    }
}
