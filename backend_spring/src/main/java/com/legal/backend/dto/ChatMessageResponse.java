package com.legal.backend.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

@Getter
@AllArgsConstructor
public class ChatMessageResponse {
    private Long id;
    private String role;
    private String content;
    private String createdAt;
}
