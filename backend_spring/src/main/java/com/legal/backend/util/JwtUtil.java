package com.legal.backend.util;

import io.jsonwebtoken.*;
import io.jsonwebtoken.security.Keys;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import javax.annotation.PostConstruct;
import java.security.Key;
import java.util.Date;

@Component
public class JwtUtil {

    /**
     * root-context.xml 에서 db.properties 를 property-placeholder 로 읽으므로
     * @Value 로 ${jwt.secret} 주입이 정상 동작합니다.
     * 운영 환경에서는 JVM 인자로 오버라이드하세요:
     *   -Djwt.secret=your-very-long-random-secret
     */
    @Value("${jwt.secret}")
    private String secret;

    @Value("${jwt.expiration}")
    private long expiration;

    private Key key;

    // javax.annotation-api 의존성 추가 후 정상 동작 (pom.xml 참고)
    @PostConstruct
    public void init() {
        this.key = Keys.hmacShaKeyFor(secret.getBytes());
    }

    public String generateToken(String username, int age) {
        return Jwts.builder()
                .setSubject(username)
                .claim("age", age)
                .setIssuedAt(new Date())
                .setExpiration(new Date(System.currentTimeMillis() + expiration))
                .signWith(key, SignatureAlgorithm.HS256)
                .compact();
    }

    public String getUsername(String token) {
        return getClaims(token).getSubject();
    }

    public int getAge(String token) {
        return getClaims(token).get("age", Integer.class);
    }

    public boolean isValid(String token) {
        try {
            getClaims(token);
            return true;
        } catch (JwtException | IllegalArgumentException e) {
            return false;
        }
    }

    private Claims getClaims(String token) {
        return Jwts.parserBuilder()
                .setSigningKey(key)
                .build()
                .parseClaimsJws(token)
                .getBody();
    }
}