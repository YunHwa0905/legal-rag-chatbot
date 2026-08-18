package com.legal.backend.controller;

import com.legal.backend.dto.DocumentDetail;
import com.legal.backend.service.DocumentService;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.reactive.function.client.WebClientResponseException;

@RestController
@RequestMapping("/api/documents")
public class DocumentController {

    @Autowired
    private DocumentService documentService;

    // 참고 문서 클릭 시 원문 조회 (성인/중장년 나이대 프론트에서만 호출)
    @GetMapping("/{docId}")
    public ResponseEntity<DocumentDetail> getDocument(@PathVariable int docId) {
        try {
            return ResponseEntity.ok(documentService.getDocument(docId));
        } catch (WebClientResponseException.NotFound e) {
            return ResponseEntity.notFound().build();
        } catch (Exception e) {
            return ResponseEntity.internalServerError().build();
        }
    }
}
