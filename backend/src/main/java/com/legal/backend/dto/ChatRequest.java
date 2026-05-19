package com.legal.backend.dto;

import lombok.Getter;
import lombok.Setter;

@Getter
@Setter
public class ChatRequest {
	private String question;
	private String lawCategory; // 선택 (민사법/형사법/행정법/지식재산권법)
}