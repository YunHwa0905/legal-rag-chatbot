"""
AIHub 법률 데이터 전처리 스크립트

역할:
- 패턴 A (민사법, 지식재산권법 계열): taskinfo 파싱
- 패턴 B (HJ_, HS_ 계열): label 파싱
- RAG용 데이터  → data/processed/rag_documents.json
- 파인튜닝용 데이터 → data/processed/finetune_alpaca.json
"""

import os
import json
import glob
from tqdm import tqdm

RAW_DIR = "./data/raw"
PROCESSED_DIR = "./data/processed"
os.makedirs(PROCESSED_DIR, exist_ok=True)

LAW_CLASS_MAP = {
    "1": "행정법", "2": "형사법",
    "01": "행정법", "02": "형사법",
}

DOCU_TYPE_MAP = {
    "1": "법령", "2": "판결문", "3": "유권해석", "4": "결정례", "5": "심결문",
    "01": "법령", "02": "판결문", "03": "유권해석", "04": "결정례", "05": "심결문",
}

DOC_CLASS_MAP = {
    "1": "판결문", "2": "법령", "3": "결정례", "4": "심결문", "5": "유권해석",
}

STATUTE_CATEGORY_MAP = {
    "민사법": "민사법", "지식재산권법": "지식재산권법",
    "행정법": "행정법", "형사법": "형사법",
}


def _get_law_category_from_path(filepath):
    path = filepath.replace("\\", "/")
    for key in ["민사법", "지식재산권법", "행정법", "형사법"]:
        if key in path:
            return key
    return "기타"


def _get_doc_type_from_path(filepath):
    path = filepath.replace("\\", "/")
    if "법령" in path:
        return "법령"
    elif "판결문" in path or "판결" in path:
        return "판결문"
    elif "유권해석" in path or "해석례" in path:
        return "유권해석"
    elif "심결례" in path or "결정례" in path:
        return "결정례"
    elif "심결문" in path:
        return "심결문"
    return "기타"


def parse_pattern_a(data, filepath):
    info = data.get("info", {})
    taskinfo = data.get("taskinfo", {})

    sentences = taskinfo.get("sentences", "")
    if isinstance(sentences, list):
        sentences = "\n".join([s for s in sentences if s and s.strip()])

    input_text = taskinfo.get("input", "")
    output_text = taskinfo.get("output", "")

    statute_category = info.get("statute_category", "")
    if statute_category and statute_category in STATUTE_CATEGORY_MAP:
        law_category = STATUTE_CATEGORY_MAP[statute_category]
    else:
        law_category = _get_law_category_from_path(filepath)

    doc_class = str(info.get("doc_class", ""))
    if doc_class and doc_class in DOC_CLASS_MAP:
        doc_type = DOC_CLASS_MAP[doc_class]
    else:
        doc_type = _get_doc_type_from_path(filepath)

    # RAG용 원문: sentences 우선, 없으면 QA 조합
    if sentences and len(sentences.strip()) > 50:
        original_text = sentences
    elif output_text:
        original_text = f"Q: {input_text}\nA: {output_text}"
    else:
        original_text = input_text

    return {
        "source": os.path.basename(filepath),
        "law_category": law_category,
        "doc_type": doc_type,
        "original_text": original_text,
        "question": input_text,
        "answer": output_text,
    }


def parse_pattern_b(data, filepath):
    info = data.get("info", {})
    label = data.get("label", {})

    input_text = label.get("input", "")
    output_text = label.get("output", "")

    law_class = str(info.get("lawClass", ""))
    law_category = LAW_CLASS_MAP.get(law_class, _get_law_category_from_path(filepath))

    docu_type = str(info.get("DocuType", ""))
    doc_type = DOCU_TYPE_MAP.get(docu_type, _get_doc_type_from_path(filepath))

    case_name = info.get("caseName", "") or info.get("title", "") or info.get("agenda", "")
    if output_text:
        original_text = f"[{case_name}]\nQ: {input_text}\nA: {output_text}"
    else:
        original_text = case_name

    return {
        "source": os.path.basename(filepath),
        "law_category": law_category,
        "doc_type": doc_type,
        "original_text": original_text,
        "question": input_text,
        "answer": output_text,
    }


