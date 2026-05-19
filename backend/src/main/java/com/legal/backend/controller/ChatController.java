package com.legal.backend.controller;

import com.legal.backend.dto.ChatRequest;
import com.legal.backend.dto.ChatResponse;
import com.legal.backend.service.ChatService;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/chat")
@RequiredArgsConstructor
public class ChatController {

	private final ChatService chatService;

	// ===========================
	// 법률 QA 채팅
	// POST /api/chat
	// Header: Authorization: Bearer {token}
	// ===========================
	@PostMapping
	public ResponseEntity<?> chat(@RequestHeader("Authorization") String authHeader, @RequestBody ChatRequest request) {
		try {
			// Bearer 토큰 추출
			String token = authHeader.substring(7);
			ChatResponse response = chatService.chat(token, request);
			return ResponseEntity.ok(response);
		} catch (Exception e) {
			return ResponseEntity.badRequest().body(e.getMessage());
		}
	}
}