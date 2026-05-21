package com.legal.backend.controller;

import com.legal.backend.dto.ChatRequest;
import com.legal.backend.dto.ChatResponse;
import com.legal.backend.service.ChatService;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import javax.servlet.http.HttpServletRequest;

@RestController
@RequestMapping("/api/chat")
public class ChatController {

    @Autowired
    private ChatService chatService;

    @PostMapping
    public ResponseEntity<ChatResponse> chat(
            @RequestBody ChatRequest req,
            HttpServletRequest httpReq) {
        try {
            String username = (String) httpReq.getAttribute("username");
            int age          = (int)    httpReq.getAttribute("age");
            ChatResponse response = chatService.chat(req, username, age);
            return ResponseEntity.ok(response);
        } catch (Exception e) {
            // 에러 로깅은 logback 이 담당
            return ResponseEntity.internalServerError().build();
        }
    }
}