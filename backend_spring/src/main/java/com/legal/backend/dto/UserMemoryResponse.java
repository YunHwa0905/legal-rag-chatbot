package com.legal.backend.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

@Getter
@AllArgsConstructor
public class UserMemoryResponse {
    private Long id;
    private String memKey;
    private String memValue;
    private String confirmedAt;
}
