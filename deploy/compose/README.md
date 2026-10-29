# Docker Compose 배포 스크립트

이관 대상 환경의 **실행 형태 2종 중 컨테이너 쪽** 진입물입니다.
네이티브 형태는 [`../native/`](../native/) 에 있습니다.

## 새 환경에 올릴 때 — 한 줄

사람이 하는 일은 **VM 생성과 SSH 접속까지**입니다.

```bash
curl -fsSL https://raw.githubusercontent.com/YunHwa0905/legal-rag-chatbot/feat/sqlite/deploy/compose/deploy.sh | bash
```

이관 패키지가 오브젝트 스토리지에 있으면 위치를 알려주세요. 색인까지
복원합니다.

```bash
curl -fsSL <위 주소> | SNAPSHOT_URI=s3://버킷/lexai/20260923-1031 bash
```

다른 CSP 의 레지스트리에서 받으려면 접두사만 바꾸면 됩니다.

```bash
curl -fsSL <위 주소> \
  | REGISTRY_PREFIX=asia-northeast3-docker.pkg.dev/<프로젝트>/<저장소> IMAGE_TAG=v3 bash
```

## 네이티브와 갈리는 지점

이 스크립트는 **저장소와 독립적으로 동작합니다.** 타겟에 git 도 소스도
필요 없습니다 — 이미지가 곧 산출물이고, 받는 것은 compose 정의 3개뿐입니다.

| | 네이티브 (`bootstrap.sh`) | 컨테이너 (`deploy.sh`) |
| --- | --- | --- |
| 타겟에 놓이는 것 | 저장소 전체 (clone) | 파일 3개 + 이미지 |
| 빌드 | 타겟에서 Maven · npm | 없음 (pull 전용) |
| GPU | 호스트 드라이버만 | 드라이버 + **nvidia-container-toolkit** |
| 서비스 관리 | `systemctl` (`lexai-*`) | `docker compose` |
| 데이터 위치 | 호스트 `~/lexai-data` | 네임드 볼륨 |

받는 파일 3개는 이렇습니다. 앞의 둘은 compose 정의이고, 세 번째는
`docker-compose.yml` 이 바인드 마운트하는 파일이라 호스트에 있어야 합니다.

```
~/lexai-compose/
  docker-compose.yml            서비스 정의
  docker-compose.registry.yml   build: 제거 + image: 지정
  .env                          시크릿 자동 발급 (600)
  deploy/
    schema.sqlite.sql           tomcat 이 최초 기동 시 스키마 생성
    snapshots/                  OpenSearch path.repo — 색인 복원 위치
```

## 스크립트가 하는 일

1. 기본 도구 확보
2. NVIDIA 드라이버 — 없으면 설치 후 **스스로 재부팅하고, 부팅이 끝나면
   같은 지점부터 자동으로 이어서 진행합니다** (`journalctl -u lexai-compose-resume -f`)
3. Docker 엔진 + nvidia-container-toolkit → **컨테이너를 하나 띄워 GPU 통과 확인**
4. compose 정의 수신 — 브랜치를 **커밋 SHA 로 고정**해서 받고 `DEPLOY_COMMIT` 에 기록
5. `.env` 생성 — JWT · OpenSearch 비밀번호 자동 발급
6. `SNAPSHOT_URI` 가 있으면 패키지 검증 (체크섬 · 커밋 · 배포 파일 · 이미지 digest ·
   압축 해제 결과) → 기존 설치 확인 → 스냅샷 배치
7. 이미지 pull (패키지에 `images.lock` 이 있으면 원본과 같은 digest 로)
8. **기동 전에** DB 를 볼륨에 넣고 데이터 지문 비교 (원본과 행 수 · 내용이 같은지)
9. OpenSearch 만 먼저 띄워 색인 복원
10. 전체 기동 → ai · tomcat · 프론트엔드 준비 확인 → 런타임(Ollama 버전 · 모델 ID) 비교 → 모델 예열
11. `verify.sh` (이관 모드에서는 기본 생략 — DB 에 verify 기록이 남기 때문)

DB 는 네임드 볼륨 안에 있어서, tomcat 이미지로 일회성 컨테이너를 띄워
(`docker compose run --rm --no-deps tomcat`) 서비스를 띄우기 **전에** 넣습니다.
예전처럼 띄운 뒤 `docker cp` 로 덮으면 열린 DB 를 바꿔치기하는 것이라 옛
`-wal`/`-shm` 이 섞일 수 있었습니다.

여러 번 실행해도 안전합니다. 같은 패키지로 다시 돌리면 데이터 단계는 건너뜁니다
(`.package-applied`).

### GPU 통과 확인을 따로 두는 이유

toolkit 이 없으면 **에러 없이 CPU 로 폴백합니다.** 컨테이너는 전부 정상으로
보이는데 응답만 1~3분이 되고, 백엔드의 FastAPI 호출 타임아웃이 180초라
채팅이 실패하기 시작합니다. 증상이 늦게, 엉뚱한 곳에서 드러나므로 기동 전에
실제로 확인합니다.

## 환경변수

전부 선택 사항입니다.

