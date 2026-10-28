#!/usr/bin/env python3
# ===========================================================
# LexAI 이관 동등성 비교 — backup.sh(소스) · deploy.sh / up.sh(타겟)가 부릅니다.
#
#   소스에서 패키지 파일 목록 · 서비스 목록 · 색인 문서 수 · 골든 질문의 검색 결과와 답변을
#   기준으로 남기고, 타겟에서 같은 방식으로 다시 재서 한 줄씩(ROW) 대조합니다.
#   비교표 형식은 WidgetRAG migcheck.py 와 같습니다 — 오케스트레이터가 두 워크로드를
#   같은 방법으로 읽습니다.
#
#   표준 라이브러리만 씁니다 (python3.8+ — VM 의 시스템 python3 로 바로 돕니다).
#
#   사용법 (보통은 스크립트가 대신 부릅니다)
#     python3 migcompare.py inventory <패키지디렉터리> --out package-files.tsv
#     python3 migcompare.py source-info --out source-info.json --form F --docs N --services "a b" [--runtime 파일] [--url U]
#     python3 migcompare.py golden-build --url U --questions 파일 --out golden.json [--repeat 2] [--runtime 파일]
#     python3 migcompare.py files-check --package <디렉터리> --out files-rows.tsv   # T1-2 만 (패키지를 오래 두지 않는 네이티브용)
#     python3 migcompare.py compare --package <디렉터리> --url U --evidence <디렉터리> --form F
#                                   --docs N --services "a b" --data-check PASS|FAIL|NA [--runtime 파일]
#                                   --csv ~/lexai-run/migration-compare.csv --timestamp "YYYY-mm-dd HH:MM:SS"
#                                   [--files-rows files-rows.tsv]   # 있으면 T1-2 를 다시 재지 않고 이 결과를 씁니다
#
#   ROW 형식 (탭 구분 6열): test  item  source  target  result  note
#     test   = T1-1 서비스 · T1-2 패키지 파일 · T1-3 데이터 · T2 LLM 응답
#     result = PASS · FAIL · WARN · SKIP · INFO
#
#   T2 판정 (질문마다)
#     소스 응답 비정상 · 소스끼리도 답이 다름          SKIP  이관과 무관
#     타겟 응답 비정상 (오류 · 빈 답변)                FAIL
#     검색 결과(근거 문서 ID · 순서)가 다름            FAIL  데이터 · 색인 확인
#     검색 같음 · 문장 같음                            PASS
#     검색 같음 · 문장 다름 · 생성 설정이 비결정적      SKIP  문장 비교 불가 (온도 0 · seed 고정 필요)
#     검색 같음 · 문장 다름 · 환경이 소스와 다름        WARN  유사도 · 차이 파일을 증적으로
#     검색 같음 · 문장 다름 · 환경이 소스와 같음        한 번 다시 묻고 같아지면 WARN(재현성), 그래도 다르면 FAIL
#   환경 = GPU 모델 · 드라이버 · Ollama 버전 · 답변 모델 ID(digest). 유사도는 합격선 없이 기록만 합니다.
#   생성 설정(온도 · seed)이 소스와 타겟에서 다르면 문장 비교 자체가 성립하지 않아 FAIL 입니다.
#
#   종료코드: 0 정상 · 1 비교 결과에 FAIL 있음 · 2 사용법 · 내부 오류 · 3 AI 서버에 닿지 않음
# ===========================================================
import argparse
import csv
import difflib
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

RESULTS = ("PASS", "FAIL", "WARN", "SKIP", "INFO")
REPORT_HEADER = ["timestamp", "form", "source_form", "package", "test", "item", "source", "target", "result", "note"]
FORMAT = 1
CHAT_PATH = "/api/v1/chat"
HEALTH_PATH = "/api/v1/health"
DEFAULT_AGE = 30


def warn(msg):
    sys.stderr.write("  WARN %s\n" % msg)


def info(msg):
    sys.stderr.write("  %s\n" % msg)


def sha256_text(s):
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def cell(v):
    s = "-" if v is None or v == "" else str(v)
    return s.replace("\t", " ").replace("\r", " ").replace("\n", " ")


