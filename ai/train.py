"""
EXAONE-3.5-7.8B QLoRA 파인튜닝 스크립트

변경사항:
- 모델: gemma-3-4b-it → EXAONE-3.5-7.8B-Instruct (한국어 특화)
- 데이터: 전체 → 품질 기반 샘플링 (목표 3~5만건, 학습 3~5시간)
- max_seq_length: 256 → 1024 (법률 문서 손실 방지)
- LoRA rank: 16 → 64 (도메인 학습량 확보)
- epoch: 3 → 2 (샘플 줄어든 만큼 epoch 유지)
"""

import os
import json
import random
import numpy as np
import torch
import pandas as pd
from datetime import datetime
from collections import defaultdict
from datasets import Dataset
from dotenv import load_dotenv
from huggingface_hub import login

from transformers import (
    AutoModelForCausalLM,
    AutoTokenizer,
    BitsAndBytesConfig,
    set_seed,
)
from peft import LoraConfig
from trl import SFTTrainer, SFTConfig

load_dotenv()

# ===========================
# 설정
# ===========================
SEED = 42
BASE_MODEL = "LGAI-EXAONE/EXAONE-3.5-7.8B-Instruct"
DATA_PATH = "./data/processed/finetune_alpaca.json"
HF_TOKEN = os.getenv("HF_TOKEN")
HF_MODEL_REPO = os.getenv("HF_MODEL_REPO", "yunhwa/legal_chatbot_exaone")

# ===========================
# 샘플링 설정
# ===========================
# 분야별 최대 샘플 수 (전체 약 4만건 목표 → 학습 3~5시간)
# 분야 4개 × 10,000건 = 40,000건
SAMPLES_PER_CATEGORY = 10_000

# 품질 필터 기준
MIN_INSTRUCTION_LEN = 10   # 질문 최소 10자
MIN_OUTPUT_LEN      = 50   # 답변 최소 50자
MAX_OUTPUT_LEN      = 2000 # 답변 최대 2000자 (너무 길면 학습 효율 낮음)

# ===========================
# 재현성 고정
# ===========================
set_seed(SEED)
random.seed(SEED)
np.random.seed(SEED)
torch.manual_seed(SEED)
torch.cuda.manual_seed_all(SEED)

print("=" * 60)
print("EXAONE-3.5-7.8B QLoRA 파인튜닝 시작")
print("=" * 60)
print(f"GPU: {torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'CPU'}")

# ===========================
# HuggingFace 로그인
# ===========================
login(token=HF_TOKEN)


# ===========================
# 데이터 로드 & 품질 기반 샘플링
# ===========================
print(f"\n[INFO] 데이터 로드 중: {DATA_PATH}")
with open(DATA_PATH, encoding="utf-8") as f:
    raw_data = json.load(f)

print(f"[INFO] 원본 데이터 총 {len(raw_data):,}건")


def quality_filter(item: dict) -> bool:
    """품질 필터: 너무 짧거나 긴 샘플 제거"""
    instruction = (item.get("instruction") or "").strip()
    output      = (item.get("output") or "").strip()

    if len(instruction) < MIN_INSTRUCTION_LEN:
        return False
    if len(output) < MIN_OUTPUT_LEN:
        return False
    if len(output) > MAX_OUTPUT_LEN:
        return False
    return True


def stratified_sample(data: list, samples_per_category: int, seed: int = 42) -> list:
    """
    분야별 균등 샘플링
    - 각 분야에서 최대 samples_per_category 건 추출
    - 데이터가 부족한 분야는 전체 사용
    """
    # 분야별로 분류
    category_map = defaultdict(list)
    for item in data:
        cat = item.get("metadata", {}).get("law_category", "기타")
        category_map[cat].append(item)

    print("\n[INFO] 분야별 품질 필터 적용 전 현황:")
    for cat, items in sorted(category_map.items()):
        print(f"  {cat}: {len(items):,}건")

    # 분야별 샘플링
    rng = random.Random(seed)
    sampled = []
    print("\n[INFO] 분야별 샘플링 결과:")
    for cat, items in sorted(category_map.items()):
        # 품질 필터 적용
        filtered = [x for x in items if quality_filter(x)]
        # 샘플링
        n = min(len(filtered), samples_per_category)
        selected = rng.sample(filtered, n)
        sampled.extend(selected)
        print(f"  {cat}: {len(items):,}건 → 필터 후 {len(filtered):,}건 → 샘플 {n:,}건")

    rng.shuffle(sampled)
    return sampled


