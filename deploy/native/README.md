# 네이티브 배포 스크립트

컨테이너 없이 호스트에 직접 설치해 서비스를 기동합니다. CSP 이관 검증용이며,
Docker Compose 구성(`docker-compose.yml`)과 같은 저장소를 공유합니다.

두 형태는 **같은 포트(9200 · 11434)를 쓰므로 동시에 띄울 수 없습니다.**
전환할 때는 한쪽을 완전히 내리세요.

## 구성

| | Docker Compose | 네이티브 |
| --- | --- | --- |
| DB | SQLite 파일 (`lexai_data` 볼륨) | **SQLite 파일** (`~/lexai-data`) |
| 검색 | OpenSearch 컨테이너 | OpenSearch tarball |
| LLM | Ollama 컨테이너 (+ toolkit) | Ollama systemd 서비스 |
| 앱 | 컨테이너 3개 | systemd 유닛 3개 |
| 진입물 | `deploy/compose/deploy.sh` | `deploy/native/bootstrap.sh` |
| 타겟에 필요한 것 | compose 정의 3개 + 이미지 | 저장소 소스 |

MySQL · Redis · Caddy 는 2026-09 이관 검증에 맞춰 양쪽 모두에서 걷어냈습니다
(각각 SQLite 파일 · 비활성화 · 프론트의 `/api` 프록시로 대체).

## 새 환경에 올릴 때 — 한 줄

사람이 하는 일은 **VM 생성과 SSH 접속까지**입니다. 그 뒤는 이 한 줄이
코드 확보 · 시크릿 발급 · GPU 드라이버 · 설치 · 데이터 복원 · 기동 · 검증을
무인으로 수행합니다.

```bash
curl -fsSL https://raw.githubusercontent.com/YunHwa0905/legal-rag-chatbot/feat/sqlite/deploy/native/bootstrap.sh | bash
```

이관 패키지가 오브젝트 스토리지에 있으면 위치를 알려주세요. 색인과 DB 까지
받아서 복원합니다.

```bash
curl -fsSL <위 주소> | SNAPSHOT_URI=s3://버킷/lexai/20260922-1530 bash
```

드라이버가 없는 인스턴스라면 설치 후 **스스로 재부팅하고, 부팅이 끝나면
같은 지점부터 자동으로 이어서 진행합니다.** 재접속해서 명령을 다시 칠
필요가 없고, 진행 상황은 이렇게 봅니다.

```bash
journalctl -u lexai-bootstrap-resume -f
```

| 환경변수 | 기본값 | 용도 |
| --- | --- | --- |
| `BRANCH` | `feat/sqlite` | 받을 브랜치 |
| `SNAPSHOT_URI` | — | 이관 패키지 위치 (`s3://` · `gs://` · `https://`) |
| `SKIP_DRIVER=1` | — | GPU 이미지를 쓰는 경우 드라이버 설치 생략 |
| `NO_START=1` | — | 준비만 하고 기동은 하지 않음 |
| `TARGET_USER` | uid 1000 | root 로 실행될 때 서비스를 돌릴 사용자 |

**이관 도구가 호출하는 경우** — CB-Tumblebug 의 `postCommands` 처럼 root 로
실행되면, 대상 사용자를 정해 저장소를 그 사용자로 받은 뒤 같은 스크립트를
그 사용자로 다시 실행합니다. 서비스가 `/root` 아래에 설치되어 나중에 사람이
SSH 로 붙었을 때 아무것도 안 보이는 상황을 막기 위해서입니다.

TTY 가 없으면 색상 제어문자를 출력하지 않고, `apt` 가 질문을 던지지 않도록
비대화형으로 동작합니다.

시크릿(`JWT_SECRET` · `OPENSEARCH_PASSWORD`)은 자동 발급되어 `.env` 에 들어가고,
사본이 `~/.lexai-secrets` 에 남습니다. **이관 시 대상 환경에 같은 값을 넣어야**
기존 색인에 접속할 수 있습니다.

## 이미 올라간 환경에서

평소에는 이 두 개만 쓰면 됩니다.

```bash
bash deploy/native/up.sh         # 설치 → 데이터 준비 → 기동 → 검증
bash deploy/native/stop.sh       # 종료
```

