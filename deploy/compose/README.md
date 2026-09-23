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
  | REGISTRY_PREFIX=asia-northeast3-docker.pkg.dev/<프로젝트>/<저장소> IMAGE_TAG=v2 bash
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
4. compose 정의 수신
5. `.env` 생성 — JWT · OpenSearch 비밀번호 자동 발급
6. 이미지 pull → `up -d --no-build`
7. `SNAPSHOT_URI` 가 있으면 **DB · 색인 복원** (체크섬 확인 후)
8. 헬스체크

DB 복원이 따로 있는 이유는 저장 위치가 달라서입니다. 네이티브는 호스트
파일이라 갖다 놓으면 끝이지만, 컴포즈는 네임드 볼륨 안이라 컨테이너가 떠야
접근할 수 있습니다. 그래서 기동 뒤에 넣고 `tomcat` 만 다시 띄웁니다.
이 단계가 없으면 빈 DB 로 떠서 **기존 계정으로 로그인이 안 되고**, 이관
전후 동등성 확인의 첫 단계가 막힙니다.

여러 번 실행해도 안전합니다. 이미 끝난 단계는 건너뜁니다.

### GPU 통과 확인을 따로 두는 이유

toolkit 이 없으면 **에러 없이 CPU 로 폴백합니다.** 컨테이너는 전부 정상으로
보이는데 응답만 1~3분이 되고, 백엔드의 FastAPI 호출 타임아웃이 180초라
채팅이 실패하기 시작합니다. 증상이 늦게, 엉뚱한 곳에서 드러나므로 기동 전에
실제로 확인합니다.

## 환경변수

전부 선택 사항입니다.

| 이름 | 기본값 | 설명 |
| --- | --- | --- |
| `BRANCH` | `feat/sqlite` | compose 정의를 받을 브랜치 |
| `DEPLOY_DIR` | `~/lexai-compose` | 배포 디렉터리 |
| `REGISTRY_PREFIX` | `yunhwa0905` | Docker Hub 계정 또는 레지스트리 주소 |
| `IMAGE_TAG` | `v2` | **고정 태그를 쓰세요** — `latest` 는 추적이 안 됩니다 |
| `SNAPSHOT_URI` | 없음 | 이관 패키지 위치 (`s3://` · `gs://` · `https://`) |
| `SKIP_DRIVER` | `0` | GPU 이미지를 쓰는 경우 `1` |
| `NO_START` | `0` | 준비만 하고 기동은 안 함 |

## 이관 도구 연동

이 한 줄이 CB-Tumblebug 의 `postCommands` 에 그대로 실리는 페이로드입니다.
root 로 실행돼도 uid 1000 사용자로 스스로 전환하므로, 이관 도구가 root 로
호출해도 배포물이 `/root` 아래에 갇히지 않습니다.

## 일상 운영

```bash
cd ~/lexai-compose
docker compose logs -f          # 로그
docker compose ps               # 상태
docker compose down             # 종료 (볼륨은 유지)
bash deploy.sh                  # 재기동 · 갱신
```

**`docker compose down -v` 는 쓰지 마세요.** 색인 볼륨까지 지워집니다.

## 주의

- 같은 VM 에서 네이티브 형태와 **동시에 띄울 수 없습니다.** 포트(9200 ·
  11434)와 GPU VRAM 이 겹칩니다. 형태별로 VM 을 따로 두세요.
- 보안 그룹은 22 만 열고, 웹은 SSH 터널로 보는 쪽을 권합니다.
  `ssh -L 8080:localhost:80 ubuntu@<IP>` → `http://localhost:8080`
- `.env` 와 `~/.lexai-secrets` 는 600 입니다. 이관 시 대상 환경에 **같은
  `OPENSEARCH_PASSWORD`** 를 넣어야 기존 색인에 붙습니다.
