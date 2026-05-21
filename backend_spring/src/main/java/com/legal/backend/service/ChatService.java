package com.legal.backend.service;

import com.legal.backend.dto.ChatRequest;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;
import org.springframework.web.reactive.function.client.WebClient;
import java.util.*;

@Service
public class ChatService {
    @Autowired private WebClient webClient;

    public Map<String, Object> chat(ChatRequest req, String username, int age) {
        Map<String, Object> body = new HashMap<>();
        body.put("question", req.getQuestion());
        body.put("age", age);
        body.put("law_category", req.getLawCategory());
        return webClient.post().uri("/api/v1/chat").bodyValue(body)
                .retrieve().bodyToMono(Map.class).block();
    }
}