def short(v):
    s = cell(v)
    if len(s) == 64 and all(c in "0123456789abcdef" for c in s):
        return s[:12]
    return s


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def read_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


# ---------- 환경 ----------
def read_runtime(path):
    """runtime-versions.txt (ollama <버전> / model <이름> <ID>) → {"ollama": v, "models": {이름: ID}}"""
    rt = {"ollama": None, "models": {}}
    if not path or not os.path.isfile(path):
        return rt
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for ln in f:
            p = ln.split()
            if len(p) >= 2 and p[0] == "ollama":
                rt["ollama"] = p[1]
            elif len(p) >= 3 and p[0] == "model":
                rt["models"][p[1]] = p[2]
    return rt


def gpu_info():
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=name,driver_version", "--format=csv,noheader"],
                             capture_output=True, text=True, timeout=30).stdout
    except Exception:
        return {"gpu": None, "driver": None}
    lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
    if not lines:
        return {"gpu": None, "driver": None}
    names = [ln.split(",")[0].strip() for ln in lines]
    driver = lines[0].split(",")[1].strip() if "," in lines[0] else None
    gpu = names[0] if len(set(names)) == 1 else " + ".join(names)
    if len(names) > 1:
        gpu = "%s x%d" % (gpu, len(names))
    return {"gpu": gpu, "driver": driver}


def answer_model_name():
    return os.environ.get("OLLAMA_MODEL") or "legal-gemma"


def environment(runtime_path):
    rt = read_runtime(runtime_path)
    g = gpu_info()
    model = answer_model_name()
    return {"gpu": g["gpu"], "driver": g["driver"], "ollama_version": rt["ollama"],
            "model": model, "model_id": rt["models"].get(model) or rt["models"].get(model + ":latest"),
            "models": rt["models"], "embedding_device": os.environ.get("EMBEDDING_DEVICE") or "cpu"}


ENV_KEYS = ("gpu", "driver", "ollama_version", "model_id")


# ---------- AI 서버 ----------
def http_json(url, body=None, timeout=300):
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def health(url):
    h = http_json(url.rstrip("/") + HEALTH_PATH, timeout=20)
    return {"temperature": h.get("llm_temperature"), "seed": h.get("llm_seed")}


def deterministic(llm):
    try:
        return float(llm.get("temperature")) == 0.0 and int(llm.get("seed")) != -1
    except (TypeError, ValueError):
        return False


def ask(url, question, age):
    t0 = time.time()
    r = {"ok": False, "error": None, "answer": None, "sources": [], "sec": None, "standalone_query": None}
    try:
        d = http_json(url.rstrip("/") + CHAT_PATH,
                      {"question": question, "age": age, "law_category": None, "history": [], "summary": None})
        ans = d.get("answer")
        r["answer"] = ans if isinstance(ans, str) else None
        r["sources"] = [{"doc_id": s.get("doc_id"), "score": s.get("score")} for s in (d.get("sources") or [])]
        r["standalone_query"] = d.get("standalone_query")
        r["ok"] = bool(r["answer"] and r["answer"].strip())
        if not r["ok"]:
            r["error"] = "빈 답변"
    except urllib.error.HTTPError as e:
        r["error"] = "HTTP %d" % e.code
    except Exception as e:  # 연결 실패 · 타임아웃
        r["error"] = "%s: %s" % (type(e).__name__, e)
    r["sec"] = round(time.time() - t0, 2)
    return r


def doc_ids(resp):
    return [s.get("doc_id") for s in resp.get("sources") or []]


def read_questions(path):
    qs = []
    with open(path, "r", encoding="utf-8") as f:
        for ln in f:
            ln = ln.strip()
            if ln and not ln.startswith("#"):
                qs.append(ln)
    return qs


# ---------- inventory ----------
def inventory(d, exclude):
    rows = []
    for name in sorted(os.listdir(d)):
        p = os.path.join(d, name)
        if name in exclude or name.startswith(".") or not os.path.isfile(p):
            continue
        rows.append((name, os.path.getsize(p), sha256_file(p)))
    return rows


def cmd_inventory(a):
    rows = inventory(a.dir, set(a.exclude) | {os.path.basename(a.out)})
    with open(a.out, "w", encoding="utf-8") as f:
        for name, size, h in rows:
            f.write("%s\t%d\t%s\n" % (name, size, h))
    info("파일 목록 %d개 · %d bytes" % (len(rows), sum(r[1] for r in rows)))
    return 0