| 이름 | 기본값 | 설명 |
| --- | --- | --- |
| `BRANCH` | `feat/sqlite` | compose 정의를 받을 브랜치 (받는 순간의 커밋으로 고정) |
| `DEPLOY_DIR` | `~/lexai-compose` | 배포 디렉터리 |
| `REGISTRY_PREFIX` | `yunhwa0905` | Docker Hub 계정 또는 레지스트리 주소 |
| `IMAGE_TAG` | `v3` | **고정 태그를 쓰세요** — `latest` 는 추적이 안 됩니다 |
| `SNAPSHOT_URI` | 없음 | 이관 패키지 위치 (로컬 경로 · `s3://` · `gs://` · `https://`) |
| `NO_UPDATE` | `0` | **이관 모드.** 옮겨 온 배포 디렉터리를 그대로 쓰고 하나라도 어긋나면 멈춤 |
| `FORCE_CLEAN` | `0` | 기존 데이터 볼륨이 있어도 진행 (DB 는 `~/lexai-replaced/<시각>` 에 보관, 모델 볼륨 유지) |
| `RUN_VERIFY` | `0` | 이관 모드에서도 `verify.sh` 실행 |
| `SKIP_VERIFY` | `0` | `verify.sh` 생략 |
| `SKIP_WARMUP` | `0` | 모델 예열 생략 |
| `FRONTEND_PORT` | `80` | 프론트엔드 호스트 포트 (`.env` 에 기록) |
| `TARGET_USER` | `cb-user` → uid 1000 | root 로 실행될 때 넘어갈 계정 |
| `SKIP_DRIVER` | `0` | GPU 이미지를 쓰는 경우 `1` |
| `NO_START` | `0` | 준비만 하고 기동은 안 함 |

진행 상황은 `~/lexai-run/status.json` (네이티브와 같은 형식, `form: compose`).
`state` 가 `success` · `failed` 가 될 때까지 폴링하면 됩니다. 실패하면
`failed_phase` · `last_error` 가 남습니다.

## Beetle 로 이관 (배포 디렉터리째)

**데이터(DB · 색인)는 Docker 볼륨(`/var/lib/docker`) 안에 있어 홈 디렉터리
전송으로는 옮겨지지 않습니다.** 반드시 패키지로 옮깁니다.

```bash
# 원본 — 쓰기를 멈추고 패키지 생성 (frontend · tomcat 은 멈춘 채로 둠)
STOP_WRITES=1 bash ~/lexai-compose/backup.sh          # → ~/lexai-backup/latest

# 전송 (Beetle 데이터 마이그레이션 2건)
#   ~/lexai-compose   제외: deploy/snapshots  .restore
#   ~/lexai-backup

# 대상
NO_UPDATE=1 SNAPSHOT_URI=$HOME/lexai-backup/latest bash ~/lexai-compose/deploy.sh
#   이미 LexAI 가 돌던 VM 이면 FORCE_CLEAN=1 추가 (A→B→A 의 두 번째 A)
```

`deploy/snapshots` 를 빼는 이유: 수 GB 이고 OpenSearch(uid 1000) 소유라 cb-user 로
읽고 쓰다 실패합니다. 대상에서 패키지로 다시 만듭니다.

이관 모드에서 멈추는 경우 — 전부 "데이터가 보존됐다" 고 말할 수 없는 상황입니다.

| 확인 | 기준 |
| --- | --- |
| 체크섬 | `checksums.sha256` 의 모든 파일 |
| 커밋 | 패키지 `source-commit.txt` = 옮겨 온 `DEPLOY_COMMIT` |
| 배포 파일 | `deploy-files.sha256` — 옮겨 온 정의 · 스크립트가 원본과 같은지 |
| 이미지 | `images.lock` — 6개 서비스 전부 digest 가 있어야 함 |
| 스냅샷 | 압축 해제 결과 = `contents.tsv` (개수 · 해시) |
| 기존 설치 | 데이터 볼륨이 있으면 `FORCE_CLEAN=1` 필요 |
| 데이터 | `data-fingerprint.tsv` — 테이블별 행 수 · 내용 해시 (결과: `~/lexai-run/data-check.txt`) |

Ollama 버전 · 모델 ID 가 다르면 경고만 남깁니다(`runtime_match`). 데이터가 아니라
답변 조건이기 때문입니다.

패키지 형식은 네이티브와 같아서 **형태 간 이관**도 됩니다 — 이 경우 이관 모드가
아니라 일반 배포에 `SNAPSHOT_URI` 만 줍니다(네이티브 패키지에는 `images.lock` 이
없으므로 Ollama 만 원본 버전으로 맞춥니다).

## 일상 운영

```bash
cd ~/lexai-compose
docker compose ps               # 상태 (.env 의 COMPOSE_FILE 로 정의가 맞춰져 있음)
docker compose logs -f          # 로그
docker compose down             # 종료 (볼륨은 유지)
docker compose up -d --no-build # 재기동
bash deploy.sh                  # 갱신 (브랜치 최신 · 이미지 고정 해제)
```

**`docker compose down -v` 는 쓰지 마세요.** 색인 · DB 볼륨까지 지워집니다.

## 주의

- 같은 VM 에서 네이티브 형태와 **동시에 띄울 수 없습니다.** 포트와 GPU VRAM 이
  겹칩니다. 형태별로 VM 을 따로 두세요.
- 보안 그룹은 22 만 열고, 웹은 SSH 터널로 보는 쪽을 권합니다.
  `ssh -L 8080:localhost:80 cb-user@<IP>` → `http://localhost:8080`
- `.env` 와 `~/.lexai-secrets.compose` 는 600 입니다. 배포 디렉터리째 옮기면 `.env` 가
  함께 가므로 기존 로그인 토큰도 그대로 유효합니다.
- Docker Hub 익명 받기는 IP 당 횟수 제한이 있습니다(429). 같은 IP 에서 VM 을 여러 번
  새로 만들면 걸릴 수 있습니다 — `docker login` 으로 풀립니다.
