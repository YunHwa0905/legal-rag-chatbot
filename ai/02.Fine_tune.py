"""
02. QLoRA 파인튜닝


수정 포인트:
- BASE_MODEL: 사용할 베이스 모델
- DATASET_NAME: HuggingFace 데이터셋 이름
- SFTConfig 내 학습 하이퍼파라미터 (epoch, batch, max_length 등)
- .env 파일에 HF_TOKEN, HF_MODEL_REPO 설정


학습 시간 조절:
- 데이터 줄이기: train_ds.select(range(N))
- max_length 줄이기: 256 (빠름) ~ 1024 (품질)
- num_train_epochs 줄이기
"""


import os
import random
import numpy as np
import torch
from datetime import datetime
from dotenv import load_dotenv
from datasets import load_dataset
import huggingface_hub


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
# 설정 (수정 포인트)
# ===========================
SEED         = 42
BASE_MODEL   = "LGAI-EXAONE/EXAONE-3.5-7.8B-Instruct"  # 수정 포인트: 모델명
DATASET_NAME = "yunhwa/legal-rag-train"                  # 수정 포인트: 데이터셋명
HF_TOKEN     = os.getenv("HF_TOKEN")
HF_MODEL_REPO = os.getenv("HF_MODEL_REPO", "yunhwa/legal_chatbot_exaone")


# ===========================
# 재현성 고정
# ===========================
set_seed(SEED)
random.seed(SEED)
np.random.seed(SEED)
torch.manual_seed(SEED)
torch.cuda.manual_seed_all(SEED)


print("=" * 60)
print(f"QLoRA 파인튜닝 시작: {BASE_MODEL}")
print("=" * 60)
print(f"GPU: {torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'CPU'}")


# ===========================
# HuggingFace 로그인
# ===========================
huggingface_hub.login(token=HF_TOKEN)



# ===========================
# 1. 데이터 로드
# ===========================
print(f"\n[INFO] 데이터셋 로드 중: {DATASET_NAME}")
ds = load_dataset(DATASET_NAME)


train_ds = ds["train"]
eval_ds  = ds["test"]


print(f"Train: {len(train_ds):,}건 / Eval: {len(eval_ds):,}건")


# 데이터 줄이고 싶을 때 (학습 시간 단축)
# train_ds = train_ds.select(range(5000))
# eval_ds  = eval_ds.select(range(200))