# ---------- source-info ----------
def cmd_source_info(a):
    data = {"format": FORMAT, "created_at": now_iso(), "form": a.form, "docs": a.docs,
            "services": sorted(a.services.split()), "env": environment(a.runtime), "llm": None}
    if a.url:
        try:
            data["llm"] = health(a.url)
        except Exception as e:
            warn("AI 서버 상태를 읽지 못했습니다: %s" % e)
    write_json(a.out, data)
    return 0


# ---------- golden-build ----------
def cmd_golden_build(a):
    try:
        llm = health(a.url)
    except Exception as e:
        warn("AI 서버에 닿지 않아 골든을 만들지 않습니다: %s" % e)
        return 3
    qs = read_questions(a.questions)
    if not qs:
        warn("골든 질문이 없습니다: %s" % a.questions)
        return 2
    items = []
    for i, q in enumerate(qs, 1):
        reps = [ask(a.url, q, a.age) for _ in range(a.repeat)]
        answers = [r["answer"] for r in reps]
        ids = [doc_ids(r) for r in reps]
        ok = all(r["ok"] for r in reps)
        item = {"id": "q%02d" % i, "question": q, "age": a.age, "ok": ok,
                "stable": ok and len(set(answers)) == 1,
                "sources_stable": ok and all(x == ids[0] for x in ids),
                "answer": reps[0]["answer"], "sources": reps[0]["sources"],
                "answer_sha256": sha256_text(reps[0]["answer"]) if reps[0]["answer"] else None,
                "reps": [{"ok": r["ok"], "error": r["error"], "sec": r["sec"],
                          "answer_sha256": sha256_text(r["answer"]) if r["answer"] else None,
                          "doc_ids": doc_ids(r)} for r in reps]}
        items.append(item)
        info("%s %s · 답변 %s · 검색 %s (%s초)" % (item["id"], "ok" if ok else "오류",
                                             "재현" if item["stable"] else "다름",
                                             "재현" if item["sources_stable"] else "다름",
                                             "/".join(str(r["sec"]) for r in reps)))
    status = "ok" if all(it["ok"] for it in items) else "partial"
    data = {"format": FORMAT, "created_at": now_iso(), "repeat": a.repeat, "status": status,
            "llm": llm, "deterministic": deterministic(llm), "env": environment(a.runtime),
            "questions": len(qs), "items": items}
    write_json(a.out, data)
    stable = sum(1 for it in items if it["stable"])
    info("골든 %d문항 · 답변 재현 %d · 설정 온도 %s · seed %s%s" % (
        len(items), stable, llm.get("temperature"), llm.get("seed"),
        "" if data["deterministic"] else " (비결정적 — 문장 비교는 건너뜁니다)"))
    return 0


# ---------- compare ----------
class Rows:
    def __init__(self):
        self.rows = []

    def add(self, test, item, source, target, result, note=None):
        if result not in RESULTS:
            raise ValueError(result)
        self.rows.append([cell(test), cell(item), short(source), short(target), result, cell(note)])

    def count(self, res):
        return sum(1 for r in self.rows if r[4] == res)


def compare_services(R, src, tgt_services):
    s, t = sorted(src.get("services") or []), sorted(tgt_services)
    if not s:
        R.add("T1-1", "services", "-", " ".join(t), "SKIP", "소스 서비스 목록 없음 (옛 패키지)")
        return
    R.add("T1-1", "services:count", len(s), len(t), "PASS" if len(s) == len(t) else "FAIL")
    missing, extra = sorted(set(s) - set(t)), sorted(set(t) - set(s))
    if missing or extra:
        R.add("T1-1", "services:names", " ".join(s), " ".join(t), "FAIL",
              "타겟에 없음: %s · 타겟에만: %s" % (" ".join(missing) or "-", " ".join(extra) or "-"))
    else:
        R.add("T1-1", "services:names", " ".join(s), " ".join(t), "PASS")


