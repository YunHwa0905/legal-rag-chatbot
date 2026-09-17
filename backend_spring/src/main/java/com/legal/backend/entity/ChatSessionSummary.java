package com.legal.backend.entity;

import lombok.*;
import java.time.LocalDateTime;

@Getter @Setter @NoArgsConstructor @AllArgsConstructor
public class ChatSessionSummary {
    private Long sessionId;
    private String summary;
    private Long throughMessageId;
    private LocalDateTime updatedAt;
}