# ===========================
# 2. 토크나이저 로드
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
# 3. 채팅 템플릿 적용
# ===========================
def to_chat_text(example):
    instruction = example["instruction"].strip()
    user_input  = (example.get("input") or "").strip()
    output      = example["output"].strip()


    # system 메시지 구성 (수정 포인트: 도메인에 맞게 변경)
    law_domain = (example.get("law_category") or user_input or "").strip()
    system_msg = (
        f"당신은 한국 법률 전문 AI 어시스턴트입니다. "
        f"분야: {law_domain}. 정확하고 신뢰할 수 있는 법률 정보를 제공하세요."
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
        # fallback 템플릿
        example["text"] = (
            f"[|system|]{system_msg}[|endofturn|]\n"
            f"[|user|]{instruction}[|endofturn|]\n"
            f"[|assistant|]{output}[|endofturn|]"
        )
    return example



remove_cols = [c for c in ["instruction", "input", "output"] if c in train_ds.column_names]
train_ds = train_ds.map(to_chat_text, remove_columns=remove_cols)
eval_ds  = eval_ds.map(to_chat_text,  remove_columns=remove_cols)


print(f"\n[샘플 확인]")
print(train_ds[0]["text"][:400])



# ===========================
# 4. GPU 설정
# ===========================
# Windows 는 flash_attention_2 미지원 → eager 고정
attn_implementation = "eager"
torch_dtype          = torch.bfloat16


print(f"\n[INFO] torch_dtype: {torch_dtype}")
print(f"[INFO] attn_implementation: {attn_implementation}")



# ===========================
# 5. 4bit 양자화 설정
# ===========================
quant_config = BitsAndBytesConfig(
    load_in_4bit=True,
    bnb_4bit_quant_type="nf4",
    bnb_4bit_compute_dtype=torch_dtype,
    bnb_4bit_use_double_quant=False,  # 수정 포인트: True 로 바꾸면 VRAM 추가 절약
)



# ===========================
# 6. 베이스 모델 로드
# ===========================
print(f"\n[INFO] 모델 로드 중: {BASE_MODEL}")
model = AutoModelForCausalLM.from_pretrained(
    BASE_MODEL,
    revision="0ff6b5ec7c13b049b253a16a889aa269e6b79a94",  # transformers 4.51 호환 커밋
    quantization_config=quant_config,
    device_map="auto",
    torch_dtype=torch_dtype,
    trust_remote_code=True,
    attn_implementation=attn_implementation,
    token=HF_TOKEN,
)
model.config.use_cache       = False
model.config.pretraining_tp  = 1
print(f"[SUCCESS] 모델 로드 완료")



# ===========================
# 7. LoRA 설정
# ===========================
peft_params = LoraConfig(
    r=16,               # 수정 포인트: 16(빠름) ~ 64(품질)
    lora_alpha=32,      # 보통 r 의 2 배
    lora_dropout=0.05,
    bias="none",
    task_type="CAUSAL_LM",
    target_modules=["q_proj", "k_proj", "v_proj", "o_proj",
                    "gate_proj", "up_proj", "down_proj"],
)



# ===========================
# 8. 학습 설정 ← group_by_length 제거됨
# ===========================
sft_args = SFTConfig(
    output_dir="./results",


    # 학습량 제어 (수정 포인트)
    num_train_epochs=5,                # 1~3 권장 (데이터 많을수록 낮게)
    per_device_train_batch_size=1,
    per_device_eval_batch_size=1,
    gradient_accumulation_steps=4,    # 유효 배치 = batch × this


    # 입력 길이 (수정 포인트)
    # 256: 빠름 / 512: 균형 / 1024: 품질
    max_seq_length=512,


    packing=True,  # 짧은 샘플 묶어서 효율 향상
    # group_by_length 제거 (packing 과 상충됨)
    dataset_text_field="text",


    # 최적화
    learning_rate=2e-4,
    weight_decay=0.001,
    max_grad_norm=0.3,
    warmup_ratio=0.03,
    lr_scheduler_type="constant",


    # 로그 / 평가 / 저장
    logging_steps=100,
    report_to="tensorboard",
    eval_strategy="steps",
    eval_steps=500,
    save_strategy="steps",
    save_steps=500,
    save_total_limit=3,


    # 혼합 정밀도
    fp16=(torch_dtype == torch.float16),
    bf16=(torch_dtype == torch.bfloat16),
    seed=SEED,


    # Windows: num_workers>0 시 멀티프로세싱 오류
    dataloader_num_workers=0,
)



# ===========================
# 9. 학습 실행
# ===========================
trainer = SFTTrainer(
    model=model,
    tokenizer=tokenizer,
    train_dataset=train_ds,
    eval_dataset=eval_ds,
    peft_config=peft_params,
    args=sft_args,
)


print(f"\n[INFO] 학습 시작...")
trainer.train()
print(f"[SUCCESS] 학습 완료")



# ===========================
# 10. 로컬 저장
# ===========================
now_str   = datetime.now().strftime("%Y_%m_%d_%H")
prefix    = BASE_MODEL.split("/")[1]
save_path = f"./models/{prefix}_{now_str}"


os.makedirs(save_path, exist_ok=True)
trainer.model.save_pretrained(save_path)
tokenizer.save_pretrained(save_path)
print(f"[SUCCESS] 로컬 저장 완료: {save_path}")



# ===========================
# 11. HuggingFace 업로드
# ===========================
print(f"\n[INFO] HuggingFace 업로드 중: {HF_MODEL_REPO}")
trainer.model.push_to_hub(HF_MODEL_REPO, token=HF_TOKEN)
tokenizer.push_to_hub(HF_MODEL_REPO, token=HF_TOKEN)
print(f"[SUCCESS] 업로드 완료: https://huggingface.co/{HF_MODEL_REPO}")