def compare_package(R, pkg):
    lst = os.path.join(pkg, "package-files.tsv")
    if not os.path.isfile(lst):
        R.add("T1-2", "package-files", "-", "-", "SKIP", "패키지에 package-files.tsv 없음 (옛 패키지)")
        return
    want = []
    with open(lst, "r", encoding="utf-8") as f:
        for ln in f:
            p = ln.rstrip("\n").split("\t")
            if len(p) == 3:
                want.append((p[0], int(p[1]), p[2]))
    have = {name: (size, h) for name, size, h in inventory(pkg, {"package-files.tsv"})}
    n_ok, bad = 0, []
    for name, size, h in want:
        got = have.get(name)
        if got is None:
            bad.append(name)
            R.add("T1-2", "file:" + name, "%d B" % size, "없음", "FAIL", "전송되지 않음")
        elif got != (size, h):
            bad.append(name)
            R.add("T1-2", "file:" + name, h, got[1], "FAIL", "바이트 %d → %d" % (size, got[0]))
        else:
            n_ok += 1
    R.add("T1-2", "files:count", len(want), sum(1 for n, _, _ in want if n in have),
          "PASS" if not bad else "FAIL", "-" if not bad else "다른 파일 %d개" % len(bad))
    R.add("T1-2", "files:bytes", sum(w[1] for w in want), sum(have[n][0] for n, _, _ in want if n in have),
          "PASS" if not bad else "FAIL")


def compare_data(R, src, tgt_docs, data_check, report):
    note = report or "-"
    if data_check == "PASS":
        R.add("T1-3", "db:fingerprint", "원본 지문", "일치", "PASS", note)
    elif data_check == "FAIL":
        R.add("T1-3", "db:fingerprint", "원본 지문", "불일치", "FAIL", note)
    else:
        R.add("T1-3", "db:fingerprint", "-", "-", "SKIP", "데이터 보존 확인을 하지 않음 (%s)" % (data_check or "NA"))
    sd = src.get("docs")
    if sd is None or sd == "":
        R.add("T1-3", "index:docs", "-", tgt_docs, "SKIP", "소스 문서 수 없음 (옛 패키지)")
    else:
        R.add("T1-3", "index:docs", sd, tgt_docs, "PASS" if str(sd) == str(tgt_docs) else "FAIL")


def similarity(a, b):
    return round(difflib.SequenceMatcher(None, a or "", b or "", autojunk=False).ratio(), 2)


def first_diff(a, b):
    a, b = a or "", b or ""
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return i
    return None if len(a) == len(b) else min(len(a), len(b))


def write_diff(path, it, tgt, why, sim, retry=None):
    def block(title, text):
        return "[%s]\n%s\n\n" % (title, text if text else "(없음)")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    off = first_diff(it.get("answer"), tgt.get("answer"))
    body = "# %s — %s\n질문: %s\n유사도: %s · 첫 차이: %s\n" % (
        it["id"], why, it["question"], sim, "-" if off is None else "%d자" % off)
    body += "근거 문서 (소스): %s\n근거 문서 (타겟): %s\n\n" % (
        [s.get("doc_id") for s in it.get("sources") or []], doc_ids(tgt))
    body += block("소스 답변", it.get("answer"))
    body += block("타겟 답변", tgt.get("answer"))
    if retry is not None:
        body += block("타겟 답변 (다시 물음)", retry.get("answer"))
    with open(path, "w", encoding="utf-8") as f:
        f.write(body)


