package com.legal.backend.dto;

import com.fasterxml.jackson.annotation.JsonProperty;
import lombok.AllArgsConstructor;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.util.List;

@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
public class ChatResponse {

	private String answer;
	private List<SourceDocument> sources;

	@JsonProperty("age_group_label")
	private String ageGroupLabel;

	private String question;
	private int age;

	@Getter
	@Setter
	@NoArgsConstructor
	@AllArgsConstructor
	public static class SourceDocument {

		@JsonProperty("doc_id")
		private int docId;

		@JsonProperty("law_category")
		private String lawCategory;

		@JsonProperty("doc_type")
		private String docType;

		private String source;
		private double score;
		private String preview;
	}
}