package com.legal.backend.controller;

import com.legal.backend.dto.UserMemoryResponse;
import com.legal.backend.service.UserMemoryService;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import javax.servlet.http.HttpServletRequest;
import java.util.List;
import java.util.NoSuchElementException;

@RestController
@RequestMapping("/api/chat/memory")
public class UserMemoryController {

    @Autowired
    private UserMemoryService userMemoryService;

    @GetMapping
    public List<UserMemoryResponse> list(HttpServletRequest req) {
        return userMemoryService.listMemory((Long) req.getAttribute("userId"));
    }

    @DeleteMapping("/{id}")
    public ResponseEntity<?> delete(@PathVariable Long id, HttpServletRequest req) {
        try {
            userMemoryService.deleteMemory(id, (Long) req.getAttribute("userId"));
            return ResponseEntity.noContent().build();
        } catch (NoSuchElementException e) {
            return ResponseEntity.notFound().build();
        }
    }
}
