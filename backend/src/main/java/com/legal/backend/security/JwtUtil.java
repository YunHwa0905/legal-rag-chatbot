package com.legal.backend.security;

import io.jsonwebtoken.*;
import io.jsonwebtoken.security.Keys;
import org.springframework.stereotype.Component;

import java.security.Key;
import java.util.Date;

@Component
public class JwtUtil {

	private static final String SECRET_KEY = "LegalRagChatbotSecretKey2024LegalRagChatbot";
	private static final long EXPIRATION = 1000 * 60 * 60 * 24; // 24시간

	private Key getKey() {
		return Keys.hmacShaKeyFor(SECRET_KEY.getBytes());
	}

	// 토큰 생성
	public String generateToken(String username, int age) {
		return Jwts.builder().setSubject(username).claim("age", age).setIssuedAt(new Date())
				.setExpiration(new Date(System.currentTimeMillis() + EXPIRATION))
				.signWith(getKey(), SignatureAlgorithm.HS256).compact();
	}

	// 토큰에서 username 추출
	public String getUsername(String token) {
		return getClaims(token).getSubject();
	}

	// 토큰에서 age 추출
	public int getAge(String token) {
		return getClaims(token).get("age", Integer.class);
	}

	// 토큰 유효성 검증
	public boolean validateToken(String token) {
		try {
			getClaims(token);
			return true;
		} catch (JwtException | IllegalArgumentException e) {
			return false;
		}
	}

	private Claims getClaims(String token) {
		return Jwts.parserBuilder().setSigningKey(getKey()).build().parseClaimsJws(token).getBody();
	}
}