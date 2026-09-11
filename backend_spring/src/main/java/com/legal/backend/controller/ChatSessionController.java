package com.legal.backend.controller;

import com.legal.backend.dao.ChatMessageDao;
import com.legal.backend.dto.ChatMessageResponse;
import com.legal.backend.dto.ChatSessionResponse;
import com.legal.backend.dto.RenameSessionRequest;
import com.legal.backend.service.ChatSessionService;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import javax.servlet.http.HttpServletRequest;
import java.util.List;
import java.util.NoSuchElementException;

@RestController
@RequestMapping("/api/chat/sessions")
public class ChatSessionController {

    @Autowired
    private ChatSessionService chatSessionService;
    @Autowired
    private ChatMessageDao chatMessageDao;

    @GetMapping
    public List<ChatSessionResponse> list(HttpServletRequest req) {
        return chatSessionService.listSessions(userId(req));
    }

    @GetMapping("/{id}/messages")
    public ResponseEntity<?> messages(@PathVariable Long id, HttpServletRequest httpReq) {
        try {
            chatSessionService.getOwnedSession(id, userId(httpReq));   // 소유권 검사, 없으면 예외
        } catch (NoSuchElementException e) {
            return ResponseEntity.notFound().build();
        }
        List<ChatMessageResponse> messages = chatMessageDao.findBySession(id).stream()
                .map(m -> new ChatMessageResponse(
                        m.getId(), m.getRole(), m.getContent(),
                        m.getCreatedAt().format(java.time.format.DateTimeFormatter.ISO_LOCAL_DATE_TIME)))
                .collect(java.util.stream.Collectors.toList());
        return ResponseEntity.ok(messages);
    }

    @PatchMapping("/{id}")
    public ResponseEntity<?> rename(@PathVariable Long id, @RequestBody RenameSessionRequest req,
                                     HttpServletRequest httpReq) {
        String title = req.getTitle() == null ? "" : req.getTitle().trim();
        if (title.isEmpty()) return ResponseEntity.badRequest().build();
        try {
            chatSessionService.renameSession(id, userId(httpReq), title);
            return ResponseEntity.noContent().build();
        } catch (NoSuchElementException e) {
            return ResponseEntity.notFound().build();
        }
    }

    @DeleteMapping("/{id}")
    public ResponseEntity<?> delete(@PathVariable Long id, HttpServletRequest httpReq) {
        try {
            chatSessionService.deleteSession(id, userId(httpReq));
            return ResponseEntity.noContent().build();
        } catch (NoSuchElementException e) {
            return ResponseEntity.notFound().build();
        }
    }

    private Long userId(HttpServletRequest req) {
        return (Long) req.getAttribute("userId");
    }
}
