package com.legal.backend.dto;

import lombok.*;
@Getter @AllArgsConstructor
public class LoginResponse {
    private String token;
    private String username;
    private int age;
    private String ageGroupLabel;
}