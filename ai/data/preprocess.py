"""
AIHub 법률 데이터 전처리 스크립트

역할:
- 패턴 A (민사법, 지식재산권법 계열): taskinfo 파싱
- 패턴 B (HJ_, HS_ 계열): label 파싱
- RAG용 데이터 → data/processed/rag_documents.json
- 파인튜닝용 데이터 → data/processed/finetune_alpaca.json
"""

import os
import json
import glob
from tqdm import tqdm

# ===========================
# 경로 설정
# ===========================
RAW_DIR = "./data/raw"
PROCESSED_DIR = "./data/processed"
os.makedirs(PROCESSED_DIR, exist_ok=True)

# ===========================
# 법률 분야 매핑
# ===========================
LAW_CLASS_MAP = {
    "01": "행정법",
    "02": "형사법",
    "03": "민사법",
    "04": "지식재산권법",
}

DOCU_TYPE_MAP = {
    "01": "법령",
    "02": "판결문",
    "03": "유권해석",
    "04": "결정례",
    "05": "심결문",
}

# ===========================
# 패턴 A 파싱 (민사법, 지식재산권법 계열)
# taskinfo 키를 가진 JSON
# ===========================
def parse_pattern_a(data: dict, filepath: str) -> dict:
    info = data.get("info", {})
    taskinfo = data.get("taskinfo", {})

    # 원문 텍스트 추출 (리스트일 수도, 문자열일 수도 있음)
    sentences = taskinfo.get("sentences", "")
    if isinstance(sentences, list):
        sentences = "\n".join(sentences)

    input_text = taskinfo.get("input", "")
    output_text = taskinfo.get("output", "")

    # 메타데이터
    law_category = info.get("statute_category", "") or info.get("doc_class", "")
    doc_type = _get_doc_type_from_path(filepath)

    return {
        "source": os.path.basename(filepath),
        "law_category": law_category,
        "doc_type": doc_type,
        "original_text": sentences,   # RAG용
        "question": input_text,        # 파인튜닝용
        "answer": output_text,         # 파인튜닝용
    }


# ===========================
# 패턴 B 파싱 (HJ_, HS_ 계열)
# label 키를 가진 JSON
# ===========================
def parse_pattern_b(data: dict, filepath: str) -> dict:
    info = data.get("info", {})
    label = data.get("label", {})

    input_text = label.get("input", "")
    output_text = label.get("output", "")

    # 법률 분야
    law_class = str(info.get("lawClass", ""))
    law_category = LAW_CLASS_MAP.get(law_class, "기타")

    # 문서 유형
    docu_type = str(info.get("DocuType", ""))
    doc_type = DOCU_TYPE_MAP.get(docu_type, "기타")

    # 판결문/법령 원문이 있으면 추출
    # fullText=Y면 별도 원문 파일 있음, N이면 없음
    # 여기서는 QA에서 추출 가능한 텍스트만 사용
    case_name = info.get("caseName", "") or info.get("title", "") or info.get("agenda", "")

    return {
        "source": os.path.basename(filepath),
        "law_category": law_category,
        "doc_type": doc_type,
        "original_text": case_name,    # RAG용 (판례명/법령명)
        "question": input_text,         # 파인튜닝용
        "answer": output_text,          # 파인튜닝용
    }


# ===========================
# 파일 경로에서 문서 유형 추출
# ===========================
def _get_doc_type_from_path(filepath: str) -> str:
    path_lower = filepath.replace("\\", "/")
    if "법령" in path_lower:
        return "법령"
    elif "판결문" in path_lower or "판결" in path_lower:
        return "판결문"
    elif "유권해석" in path_lower or "해석" in path_lower:
        return "유권해석"
    elif "심결례" in path_lower or "결정례" in path_lower:
        return "결정례"
    elif "심결문" in path_lower:
        return "심결문"
    return "기타"


# ===========================
# 단일 파일 파싱
# ===========================
def parse_file(filepath: str) -> dict | None:
    try:
        with open(filepath, "r", encoding="utf-8") as f:
            data = json.load(f)

        # 패턴 구분
        if "taskinfo" in data:
            return parse_pattern_a(data, filepath)
        elif "label" in data:
            return parse_pattern_b(data, filepath)
        else:
            print(f"[SKIP] 알 수 없는 패턴: {filepath}")
            return None

    except Exception as e:
        print(f"[ERROR] {filepath}: {e}")
        return None


# ===========================
# RAG용 데이터 변환
# OpenSearch에 적재할 형태
# ===========================
def to_rag_document(parsed: dict, doc_id: int) -> dict:
    return {
        "doc_id": doc_id,
        "law_category": parsed["law_category"],
        "doc_type": parsed["doc_type"],
        "source": parsed["source"],
        "text": parsed["original_text"],   # 임베딩 & 검색 대상
        "metadata": {
            "law_category": parsed["law_category"],
            "doc_type": parsed["doc_type"],
            "source": parsed["source"],
        }
    }


# ===========================
# 파인튜닝용 Alpaca 포맷 변환
# ===========================
def to_alpaca(parsed: dict) -> dict:
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


# ===========================
# 전체 처리 메인 함수
# ===========================
def run():
    print("=" * 50)
    print("AIHub 법률 데이터 전처리 시작")
    print("=" * 50)

    # JSON 파일 전체 수집
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

        # RAG용: 원문 텍스트가 있는 경우만
        if parsed["original_text"] and len(parsed["original_text"].strip()) > 10:
            rag_documents.append(to_rag_document(parsed, doc_id))
            doc_id += 1

        # 파인튜닝용: 질문과 답변이 모두 있는 경우만
        if parsed["question"] and parsed["answer"]:
            alpaca_dataset.append(to_alpaca(parsed))

    # ===========================
    # 저장
    # ===========================
    rag_output_path = os.path.join(PROCESSED_DIR, "rag_documents.json")
    finetune_output_path = os.path.join(PROCESSED_DIR, "finetune_alpaca.json")

    with open(rag_output_path, "w", encoding="utf-8") as f:
        json.dump(rag_documents, f, ensure_ascii=False, indent=2)

    with open(finetune_output_path, "w", encoding="utf-8") as f:
        json.dump(alpaca_dataset, f, ensure_ascii=False, indent=2)

    # ===========================
    # 결과 출력
    # ===========================
    print("\n" + "=" * 50)
    print("전처리 완료")
    print("=" * 50)
    print(f"총 처리 파일     : {len(json_files)}개")
    print(f"스킵 파일        : {skip_count}개")
    print(f"RAG용 문서       : {len(rag_documents)}개 → {rag_output_path}")
    print(f"파인튜닝용 데이터 : {len(alpaca_dataset)}개 → {finetune_output_path}")

    # 법률 분야별 통계
    print("\n[법률 분야별 RAG 문서 수]")
    category_count = {}
    for doc in rag_documents:
        cat = str(doc["law_category"])  # int → str 변환
        category_count[cat] = category_count.get(cat, 0) + 1
    for cat, count in sorted(category_count.items(), key=lambda x: str(x[0])):
        print(f"  {cat}: {count}개")

    print("\n[문서 유형별 파인튜닝 데이터 수]")
    type_count = {}
    for item in alpaca_dataset:
        dtype = str(item["metadata"]["doc_type"])  # int → str 변환
        type_count[dtype] = type_count.get(dtype, 0) + 1
    for dtype, count in sorted(type_count.items(), key=lambda x: str(x[0])):
        print(f"  {dtype}: {count}개")


if __name__ == "__main__":
    run()
