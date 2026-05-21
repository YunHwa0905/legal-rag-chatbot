package com.legal.backend.client;

import com.legal.backend.dto.ChatResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;
import org.springframework.web.reactive.function.client.WebClient;

import java.util.Map;

@Component
@RequiredArgsConstructor
public class FastApiClient {

	@Value("${fastapi.url}")
	private String fastapiUrl;

	private final WebClient.Builder webClientBuilder;

	public ChatResponse chat(String question, int age, String lawCategory) {
		WebClient webClient = webClientBuilder.baseUrl(fastapiUrl).build();

		Map<String, Object> requestBody = Map.of("question", question, "age", age, "law_category",
				lawCategory != null ? lawCategory : "");

		return webClient.post().uri("/api/v1/chat").bodyValue(requestBody).retrieve().bodyToMono(ChatResponse.class)
				.block();
	}
}