def compare_golden(R, pkg, url, runtime, evidence, age_default):
    gpath = os.path.join(pkg, "golden.json")
    if not os.path.isfile(gpath):
        R.add("T2", "golden", "-", "-", "SKIP", "패키지에 golden.json 없음 (GOLDEN=0 이거나 옛 패키지)")
        return None
    g = read_json(gpath)
    items = g.get("items") or []
    src_llm, src_env = g.get("llm") or {}, g.get("env") or {}
    tgt_env = environment(runtime)
    try:
        tgt_llm = health(url)
    except Exception as e:
        R.add("T2", "target:health", "-", "-", "FAIL", "타겟 AI 서버에 닿지 않음: %s" % e)
        return None

    # 전제 — 생성 설정
    pre_ok = True
    for k in ("temperature", "seed"):
        s, t = src_llm.get(k), tgt_llm.get(k)
        try:
            same = s is not None and t is not None and float(s) == float(t)
        except (TypeError, ValueError):
            same = False
        pre_ok = pre_ok and same
        R.add("T2", "pre:" + k, s, t, "PASS" if same else "FAIL",
              "-" if same else "생성 설정이 다름 — 같은 값으로 AI 서버를 띄워야 문장 비교가 성립")
    det = deterministic(src_llm) and deterministic(tgt_llm)
    if not det:
        R.add("T2", "pre:deterministic", "온도 %s · seed %s" % (src_llm.get("temperature"), src_llm.get("seed")),
              "온도 %s · seed %s" % (tgt_llm.get("temperature"), tgt_llm.get("seed")), "INFO",
              "비결정적 설정 — 문장 비교는 건너뛰고 검색 결과만 판정 (온도 0 · seed 고정 필요)")

    # 환경
    env_same = True
    for k in ENV_KEYS:
        s, t = src_env.get(k), tgt_env.get(k)
        if s is None or t is None:
            env_same = False
            R.add("T2", "env:" + k, s, t, "WARN", "값 없음(수집 실패)")
        elif s == t:
            R.add("T2", "env:" + k, s, t, "PASS")
        else:
            env_same = False
            R.add("T2", "env:" + k, s, t, "INFO", "환경 차이 — 문장이 달라도 WARN 으로 봄")
    if src_env.get("embedding_device") != tgt_env.get("embedding_device"):
        R.add("T2", "env:embedding_device", src_env.get("embedding_device"), tgt_env.get("embedding_device"),
              "INFO", "임베딩 장치 차이 — 검색 결과가 다르면 먼저 확인")

    st = g.get("status")
    R.add("T2", "golden:status", st, "-", "PASS" if st == "ok" else "WARN",
          "-" if st == "ok" else "소스 골든 일부 비정상 — 해당 문항은 이관과 무관으로 건너뜀")

    out_items = []
    diff_dir = os.path.join(evidence, "diffs")
    for it in items:
        qid, q = it["id"], it["question"]
        tgt = ask(url, q, it.get("age") or age_default)
        rec = {"id": qid, "question": q, "target": tgt, "retry": None, "result": None, "note": None}
        src_ids, tgt_ids = [s.get("doc_id") for s in it.get("sources") or []], doc_ids(tgt)
        s_label = "a:%s d:%s" % ((it.get("answer_sha256") or "-")[:12], ",".join(map(str, src_ids[:6])) or "-")
        t_sha = sha256_text(tgt["answer"])[:12] if tgt.get("answer") else "-"
        t_label = "a:%s d:%s" % (t_sha, ",".join(map(str, tgt_ids[:6])) or "-")

        def emit(res, note):
            rec["result"], rec["note"] = res, note
            R.add("T2", qid, s_label, t_label, res, note)

        if not it.get("ok"):
            emit("SKIP", "소스 골든 응답 비정상 — 이관과 무관")
        elif not tgt["ok"]:
            emit("FAIL", "타겟 응답 비정상 (%s)" % (tgt.get("error") or "-"))
        elif src_ids != tgt_ids:
            note = "검색 결과 다름 — 데이터 · 색인 확인"
            if not it.get("sources_stable"):
                note = "검색 결과 다름 (소스끼리도 달랐음)"
            if src_env.get("embedding_device") != tgt_env.get("embedding_device"):
                note += " · 임베딩 장치 다름"
            emit("FAIL", note)
            write_diff(os.path.join(diff_dir, qid + ".diff"), it, tgt, note, similarity(it.get("answer"), tgt.get("answer")))
        elif tgt["answer"] == it.get("answer"):
            emit("PASS", "검색 결과 · 답변 완전 일치")
        elif not it.get("stable"):
            emit("SKIP", "검색 같음 · 소스끼리도 답이 달라 문장 비교 불가 — 이관과 무관")
        elif not det or not pre_ok:
            emit("SKIP" if pre_ok else "FAIL",
                 "검색 같음 · 문장 다름 — " + ("비결정적 설정이라 문장 비교 불가" if pre_ok else "생성 설정이 소스와 다름"))
        else:
            sim = similarity(it.get("answer"), tgt["answer"])
            if not env_same:
                note = "검색 같음 · 문장만 다름 — 환경 차이 (유사도 %s)" % sim
                emit("WARN", note)
                write_diff(os.path.join(diff_dir, qid + ".diff"), it, tgt, note, sim)
            else:
                retry = ask(url, q, it.get("age") or age_default)
                rec["retry"] = retry
                if retry.get("answer") == it.get("answer"):
                    note = "검색 같음 · 다시 물으니 일치 — 재현성 문제(캐시 · 동시 요청), 이관과 무관"
                    emit("WARN", note)
                else:
                    note = "검색 같음 · 환경이 같은데 문장이 다름 (다시 물어도 다름, 유사도 %s) — 모델 · 설정 확인" % sim
                    emit("FAIL", note)
                write_diff(os.path.join(diff_dir, qid + ".diff"), it, tgt, note, sim, retry)
        out_items.append(rec)
    return {"llm": tgt_llm, "env": tgt_env, "items": out_items}


