# LexAI 배포 가이드 (AWS EC2 g4dn.xlarge)

대상 서버: `g4dn.xlarge` / Ubuntu (Deep Learning OSS Nvidia Driver AMI) / EBS 100GB / 탄력적 IP `3.36.138.239`

**이 문서는 HTTP(탄력적 IP)로 배포를 완주하는 것을 기본 경로로 합니다.**
도메인 연결은 담당자에게 요청해야 하는 작업이라 완료 시점을 통제할 수 없으므로, 배포를 막지 않도록 [부록 A](#부록-a-도메인-연결-후-https-전환)로 분리했습니다. 나중에 도메인이 붙어도 3단계 5분이면 HTTPS로 전환됩니다.

---

## 준비물 확인

| 준비물 | 상태 | 없으면 |
|---|---|---|
| **GitHub에 코드 push 완료** | 직접 수행 | 서버가 `git clone` 으로 받으므로 **필수 선행 조건** |
| 서버 셸 접속 수단 | `.pem`(학교) 또는 EC2 Instance Connect | 아래 참고 |
| 학교 PC의 OpenSearch 인덱스 | 253,207건 | 8단계 대안 참고 |
| 도메인 | 담당자 요청 → 대기 | HTTP로 완주 가능. [부록 A](#부록-a-도메인-연결-후-https-전환) |
| `EC2_SSH_KEY` GitHub Secret | 등록 완료 | 10단계에서 사용 |

> **GPU는 서버(T4)에만 필요합니다.** 작업하는 PC의 사양은 무관합니다. 빌드도 실행도 전부 서버에서 일어나고, 로컬 PC는 SSH 터미널 + 인덱스 원본 제공 역할입니다.

### 셸 접속 수단에 대해

`.pem` 을 GitHub Secrets에 넣어두셨다면 **10단계의 자동 배포는 어디서든 동작합니다.** 다만 Secrets는 write-only라 값을 되꺼낼 수 없고, 최초 구축(clone + `.env` 작성 + sysctl)은 셸이 필요하므로 다음 중 하나가 필요합니다.

1. **`.pem` 파일** — 학교 PC에 있음
2. **EC2 Instance Connect** — 브라우저 접속, `.pem` 불필요
   AWS 콘솔 → 인스턴스 선택 → **연결** → **EC2 Instance Connect**
   HTTPS를 타므로 학교/사내 네트워크의 22번 아웃바운드 차단과 무관합니다.
   단 보안 그룹 22번 인바운드가 **AWS EC2 Instance Connect IP 범위**(또는 임시로 `0.0.0.0/0`)를 허용해야 합니다. 내 IP만 열려 있으면 브라우저 접속이 실패합니다.

> **2번이 되면 인덱스를 제외한 2~7단계는 오늘 노트북에서 진행할 수 있습니다.** 학교가 반드시 필요한 것은 1단계(스냅샷)와 8단계(복원)뿐입니다. 한 번에 하실지 나눠 하실지는 편한 쪽으로 정하세요 — 아래 순서는 어느 쪽이든 그대로 따라가면 됩니다.

---

## 진행 순서

```
[0] 지금 바로: 도메인 연결 요청 발송      → 담당자 대기 (통제 불가 → 부록 A로 분리)

[1] 학교에서 먼저: 스냅샷 생성 + 업로드 착수  → 업로드 대기 (대역폭 의존)
              │
              │  ↓ 업로드 대기 중에 아래를 진행
              │
[2] 서버 접속 & 사전 확인       (5분)
[3] 호스트 준비 (sysctl)        (1분)
[4] 코드 받기 + .env 작성       (10분)
[5] 빌드 & 기동                 (10~20분)
[6] Ollama 모델 준비            (5~10분)
[7] 검증 ① 배선                 (5분)   ← 인덱스 없이도 여기까지 전부 검증됨
              │
[8] 인덱스 복원                 (10분)  ← [1]의 업로드 완료 후
[9] 검증 ② 응답 품질            (10분)
[10] 자동 배포 확인             (10분)

── 이후 도메인 연결 통보를 받으면 → 부록 A (5분)
```

> **순서를 바꾸면 반드시 문제가 생기는 지점**
> - 수동 배포 성공보다 자동화를 먼저 할 수 없습니다 (10단계)
> - GPU 통과 확인보다 성능 판단을 먼저 할 수 없습니다 (6단계 — CPU 폴백은 조용히 일어납니다)
> - 인덱스 문서 수 확인보다 응답 품질 판단을 먼저 할 수 없습니다 (8→9단계)
> - DNS 전파 확인보다 인증서 발급을 먼저 할 수 없습니다 (부록 A)

---

# 0단계. 도메인 연결 요청 (지금 바로)

담당자가 처리해주는 구조이므로 **소요 시간이 내 통제 밖에 있습니다.** 가장 먼저 요청을 보내두고, 회신을 기다리지 않고 배포를 진행하세요.

요청에 필요한 정보는 이것뿐입니다.

```
연결할 주소 : <원하는 도메인 또는 서브도메인>
레코드 타입 : A
값 (IP)     : 3.36.138.239
TTL         : 300 (낮게 설정 부탁)
```

> **요청 시 함께 확인하면 좋은 것**
> - 연결 완료 후 알려달라고 요청하세요 (전파 확인 시점을 알기 위해)
> - `www` 를 함께 쓸 계획이면 그것도 같이 요청하세요. 나중에 따로 요청하면 대기가 두 번 발생합니다
> - CNAME이 아니라 **A 레코드**여야 합니다. 탄력적 IP를 직접 가리켜야 합니다

회신을 받으면 [부록 A](#부록-a-도메인-연결-후-https-전환)로 가세요. 그때까지는 `http://3.36.138.239` 로 모든 기능이 정상 동작합니다.

---

# 1단계. 스냅샷 생성 + 업로드 착수 (학교 PC)

학교 PC의 로컬 OpenSearch에서 인덱스를 떠서 서버로 보냅니다. 253,207건을 서버에서 다시 임베딩하는 것보다 스냅샷 복원이 훨씬 빠릅니다.

**이 업로드가 일정의 병목입니다. 걸어두고 창을 하나 더 열어 2단계로 넘어가세요.**

## ① 인덱스 이름 확인

코드 기본값은 `legal_documents` 인데 README에는 `legal_docs` 로 적혀 있습니다. **실제 이름을 확인해서 4단계의 `OPENSEARCH_INDEX` 와 일치시켜야 합니다.**

```bash
curl -k -u admin:<비밀번호> "https://localhost:9200/_cat/indices?v"
```

## ② `path.repo` 설정

스냅샷은 `path.repo` 에 등록된 경로에만 만들 수 있습니다. 로컬 OpenSearch가 도커라면 볼륨 마운트와 함께 재기동해야 합니다.

```bash
docker volume ls                  # ★ 기존 인덱스가 담긴 볼륨 이름을 먼저 확인

docker rm -f opensearch
docker run -d --name opensearch \
  -p 9200:9200 -p 9600:9600 \
  -e discovery.type=single-node \
  -e path.repo=/mnt/snapshots \
  -e OPENSEARCH_INITIAL_ADMIN_PASSWORD='<비밀번호>' \
  -v <기존_볼륨_이름>:/usr/share/opensearch/data \
  -v C:/snapshots:/mnt/snapshots \
  opensearchproject/opensearch:2.13.0
```

볼륨 이름을 잘못 지정하면 **빈 클러스터가 떠서 스냅샷할 게 없습니다.** 재기동 후 ①을 다시 실행해 253,207건이 보이는지 확인하고 넘어가세요.

## ③ 스냅샷 생성

```bash
# 저장소 등록
curl -k -u admin:<비밀번호> -X PUT "https://localhost:9200/_snapshot/lexai_repo" \
  -H 'Content-Type: application/json' \
  -d '{"type":"fs","settings":{"location":"/mnt/snapshots"}}'

# 스냅샷 생성 (완료까지 대기)
curl -k -u admin:<비밀번호> -X PUT \
  "https://localhost:9200/_snapshot/lexai_repo/legal_docs_snap?wait_for_completion=true" \
  -H 'Content-Type: application/json' \
  -d '{"indices":"legal_documents","include_global_state":false}'
```

## ④ 압축 후 크기 확인

```bash
tar czf legal_snapshot.tar.gz -C /c/snapshots .
du -sh legal_snapshot.tar.gz      # ★ 크기를 먼저 확인하고 아래 방법을 고릅니다
```

## ⑤ 업로드 착수 — 둘 중 하나

**방법 1: scp 직접 전송** (준비물이 적음 — 학교에서 `.pem` 이 손에 있을 때)

```bash
scp -i <키>.pem legal_snapshot.tar.gz ubuntu@3.36.138.239:~/
```

**방법 2: S3 경유** (중단되어도 재개 가능 — 파일이 크거나 업로드가 느릴 때)

```bash
aws s3 cp legal_snapshot.tar.gz s3://<버킷>/legal_snapshot.tar.gz
```

> `scp` 는 중간에 끊기면 처음부터 다시 해야 합니다. 파일이 몇 GB이고 학교 업로드가 느리면 S3가 안전합니다. 다만 S3는 학교 PC에 AWS CLI와 자격증명 설정이 필요합니다.

---

# 2단계. 서버 접속 & 사전 확인

```bash
chmod 400 <키>.pem                       # 권한이 열려 있으면 ssh 가 키를 거부합니다
ssh -i <키>.pem ubuntu@3.36.138.239
```

`.pem` 이 없거나 22번이 막혔으면 AWS 콘솔의 **EC2 Instance Connect** 로 접속하세요 (준비물 항목 참고).

접속 후 3가지를 확인합니다.

```bash
nvidia-smi                 # T4 16GB 인식 확인
docker compose version     # v2 플러그인 확인
df -h /                    # ★ 여유 공간 확인
```

`df -h` 가 중요합니다. PyTorch DLAMI는 AMI 자체가 디스크를 많이 씁니다. **여유가 40GB 미만이면** DLAMI 기본 conda 환경을 정리하세요 (모든 서비스를 컨테이너로 돌리므로 호스트 PyTorch는 쓰지 않습니다).

**보안 그룹 인바운드** (EC2 콘솔에서 확인):

| 포트 | 소스 | 용도 |
|---|---|---|
| 22 | 내 IP (또는 Instance Connect 사용 시 해당 범위) | SSH |
| 80 | 0.0.0.0/0 | HTTP / 나중에 ACME 도메인 검증 |
| 443 | 0.0.0.0/0 | HTTPS (도메인 연결 후 사용) |

**9200 / 11434 / 3306 은 절대 열지 마세요.** OpenSearch와 Ollama는 인증이 없어 인터넷에 노출되면 즉시 남용됩니다. 이 구성에서는 세 포트 모두 도커 내부 네트워크에만 존재합니다.

443은 지금 쓰지 않더라도 미리 열어두면 부록 A에서 추가 작업이 없습니다.

---

# 3단계. 호스트 준비

OpenSearch는 `vm.max_map_count` 가 낮으면 **부팅에 실패합니다.** 재부팅 후에도 유지되도록 설정합니다.

```bash
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-opensearch.conf
sudo sysctl --system
sysctl vm.max_map_count        # 262144 확인
```

---

# 4단계. 코드 받기 + `.env` 작성

```bash
cd ~
git clone <저장소 URL> legal-rag-chatbot
cd legal-rag-chatbot

cp .env.example .env
```

비밀값을 생성합니다.

```bash
openssl rand -base64 48      # JWT_SECRET 용
openssl rand -base64 24      # DB 비밀번호 용
```

`nano .env` 로 열어 **반드시 바꿔야 하는 항목**을 채웁니다.

| 변수 | 비고 |
|---|---|
| `MYSQL_ROOT_PASSWORD` | 새 값 |
| `DB_PASSWORD` | 새 값 — 기존 `Legal1234!` 는 git 히스토리에 노출되어 있어 재사용 금지 |
| `JWT_SECRET` | 새 값 — 위와 동일한 이유. 32자 이상 |
| `OPENSEARCH_PASSWORD` | 새 값. 대·소문자 + 숫자 + 특수문자 |
| `OPENSEARCH_INDEX` | **1단계 ①에서 확인한 실제 인덱스 이름** |
| `SITE_ADDRESS` | **`:80` 그대로 둡니다** — 도메인 연결 후 부록 A에서 변경 |

> 값에 `$` 가 들어가면 docker compose가 변수로 해석합니다. `$$` 로 이스케이프하세요.

---

# 5단계. 빌드 & 기동

```bash
docker compose build          # 최초 빌드는 10~20분 (Maven + pip)
docker compose up -d
docker compose ps
```

**뜬 것과 동작하는 것은 다릅니다.** 순서대로 확인합니다.

```bash
# ① 컨테이너 상태 — 모두 running / healthy 인지
docker compose ps

# ② OpenSearch (가장 먼저 healthy 가 되어야 함)
docker compose logs opensearch | tail -30

# ③ MySQL 스키마 — users 테이블이 생성됐는지
docker compose exec mysql mysql -u root -p"$(grep MYSQL_ROOT_PASSWORD .env | cut -d= -f2-)" \
  -e "USE legal_chatbot; SHOW TABLES; DESCRIBE users;"

# ④ AI 서버 — lifespan 에서 임베딩 모델(450MB)을 받으므로 최초 1~3분 걸립니다
docker compose logs -f ai      # "[SUCCESS] 서버 준비 완료" 를 기다립니다

# ⑤ Tomcat — entrypoint 가 db.properties 를 만들었는지
docker compose logs tomcat | head -20
```

실패는 대부분 환경변수 오타나 서비스 이름 불일치이며 로그에 그대로 찍힙니다. `tomcat` 은 필수 환경변수가 비어 있으면 `[FATAL]` 을 남기고 즉시 죽습니다.

---

# 6단계. Ollama 모델 준비 (최초 1회)

```bash
bash deploy/ollama-init.sh
```

이 스크립트가 하는 일:

1. 컨테이너가 **GPU를 인식하는지 확인** — 여기서 실패하면 추론이 조용히 CPU로 떨어져 응답이 1~3분이 됩니다
2. 베이스 모델 다운로드 (`gemma3:4b-it-q8_0` → 실패 시 `gemma3:4b` 폴백)
3. 원본 Modelfile의 파라미터(temperature 0.1 등)를 적용해 `legal-gemma` 생성

> **학교 PC의 GGUF 파일은 필요하지 않습니다.** `ai/gguf/gemma_base/Modelfile` 을 보면 현재 `legal-gemma` 는 파인튜닝 모델이 아니라 구글 원본 Gemma 3 4B Instruct + 파라미터 튜닝 조합입니다. 서버가 직접 받으면 같은 가중치이므로 5GB 전송이 불필요합니다.

실제 추론 확인:

```bash
docker exec -it lexai-ollama ollama run legal-gemma "계약이 무엇인가요?"
```

**GPU면 수 초 내에 토큰이 흐릅니다.** 30초가 지나도 조용하면 CPU 폴백을 의심하고 확인하세요.

```bash
docker exec lexai-ollama nvidia-smi
```

---

# 7단계. 검증 ① 배선 (인덱스 없이 가능)

인덱스가 아직 비어 있어도 여기까지는 전부 검증됩니다. `ai/rag/pipeline.py` 가 검색 0건일 때 LLM을 호출하지 않고 안내 문구를 200으로 반환하기 때문입니다.

```bash
BASE=http://localhost        # 서버 안에서 실행

# ① 회원가입 → 200 (MySQL 연결 + 스키마 확인)
curl -i -X POST $BASE/api/auth/signup \
  -H 'Content-Type: application/json' \
  -d '{"username":"testuser","password":"test1234","age":30}'

# ② 로그인 → 200 + token
TOKEN=$(curl -s -X POST $BASE/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"testuser","password":"test1234"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
echo "$TOKEN"

# ③ 토큰 없이 채팅 → 401 (JwtFilter 동작 확인)
curl -i -X POST $BASE/api/chat \
  -H 'Content-Type: application/json' \
  -d '{"question":"계약이 뭔가요?","lawCategory":null}'

# ④ 토큰으로 채팅 → 200
#    인덱스 적재 전이면 answer = "관련 법률 문서를 찾을 수 없습니다."
#    ★ 이 응답이 나오면 프론트 → Tomcat → FastAPI → OpenSearch 전 구간 배선이 정상입니다
curl -i -X POST $BASE/api/chat \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"question":"계약이 뭔가요?","lawCategory":null}'
```

**상태 코드 읽는 법** — 원인이 완전히 다릅니다.

| 응답 | 원인 |
|---|---|
| `401` | 토큰 없음 / 만료 / 시크릿 불일치 → `JwtFilter` |
| `404` | 프록시 경로 또는 컨텍스트 경로 문제 → Caddyfile / WAR 배포 위치 |
| `500` | DB 연결, 스키마 없음, FastAPI 예외 → `docker compose logs tomcat ai` |
| `502` | 업스트림이 아직 안 떴음 (특히 `ai` 최초 기동 중) |
| `504` | 업스트림 타임아웃 → 추론이 CPU로 떨어졌을 가능성 |

브라우저에서 `http://3.36.138.239` 에 접속해 회원가입·로그인도 해보세요. 개발자도구 **Network 탭의 상태 코드**가 가장 빠른 진단 도구입니다.

> 브라우저가 "안전하지 않음" 을 표시하는 것은 정상입니다. HTTP라서 그렇고, 도메인 연결 후 부록 A를 진행하면 사라집니다. **기능은 전부 정상 동작합니다** — 이 프로젝트는 세션 쿠키가 아니라 localStorage JWT를 쓰기 때문에 `Secure` / `SameSite` 로 로그인이 깨지는 문제가 없습니다.

---

# 8단계. 인덱스 복원

1단계의 업로드가 끝났으면 복원합니다.

```bash
cd ~/legal-rag-chatbot

# scp 로 홈 디렉터리에 올린 경우
tar xzf ~/legal_snapshot.tar.gz -C deploy/snapshots/

# S3 를 쓴 경우
# aws s3 cp s3://<버킷>/legal_snapshot.tar.gz .
# tar xzf legal_snapshot.tar.gz -C deploy/snapshots/

sudo chown -R 1000:1000 deploy/snapshots     # OpenSearch 컨테이너 uid
```

복원 명령을 실행합니다.

```bash
OS_PW=$(grep OPENSEARCH_PASSWORD .env | cut -d= -f2-)
OS="docker compose exec -T opensearch curl -sk -u admin:$OS_PW"

# 저장소 등록 (path.repo 는 compose 에 이미 설정되어 있습니다)
$OS -X PUT "https://localhost:9200/_snapshot/lexai_repo" \
  -H 'Content-Type: application/json' \
  -d '{"type":"fs","settings":{"location":"/mnt/snapshots"}}'

# 스냅샷 목록 확인 — 여기서 안 보이면 압축 해제 경로나 권한 문제입니다
$OS "https://localhost:9200/_snapshot/lexai_repo/_all?pretty"

# 복원
$OS -X POST "https://localhost:9200/_snapshot/lexai_repo/legal_docs_snap/_restore?wait_for_completion=true" \
  -H 'Content-Type: application/json' \
  -d '{"indices":"legal_documents","include_global_state":false}'

# ★ 문서 수 확인 — 253207 이 나와야 합니다. 0 이면 이후 검증이 무의미합니다.
$OS "https://localhost:9200/legal_documents/_count?pretty"
```

복원 후 AI 서버를 재시작해 인덱스를 다시 잡게 합니다.

```bash
docker compose restart ai
docker compose logs -f ai      # "[SUCCESS] 서버 준비 완료" 대기
```

### 대안 (스냅샷이 어려울 때)

`ai/indexing/index_builder.py` 로 서버에서 재인덱싱할 수 있습니다. T4를 쓰면 임베딩 자체는 30분~1시간이면 끝나지만, **AIHub 원본 데이터를 서버로 올려야 하고 그 용량이 스냅샷보다 큽니다.** 또한 배포 이미지는 CPU 전용 torch로 만들어져 있어 GPU 임베딩을 쓰려면 `ai/Dockerfile` 의 `--index-url` 을 제거하고 `ai` 서비스에 GPU 예약을 추가해야 합니다. 스냅샷 경로를 먼저 시도하세요.

---

# 9단계. 검증 ② 응답 품질

7단계의 ④를 다시 호출합니다. 이번에는 실제 답변과 `sources` 가 와야 합니다.

```bash
BASE=http://3.36.138.239        # 도메인 연결 후에는 https://<도메인>

TOKEN=$(curl -s -X POST $BASE/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"testuser","password":"test1234"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')

curl -s -X POST $BASE/api/chat \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"question":"계약은 언제 성립하나요?","lawCategory":null}' | python3 -m json.tool
```

확인 항목:

- `answer` 에 실제 법률 답변이 있는지
- `sources` 가 비어 있지 않은지
- **나이대별 문체 분기** — 나이가 다른 계정 두 개(예: 10세 / 45세)로 같은 질문을 던져 말투가 실제로 달라지는지
- 응답 시간 — T4 기준 20~30초. 1분을 넘으면 CPU 폴백을 의심 (6단계로 돌아가 확인)

마지막으로 브라우저에서 회원가입 → 로그인 → 채팅을 한 번 통과시켜 보세요.

---

# 10단계. 자동 배포 확인

수동 배포와 검증이 끝난 **다음에** 켭니다. 수동으로 성공하지 못한 배포를 자동화하면 실패 원인이 두 배로 늘어납니다.

`EC2_SSH_KEY` 는 이미 등록되어 있으니, 나머지 두 개만 확인하면 됩니다.

1. GitHub → Settings → Secrets and variables → Actions 에서 확인/추가:
   - `EC2_SSH_KEY` — **등록 완료**
   - `EC2_HOST` = `3.36.138.239`
   - `EC2_USER` = `ubuntu`
2. Actions 탭에서 **Deploy to EC2** → **Run workflow** 로 수동 실행해 성공 확인
3. 성공하면 `.github/workflows/deploy.yml` 의 `push` 트리거 주석을 해제

```yaml
# 주석 해제 후
on:
  workflow_dispatch:
  push:
    branches:
      - main
```

이 단계를 마치면 **`.pem` 이 없는 PC에서도 push만으로 배포됩니다.** 오늘 여기까지 해두면 "키가 학교에 있어서 못 한다"는 상황이 반복되지 않습니다.

모델·인덱스 적재는 자동화에 포함하지 않았습니다. 매 푸시마다 5GB 모델을 다시 만들면 배포가 몇십 분이 됩니다. 자산은 볼륨에 남고 코드만 재빌드됩니다.

---

# 부록 A. 도메인 연결 후 HTTPS 전환

담당자로부터 **연결 완료 회신을 받은 뒤에** 진행합니다. 인증서 자동 발급이 도메인 확인에 의존하므로, 전파 전에 전환하면 발급이 실패합니다.

## ① 전파 확인 (가장 중요)

```bash
dig +short <도메인>
# dig 가 없으면: nslookup <도메인>
```

**`3.36.138.239` 가 출력되어야 합니다.** 아무것도 안 나오거나 다른 IP가 나오면 아직 전파 중이거나 레코드가 잘못 등록된 것입니다. 이 상태에서 전환하면 안 됩니다.

담당자가 완료했다고 해도 전파에 시간이 걸릴 수 있습니다. 확인될 때까지 기다리세요 — 전환 자체는 5분이면 끝나므로 서두를 이유가 없습니다.

## ② 전환

```bash
cd ~/legal-rag-chatbot
nano .env
```

`SITE_ADDRESS` 를 바꿉니다.

```diff
- SITE_ADDRESS=:80
+ SITE_ADDRESS=<도메인>
```

> `www` 도 함께 연결했다면 쉼표로 둘 다 적을 수 있습니다:
> `SITE_ADDRESS=example.com, www.example.com`

환경변수 변경은 **재시작이 아니라 재생성**이 필요합니다.

```bash
docker compose up -d caddy
```

## ③ 발급 확인

```bash
docker compose logs -f caddy     # "certificate obtained successfully" 확인
curl -I https://<도메인>
```

브라우저로 `https://<도메인>` 에 접속해 자물쇠 표시를 확인하고, 로그인 → 채팅을 한 번 통과시켜 보세요.

애플리케이션 쪽은 **수정할 것이 없습니다.** 프론트엔드가 이미 상대경로(`/api/...`)만 사용하므로 mixed content 문제가 발생하지 않고, localStorage JWT라서 쿠키 속성 변경도 불필요합니다.

## 실패했을 때

| 증상 | 원인 |
|---|---|
| `no such host` / 발급 시도조차 안 함 | DNS 전파 미완료. ①로 돌아가세요 |
| ACME 검증 실패 | 80 포트가 막혔거나 보안 그룹에서 차단. 검증은 80을 통해 이루어집니다 |
| `too many certificates already issued` | 발급 재시도를 반복해 rate limit에 걸림. 1주일 대기하거나 서브도메인 변경 |

인증서는 `caddy_data` 볼륨에 저장됩니다. **이 볼륨을 지우면 재발급이 필요하고 rate limit 위험이 있으니 지우지 마세요.**

## ④ 전환이 확인된 다음에

HTTPS가 확실히 동작하는 것을 확인한 뒤에 HSTS를 켜세요 (`deploy/Caddyfile` 하단 참고). 먼저 켜면 문제가 생겼을 때 브라우저가 HTTP로 되돌아가지 못합니다.

---

# 이후 운영 규칙

## 변경 종류별 반영 방법

| 바꾼 것 | 필요한 조치 |
|---|---|
| 코드 / 정적 파일 (HTML, Java, Python) | `docker compose build <서비스> && docker compose up -d` |
| 환경변수 (`.env`) | `docker compose up -d` — **재생성**이 필요. `restart` 로는 반영되지 않습니다 |
| Caddyfile | `docker compose up -d caddy` |
| 스키마 (`init.sql`) | 이미 데이터가 있으면 실행되지 않습니다. 직접 `ALTER TABLE` 하세요 |

## 고쳤는데 화면이 그대로일 때

브라우저 캐시부터 의심하세요. 서버가 실제로 무엇을 주고 있는지 직접 받아보면 5초 만에 판별됩니다.

```bash
curl -s $BASE/chat.html | grep "url:"      # /api/chat 으로 바뀌어 있는지
```

## 인스턴스를 끌 때 (비용 관리)

g4dn.xlarge는 시간당 $0.6 전후입니다. 필요할 때만 켜는 운영이 합리적입니다.

- **탄력적 IP는 정지해도 유지**되므로 도메인 연결과 인증서는 그대로 살아있습니다
- **★ g4dn의 125GB NVMe는 임시 스토리지라 stop/start 시 삭제됩니다.** 이 구성의 볼륨은 모두 도커 기본 위치(루트 EBS)에 있으므로 안전하지만, 성능을 이유로 볼륨을 NVMe로 옮기면 **인덱스와 모델이 사라집니다**
- 재기동 후 `ai` 컨테이너가 healthy가 되기까지 1~3분 걸립니다 (임베딩 모델 로드)

## 세션

JWT는 상태를 서버에 두지 않으므로 **재기동해도 로그인이 유지됩니다.** 토큰 만료(기본 24시간)까지 유효합니다. 단 `JWT_SECRET` 을 바꾸면 발급된 모든 토큰이 무효화되어 전원 재로그인이 필요합니다.

---

# 트러블슈팅

| 증상 | 원인 / 확인 |
|---|---|
| SSH 접속 불가 | 22번 아웃바운드 차단 → AWS 콘솔의 EC2 Instance Connect 사용. 또는 `.pem` 권한(`chmod 400`), 보안 그룹 인바운드 확인 |
| `opensearch` 가 기동 직후 종료 | `vm.max_map_count` 미설정(3단계) 또는 `OPENSEARCH_PASSWORD` 복잡도 미달 |
| `tomcat` 이 `[FATAL]` 남기고 종료 | `.env` 의 `DB_URL`/`DB_PASSWORD`/`JWT_SECRET` 누락 또는 시크릿 32자 미만 |
| 회원가입 500 | `users` 테이블 없음 → `mysql_data` 볼륨이 이미 있는 상태로 `init.sql` 을 추가한 경우. 직접 생성 |
| 채팅 응답이 1~3분 | GPU 폴백. `docker exec lexai-ollama nvidia-smi` 확인 |
| 채팅이 항상 "찾을 수 없습니다" | 인덱스 비어 있음 또는 `OPENSEARCH_INDEX` 이름 불일치. `_count` 와 `_cat/indices` 확인 |
| 스냅샷 목록이 비어 있음 | 압축 해제 경로가 `deploy/snapshots/` 최상단이 아님, 또는 `chown 1000:1000` 누락 |
| 로컬 스냅샷 생성 시 인덱스가 안 보임 | 재기동 시 볼륨 이름을 잘못 지정해 빈 클러스터가 뜬 경우 (1단계 ②) |
| 인증서 발급 실패 | 부록 A의 실패 표 참고 |
| 빌드 중 디스크 부족 | `docker system prune -a` 후 `df -h`. DLAMI 기본 conda 환경 정리 |
| `docker compose build` 에서 `--mount` 오류 | BuildKit 비활성. `DOCKER_BUILDKIT=1 docker compose build` |
