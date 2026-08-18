package com.legal.backend.dto;

import com.fasterxml.jackson.annotation.JsonProperty;
import lombok.Getter;
import lombok.Setter;

@Getter
@Setter
public class DocumentDetail {

    @JsonProperty("doc_id")
    private int docId;

    @JsonProperty("law_category")
    private String lawCategory;

    @JsonProperty("doc_type")
    private String docType;

    private String source;

    private String text;
}
