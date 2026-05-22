"""
03. 파인튜닝 모델 병합 및 저장/HuggingFace 업로드

역할:
- 베이스 모델 + LoRA 어댑터 로드
- 어댑터 병합(merge_and_unload)
- 로컬 저장 + HuggingFace 업로드

수정 포인트:
- NEW_MODEL: 02에서 저장된 어댑터 로컬 경로
- HF_UPLOAD_REPO: 업로드할 HuggingFace 저장소명
- MERGED_SAVE_PATH: 병합 모델 로컬 저장 경로
"""

import os
import torch
import huggingface_hub
from dotenv import load_dotenv
from transformers import AutoModelForCausalLM, AutoTokenizer
from peft import PeftModel, PeftConfig

load_dotenv()

# ===========================
# 설정 (수정 포인트)
# ===========================
BASE_MODEL        = "LGAI-EXAONE/EXAONE-3.5-7.8B-Instruct"
REVISION          = "0ff6b5ec7c13b049b253a16a889aa269e6b79a94"  # transformers 4.51 호환
NEW_MODEL         = "./models/EXAONE-3.5-7.8B-Instruct_2026_05_22_12"  # 어댑터 경로
MERGED_SAVE_PATH  = "D:/models/exaone_legal_merged"              # 병합 모델 로컬 저장
HF_UPLOAD_REPO    = "yunhwa/legal_chatbot_exaone"
HF_TOKEN          = os.getenv("HF_TOKEN")

# ===========================
# HuggingFace 로그인
# ===========================
huggingface_hub.login(token=HF_TOKEN)
print(f"[SUCCESS] HuggingFace 로그인 완료")

# ===========================
# 1. 베이스 모델 로드
# ===========================
print(f"\n[INFO] 베이스 모델 로드 중: {BASE_MODEL}")
base_model = AutoModelForCausalLM.from_pretrained(
    BASE_MODEL,
    revision=REVISION,
    low_cpu_mem_usage=True,
    return_dict=True,
    torch_dtype=torch.bfloat16,
    trust_remote_code=True,
)
print(f"[SUCCESS] 베이스 모델 로드 완료")

# ===========================
# 2. 토크나이저 로드
# ===========================
print(f"\n[INFO] 토크나이저 로드 중")
tokenizer = AutoTokenizer.from_pretrained(
    BASE_MODEL,
    revision=REVISION,
    trust_remote_code=True,
)
tokenizer.pad_token    = tokenizer.eos_token
tokenizer.padding_side = "right"
print(f"[SUCCESS] 토크나이저 로드 완료")

# ===========================
# 3. LoRA 어댑터 적용
# ===========================
print(f"\n[INFO] 어댑터 로드 중: {NEW_MODEL}")
peft_config = PeftConfig.from_pretrained(NEW_MODEL)
print(f"  LoRA rank: {peft_config.r}")
print(f"  target modules: {peft_config.target_modules}")

model = PeftModel.from_pretrained(base_model, NEW_MODEL)
print(f"[SUCCESS] 어댑터 적용 완료")

# ===========================
# 4. 어댑터 병합
# ===========================
print(f"\n[INFO] 어댑터 병합 중... (시간이 걸릴 수 있습니다)")
merged_model = model.merge_and_unload()
print(f"[SUCCESS] 병합 완료")

# ===========================
# 5. 로컬 저장
# ===========================
print(f"\n[INFO] 로컬 저장 중: {MERGED_SAVE_PATH}")
os.makedirs(MERGED_SAVE_PATH, exist_ok=True)

merged_model.save_pretrained(MERGED_SAVE_PATH, safe_serialization=False)
tokenizer.save_pretrained(MERGED_SAVE_PATH)

print(f"[SUCCESS] 로컬 저장 완료: {MERGED_SAVE_PATH}")

# 저장된 파일 목록 출력
files = os.listdir(MERGED_SAVE_PATH)
total_size = sum(
    os.path.getsize(os.path.join(MERGED_SAVE_PATH, f))
    for f in files
)
print(f"  저장 파일 수: {len(files)}개")
print(f"  총 크기: {total_size / (1024**3):.1f}GB")

# ===========================
# 6. HuggingFace 업로드
# ===========================
print(f"\n[INFO] HuggingFace 업로드 중: {HF_UPLOAD_REPO}")
merged_model.push_to_hub(HF_UPLOAD_REPO, token=HF_TOKEN, safe_serialization=True)
tokenizer.push_to_hub(HF_UPLOAD_REPO, token=HF_TOKEN)
print(f"[SUCCESS] 업로드 완료: https://huggingface.co/{HF_UPLOAD_REPO}")

print(f"\n{'='*60}")
print(f"완료!")
print(f"{'='*60}")
print(f"로컬 병합 모델: {MERGED_SAVE_PATH}")
print(f"HF 저장소: https://huggingface.co/{HF_UPLOAD_REPO}")
print(f"\n다음 단계:")
print(f"  python 04_gguf_convert.py")
print(f"  → MERGED_SAVE_PATH를 '{MERGED_SAVE_PATH}'로 설정하면 재다운로드 없이 바로 변환")