`up.sh` 는 백지 상태에서도, 이미 다 깔린 상태에서도 그대로 동작합니다.
각 단계가 멱등이라 이미 된 항목은 건너뜁니다. 단계별 소요 시간을 출력하므로
이관 예상 시간을 재는 용도로도 쓸 수 있습니다.

```bash
bash deploy/native/up.sh --skip-install    # 재기동만
bash deploy/native/up.sh --skip-verify
```

개별 단계를 직접 부를 수도 있습니다.

```bash
bash deploy/native/install.sh    # 런타임·OpenSearch·Ollama 설치
bash deploy/native/restore.sh    # 스키마·모델·색인 준비
bash deploy/native/start.sh      # 기동
bash deploy/native/verify.sh     # 합격 기준 판정
bash deploy/native/backup.sh     # 이관 패키지 생성
bash deploy/native/bootstrap.sh  # 위 전체를 새 환경에서 한 번에 (보통 curl 로 실행)
```

개별 대상만 다루려면 인자를 주세요.

```bash
bash deploy/native/start.sh opensearch
bash deploy/native/stop.sh frontend
```

## 사전 준비

`.env` 에 다음이 있어야 합니다 (`.env.example` 참고).

```
OPENSEARCH_PASSWORD=...
JWT_SECRET=...            # 32자 이상
TZ=Asia/Seoul
```

색인 데이터는 스냅샷으로 옮깁니다. `backup.sh` 산출물을 `~/lexai-snapshots` 에
풀어두면 `restore.sh` 가 복원합니다. 없으면 `restore.sh` 가 거기서 멈춥니다 —
색인 없이 기동하면 서비스는 정상으로 보이는데 답변만 근거 없이 나옵니다.

## 경로

| | 기본값 | 환경변수 |
| --- | --- | --- |
| 저장소 | `~/legal-rag-chatbot` | `REPO_DIR` |
| OpenSearch | `~/opensearch-2.13.0` | `OPENSEARCH_HOME` |
| 스냅샷 | `~/lexai-snapshots` | `SNAPSHOT_DIR` |
| DB 파일 | `~/lexai-data/lexai.db` | `DB_PATH` |
| 로그·PID | `~/lexai-run/` | `RUN_DIR` |

## 검증 결과 누적

`verify.sh` 는 실행할 때마다 `~/lexai-run/results.csv` 에 한 줄을 더합니다.
환경을 오갈 때 같은 기준으로 비교하기 위한 것입니다.

```
timestamp,form,pass,fail,cold_sec,warm_sec,sources,os_docs,db_msgs,result
```

환경 이름을 붙이려면 `FORM=gcp-shell bash deploy/native/verify.sh`.

## 이 스크립트들이 막아주는 함정

전부 실제로 한 번씩 겪은 것들입니다.

| | 증상 |
| --- | --- |
| `LD_LIBRARY_PATH` 에 k-NN 라이브러리 경로 | 없으면 **벡터 검색이 들어오는 순간 노드가 죽음**. BM25 만으로는 멀쩡해서 기동 확인으로는 안 잡힘 |
| `opensearch.yml` 은 지우고 다시 추가 | 덧붙이면 중복 키로 기동 즉시 실패 |
| 스냅샷 복원 허용 설정 2줄 | 없으면 복원이 403 (`no permissions for []`) |
| 스냅샷 디렉터리 소유권 | 컨테이너(uid 1000) ↔ 네이티브(ubuntu) 불일치 시 `access_denied` |
| DB 절대경로 | 상대경로면 실행 위치를 따라가 빈 DB 를 새로 만들고 첫 회원가입이 500 |
| `TZ=Asia/Seoul` | 없으면 시각이 UTC 로 기록되어 9시간 어긋남 |
| `127.0.0.1` (localhost 아님) | Node 17+ 에서 `::1` 로 해석되어 연결 거부 |
| 환경변수는 `.env` 에서 로드 | 창마다 export 하면 한 곳에서 누락되어 401 |

## 이관 절차

기존 환경에서:

```bash
bash deploy/native/backup.sh
# ~/lexai-backup/<시각>/ 을 오브젝트 스토리지로 전송
```

대상 환경에서: 패키지의 `MANIFEST.txt` 에 순서가 적혀 있습니다.
LLM 모델과 임베딩 모델은 옮기지 않습니다 — 대상에서 자동으로 받습니다.
