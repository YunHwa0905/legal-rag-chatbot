package com.legal.backend.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

@Getter
@AllArgsConstructor
public class ChatSessionResponse {
    private Long id;
    private String title;
    private String updatedAt;
}
