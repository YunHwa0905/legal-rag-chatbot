package com.legal.backend.service;

import com.legal.backend.dao.UserDao;
import com.legal.backend.dto.*;
import com.legal.backend.entity.User;
import com.legal.backend.util.JwtUtil;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.stereotype.Service;

@Service
public class AuthService {
    @Autowired private UserDao userDao;
    @Autowired private BCryptPasswordEncoder passwordEncoder;
    @Autowired private JwtUtil jwtUtil;

    public void signup(SignupRequest req) {
        if (userDao.existsByUsername(req.getUsername()) > 0)
            throw new RuntimeException("이미 사용 중인 아이디입니다.");
        User user = new User();
        user.setUsername(req.getUsername());
        user.setPassword(passwordEncoder.encode(req.getPassword()));
        user.setAge(req.getAge());
        userDao.save(user);
    }

    public LoginResponse login(LoginRequest req) {
        User user = userDao.findByUsername(req.getUsername());
        if (user == null || !passwordEncoder.matches(req.getPassword(), user.getPassword()))
            throw new RuntimeException("아이디 또는 비밀번호가 올바르지 않습니다.");
        String token = jwtUtil.generateToken(user.getUsername(), user.getAge());
        return new LoginResponse(token, user.getUsername(), user.getAge(), getAgeGroupLabel(user.getAge()));
    }

    private String getAgeGroupLabel(int age) {
        if (age <= 10) return "초등학생 눈높이로 설명 중";
        else if (age <= 19) return "청소년 눈높이로 설명 중";
        else if (age <= 40) return "일반 성인 눈높이로 설명 중";
        else return "전문가 눈높이로 설명 중";
    }
}