"""
01. 법률 학습 데이터 샘플링 및 HuggingFace 업로드

현재 상황:
- data/processed/finetune_alpaca.json (253,207건) 이미 존재
- 여기서 품질 필터 + 분야별 균등 샘플링 후 HF에 업로드

수정 포인트:
- SAMPLES_PER_CATEGORY: 분야별 샘플 수 (기본 1,000건 × 4분야 = 4,000건)
- HF_DATASET_REPO: .env 또는 아래 기본값 변경
"""

import os
import json
import random
from collections import defaultdict
from datasets import Dataset, DatasetDict
from dotenv import load_dotenv

load_dotenv()

# ===========================
# 설정 (수정 포인트)
# ===========================
DATA_PATH       = "./data/processed/finetune_alpaca.json"
HF_TOKEN        = os.getenv("HF_TOKEN")
HF_DATASET_REPO = os.getenv("HF_DATASET_REPO", "yunhwa/legal-rag-train")
SEED            = 42

# 분야별 샘플 수 (수정 포인트)
# 1,000 x 4분야 = 4,000건  → 빠른 테스트용
# 10,000 x 4분야 = 40,000건 → 실제 학습용
SAMPLES_PER_CATEGORY = 1_000

# 품질 필터 기준
MIN_INSTRUCTION_LEN = 10
MIN_OUTPUT_LEN      = 50
MAX_OUTPUT_LEN      = 2000


# ===========================
# 품질 필터
# ===========================
def quality_filter(item: dict) -> bool:
    instruction = (item.get("instruction") or "").strip()
    output      = (item.get("output") or "").strip()
    if len(instruction) < MIN_INSTRUCTION_LEN:
        return False
    if len(output) < MIN_OUTPUT_LEN:
        return False
    if len(output) > MAX_OUTPUT_LEN:
        return False
    return True


# ===========================
# 분야별 균등 샘플링
# ===========================
def stratified_sample(data: list, samples_per_category: int, seed: int = 42) -> list:
    category_map = defaultdict(list)
    for item in data:
        cat = item.get("metadata", {}).get("law_category", "기타")
        category_map[cat].append(item)

    print("\n[INFO] 분야별 현황:")
    for cat, items in sorted(category_map.items()):
        filtered = [x for x in items if quality_filter(x)]
        print(f"  {cat}: 전체 {len(items):,}건 → 필터 후 {len(filtered):,}건")

    rng     = random.Random(seed)
    sampled = []

    print("\n[INFO] 샘플링 결과:")
    for cat, items in sorted(category_map.items()):
        filtered = [x for x in items if quality_filter(x)]
        n        = min(len(filtered), samples_per_category)
        selected = rng.sample(filtered, n)
        sampled.extend(selected)
        print(f"  {cat}: {n:,}건 선택")

    rng.shuffle(sampled)
    return sampled


# ===========================
# 메인
# ===========================
if __name__ == "__main__":

    # 1. 원본 데이터 로드
    print(f"[INFO] 데이터 로드 중: {DATA_PATH}")
    with open(DATA_PATH, "r", encoding="utf-8") as f:
        raw_data = json.load(f)
    print(f"[INFO] 원본 데이터: {len(raw_data):,}건")

    # 2. 샘플링
    sampled = stratified_sample(raw_data, SAMPLES_PER_CATEGORY, SEED)
    print(f"\n[INFO] 최종 샘플: {len(sampled):,}건")

    # 3. HF 업로드용 포맷 (metadata 컬럼 보존)
    upload_data = [
        {
            "instruction":  d["instruction"].strip(),
            "input":        d.get("input", "").strip(),
            "output":       d["output"].strip(),
            "law_category": d.get("metadata", {}).get("law_category", ""),
            "doc_type":     d.get("metadata", {}).get("doc_type", ""),
            "source":       d.get("metadata", {}).get("source", ""),
        }
        for d in sampled
    ]

    # 4. train/test 분할 (95% / 5%)
    ds       = Dataset.from_list(upload_data)
    ds_split = ds.train_test_split(test_size=0.05, seed=SEED)
    ds_dict  = DatasetDict({"train": ds_split["train"], "test": ds_split["test"]})

    print(f"  Train: {len(ds_dict['train']):,}건 / Test: {len(ds_dict['test']):,}건")

    # 5. HuggingFace 업로드
    print(f"\n[INFO] HuggingFace 업로드 중: {HF_DATASET_REPO}")
    ds_dict.push_to_hub(
        HF_DATASET_REPO,
        token=HF_TOKEN,
        commit_message=(
            f"샘플링 업로드: {len(upload_data):,}건 "
            f"(분야별 {SAMPLES_PER_CATEGORY:,}건, seed={SEED})"
        ),
    )
    print(f"[SUCCESS] 업로드 완료: https://huggingface.co/datasets/{HF_DATASET_REPO}")