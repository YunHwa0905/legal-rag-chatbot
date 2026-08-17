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
# ===========================================================

set -e

PROPS="${CATALINA_HOME}/webapps/ROOT/WEB-INF/classes/db.properties"

# -----------------------------------------------------------
# 필수 환경변수 검증
#
# 오타로 값이 비면 Tomcat 이 뜬 뒤 첫 요청에서야 이상하게 실패합니다.
# 여기서 미리 죽이면 원인이 로그 맨 앞에 그대로 찍힙니다.
# -----------------------------------------------------------
missing=""
for var in DB_URL DB_USERNAME DB_PASSWORD JWT_SECRET; do
    eval "value=\$$var"
    if [ -z "$value" ]; then
        missing="$missing $var"
    fi
done

if [ -n "$missing" ]; then
    echo "[FATAL] 필수 환경변수가 비어 있습니다:$missing" >&2
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
# db.properties 생성
# -----------------------------------------------------------
mkdir -p "$(dirname "$PROPS")"
cat > "$PROPS" <<EOF
# 이 파일은 컨테이너 기동 시 docker-entrypoint.sh 가 자동 생성합니다.
# 직접 수정해도 다음 기동에서 덮어써집니다.
db.driver.Class=com.mysql.cj.jdbc.Driver
db.url=${DB_URL}
db.username=${DB_USERNAME}
db.password=${DB_PASSWORD}
fastapi.url=${FASTAPI_URL:-http://ai:8000}
jwt.secret=${JWT_SECRET}
jwt.expiration=${JWT_EXPIRATION:-86400000}
EOF

chmod 600 "$PROPS"

echo "[INFO] db.properties 생성 완료"
echo "[INFO]   db.url      = ${DB_URL}"
echo "[INFO]   fastapi.url = ${FASTAPI_URL:-http://ai:8000}"
echo "[INFO]   CORS origin = ${CORS_ALLOWED_ORIGIN:-(없음 — 동일 오리진)}"

exec "$@"
