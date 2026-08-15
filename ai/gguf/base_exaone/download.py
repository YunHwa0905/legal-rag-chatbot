# download.py
from huggingface_hub import hf_hub_download

path = hf_hub_download(
    repo_id="LGAI-EXAONE/EXAONE-3.5-7.8B-Instruct-GGUF",
    filename="EXAONE-3.5-7.8B-Instruct-Q8_0.gguf",
    local_dir="."
)
print(path)