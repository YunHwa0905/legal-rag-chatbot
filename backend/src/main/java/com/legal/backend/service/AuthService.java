package com.legal.backend.service;

import com.legal.backend.dto.LoginRequest;
import com.legal.backend.dto.LoginResponse;
import com.legal.backend.dto.SignupRequest;
import com.legal.backend.entity.User;
import com.legal.backend.repository.UserRepository;
import com.legal.backend.security.JwtUtil;
import lombok.RequiredArgsConstructor;
import org.springframework.security.authentication.BadCredentialsException;
import org.springframework.security.core.userdetails.UsernameNotFoundException;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;

@Service
@RequiredArgsConstructor
public class AuthService {

    private final UserRepository userRepository;
    private final PasswordEncoder passwordEncoder;
    private final JwtUtil jwtUtil;

    // ===========================
    // 회원가입
    // ===========================
    public void signup(SignupRequest request) {
        if (userRepository.existsByUsername(request.getUsername())) {
            throw new IllegalArgumentException("이미 사용 중인 아이디입니다.");
        }

        User user = User.builder()
                .username(request.getUsername())
                .password(passwordEncoder.encode(request.getPassword()))
                .age(request.getAge())
                .role(User.Role.USER)
                .build();

        userRepository.save(user);
    }

    // ===========================
    // 로그인
    // ===========================
    public LoginResponse login(LoginRequest request) {
        User user = userRepository.findByUsername(request.getUsername())
                .orElseThrow(() -> new UsernameNotFoundException("존재하지 않는 아이디입니다."));

        if (!passwordEncoder.matches(request.getPassword(), user.getPassword())) {
            throw new BadCredentialsException("비밀번호가 올바르지 않습니다.");
        }

        String token = jwtUtil.generateToken(user.getUsername(), user.getAge());
        String ageGroupLabel = getAgeGroupLabel(user.getAge());

        return new LoginResponse(token, user.getUsername(), user.getAge(), ageGroupLabel);
    }

    // ===========================
    // 나이대 레이블
    // ===========================
    private String getAgeGroupLabel(int age) {
        if (age <= 10) return "초등학생 눈높이로 설명 중";
        else if (age <= 19) return "청소년 눈높이로 설명 중";
        else if (age <= 40) return "일반 성인 눈높이로 설명 중";
        else return "전문 법률 용어로 설명 중";
    }
}