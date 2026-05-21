"""
EXAONE-3.5-7.8B 모델 로드 & 추론 모듈

변경사항:
- 모델: gemma-3-4b-it → EXAONE-3.5-7.8B-Instruct
- trust_remote_code=True 추가 (EXAONE 필수)
- system 역할 분리 (EXAONE chat template 지원)
- double_quant=True로 VRAM 절약
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
        bnb_4bit_compute_dtype=torch.bfloat16,
        bnb_4bit_use_double_quant=True,  # VRAM 추가 절약
    )


def load_model():
    global _model, _tokenizer

    if _model is not None:
        return _model, _tokenizer

    print(f"[INFO] 모델 로드 중: {settings.MODEL_NAME}")

    _tokenizer = AutoTokenizer.from_pretrained(
        settings.MODEL_NAME,
        trust_remote_code=True,          # EXAONE 필수
        token=settings.HF_TOKEN if settings.HF_TOKEN else None,
    )

    if _tokenizer.pad_token is None:
        _tokenizer.pad_token = _tokenizer.eos_token

    _model = AutoModelForCausalLM.from_pretrained(
        settings.MODEL_NAME,
        quantization_config=_get_bnb_config(),
        device_map="auto",
        dtype=torch.bfloat16,            # torch_dtype → dtype (신버전 transformers)
        trust_remote_code=True,
        attn_implementation="eager",     # Windows는 flash_attention_2 미지원
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

    # EXAONE은 system 역할을 별도로 지원
    messages = [
        {"role": "system",    "content": system_prompt},
        {"role": "user",      "content": user_message},
    ]

    try:
        prompt = tokenizer.apply_chat_template(
            messages,
            tokenize=False,
            add_generation_prompt=True,
        )
    except Exception:
        # EXAONE fallback 템플릿
        prompt = (
            f"[|system|]{system_prompt}[|endofturn|]\n"
            f"[|user|]{user_message}[|endofturn|]\n"
            f"[|assistant|]"
        )

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
            do_sample=settings.DO_SAMPLE,
            temperature=settings.TEMPERATURE if settings.DO_SAMPLE else None,
            top_p=settings.TOP_P if settings.DO_SAMPLE else None,
            pad_token_id=tokenizer.eos_token_id,
            eos_token_id=tokenizer.eos_token_id,
            repetition_penalty=1.1,
        )

    input_length     = inputs["input_ids"].shape[1]
    generated_tokens = outputs[0][input_length:]
    answer           = tokenizer.decode(generated_tokens, skip_special_tokens=True)

    return answer.strip()


def test():
    from prompt.template import build_prompt

    question = "계약서에 도장 안 찍으면 어떻게 되나요?"
    context = """[문서 1] (민사법 - 법령)
민법 제563조에 따르면 매매계약은 당사자 일방이 재산권을 상대방에게 이전할 것을 약정하고,
상대방이 그 대금을 지급할 것을 약정함으로써 효력이 생긴다.
계약은 원칙적으로 당사자 간의 합의만으로 성립하며, 서면이나 날인이 필수 요건은 아니다."""

    for age in [8, 25, 55]:
        print(f"\n{'='*50}")
        print(f"나이: {age}세")
        print(f"{'='*50}")
        prompt = build_prompt(question, context, age)
        answer = generate(prompt["system"], prompt["user"])
        print(f"나이대: {prompt['age_group_label']}")
        print(f"\n[답변]\n{answer}")


if __name__ == "__main__":
    test()