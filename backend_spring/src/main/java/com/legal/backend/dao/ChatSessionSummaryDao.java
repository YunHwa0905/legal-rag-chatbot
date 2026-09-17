package com.legal.backend.dao;

import com.legal.backend.entity.ChatSessionSummary;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

@Mapper
public interface ChatSessionSummaryDao {
    ChatSessionSummary find(@Param("sessionId") Long sessionId);

    int upsertIfNewer(@Param("sessionId") Long sessionId,
                       @Param("summary") String summary,
                       @Param("throughMessageId") Long throughMessageId);
}
