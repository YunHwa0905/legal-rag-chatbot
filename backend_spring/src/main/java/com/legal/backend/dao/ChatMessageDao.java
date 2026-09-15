package com.legal.backend.dao;

import com.legal.backend.entity.ChatMessage;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

import java.util.List;

@Mapper
public interface ChatMessageDao {
    List<ChatMessage> findBySession(@Param("sessionId") Long sessionId);
    int insert(ChatMessage message);
}
