package com.legal.backend.controller;

import com.legal.backend.dto.ChatRequest;
import com.legal.backend.service.ChatService;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import javax.servlet.http.HttpServletRequest;
import java.util.Map;

@RestController
@RequestMapping("/api/chat")
public class ChatController {
    @Autowired private ChatService chatService;

    @PostMapping
    public ResponseEntity<?> chat(@RequestBody ChatRequest req, HttpServletRequest httpReq) {
        try {
            String username = (String) httpReq.getAttribute("username");
            int age = (int) httpReq.getAttribute("age");
            return ResponseEntity.ok(chatService.chat(req, username, age));
        } catch (Exception e) {
            return ResponseEntity.internalServerError().body("오류: " + e.getMessage());
        }
    }
}