def append_csv(path, meta, rows):
    header = ",".join(REPORT_HEADER)
    if os.path.isfile(path) and os.path.getsize(path) > 0:
        with open(path, "r", encoding="utf-8", errors="replace", newline="") as f:
            first = f.readline().rstrip("\r\n")
        if first != header:
            stem = path[:-4] if path.endswith(".csv") else path
            os.rename(path, "%s-%s.csv" % (stem, time.strftime("%Y%m%d-%H%M%S")))
            warn("열 구성이 다른 기존 비교표를 비켜뒀습니다")
    new = not (os.path.isfile(path) and os.path.getsize(path) > 0)
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    with open(path, "w" if new else "a", encoding="utf-8", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        if new:
            w.writerow(REPORT_HEADER)
        for r in rows:
            w.writerow(meta + r)


def verdict(rows, test):
    rs = [r[4] for r in rows if r[0] == test]
    if "FAIL" in rs:
        return "FAIL"
    if "WARN" in rs:
        return "WARN"
    if "PASS" not in rs:
        return "미수행"
    return "PASS"


def cmd_compare(a):
    os.makedirs(a.evidence, exist_ok=True)
    R = Rows()
    spath = os.path.join(a.package, "source-info.json")
    src = read_json(spath) if os.path.isfile(spath) else {}
    compare_services(R, src, a.services.split())
    if a.files_rows:
        if os.path.isfile(a.files_rows):
            with open(a.files_rows, "r", encoding="utf-8") as f:
                for ln in f:
                    p = ln.rstrip("\n").split("\t")
                    if len(p) == 6:
                        R.rows.append(p)
        else:
            R.add("T1-2", "package-files", "-", "-", "SKIP", "패키지 파일 대조 결과 없음")
    else:
        compare_package(R, a.package)
    compare_data(R, src, a.docs, a.data_check, a.data_check_report)
    tgt = compare_golden(R, a.package, a.url, a.runtime, a.evidence, DEFAULT_AGE)

    for name in ("golden.json", "source-info.json", "package-files.tsv", "runtime-versions.txt"):
        p = os.path.join(a.package, name)
        if os.path.isfile(p):
            with open(p, "rb") as fi, open(os.path.join(a.evidence, "source-" + name), "wb") as fo:
                fo.write(fi.read())
    if tgt is not None:
        write_json(os.path.join(a.evidence, "target-golden.json"), tgt)
    with open(os.path.join(a.evidence, "rows.tsv"), "w", encoding="utf-8") as f:
        for r in R.rows:
            f.write("\t".join(r) + "\n")

    src_form = src.get("form") or "-"
    # 패키지 이름 — 소스가 패키지를 만든 시각 (패키지 폴더는 고정 경로 latest 라 이름으로 구분되지 않습니다)
    created = src.get("created_at") or ""
    pkg_name = (created[:4] + created[5:7] + created[8:10] + "-" + created[11:13] + created[14:16] + created[17:19]
                if len(created) >= 19 else os.path.basename(os.path.realpath(a.package.rstrip("/"))))
    append_csv(a.csv, [a.timestamp, a.form, src_form, pkg_name], R.rows)

    tests = ("T1-1", "T1-2", "T1-3", "T2")
    v = {t: verdict(R.rows, t) for t in tests}
    overall = "FAIL" if R.count("FAIL") else ("WARN" if R.count("WARN") else "PASS")
    desc = {"T1-1": "서비스 수 · 이름", "T1-2": "패키지 파일 (이름 · 바이트 · 해시)",
            "T1-3": "데이터 (DB 지문 · 색인 문서 수)", "T2": "LLM 응답 (검색 결과 · 답변)"}
    lines = ["이관 동등성: %s" % overall,
             "일시 %s · 타겟 %s · 소스 %s · 패키지 %s" % (a.timestamp, a.form, src_form, pkg_name), "",
             "%-6s %-6s %5s %5s %5s %5s %5s  %s" % ("test", "판정", "PASS", "FAIL", "WARN", "SKIP", "INFO", "항목")]
    for t in tests:
        cnt = [sum(1 for r in R.rows if r[0] == t and r[4] == res) for res in RESULTS]
        lines.append("%-6s %-6s %5d %5d %5d %5d %5d  %s" % ((t, v[t]) + tuple(cnt) + (desc[t],)))
    bad = [r for r in R.rows if r[4] in ("FAIL", "WARN")]
    lines += ["", "FAIL · WARN %d건" % len(bad)]
    lines += ["  %s [%s] %s — %s → %s%s" % (r[4], r[0], r[1], r[2], r[3], "" if r[5] == "-" else " (%s)" % r[5])
              for r in bad] or ["  (없음)"]
    with open(os.path.join(a.evidence, "summary.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    with open(os.path.join(a.evidence, "verdict.txt"), "w", encoding="utf-8") as f:
        f.write(overall + "\n")
    sys.stdout.write("\n".join(lines) + "\n")
    return 1 if overall == "FAIL" else 0


def cmd_files_check(a):
    R = Rows()
    compare_package(R, a.package)
    with open(a.out, "w", encoding="utf-8") as f:
        for r in R.rows:
            f.write("\t".join(r) + "\n")
    bad = R.count("FAIL")
    info("패키지 파일 대조 — %s" % ("PASS" if not bad else "FAIL %d건" % bad))
    return 1 if bad else 0


# ---------- 진입 ----------
def main(argv=None):
    p = argparse.ArgumentParser(prog="migcompare.py", description="LexAI 이관 동등성 비교")
    sub = p.add_subparsers(dest="cmd")
    sub.required = True

    s = sub.add_parser("inventory")
    s.add_argument("dir")
    s.add_argument("--out", required=True)
    s.add_argument("--exclude", action="append", default=[])
    s.set_defaults(func=cmd_inventory)

    s = sub.add_parser("source-info")
    s.add_argument("--out", required=True)
    s.add_argument("--form", required=True)
    s.add_argument("--docs", default="")
    s.add_argument("--services", default="")
    s.add_argument("--runtime")
    s.add_argument("--url")
    s.set_defaults(func=cmd_source_info)

    s = sub.add_parser("golden-build")
    s.add_argument("--url", required=True)
    s.add_argument("--questions", required=True)
    s.add_argument("--out", required=True)
    s.add_argument("--repeat", type=int, default=2)
    s.add_argument("--age", type=int, default=DEFAULT_AGE)
    s.add_argument("--runtime")
    s.set_defaults(func=cmd_golden_build)

    s = sub.add_parser("files-check")
    s.add_argument("--package", required=True)
    s.add_argument("--out", required=True)
    s.set_defaults(func=cmd_files_check)

    s = sub.add_parser("compare")
    s.add_argument("--package", required=True)
    s.add_argument("--url", required=True)
    s.add_argument("--evidence", required=True)
    s.add_argument("--form", required=True)
    s.add_argument("--docs", default="")
    s.add_argument("--services", default="")
    s.add_argument("--data-check", default="NA")
    s.add_argument("--data-check-report")
    s.add_argument("--runtime")
    s.add_argument("--csv", required=True)
    s.add_argument("--timestamp", required=True)
    s.add_argument("--files-rows")
    s.set_defaults(func=cmd_compare)

    a = p.parse_args(argv)
    try:
        return a.func(a)
    except (OSError, ValueError, KeyError) as e:
        sys.stderr.write("  FATAL %s: %s\n" % (type(e).__name__, e))
        return 2


if __name__ == "__main__":
    sys.exit(main())
