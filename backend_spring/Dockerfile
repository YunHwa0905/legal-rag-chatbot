# syntax=docker/dockerfile:1

# ===========================================================
# Spring Legacy WAR → Tomcat 9 (Java 11)
#
# 핵심 두 가지:
#  1) ROOT 로 배포해 컨텍스트 경로 /backend_spring 을 없앱니다.
#     → API 경로가 /api/auth/login, /api/chat 으로 단순해지고
#       프론트엔드가 상대경로만 쓰면 되므로 CORS 가 사라집니다.
#  2) WAR 를 빌드 시점에 미리 펼쳐둡니다.
#     → entrypoint 가 db.properties 를 환경변수로 생성해 넣을 수 있습니다.
#       (WAR 안에 비밀값을 굽지 않기 위한 구조)
# ===========================================================

# -----------------------------------------------------------
# 1단계: Maven 빌드
# -----------------------------------------------------------
FROM maven:3.9-eclipse-temurin-11 AS build

WORKDIR /build
COPY pom.xml .
COPY src ./src

# BuildKit 캐시 마운트로 ~/.m2 를 재사용합니다 (재빌드 시 의존성 재다운로드 방지).
RUN --mount=type=cache,target=/root/.m2 \
    mvn -B -DskipTests clean package


# -----------------------------------------------------------
# 2단계: Tomcat 런타임
# -----------------------------------------------------------
FROM tomcat:9.0-jdk11-temurin

# 한글 요청/응답 인코딩
ENV CATALINA_OPTS="-Dfile.encoding=UTF-8 -Duser.timezone=Asia/Seoul"

# 공식 이미지의 webapps 는 비어 있습니다(기본 앱은 webapps.dist 로 이동).
# WAR 를 webapps/ROOT 에 펼쳐 넣습니다.
COPY --from=build /build/target/*.war /tmp/app.war
RUN mkdir -p "$CATALINA_HOME/webapps/ROOT" \
 && cd "$CATALINA_HOME/webapps/ROOT" \
 && jar -xf /tmp/app.war \
 && rm -f /tmp/app.war

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["catalina.sh", "run"]
