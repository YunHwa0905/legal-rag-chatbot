package com.legal.backend.service;

import com.legal.backend.dao.UserMemoryDao;
import com.legal.backend.entity.UserMemory;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.NoSuchElementException;

import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class UserMemoryServiceTest {

    @Mock
    private UserMemoryDao userMemoryDao;

    @InjectMocks
    private UserMemoryService userMemoryService;

    @Test
    void deleteMemory_내_소유면_삭제한다() {
        UserMemory memory = new UserMemory(1L, 7L, "role_in_case", "임차인", null,
                new BigDecimal("0.80"), LocalDateTime.now(), LocalDateTime.now());
        when(userMemoryDao.findById(1L)).thenReturn(memory);

        userMemoryService.deleteMemory(1L, 7L);

        verify(userMemoryDao).delete(1L);
    }

    @Test
    void deleteMemory_남의_소유면_예외를_던지고_삭제하지_않는다() {
        UserMemory memory = new UserMemory(1L, 999L, "role_in_case", "임차인", null,
                new BigDecimal("0.80"), LocalDateTime.now(), LocalDateTime.now());
        when(userMemoryDao.findById(1L)).thenReturn(memory);

        assertThrows(NoSuchElementException.class, () -> userMemoryService.deleteMemory(1L, 7L));
        verify(userMemoryDao, never()).delete(anyLong());
    }
}
