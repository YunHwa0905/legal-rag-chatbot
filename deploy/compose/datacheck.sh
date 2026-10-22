#!/usr/bin/env bash
# ===========================================================
# 데이터 지문 — 이관 전후 데이터 보존 확인 (Docker Compose 형태)
#
#   datacheck.sh write <db> <출력.tsv>
#   datacheck.sh check <db> <원본.tsv>
#
# 호스트에는 sqlite3 가 없을 수 있어 tomcat 이미지 안에서 실행합니다
# (deploy.sh · backup.sh 가 docker compose run 으로 부릅니다).
#
# ★ 알고리즘은 deploy/native/common.sh 의 write_data_fingerprint ·
#   check_data_fingerprint 와 한 글자도 다르면 안 됩니다. 그래야 컴포즈에서
#   뜬 패키지를 네이티브로(또는 반대로) 복원해도 같은 기준으로 비교됩니다.
#
# 형식(TSV): 테이블 <TAB> 행수 <TAB> 컬럼,목록 <TAB> sha256
# 대상에서 마이그레이션이 컬럼을 더해도, 원본에 있던 컬럼만 해시하므로
# 원본 데이터 비교는 그대로 유효합니다.
# ===========================================================
set -euo pipefail

_table_hash() {  # _table_hash <db> <테이블> <컬럼,목록>
    sqlite3 -readonly "$1" ".mode quote" "SELECT $3 FROM \"$2\" ORDER BY rowid;" | sha256sum | cut -d' ' -f1
}

write_fp() {  # write_fp <db> <출력>
    local db="$1" out="$2" t cols n
    : > "$out"
    for t in $(sqlite3 -readonly "$db" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;"); do
        cols="$(sqlite3 -readonly "$db" "SELECT group_concat('\"'||name||'\"', ',') FROM (SELECT name FROM pragma_table_info('$t') ORDER BY cid);")"
        n="$(sqlite3 -readonly "$db" "SELECT COUNT(*) FROM \"$t\";")"
        printf '%s\t%s\t%s\t%s\n' "$t" "$n" "$cols" "$(_table_hash "$db" "$t" "$cols")" >> "$out"
    done
}

check_fp() {  # check_fp <db> <원본> — 표로 출력하고, 하나라도 다르면 1
    local db="$1" want="$2" t n cols h have_n have_h bad=0 status
    printf '    %-22s %10s %10s  %s\n' "테이블" "원본" "대상" "내용"
    while IFS=$'\t' read -r t n cols h; do
        [ -n "$t" ] || continue
        if [ "$(sqlite3 -readonly "$db" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$t';")" != "1" ]; then
            printf '    %-22s %10s %10s  %s\n' "$t" "$n" "-" "테이블 없음"; bad=1; continue
        fi
        have_n="$(sqlite3 -readonly "$db" "SELECT COUNT(*) FROM \"$t\";")"
        if ! have_h="$(_table_hash "$db" "$t" "$cols" 2>/dev/null)" || [ -z "$have_h" ]; then
            printf '    %-22s %10s %10s  %s\n' "$t" "$n" "$have_n" "컬럼 누락"; bad=1; continue
        fi
        if [ "$have_n" = "$n" ] && [ "$have_h" = "$h" ]; then status="일치"; else status="불일치"; bad=1; fi
        printf '    %-22s %10s %10s  %s\n' "$t" "$n" "$have_n" "$status"
    done < "$want"
    [ "$bad" = "0" ]
}

case "${1:-}" in
    write) write_fp "$2" "$3" ;;
    check) check_fp "$2" "$3" ;;
    *) echo "사용법: datacheck.sh write <db> <out> | check <db> <want>" >&2; exit 2 ;;
esac