sampled_data = stratified_sample(raw_data, SAMPLES_PER_CATEGORY, SEED)

clean_data = [
    {
        "instruction": d["instruction"].strip(),
        "input":       d.get("input", "").strip(),
        "output":      d["output"].strip(),
    }
    for d in sampled_data
]

print(f"\n[INFO] 최종 학습 데이터: {len(clean_data):,}건")

ds = Dataset.from_list(clean_data)
ds_split = ds.train_test_split(test_size=0.05, seed=SEED)  # eval 5%로 최소화
train_ds = ds_split["train"]
eval_ds  = ds_split["test"]

print(f"Train: {len(train_ds):,}건 / Eval: {len(eval_ds):,}건")

df_train = train_ds.to_pandas()
print(f"\n[도메인별 분포]\n{df_train['input'].value_counts().to_string()}")


# ===========================
# 토크나이저 로드
# EXAONE은 trust_remote_code=True 필수
# ===========================
print(f"\n[INFO] 토크나이저 로드 중: {BASE_MODEL}")
tokenizer = AutoTokenizer.from_pretrained(
    BASE_MODEL,
    trust_remote_code=True,
    token=HF_TOKEN,
)
tokenizer.padding_side = "right"

if tokenizer.pad_token is None:
    tokenizer.pad_token = tokenizer.eos_token


# ===========================
# 채팅 템플릿 적용
# EXAONE chat template 사용
# ===========================
def to_chat_text(example):
    instruction = example["instruction"].strip()
    law_domain  = example["input"].strip()
    output      = example["output"].strip()

    # 법률 도메인 정보를 system 프롬프트에 포함
    system_msg = (
        f"당신은 한국 법률 전문 AI 어시스턴트입니다. "
        f"분야: {law_domain}. "
        f"정확하고 신뢰할 수 있는 법률 정보를 제공하세요."
        if law_domain else
        "당신은 한국 법률 전문 AI 어시스턴트입니다. "
        "정확하고 신뢰할 수 있는 법률 정보를 제공하세요."
    )

    messages = [
        {"role": "system",    "content": system_msg},
        {"role": "user",      "content": instruction},
        {"role": "assistant", "content": output},
    ]

    try:
        example["text"] = tokenizer.apply_chat_template(
            messages,
            tokenize=False,
            add_generation_prompt=False,
        )
    except Exception:
        # EXAONE fallback 템플릿
        example["text"] = (
            f"[|system|]{system_msg}[|endofturn|]\n"
            f"[|user|]{instruction}[|endofturn|]\n"
            f"[|assistant|]{output}[|endofturn|]"
        )
    return example


train_ds = train_ds.map(to_chat_text, remove_columns=["instruction", "input", "output"])
eval_ds  = eval_ds.map(to_chat_text,  remove_columns=["instruction", "input", "output"])

print(f"\n[샘플 확인]")
print(train_ds[0]["text"][:400])


# ===========================
# GPU 아키텍처 확인
# ===========================
if torch.cuda.is_available() and torch.cuda.get_device_capability()[0] >= 8:
    attn_implementation = "flash_attention_2"
    torch_dtype = torch.bfloat16
else:
    attn_implementation = "eager"
    torch_dtype = torch.bfloat16  # EXAONE은 bfloat16 권장

print(f"\n[INFO] torch_dtype: {torch_dtype}")
print(f"[INFO] attn_implementation: {attn_implementation}")


# ===========================
# 4bit 양자화 설정
# ===========================
quant_config = BitsAndBytesConfig(
    load_in_4bit=True,
    bnb_4bit_quant_type="nf4",
    bnb_4bit_compute_dtype=torch_dtype,
    bnb_4bit_use_double_quant=True,   # double quant로 VRAM 추가 절약
)


