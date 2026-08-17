-- ===========================================================
-- MySQL 초기 스키마
--
-- 이 파일은 mysql_data 볼륨이 "비어 있을 때만" 1회 실행됩니다.
-- 이미 데이터가 있는 상태에서 스키마를 바꾸려면 직접 ALTER 하세요.
--
-- 기존에는 Workbench 로 수동 생성했던 테이블입니다.
-- 스크립트로 남겨두지 않으면 재배포마다 회원가입이 500 으로 실패합니다.
-- 참조: backend_spring/src/main/resources/mybatis/UserMapper.xml
-- ===========================================================

CREATE TABLE IF NOT EXISTS users (
    id         BIGINT       NOT NULL AUTO_INCREMENT,
    username   VARCHAR(50)  NOT NULL,
    -- BCrypt 해시는 60자 고정. 여유를 둬서 100.
    password   VARCHAR(100) NOT NULL,
    age        INT          NOT NULL,
    created_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uk_users_username (username)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_unicode_ci;
