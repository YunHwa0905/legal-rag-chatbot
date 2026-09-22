-- ===========================================================
-- SQLite 초기 스키마 (Shell 형태 배포용)
--
-- MySQL 구성에서는 스키마가 두 군데로 나뉘어 있었습니다:
--   deploy/init.sql                  → users (컨테이너 최초 기동 시 1회)
--   db/migration/V1__chat_tables.sql → 나머지 5개 (Flyway가 앱 기동 시)
-- SQLite 에는 "컨테이너 초기화" 개념이 없으므로 6개를 한 파일로 모읍니다.
--
-- 적용:
--   sqlite3 "$DB_PATH" < deploy/schema.sqlite.sql
-- 여러 번 실행해도 안전합니다 (IF NOT EXISTS).
--
-- -----------------------------------------------------------
-- MySQL → SQLite 변환 규칙
--
--   BIGINT AUTO_INCREMENT   → INTEGER PRIMARY KEY AUTOINCREMENT
--       ★ 반드시 INTEGER 여야 rowid 별칭이 됩니다. BIGINT 로 쓰면
--         AUTOINCREMENT 가 동작하지 않습니다.
--   VARCHAR(n) / TEXT / JSON → TEXT   (SQLite 는 길이 제한을 무시합니다)
--   ENUM('a','b')            → TEXT + CHECK 제약
--   DECIMAL(3,2)             → REAL
--   KEY / UNIQUE KEY         → CREATE INDEX / CREATE UNIQUE INDEX
--   ENGINE / CHARSET / COLLATE → 없음 (SQLite 는 항상 UTF-8)
--
-- -----------------------------------------------------------
-- 연결할 때마다 반드시 걸어야 하는 것 (이 파일이 아니라 커넥션 설정)
--
--   PRAGMA foreign_keys = ON;    ← 기본값이 OFF 입니다. 안 걸면 FK 가
--                                   선언만 되고 실제로 검사되지 않습니다.
--   PRAGMA busy_timeout = 5000;  ← 비동기 요약 스레드와 요청 스레드가 동시에
--                                   쓰므로, 없으면 SQLITE_BUSY 가 산발적으로 터집니다.
-- ===========================================================


-- WAL 모드는 DB 파일에 기록되어 유지됩니다(연결마다 걸 필요 없음).
-- 읽기와 쓰기가 서로를 막지 않게 해줍니다 — 단일 writer 제약을 완화하는 핵심 설정.
PRAGMA journal_mode = WAL;

-- 쓰기 성능과 내구성의 절충. WAL 과 함께 쓰는 일반적인 조합입니다.
PRAGMA synchronous = NORMAL;


-- ===========================================================
-- 사용자
-- ===========================================================
CREATE TABLE IF NOT EXISTS users (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    username   TEXT    NOT NULL,
    -- BCrypt 해시는 60자 고정. SQLite 는 길이 제한이 없어 TEXT 로 둡니다.
    password   TEXT    NOT NULL,
    age        INTEGER NOT NULL,
    created_at TEXT    NOT NULL DEFAULT (datetime('now', 'localtime'))
);

CREATE UNIQUE INDEX IF NOT EXISTS uk_users_username ON users (username);


-- ===========================================================
-- 대화 세션
-- ===========================================================
CREATE TABLE IF NOT EXISTS chat_session (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id    INTEGER NOT NULL,
    title      TEXT    NOT NULL DEFAULT '새 대화',
    created_at TEXT    NOT NULL DEFAULT (datetime('now', 'localtime')),
    updated_at TEXT    NOT NULL DEFAULT (datetime('now', 'localtime')),
    deleted_at TEXT    NULL,
    CONSTRAINT fk_chat_session_user FOREIGN KEY (user_id) REFERENCES users (id)
);

CREATE INDEX IF NOT EXISTS idx_chat_session_user
    ON chat_session (user_id, deleted_at, updated_at);


