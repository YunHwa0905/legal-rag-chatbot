package com.legal.backend.entity;

import lombok.*;
@Getter @Setter @NoArgsConstructor @AllArgsConstructor
public class User {
    private Long id;
    private String username;
    private String password;
    private int age;
}