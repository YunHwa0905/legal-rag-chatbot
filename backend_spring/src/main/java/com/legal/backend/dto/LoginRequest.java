package com.legal.backend.dto;

import lombok.*;
@Getter @Setter
public class LoginRequest {
    private String username;
    private String password;
}