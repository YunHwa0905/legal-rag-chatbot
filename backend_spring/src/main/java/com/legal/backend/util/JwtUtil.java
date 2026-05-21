package com.legal.backend.util;

import io.jsonwebtoken.*;
import io.jsonwebtoken.security.Keys;
import org.springframework.stereotype.Component;
import java.security.Key;
import java.util.Date;

@Component
public class JwtUtil {
    private static final String SECRET = "legalRagChatbotSecretKeyForJwtToken2024!!";
    private static final long EXPIRATION = 1000L * 60 * 60 * 24;
    private final Key key = Keys.hmacShaKeyFor(SECRET.getBytes());

    public String generateToken(String username, int age) {
        return Jwts.builder().setSubject(username).claim("age", age)
                .setIssuedAt(new Date())
                .setExpiration(new Date(System.currentTimeMillis() + EXPIRATION))
                .signWith(key, SignatureAlgorithm.HS256).compact();
    }

    public String getUsername(String token) { return getClaims(token).getSubject(); }
    public int getAge(String token) { return getClaims(token).get("age", Integer.class); }

    public boolean isValid(String token) {
        try { getClaims(token); return true; }
        catch (JwtException | IllegalArgumentException e) { return false; }
    }

    private Claims getClaims(String token) {
        return Jwts.parserBuilder().setSigningKey(key).build().parseClaimsJws(token).getBody();
    }
}