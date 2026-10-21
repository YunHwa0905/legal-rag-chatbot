# SQLite 스키마 마이그레이션 (Shell 형태)

`deploy/schema.sqlite.sql` 은 **기준선(v0)** 입니다. 이 파일은 더 고치지 않습니다.
이후의 스키마 변경은 전부 이 폴더에 번호를 붙인 SQL 파일로 추가합니다.

```
deploy/migrations/0001_add_user_email.sql
deploy/migrations/0002_create_feedback.sql
```

## 동작

- `restore.sh` 가 기준선을 적용한 뒤 `apply_schema_migrations` (common.sh) 를 호출합니다.
- DB 의 `PRAGMA user_version` 보다 큰 번호만, 번호 순서대로 적용합니다.
- 파일마다 `BEGIN … PRAGMA user_version = N; COMMIT` 으로 감싸 한 트랜잭션으로 실행합니다.
  실패하면 그 파일의 변경과 버전 기록이 함께 취소되고 restore.sh 가 멈춥니다.
- DB 버전이 코드의 최신 번호보다 크면(새 코드의 DB 를 옛 코드로 옮긴 경우) 멈춥니다.
- `backup.sh` 의 MANIFEST.txt 에 패키지 DB 의 스키마 버전이 기록됩니다.

## 규칙

1. 파일 이름은 `NNNN_설명.sql` (4자리 번호). 번호는 1부터, 겹치면 안 됩니다.
2. **이미 push 한 파일은 고치지 않습니다.** 바꿀 게 있으면 새 번호로 추가합니다.
   (이미 적용된 DB 는 그 파일을 다시 실행하지 않으므로, 고친 내용이 반영되지 않습니다)
3. 파일 안에 `BEGIN` / `COMMIT` 을 쓰지 않습니다. 감싸는 건 스크립트가 합니다.
4. 트랜잭션 안에서 안 되는 문장은 쓰지 않습니다: `VACUUM`, `PRAGMA journal_mode` 등.
5. SQLite 의 `ALTER TABLE` 은 제한적입니다(`ADD COLUMN`, `RENAME` 정도).
   컬럼 삭제·타입 변경은 "새 테이블 생성 → 데이터 복사 → 교체" 로 작성합니다.
6. `ADD COLUMN ... NOT NULL` 에는 `DEFAULT` 가 있어야 합니다(기존 행 때문).

## 범위

Shell 형태(`deploy/native`) 전용입니다. Docker 형태(`backend_spring/docker-entrypoint.sh`)는
아직 이 폴더를 읽지 않습니다.
