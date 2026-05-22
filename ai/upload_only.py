 
import os
os.environ['HF_HOME'] = 'D:/hf_cache'
from huggingface_hub import HfApi, login
from dotenv import load_dotenv
load_dotenv()

token = os.getenv('HF_TOKEN')
login(token=token)

api = HfApi()
api.upload_folder(
    folder_path='./models/exaone_legal_merged',
    repo_id='yunhwa/legal_chatbot_exaone',
    repo_type='model',
    token=token,
)
print('업로드 완료!')