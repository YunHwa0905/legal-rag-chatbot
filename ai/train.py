"""
Gemma QLoRA 파인튜닝 스크립트

기반: 02__Fine_tune.ipynb
모델: google/gemma-3-4b-it
데이터: data/processed/finetune_alpaca.json
"""

import os
import json
import random
import numpy as np
import torch
from datetime import datetime
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
BASE_MODEL = "google/gemma-3-4b-it"
DATA_PATH = "./data/processed/finetune_alpaca.json"
HF_TOKEN = os.getenv("HF_TOKEN")
HF_MODEL_REPO = os.getenv("HF_MODEL_REPO", "yunhwa/legal_chatbot")

# ===========================
# 재현성 고정
# ===========================
set_seed(SEED)
random.seed(SEED)
np.random.seed(SEED)
torch.manual_seed(SEED)
torch.cuda.manual_seed_all(SEED)

print("=" * 50)
print("Gemma QLoRA 파인튜닝 시작")
print("=" * 50)
print(f"GPU: {torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'CPU'}")


# ===========================
# HuggingFace 로그인
# ===========================
login(token=HF_TOKEN)


# ===========================
# 데이터 로드 & 분할
# ===========================
print(f"\n[INFO] 데이터 로드 중: {DATA_PATH}")
with open(DATA_PATH, encoding="utf-8") as f:
    data = json.load(f)

# metadata 필드 제거 (학습에 불필요)
clean_data = [
    {
        "instruction": d["instruction"],
        "input": d["input"],
        "output": d["output"],
    }
    for d in data
    if d.get("instruction") and d.get("output")
]

ds = Dataset.from_list(clean_data)
ds_split = ds.train_test_split(test_size=0.2, seed=SEED)
train_ds = ds_split["train"]
eval_ds = ds_split["test"]

print(f"전체 : {len(ds):,}개")
print(f"Train: {len(train_ds):,}개 (80%)")
print(f"Eval : {len(eval_ds):,}개 (20%)")

# 도메인별 분포 확인
import pandas as pd
df_train = train_ds.to_pandas()
print(f"\n[도메인별 분포]\n{df_train['input'].value_counts().to_string()}")


# ===========================
# 토크나이저 로드
# ===========================
print(f"\n[INFO] 토크나이저 로드 중: {BASE_MODEL}")
tokenizer = AutoTokenizer.from_pretrained(
    BASE_MODEL,
    trust_remote_code=True,
    use_fast=False,
    token=HF_TOKEN,
)
tokenizer.pad_token = tokenizer.eos_token
tokenizer.padding_side = "right"


# ===========================
# 채팅 템플릿 적용
# ===========================
def to_chat_text(example):
    instruction = example["instruction"].strip()
    user_input = example["input"].strip()
    output = example["output"].strip()

    user_msg = (
        f"{instruction}\n\n[입력]\n{user_input}"
        if instruction and user_input
        else instruction or user_input
    )

    messages = [
        {"role": "user", "content": user_msg},
        {"role": "assistant", "content": output},
    ]

    try:
        example["text"] = tokenizer.apply_chat_template(
            messages,
            tokenize=False,
            add_generation_prompt=False,
        )
    except Exception:
        example["text"] = (
            "<start_of_turn>user\n"
            f"{user_msg}\n"
            "<end_of_turn>\n"
            "<start_of_turn>model\n"
            f"{output}\n"
            "<end_of_turn>"
        )
    return example


train_ds = train_ds.map(
    to_chat_text,
    remove_columns=["instruction", "input", "output"],
)
eval_ds = eval_ds.map(
    to_chat_text,
    remove_columns=["instruction", "input", "output"],
)

print(f"\n[샘플 확인]")
print(train_ds[0]["text"][:300])


# ===========================
# GPU 아키텍처 확인
# RTX 2000 Ada → Ampere (sm_86) → bfloat16 사용 가능
# ===========================
if torch.cuda.get_device_capability()[0] >= 8:
    attn_implementation = "flash_attention_2"
    torch_dtype = torch.bfloat16
else:
    attn_implementation = "eager"
    torch_dtype = torch.float16

print(f"\n[INFO] torch_dtype: {torch_dtype}")
print(f"[INFO] attn_implementation: {attn_implementation}")


# ===========================
# 4bit 양자화 설정
# ===========================
quant_config = BitsAndBytesConfig(
    load_in_4bit=True,
    bnb_4bit_quant_type="nf4",
    bnb_4bit_compute_dtype=torch_dtype,
    bnb_4bit_use_double_quant=False,
)


# ===========================
# 모델 로드
# ===========================
print(f"\n[INFO] 모델 로드 중: {BASE_MODEL}")
model = AutoModelForCausalLM.from_pretrained(
    BASE_MODEL,
    quantization_config=quant_config,
    device_map="auto",
    token=HF_TOKEN,
)
model.config.use_cache = False
model.config.pretraining_tp = 1
print(f"[SUCCESS] 모델 로드 완료")


# ===========================
# LoRA 설정
# ===========================
peft_params = LoraConfig(
    r=16,
    lora_alpha=32,
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
# ===========================
now_str = datetime.now().strftime("%Y_%m_%d_%H")
save_path = f"./models/gemma-3-4b-legal_{now_str}"

sft_args = SFTConfig(
    output_dir="./results",
    num_train_epochs=3,
    per_device_train_batch_size=1,
    per_device_eval_batch_size=1,
    gradient_accumulation_steps=4,
    max_seq_length=256,
    packing=True,
    dataset_text_field="text",
    learning_rate=2e-4,
    weight_decay=0.001,
    max_grad_norm=0.3,
    warmup_steps=100,
    lr_scheduler_type="constant",
    logging_steps=500,
    report_to="tensorboard",
    eval_strategy="no",
    save_strategy="steps",
    save_steps=1000,
    save_total_limit=3,
    fp16=(torch_dtype == torch.float16),
    bf16=(torch_dtype == torch.bfloat16),
    seed=SEED,
)


# ===========================
# 학습 실행
# ===========================
trainer = SFTTrainer(
    model=model,
    train_dataset=train_ds,
    eval_dataset=None,
    peft_config=peft_params,
    args=sft_args,           # trl 1.4.0: tokenizer 파라미터 제거, 자동으로 모델에서 가져옴
)

print(f"\n[INFO] 학습 시작...")
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