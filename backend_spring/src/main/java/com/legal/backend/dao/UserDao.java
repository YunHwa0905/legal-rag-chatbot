package com.legal.backend.dao;

import com.legal.backend.entity.User;
import org.apache.ibatis.annotations.Mapper;
@Mapper
public interface UserDao {
    User findByUsername(String username);
    int save(User user);
    int existsByUsername(String username);
}
