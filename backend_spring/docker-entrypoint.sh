#!/bin/sh
# ===========================================================
# Tomcat 기동 전에 db.properties 를 환경변수로부터 생성합니다.
#
# 왜 이렇게 하는가:
#   root-context.xml 이 <context:property-placeholder location="classpath:db.properties"/>
#   로 값을 읽으므로 파일이 반드시 존재해야 합니다. 그런데 이미지에 비밀값을
#   굽고 싶지 않고, JVM 인자(-D)로 넘기면 ps 출력에 비밀번호가 노출됩니다.
#   그래서 기동 시점에 파일을 만들어 넣습니다.
#
# 이 파일은 컨테이너 안에서만 만들어지며 이미지 레이어에는 남지 않습니다.
#
# ★ DB 가 MySQL 에서 SQLite 로 바뀌면서 달라진 점:
#   - DB_USERNAME / DB_PASSWORD 가 없습니다. 파일 권한이 곧 접근 제어입니다.
#   - DB_URL 대신 DB_PATH(파일 경로)를 받습니다.
#   - DB 파일이 없으면 마운트된 스키마로 직접 만듭니다. MySQL 컨테이너가
#     첫 기동에 init.sql 을 실행해주던 역할을 여기서 대신합니다.
# ===========================================================

set -e

PROPS="${CATALINA_HOME}/webapps/ROOT/WEB-INF/classes/db.properties"
DB_PATH="${DB_PATH:-/var/lib/lexai/lexai.db}"
SCHEMA_FILE="${SCHEMA_FILE:-/opt/schema.sqlite.sql}"

# -----------------------------------------------------------
# 필수 환경변수 검증
#
# 오타로 값이 비면 Tomcat 이 뜬 뒤 첫 요청에서야 이상하게 실패합니다.
# 여기서 미리 죽이면 원인이 로그 맨 앞에 그대로 찍힙니다.
# -----------------------------------------------------------
if [ -z "$JWT_SECRET" ]; then
    echo "[FATAL] JWT_SECRET 이 비어 있습니다." >&2
    echo "[FATAL] .env 파일을 확인하세요 (.env.example 참고)." >&2
    exit 1
fi

# HS256 키 길이 검증 — 32바이트 미만이면 JwtUtil 의 init() 에서 예외가 납니다.
if [ "${#JWT_SECRET}" -lt 32 ]; then
    echo "[FATAL] JWT_SECRET 이 너무 짧습니다 (${#JWT_SECRET}자). 32자 이상 필요." >&2
    echo "[FATAL] openssl rand -base64 48 로 생성하세요." >&2
    exit 1
fi

# -----------------------------------------------------------
# DB 파일 확인
#
# 파일이 없으면 SQLite 는 조용히 빈 DB 를 새로 만듭니다. 그 상태로 뜨면
# 테이블이 없어 첫 회원가입이 500 으로 실패하는데, 원인이 로그에 잘
# 드러나지 않습니다. 그래서 여기서 먼저 잡습니다.
# -----------------------------------------------------------
mkdir -p "$(dirname "$DB_PATH")"

if [ ! -f "$DB_PATH" ]; then
    if [ -f "$SCHEMA_FILE" ]; then
        echo "[INFO] DB 파일이 없어 스키마를 적용합니다: ${DB_PATH}"
        sqlite3 "$DB_PATH" < "$SCHEMA_FILE" > /dev/null
        echo "[INFO] 스키마 적용 완료 (테이블 $(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';")개)"
    else
        echo "[FATAL] DB 파일도 스키마 파일도 없습니다." >&2
        echo "[FATAL]   DB     : ${DB_PATH}" >&2
        echo "[FATAL]   스키마 : ${SCHEMA_FILE}" >&2
        echo "[FATAL] compose 의 볼륨 마운트를 확인하세요." >&2
        exit 1
    fi
fi

if [ ! -w "$DB_PATH" ]; then
    echo "[FATAL] DB 파일에 쓸 수 없습니다: ${DB_PATH}" >&2
    echo "[FATAL] 파일 소유자와 컨테이너 실행 사용자를 확인하세요." >&2
    exit 1
fi

# -----------------------------------------------------------
# 타임존
#
# 스키마와 매퍼가 datetime('now','localtime') 으로 시각을 기록합니다.
# 이 localtime 은 JVM 설정(-Duser.timezone)이 아니라 OS 타임존을 따르므로,
# TZ 가 없으면 컨테이너 기본값(UTC)으로 기록되어 9시간 어긋납니다.
# -----------------------------------------------------------
if [ -z "$TZ" ]; then
    echo "[WARN] TZ 가 설정되지 않았습니다. 시각이 UTC 로 기록됩니다." >&2
    echo "[WARN] .env 에 TZ=Asia/Seoul 을 넣으세요." >&2
fi

# -----------------------------------------------------------
# db.properties 생성
# -----------------------------------------------------------
mkdir -p "$(dirname "$PROPS")"
cat > "$PROPS" <<EOF
# 이 파일은 컨테이너 기동 시 docker-entrypoint.sh 가 자동 생성합니다.
# 직접 수정해도 다음 기동에서 덮어써집니다.
db.driver.Class=org.sqlite.JDBC
db.url=jdbc:sqlite:${DB_PATH}
fastapi.url=${FASTAPI_URL:-http://ai:8000}
jwt.secret=${JWT_SECRET}
jwt.expiration=${JWT_EXPIRATION:-86400000}
EOF

chmod 600 "$PROPS"

echo "[INFO] db.properties 생성 완료"
echo "[INFO]   db.url      = jdbc:sqlite:${DB_PATH}"
echo "[INFO]   db 파일 크기 = $(wc -c < "$DB_PATH") bytes"
echo "[INFO]   fastapi.url = ${FASTAPI_URL:-http://ai:8000}"
echo "[INFO]   TZ          = ${TZ:-(미설정 — UTC)}"
echo "[INFO]   CORS origin = ${CORS_ALLOWED_ORIGIN:-(없음 — 동일 오리진)}"

exec "$@"
