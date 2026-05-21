package com.legal.backend.dto;

import lombok.*;
@Getter @Setter
public class ChatRequest {
    private String question;
    private String lawCategory;
}
