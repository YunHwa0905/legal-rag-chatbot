"""
04. GGUF 변환 및 HuggingFace 업로드

흐름:
1. HF에서 병합 모델 다운로드 (03에서 올린 모델)
2. llama.cpp 클론 및 설치
3. safetensors → GGUF 변환
4. HF에 GGUF 파일 업로드

수정 포인트:
- HF_MODEL_REPO: 03에서 올린 병합 모델 저장소명
- GGUF_OUTPUT_NAME: 생성할 GGUF 파일명
- GGUF_OUTTYPE: 양자화 타입 (f16 / q8_0 / q4_0)
- HF_GGUF_REPO: GGUF 파일 업로드할 HF 저장소명
"""

import os
import subprocess
import sys
from huggingface_hub import snapshot_download, HfApi, login
from dotenv import load_dotenv

load_dotenv()

# ===========================
# 설정 (수정 포인트)
# ===========================
HF_TOKEN       = os.getenv("HF_TOKEN")

# 03에서 업로드한 병합 모델
HF_MODEL_REPO  = "yunhwa/legal_chatbot_exaone"

# 모델 다운로드 로컬 경로
MODEL_DIR = "./models/exaone_legal_merged"

# GGUF 변환 설정
# outtype 옵션: f16(16GB, 최고품질) / q8_0(8GB, 권장) / q4_0(4GB, 경량)
GGUF_OUTTYPE   = "q8_0"
GGUF_OUTPUT_NAME = "legal_exaone_q8.gguf"
GGUF_OUTPUT_PATH = f"./gguf/{GGUF_OUTPUT_NAME}"

# GGUF 업로드할 HF 저장소
HF_GGUF_REPO   = "yunhwa/legal_chatbot_exaone_gguf"

# llama.cpp 클론 경로
LLAMA_CPP_DIR  = "./gguf/llama.cpp"


# ===========================
# 유틸: 명령어 실행
# ===========================
def run(cmd: str):
    print(f"\n[CMD] {cmd}")
    result = subprocess.run(cmd, shell=True)
    if result.returncode != 0:
        print(f"[ERROR] 명령어 실패 (returncode={result.returncode})")
        sys.exit(1)


# ===========================
# 1. HuggingFace 로그인
# ===========================
print("=" * 60)
print("GGUF 변환 파이프라인 시작")
print("=" * 60)

login(token=HF_TOKEN)
print(f"[SUCCESS] HuggingFace 로그인 완료")


# ===========================
# 2. 병합 모델 다운로드
# ===========================
# print(f"\n[INFO] 모델 다운로드 중: {HF_MODEL_REPO}")
# os.makedirs(MODEL_DIR, exist_ok=True)

# snapshot_download(
#     repo_id=HF_MODEL_REPO,
#     local_dir=MODEL_DIR,
#     local_dir_use_symlinks=False,
#     revision="main",
#     token=HF_TOKEN,
# )
# print(f"[SUCCESS] 모델 다운로드 완료: {MODEL_DIR}")


# ===========================
# 3. llama.cpp 설치
# ===========================
os.makedirs("./gguf", exist_ok=True)

if not os.path.exists(LLAMA_CPP_DIR):
    print(f"\n[INFO] llama.cpp 클론 중...")
    run(f"git clone https://github.com/ggerganov/llama.cpp {LLAMA_CPP_DIR}")
else:
    print(f"\n[INFO] llama.cpp 이미 존재, 업데이트 중...")
    run(f"git -C {LLAMA_CPP_DIR} pull")

print(f"\n[INFO] llama.cpp requirements 설치 중...")
run(f"pip install -r {LLAMA_CPP_DIR}/requirements.txt")

# mistral_common 누락 시 설치
run("pip install mistral_common==1.8.5 -q")

print(f"[SUCCESS] llama.cpp 설치 완료")


# ===========================
# 4. GGUF 변환
# ===========================
print(f"\n[INFO] GGUF 변환 중...")
print(f"  입력: {MODEL_DIR}")
print(f"  출력: {GGUF_OUTPUT_PATH}")
print(f"  타입: {GGUF_OUTTYPE}")

run(
    f"python {LLAMA_CPP_DIR}/convert_hf_to_gguf.py "
    f"{MODEL_DIR} "
    f"--outfile {GGUF_OUTPUT_PATH} "
    f"--outtype {GGUF_OUTTYPE}"
)

# 변환 결과 확인
if not os.path.exists(GGUF_OUTPUT_PATH):
    print(f"[ERROR] GGUF 파일 생성 실패: {GGUF_OUTPUT_PATH}")
    sys.exit(1)

file_size_gb = os.path.getsize(GGUF_OUTPUT_PATH) / (1024 ** 3)
print(f"[SUCCESS] GGUF 변환 완료: {GGUF_OUTPUT_PATH} ({file_size_gb:.1f}GB)")


# ===========================
# 5. HuggingFace GGUF 업로드
# ===========================
print(f"\n[INFO] HuggingFace 업로드 중: {HF_GGUF_REPO}")

api = HfApi()

# 저장소 없으면 자동 생성
try:
    api.create_repo(
        repo_id=HF_GGUF_REPO,
        repo_type="model",
        exist_ok=True,
        token=HF_TOKEN,
    )
except Exception as e:
    print(f"[WARN] 저장소 생성 중 오류 (이미 존재할 수 있음): {e}")

api.upload_file(
    path_or_fileobj=GGUF_OUTPUT_PATH,
    path_in_repo=GGUF_OUTPUT_NAME,
    repo_id=HF_GGUF_REPO,
    repo_type="model",
    token=HF_TOKEN,
)

print(f"[SUCCESS] 업로드 완료: https://huggingface.co/{HF_GGUF_REPO}")
print(f"\n{'=' * 60}")
print(f"완료!")
print(f"{'=' * 60}")
print(f"GGUF 파일 : {GGUF_OUTPUT_PATH} ({file_size_gb:.1f}GB)")
print(f"HF 저장소 : https://huggingface.co/{HF_GGUF_REPO}")
print(f"\nOllama 사용법:")
print(f"  1. GGUF 다운로드 후 Modelfile 작성")
print(f"  2. ollama create legal-exaone -f Modelfile")
print(f"  3. ollama run legal-exaone")