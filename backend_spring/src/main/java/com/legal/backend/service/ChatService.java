package com.legal.backend.service;

import com.legal.backend.dto.ChatRequest;
import com.legal.backend.dto.ChatResponse;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;
import org.springframework.web.reactive.function.client.WebClient;

import java.util.HashMap;
import java.util.Map;

@Service
public class ChatService {

    @Autowired
    private WebClient webClient;

    public ChatResponse chat(ChatRequest req, String username, int age) {
        Map<String, Object> body = new HashMap<>();
        body.put("question", req.getQuestion());
        body.put("age", age);
        body.put("law_category", req.getLawCategory());

        /*
         * WebClient 가 Jackson 을 사용해 응답을 ChatResponse 로 역직렬화합니다.
         * ChatResponse 의 @JsonProperty 가 snake_case → camelCase 변환을 담당합니다.
         */
        return webClient.post()
                .uri("/api/v1/chat")
                .bodyValue(body)
                .retrieve()
                .bodyToMono(ChatResponse.class)
                .block();
    }
}