def parse_file(filepath):
    try:
        with open(filepath, "r", encoding="utf-8") as f:
            data = json.load(f)

        if "taskinfo" in data:
            return parse_pattern_a(data, filepath)
        elif "label" in data:
            return parse_pattern_b(data, filepath)
        else:
            return None
    except Exception as e:
        print(f"[ERROR] {filepath}: {e}")
        return None


def to_rag_document(parsed, doc_id):
    return {
        "doc_id": doc_id,
        "law_category": parsed["law_category"],
        "doc_type": parsed["doc_type"],
        "source": parsed["source"],
        "text": parsed["original_text"],
    }


def to_alpaca(parsed):
    return {
        "instruction": (
            "당신은 대한민국 법률 전문 AI 어시스턴트입니다. "
            "질문에 대해 정확하고 신뢰할 수 있는 법률 정보를 제공하세요. "
            "답변은 관련 법령과 판례를 근거로 작성하세요."
        ),
        "input": parsed["question"],
        "output": parsed["answer"],
        "metadata": {
            "law_category": parsed["law_category"],
            "doc_type": parsed["doc_type"],
            "source": parsed["source"],
        }
    }


def run():
    print("=" * 50)
    print("AIHub 법률 데이터 전처리 시작")
    print("=" * 50)

    json_files = glob.glob(os.path.join(RAW_DIR, "**", "*.json"), recursive=True)
    print(f"\n총 {len(json_files)}개 파일 발견\n")

    rag_documents = []
    alpaca_dataset = []
    skip_count = 0
    doc_id = 0

    for filepath in tqdm(json_files, desc="파일 처리 중"):
        parsed = parse_file(filepath)
        if parsed is None:
            skip_count += 1
            continue

        if parsed["original_text"] and len(parsed["original_text"].strip()) > 10:
            rag_documents.append(to_rag_document(parsed, doc_id))
            doc_id += 1

        if parsed["question"] and parsed["answer"]:
            alpaca_dataset.append(to_alpaca(parsed))

    rag_output_path = os.path.join(PROCESSED_DIR, "rag_documents.json")
    finetune_output_path = os.path.join(PROCESSED_DIR, "finetune_alpaca.json")

    with open(rag_output_path, "w", encoding="utf-8") as f:
        json.dump(rag_documents, f, ensure_ascii=False, indent=2)

    with open(finetune_output_path, "w", encoding="utf-8") as f:
        json.dump(alpaca_dataset, f, ensure_ascii=False, indent=2)

    print("\n" + "=" * 50)
    print("전처리 완료")
    print("=" * 50)
    print(f"총 처리 파일     : {len(json_files)}개")
    print(f"스킵 파일        : {skip_count}개")
    print(f"RAG용 문서       : {len(rag_documents)}개 → {rag_output_path}")
    print(f"파인튜닝용 데이터 : {len(alpaca_dataset)}개 → {finetune_output_path}")

    print("\n[법률 분야별 RAG 문서 수]")
    category_count = {}
    for doc in rag_documents:
        cat = str(doc["law_category"])
        category_count[cat] = category_count.get(cat, 0) + 1
    for cat, count in sorted(category_count.items(), key=lambda x: str(x[0])):
        print(f"  {cat}: {count}개")

    print("\n[문서 유형별 파인튜닝 데이터 수]")
    type_count = {}
    for item in alpaca_dataset:
        dtype = str(item["metadata"]["doc_type"])
        type_count[dtype] = type_count.get(dtype, 0) + 1
    for dtype, count in sorted(type_count.items(), key=lambda x: str(x[0])):
        print(f"  {dtype}: {count}개")


if __name__ == "__main__":
    run()