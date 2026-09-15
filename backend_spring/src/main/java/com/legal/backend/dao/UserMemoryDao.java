package com.legal.backend.dao;

import com.legal.backend.entity.UserMemory;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

import java.util.List;

@Mapper
public interface UserMemoryDao {
    List<UserMemory> findByUser(@Param("userId") Long userId);
    UserMemory findById(@Param("id") Long id);
    int delete(@Param("id") Long id);
}
