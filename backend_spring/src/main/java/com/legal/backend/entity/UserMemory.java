package com.legal.backend.entity;

import lombok.*;
import java.math.BigDecimal;
import java.time.LocalDateTime;

@Getter @Setter @NoArgsConstructor @AllArgsConstructor
public class UserMemory {
    private Long id;
    private Long userId;
    private String memKey;
    private String memValue;
    private Long sourceMessageId;
    private BigDecimal confidence;
    private LocalDateTime confirmedAt;
    private LocalDateTime updatedAt;
}
