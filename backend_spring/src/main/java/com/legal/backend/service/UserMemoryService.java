package com.legal.backend.service;

import com.legal.backend.dao.UserMemoryDao;
import com.legal.backend.dto.UserMemoryResponse;
import com.legal.backend.entity.UserMemory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;

import java.time.format.DateTimeFormatter;
import java.util.List;
import java.util.NoSuchElementException;
import java.util.stream.Collectors;

@Service
public class UserMemoryService {

    private static final DateTimeFormatter ISO = DateTimeFormatter.ISO_LOCAL_DATE_TIME;

    @Autowired
    private UserMemoryDao userMemoryDao;

    public List<UserMemoryResponse> listMemory(Long userId) {
        return userMemoryDao.findByUser(userId).stream()
                .map(this::toResponse)
                .collect(Collectors.toList());
    }

    public void deleteMemory(Long id, Long userId) {
        UserMemory memory = userMemoryDao.findById(id);
        if (memory == null || !memory.getUserId().equals(userId)) {
            throw new NoSuchElementException("메모리를 찾을 수 없습니다: " + id);
        }
        userMemoryDao.delete(id);
    }

    private UserMemoryResponse toResponse(UserMemory m) {
        return new UserMemoryResponse(m.getId(), m.getMemKey(), m.getMemValue(), m.getConfirmedAt().format(ISO));
    }
}