-- ===========================================================
-- 대화 메시지
--   MySQL 의 ENUM('user','assistant') 을 CHECK 제약으로 옮깁니다.
--   sources_json 은 MySQL 에서 JSON 타입이었지만 애플리케이션이
--   문자열로 직렬화해 넣고 읽으므로 TEXT 로 충분합니다.
-- ===========================================================
CREATE TABLE IF NOT EXISTS chat_message (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id       INTEGER NOT NULL,
    role             TEXT    NOT NULL CHECK (role IN ('user', 'assistant')),
    content          TEXT    NOT NULL,
    standalone_query TEXT    NULL,
    sources_json     TEXT    NULL,
    created_at       TEXT    NOT NULL DEFAULT (datetime('now', 'localtime')),
    CONSTRAINT fk_chat_message_session FOREIGN KEY (session_id) REFERENCES chat_session (id)
);

CREATE INDEX IF NOT EXISTS idx_chat_message_session
    ON chat_message (session_id, created_at);


-- ===========================================================
-- 세션 요약 (세션당 1행)
-- ===========================================================
CREATE TABLE IF NOT EXISTS chat_session_summary (
    session_id         INTEGER PRIMARY KEY,
    summary            TEXT    NOT NULL,
    through_message_id INTEGER NOT NULL,
    updated_at         TEXT    NOT NULL DEFAULT (datetime('now', 'localtime')),
    CONSTRAINT fk_summary_session FOREIGN KEY (session_id) REFERENCES chat_session (id)
);


-- ===========================================================
-- 사용자 기억
-- ===========================================================
CREATE TABLE IF NOT EXISTS user_memory (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id           INTEGER NOT NULL,
    mem_key           TEXT    NOT NULL,
    mem_value         TEXT    NOT NULL,
    source_message_id INTEGER NULL,
    confidence        REAL    NOT NULL DEFAULT 0.80,
    confirmed_at      TEXT    NOT NULL DEFAULT (datetime('now', 'localtime')),
    updated_at        TEXT    NOT NULL DEFAULT (datetime('now', 'localtime')),
    CONSTRAINT fk_user_memory_user FOREIGN KEY (user_id) REFERENCES users (id)
);

CREATE UNIQUE INDEX IF NOT EXISTS uk_user_memory ON user_memory (user_id, mem_key);


-- ===========================================================
-- 비동기 작업 로그
-- ===========================================================
CREATE TABLE IF NOT EXISTS chat_async_job (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    job_type      TEXT    NOT NULL CHECK (job_type IN ('summary', 'memory_extract')),
    session_id    INTEGER NOT NULL,
    status        TEXT    NOT NULL CHECK (status IN ('success', 'failed')),
    error_message TEXT    NULL,
    created_at    TEXT    NOT NULL DEFAULT (datetime('now', 'localtime'))
);

CREATE INDEX IF NOT EXISTS idx_async_job_session
    ON chat_async_job (session_id, created_at);


-- ===========================================================
-- updated_at 자동 갱신 트리거
--
-- MySQL 의 ON UPDATE CURRENT_TIMESTAMP 에 대응하는 기능이 SQLite 에는
-- 없어서 트리거로 대신합니다.
--
-- WHEN 절이 핵심입니다: 애플리케이션이 updated_at 을 직접 지정한 UPDATE
-- (예: ChatSessionMapper 의 touch) 에서는 트리거가 값을 덮어쓰지 않고,
-- 지정하지 않은 UPDATE 에서만 현재 시각을 채웁니다. MySQL 의 동작과 같습니다.
--
-- 재귀 걱정은 없습니다 — SQLite 는 recursive_triggers 가 기본 OFF 라
-- 트리거 안의 UPDATE 가 자기 자신을 다시 부르지 않습니다.
-- ===========================================================
CREATE TRIGGER IF NOT EXISTS trg_chat_session_updated_at
AFTER UPDATE ON chat_session
FOR EACH ROW
WHEN NEW.updated_at = OLD.updated_at
BEGIN
    UPDATE chat_session
       SET updated_at = datetime('now', 'localtime')
     WHERE id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_chat_session_summary_updated_at
AFTER UPDATE ON chat_session_summary
FOR EACH ROW
WHEN NEW.updated_at = OLD.updated_at
BEGIN
    UPDATE chat_session_summary
       SET updated_at = datetime('now', 'localtime')
     WHERE session_id = NEW.session_id;
END;

CREATE TRIGGER IF NOT EXISTS trg_user_memory_updated_at
AFTER UPDATE ON user_memory
FOR EACH ROW
WHEN NEW.updated_at = OLD.updated_at
BEGIN
    UPDATE user_memory
       SET updated_at = datetime('now', 'localtime')
     WHERE id = NEW.id;
END;
