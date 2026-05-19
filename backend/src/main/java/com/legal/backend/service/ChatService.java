package com.legal.backend.service;

import com.legal.backend.client.FastApiClient;
import com.legal.backend.dto.ChatRequest;
import com.legal.backend.dto.ChatResponse;
import com.legal.backend.repository.UserRepository;
import com.legal.backend.security.JwtUtil;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;

@Service
@RequiredArgsConstructor
public class ChatService {

	private final FastApiClient fastApiClient;
	private final JwtUtil jwtUtil;
	private final UserRepository userRepository;

	public ChatResponse chat(String token, ChatRequest request) {
		// JWT 토큰에서 나이 추출
		int age = jwtUtil.getAge(token);

		// FastAPI 호출
		return fastApiClient.chat(request.getQuestion(), age, request.getLawCategory());
	}
}