package com.legal.backend.entity;

import lombok.*;
import java.time.LocalDateTime;

@Getter @Setter @NoArgsConstructor @AllArgsConstructor
public class ChatMessage {
    private Long id;
    private Long sessionId;
    private String role;             // "user" | "assistant"
    private String content;
    private String standaloneQuery;  // Phase 1부터 값이 채워짐. Phase 0에서는 항상 null
    private String sourcesJson;
    private LocalDateTime createdAt;
}