# ===========================
# 모델 로드
# EXAONE은 trust_remote_code=True 필수
# ===========================
print(f"\n[INFO] 모델 로드 중: {BASE_MODEL}")
model = AutoModelForCausalLM.from_pretrained(
    BASE_MODEL,
    quantization_config=quant_config,
    device_map="auto",
    torch_dtype=torch_dtype,
    trust_remote_code=True,
    attn_implementation=attn_implementation,
    token=HF_TOKEN,
)
model.config.use_cache = False
print(f"[SUCCESS] 모델 로드 완료")


# ===========================
# LoRA 설정
# rank 16 → 64: 도메인 특화 학습량 확보
# ===========================
peft_params = LoraConfig(
    r=64,                    # 16 → 64: 법률 도메인 학습에 충분한 rank
    lora_alpha=128,          # alpha = 2 * r 권장
    lora_dropout=0.05,
    bias="none",
    task_type="CAUSAL_LM",
    target_modules=[
        "q_proj", "k_proj", "v_proj", "o_proj",
        "gate_proj", "up_proj", "down_proj",
    ],
)


# ===========================
# 학습 설정
# 목표: RTX 2000 Ada 기준 3~5시간
#
# 예상 학습 시간 계산:
# 데이터 ~40,000건 × 2 epoch
# max_seq_length=1024, packing=True
# → 예상 스텝 수 ~5,000~8,000
# → RTX 2000 Ada 기준 약 3~4시간
# ===========================
now_str = datetime.now().strftime("%Y_%m_%d_%H")
save_path = f"./models/exaone-3.5-7.8b-legal_{now_str}"

sft_args = SFTConfig(
    output_dir="./results",
    num_train_epochs=2,              # 3 → 2 (샘플 품질 높아졌으므로)
    per_device_train_batch_size=1,
    per_device_eval_batch_size=1,
    gradient_accumulation_steps=8,   # 4 → 8 (7.8B 모델은 유효 배치 크게)
    max_seq_length=1024,             # 256 → 1024 (법률 문서 손실 방지)
    packing=True,
    dataset_text_field="text",
    learning_rate=1e-4,              # 2e-4 → 1e-4 (큰 모델은 낮은 LR 권장)
    weight_decay=0.01,
    max_grad_norm=0.3,
    warmup_ratio=0.03,               # warmup_steps → ratio로 변경 (데이터 수 유동적)
    lr_scheduler_type="cosine",      # constant → cosine (수렴 안정성)
    logging_steps=50,
    report_to="tensorboard",
    eval_strategy="steps",
    eval_steps=500,                  # 중간 성능 모니터링
    save_strategy="steps",
    save_steps=500,
    save_total_limit=3,
    load_best_model_at_end=True,     # 가장 좋은 체크포인트 자동 선택
    bf16=(torch_dtype == torch.bfloat16),
    fp16=False,
    seed=SEED,
    dataloader_num_workers=2,
)


# ===========================
# 학습 실행
# ===========================
trainer = SFTTrainer(
    model=model,
    train_dataset=train_ds,
    eval_dataset=eval_ds,
    peft_config=peft_params,
    args=sft_args,
)

print(f"\n[INFO] 학습 시작...")
print(f"[INFO] 예상 학습 시간: 3~5시간 (RTX 2000 Ada 기준)")
trainer.train()
print(f"[SUCCESS] 학습 완료")


# ===========================
# 모델 저장
# ===========================
os.makedirs(save_path, exist_ok=True)
trainer.model.save_pretrained(save_path)
tokenizer.save_pretrained(save_path)
print(f"[SUCCESS] 로컬 저장 완료: {save_path}")


# ===========================
# HuggingFace 업로드
# ===========================
print(f"\n[INFO] HuggingFace 업로드 중: {HF_MODEL_REPO}")
trainer.model.push_to_hub(HF_MODEL_REPO, token=HF_TOKEN)
tokenizer.push_to_hub(HF_MODEL_REPO, token=HF_TOKEN)
print(f"[SUCCESS] HuggingFace 업로드 완료: {HF_MODEL_REPO}")