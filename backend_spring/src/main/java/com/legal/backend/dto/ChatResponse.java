package com.legal.backend.dto;

import com.fasterxml.jackson.annotation.JsonProperty;
import lombok.Getter;
import lombok.Setter;
import java.util.List;

@Getter
@Setter
public class ChatResponse {

    private String answer;

    private List<SourceDocument> sources;

    // FastAPI: "age_group_label" → Java: ageGroupLabel
    @JsonProperty("age_group_label")
    private String ageGroupLabel;

    private String question;

    private int age;

    @Getter
    @Setter
    public static class SourceDocument {

        // FastAPI snake_case 필드를 @JsonProperty 로 명시적으로 매핑
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