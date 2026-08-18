package com.legal.backend.service;

import com.legal.backend.dto.DocumentDetail;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;
import org.springframework.web.reactive.function.client.WebClient;

@Service
public class DocumentService {

    @Autowired
    private WebClient webClient;

    public DocumentDetail getDocument(int docId) {
        return webClient.get()
                .uri("/api/v1/documents/{docId}", docId)
                .retrieve()
                .bodyToMono(DocumentDetail.class)
                .block();
    }
}
