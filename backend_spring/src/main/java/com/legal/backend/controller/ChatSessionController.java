package com.legal.backend.controller;

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

    @GetMapping
    public List<ChatSessionResponse> list(HttpServletRequest req) {
        return chatSessionService.listSessions(userId(req));
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
