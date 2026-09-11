package com.legal.backend.dao;

import com.legal.backend.entity.ChatSession;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

import java.util.List;

@Mapper
public interface ChatSessionDao {
    List<ChatSession> findByUser(@Param("userId") Long userId);
    ChatSession findById(@Param("id") Long id);
    int insert(ChatSession session);
    int updateTitle(@Param("id") Long id, @Param("title") String title);
    int softDelete(@Param("id") Long id);
}
