package com.legal.backend.dto;

import lombok.*;
@Getter @Setter
public class SignupRequest {
    private String username;
    private String password;
    private int age;
}