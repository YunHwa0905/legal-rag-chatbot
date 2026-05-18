"""
Gemma 모델 로드 & 추론 모듈

역할:
- HuggingFace에서 Gemma 모델 로드
- QLoRA(4bit) 양자화로 VRAM 절약
- 나이대별 프롬프트 기반 답변 생성
"""

import sys
import os
import torch
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from transformers import (
    AutoTokenizer,
    AutoModelForCausalLM,
    BitsAndBytesConfig,
)
from core.config import settings


# ===========================
# 모델 싱글톤 관리
# ===========================
_model = None
_tokenizer = None


def _get_bnb_config() -> BitsAndBytesConfig:
    return BitsAndBytesConfig(
        load_in_4bit=True,
        bnb_4bit_quant_type="nf4",
        bnb_4bit_compute_dtype=torch.bfloat16,  # float16 → bfloat16
        bnb_4bit_use_double_quant=True,
    )


def load_model():
    global _model, _tokenizer

    if _model is not None:
        return _model, _tokenizer

    print(f"[INFO] 모델 로드 중: {settings.MODEL_NAME}")

    _tokenizer = AutoTokenizer.from_pretrained(
        settings.MODEL_NAME,
        token=settings.HF_TOKEN if settings.HF_TOKEN else None,
    )

    if _tokenizer.pad_token is None:
        _tokenizer.pad_token = _tokenizer.eos_token

    _model = AutoModelForCausalLM.from_pretrained(
        settings.MODEL_NAME,
        quantization_config=_get_bnb_config(),
        device_map="auto",
        torch_dtype=torch.bfloat16,
        attn_implementation="eager",   # ← 이거 추가
        token=settings.HF_TOKEN if settings.HF_TOKEN else None,
    )

    _model.eval()
    print(f"[SUCCESS] 모델 로드 완료")
    print(f"[INFO] 사용 디바이스: {next(_model.parameters()).device}")

    return _model, _tokenizer


def generate(
    system_prompt: str,
    user_message: str,
) -> str:
    model, tokenizer = load_model()

    messages = [
        {"role": "user", "content": f"{system_prompt}\n\n{user_message}"}
    ]

    try:
        prompt = tokenizer.apply_chat_template(
            messages,
            tokenize=False,
            add_generation_prompt=True,
        )
    except Exception:
        prompt = f"{system_prompt}\n\n{user_message}\n\n답변:"

    inputs = tokenizer(
        prompt,
        return_tensors="pt",
        truncation=True,
        max_length=4096,
    ).to(model.device)

    with torch.no_grad():
        outputs = model.generate(
            **inputs,
            max_new_tokens=settings.MAX_NEW_TOKENS,
            do_sample=False,
            pad_token_id=tokenizer.eos_token_id,
            eos_token_id=tokenizer.eos_token_id,
            repetition_penalty=1.1,
            temperature=None,
            top_p=None,
            top_k=None,
        )

    # 디버그
    input_length = inputs["input_ids"].shape[1]
    generated_tokens = outputs[0][input_length:]
    print(f"[DEBUG] input_length: {input_length}")
    print(f"[DEBUG] output length: {len(outputs[0])}")
    print(f"[DEBUG] generated tokens count: {len(generated_tokens)}")
    print(f"[DEBUG] generated_tokens raw: {generated_tokens[:10]}")

    answer = tokenizer.decode(generated_tokens, skip_special_tokens=True)
    print(f"[DEBUG] decoded answer: '{answer[:100]}'")

    return answer.strip()


def test():
    from prompt.template import build_prompt

    question = "계약서에 도장 안 찍으면 어떻게 되나요?"
    context = """[문서 1] (민사법 - 법령)
민법 제563조에 따르면 매매계약은 당사자 일방이 재산권을 상대방에게 이전할 것을 약정하고,
상대방이 그 대금을 지급할 것을 약정함으로써 효력이 생긴다.
계약은 원칙적으로 당사자 간의 합의만으로 성립하며, 서면이나 날인이 필수 요건은 아니다."""

    test_cases = [
        {"age": 8,  "label": "8세 (어린이)"},
        {"age": 25, "label": "25세 (성인)"},
    ]

    for case in test_cases:
        print(f"\n{'='*50}")
        print(f"[{case['label']}] 질문: {question}")
        print(f"{'='*50}")

        prompt = build_prompt(question, context, case["age"])
        answer = generate(prompt["system"], prompt["user"])

        print(f"나이대: {prompt['age_group_label']}")
        print(f"\n[답변]")
        print(answer)


if __name__ == "__main__":
    test()