import json 
path = 'models/exaone_legal_merged/config.json' 
c = json.load(open(path, encoding='utf-8')) 
c['model_type'] = 'llama' 
c['architectures'] = ['LlamaForCausalLM'] 
c.pop('auto_map', None) 
json.dump(c, open(path, 'w', encoding='utf-8'), indent=2, ensure_ascii=False) 
print('완료') 
