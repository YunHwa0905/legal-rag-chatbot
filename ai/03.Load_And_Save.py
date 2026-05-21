"""
03. 파인튜닝 모델 병합 및 HuggingFace 업로드

역할:
- 베이스 모델 + LoRA 어댑터 로드
- 추론 테스트
- 어댑터 병합(merge) 후 HuggingFace 업로드

수정 포인트:
- BASE_MODEL: 베이스 모델명
- NEW_MODEL: 파인튜닝된 어댑터 로컬 경로
- HF_UPLOAD_REPO: 업로드할 HuggingFace 저장소명
"""

import os
import torch
import huggingface_hub
from dotenv import load_dotenv

from transformers import (
    AutoModelForCausalLM,
    AutoTokenizer,
)
from peft import PeftModel, PeftConfig

load_dotenv()

# ===========================
# 설정 (수정 포인트)
# ===========================
BASE_MODEL     = "LGAI-EXAONE/EXAONE-3.5-7.8B-Instruct"  # 베이스 모델
NEW_MODEL      = "./models/EXAONE-3.5-7.8B-Instruct_2026_05_21_10"  # 어댑터 경로
HF_UPLOAD_REPO = "yunhwa/legal_chatbot_exaone"             # 업로드 저장소
HF_TOKEN       = os.getenv("HF_TOKEN")

# ===========================
# HuggingFace 로그인
# ===========================
huggingface_hub.login(token=HF_TOKEN)


# ===========================
# 1. 베이스 모델 & 토크나이저 로드
# ===========================
print(f"[INFO] 베이스 모델 로드 중: {BASE_MODEL}")
base_model = AutoModelForCausalLM.from_pretrained(
    BASE_MODEL,
    low_cpu_mem_usage=True,
    return_dict=True,
    torch_dtype=torch.bfloat16,  # 수정 포인트: float16 / bfloat16 / float32
    device_map="auto",
    trust_remote_code=True,
)

tokenizer = AutoTokenizer.from_pretrained(
    BASE_MODEL,
    trust_remote_code=True,
)
tokenizer.pad_token    = tokenizer.eos_token
tokenizer.padding_side = "right"
print(f"[SUCCESS] 베이스 모델 로드 완료")


# ===========================
# 2. LoRA 어댑터 적용
# ===========================
print(f"\n[INFO] 어댑터 로드 중: {NEW_MODEL}")
peft_config = PeftConfig.from_pretrained(NEW_MODEL)
print(peft_config)

model = PeftModel.from_pretrained(base_model, NEW_MODEL)
print(f"[SUCCESS] 어댑터 적용 완료")


# ===========================
# 3. 추론 함수
# ===========================
def infer(
    question: str,
    input_text: str = None,
    system: str = None,
    max_new_tokens: int = 256,
    temperature: float = 0.7,
    top_p: float = 0.9,
) -> str:
    model.eval()

    messages = []
    if system:
        messages.append({"role": "system", "content": system})

    user_msg = (
        f"{question}\n\n[입력]\n{input_text}"
        if input_text else question
    )
    messages.append({"role": "user", "content": user_msg})

    try:
        prompt = tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True
        )
    except Exception:
        prompt = (
            f"[|system|]{system}[|endofturn|]\n" if system else ""
            f"[|user|]{user_msg}[|endofturn|]\n"
            f"[|assistant|]"
        )

    inputs = tokenizer(
        prompt, return_tensors="pt", truncation=True, max_length=2048
    )

    if inputs["input_ids"].max() >= model.get_input_embeddings().num_embeddings:
        raise ValueError("token id out of range (tokenizer/model vocab mismatch)")

    inputs    = inputs.to(model.device)
    amp_dtype = next(model.parameters()).dtype
    if amp_dtype not in (torch.float16, torch.bfloat16):
        amp_dtype = torch.float16

    with torch.no_grad(), torch.autocast("cuda", dtype=amp_dtype):
        outputs = model.generate(
            **inputs,
            max_new_tokens=max_new_tokens,
            do_sample=True,
            temperature=temperature,
            top_p=top_p,
            eos_token_id=tokenizer.eos_token_id,
            pad_token_id=tokenizer.eos_token_id,
            use_cache=False,
        )

    return tokenizer.decode(outputs[0], skip_special_tokens=True)


# ===========================
# 4. 추론 테스트
# ===========================
print("\n" + "=" * 50)
print("추론 테스트")
print("=" * 50)

test_cases = [
    {
        "system":     "당신은 한국 법률 전문 AI 어시스턴트입니다.",
        "question":   "계약서에 도장을 찍지 않으면 계약이 무효인가요?",
        "input_text": "민사법",
    },
    {
        "system":     "당신은 한국 법률 전문 AI 어시스턴트입니다.",
        "question":   "임의동행을 거부할 수 있나요?",
        "input_text": "형사법",
    },
]

for case in test_cases:
    print(f"\n[질문] {case['question']}")
    answer = infer(
        system=case["system"],
        question=case["question"],
        input_text=case["input_text"],
        max_new_tokens=256,
        temperature=0.1,
        top_p=0.9,
    )
    print(f"[답변] {answer}")


# ===========================
# 5. 어댑터 병합 & HuggingFace 업로드
# ===========================
print(f"\n[INFO] 어댑터 병합 중...")
merged_model = model.merge_and_unload()
print(f"[SUCCESS] 병합 완료")

print(f"\n[INFO] HuggingFace 업로드 중: {HF_UPLOAD_REPO}")
merged_model.push_to_hub(HF_UPLOAD_REPO, token=HF_TOKEN)
tokenizer.push_to_hub(HF_UPLOAD_REPO, token=HF_TOKEN)
print(f"[SUCCESS] 업로드 완료: https://huggingface.co/{HF_UPLOAD_REPO}")