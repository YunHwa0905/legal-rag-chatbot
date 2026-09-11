package com.legal.backend.util;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;

import static org.junit.jupiter.api.Assertions.assertEquals;

class JwtUtilTest {

    private JwtUtil jwtUtil;

    @BeforeEach
    void setUp() {
        jwtUtil = new JwtUtil();
        ReflectionTestUtils.setField(jwtUtil, "secret", "test-secret-at-least-32-bytes-long!!");
        ReflectionTestUtils.setField(jwtUtil, "expiration", 3600000L);
        jwtUtil.init();
    }

    @Test
    void generateToken_담은_userId를_getUserId로_그대로_꺼낼_수_있다() {
        String token = jwtUtil.generateToken(42L, "yunhwa", 25);

        assertEquals(42L, jwtUtil.getUserId(token));
        assertEquals("yunhwa", jwtUtil.getUsername(token));
        assertEquals(25, jwtUtil.getAge(token));
    }
}
