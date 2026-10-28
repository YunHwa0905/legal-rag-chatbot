# 가짜 AI 서버로 migcompare.py 의 판정 경우를 하나씩 확인합니다 — python3 deploy/migcompare_test.py
import json, os, subprocess, sys, tempfile, threading, csv, shutil
from http.server import BaseHTTPRequestHandler, HTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
MC = os.path.join(HERE, "migcompare.py")  # 같은 폴더 (deploy/)
FAKEBIN = tempfile.mkdtemp()
with open(os.path.join(FAKEBIN, "nvidia-smi"), "w") as _f:
    _f.write("#!/bin/sh\necho 'NVIDIA L4, 580.95.05'\n")
os.chmod(os.path.join(FAKEBIN, "nvidia-smi"), 0o755)

STATE = {"temp": 0.0, "seed": 42, "answers": {}, "ids": {}, "flaky": set(), "calls": {}, "error": set()}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        b = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        self._send(200, {"status": "ok", "message": "x", "llm_temperature": STATE["temp"], "llm_seed": STATE["seed"]})

    def do_POST(self):
        q = json.loads(self.rfile.read(int(self.headers["Content-Length"])))["question"]
        n = STATE["calls"].get(q, 0)
        STATE["calls"][q] = n + 1
        if q in STATE["error"]:
            return self._send(500, {"detail": "boom"})
        ans = STATE["answers"].get(q, "답 " + q)
        if q in STATE["flaky"]:
            ans = ans + (" 변형%d" % n)
        ids = STATE["ids"].get(q, [1, 2, 3])
        self._send(200, {"answer": ans, "sources": [{"doc_id": i, "score": 0.9} for i in ids],
                         "age_group_label": "", "question": q, "age": 30})


def run(*args):
    env = dict(os.environ, OLLAMA_MODEL="legal-gemma", PATH=FAKEBIN + ":" + os.environ["PATH"])
    p = subprocess.run([sys.executable, "-I", MC] + list(args), capture_output=True, text=True, env=env)
    return p.returncode, p.stdout, p.stderr


def main():
    srv = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    url = "http://127.0.0.1:%d" % srv.server_port
    d = tempfile.mkdtemp()
    pkg, ev = os.path.join(d, "pkg"), os.path.join(d, "ev")
    os.makedirs(pkg)
    qf = os.path.join(d, "q.txt")
    qs = ["Q1 같음", "Q2 검색다름", "Q3 문장다름", "Q4 타겟오류", "Q5 소스불안정"]
    open(qf, "w").write("# 주석\n" + "\n".join(qs) + "\n")
    rt = os.path.join(d, "rt.txt")
    open(rt, "w").write("ollama 0.12.3\nmodel legal-gemma:latest abc123\n")
    open(os.path.join(pkg, "lexai.db"), "wb").write(b"db")

    # 소스: Q5 는 매번 다른 답
    STATE["flaky"] = {"Q5 소스불안정"}
    rc, out, err = run("golden-build", "--url", url, "--questions", qf, "--out", os.path.join(pkg, "golden.json"), "--runtime", rt)
    assert rc == 0, err
    shutil.copy(os.path.join(pkg, "golden.json"), os.path.join(d, "golden.bak"))
    g = json.load(open(os.path.join(pkg, "golden.json")))
    assert g["deterministic"] and g["items"][4]["stable"] is False and g["items"][0]["stable"], g
    rc, out, err = run("source-info", "--out", os.path.join(pkg, "source-info.json"), "--form", "compose",
                       "--docs", "253207", "--services", "ai frontend ollama opensearch tomcat", "--runtime", rt, "--url", url)
    assert rc == 0, err
    rc, out, err = run("inventory", pkg, "--out", os.path.join(pkg, "package-files.tsv"))
    assert rc == 0, err
    assert len(open(os.path.join(pkg, "package-files.tsv")).read().splitlines()) == 3

    def compare(tag, **kw):
        e = os.path.join(ev, tag)
        args = ["compare", "--package", pkg, "--url", url, "--evidence", e, "--form", "compose-tgt",
                "--docs", kw.get("docs", "253207"), "--services", kw.get("services", "ai frontend ollama opensearch tomcat"),
                "--data-check", kw.get("dc", "PASS"), "--runtime", kw.get("rt", rt),
                "--csv", os.path.join(d, "cmp.csv"), "--timestamp", "2026-10-29 10:00:0" + tag[-1]]
        if kw.get("files_rows"):
            args += ["--files-rows", kw["files_rows"]]
        rc, out, err = run(*args)
        rows = [ln.split("\t") for ln in open(os.path.join(e, "rows.tsv")).read().splitlines()]
        return rc, {r[1]: (r[4], r[5]) for r in rows}, out, err

    # 1) 타겟: Q2 검색 다름, Q3 문장 다름, Q4 오류, 환경 같음 → Q3 재시도도 다름 → FAIL
    STATE["flaky"] = set()
    STATE["ids"] = {"Q2 검색다름": [3, 2, 1]}
    STATE["answers"] = {"Q3 문장다름": "다른 답"}
    STATE["error"] = {"Q4 타겟오류"}
    rc, r, out, err = compare("c1")
    assert rc == 1, (out, err)
    assert r["q01"][0] == "PASS", r["q01"]
    assert r["q02"][0] == "FAIL" and "검색 결과 다름" in r["q02"][1]
    assert r["q03"][0] == "FAIL" and "환경이 같은데" in r["q03"][1], r["q03"]
    assert r["q04"][0] == "FAIL" and "타겟 응답 비정상" in r["q04"][1]
    assert r["q05"][0] == "SKIP", r["q05"]
    assert r["services:count"][0] == "PASS" and r["files:count"][0] == "PASS" and r["index:docs"][0] == "PASS"
    assert os.path.isfile(os.path.join(ev, "c1", "golden-diff", "q03.diff"))
    print("c1 ok")

    # 2) 환경 다름(Ollama 버전) → Q3 WARN, 나머지 정상 → 전체 WARN
    rt2 = os.path.join(d, "rt2.txt")
    open(rt2, "w").write("ollama 0.13.0\nmodel legal-gemma:latest abc123\n")
    STATE["ids"], STATE["error"] = {}, set()
    rc, r, out, err = compare("c2", rt=rt2)
    assert rc == 0, (out, err)
    assert r["q03"][0] == "WARN" and "환경 차이" in r["q03"][1], r["q03"]
    assert r["env:ollama_version"][0] == "INFO"
    assert "이관 동등성: WARN" in out, out
    print("c2 ok")

    # 3) 재현성 문제 — 첫 답만 다르고 다시 물으면 소스와 같음
    STATE["answers"] = {}
    STATE["calls"] = {}
    class Once(dict):
        pass
    orig = H.do_POST
    def once(self):
        q_len = int(self.headers["Content-Length"])
        body = self.rfile.read(q_len)
        q = json.loads(body)["question"]
        STATE["calls"][q] = STATE["calls"].get(q, 0) + 1
        ans = "답 " + q
        if q == "Q3 문장다름" and STATE["calls"][q] == 1:
            ans = "첫 답만 다름"
        self._send(200, {"answer": ans, "sources": [{"doc_id": i, "score": 0.9} for i in [1, 2, 3]],
                         "age_group_label": "", "question": q, "age": 30})
    H.do_POST = once
    rc, r, out, err = compare("c3")
    H.do_POST = orig
    assert r["q03"][0] == "WARN" and "재현성" in r["q03"][1], r["q03"]
    print("c3 ok")

    # 4) 생성 설정 다름 → pre FAIL, 데이터 지문 FAIL, 서비스 빠짐, 문서 수 다름, 패키지 파일 손상
    STATE["temp"] = 0.1
    open(os.path.join(pkg, "lexai.db"), "wb").write(b"broken")
    STATE["answers"] = {"Q3 문장다름": "다른 답"}
    rc, r, out, err = compare("c4", dc="FAIL", services="ai frontend ollama opensearch", docs="1")
    assert rc == 1
    assert r["pre:temperature"][0] == "FAIL"
    assert r["q03"][0] == "FAIL" and "생성 설정" in r["q03"][1], r["q03"]
    assert r["db:fingerprint"][0] == "FAIL" and r["services:count"][0] == "FAIL" and r["index:docs"][0] == "FAIL"
    assert r["file:lexai.db"][0] == "FAIL"
    print("c4 ok")

    # 5) 소스 · 타겟 모두 비결정적 → 문장 비교 SKIP, 검색만 판정
    open(os.path.join(pkg, "lexai.db"), "wb").write(b"db")
    g = json.load(open(os.path.join(pkg, "golden.json")))
    g["llm"] = {"temperature": 0.1, "seed": -1}
    g["deterministic"] = False
    json.dump(g, open(os.path.join(pkg, "golden.json"), "w"))
    STATE["seed"] = -1
    rc, r, out, err = compare("c5")
    assert r["q03"][0] == "SKIP" and "비결정적" in r["q03"][1], r["q03"]
    assert r["pre:deterministic"][0] == "INFO"
    print("c5 ok")

    # 5-1) AI 서버가 생성 설정을 알려 주지 않음(옛 이미지) — 확인 불가라 FAIL 이 아니라 SKIP, 검색만 판정
    g = json.load(open(os.path.join(pkg, "golden.json")))
    g["llm"] = {"temperature": None, "seed": None}
    g["deterministic"] = False
    json.dump(g, open(os.path.join(pkg, "golden.json"), "w"))
    STATE["temp"], STATE["seed"] = None, None
    rc, r, out, err = compare("c55")
    assert r["pre:temperature"][0] == "SKIP" and r["pre:seed"][0] == "SKIP", r
    assert r["q03"][0] == "SKIP" and r["q01"][0] == "PASS", (r["q03"], r["q01"])
    assert "FAIL" not in [v[0] for k, v in r.items() if k.startswith(("pre:", "q0"))], r
    STATE["temp"], STATE["seed"] = 0.1, -1
    print("c5-1 ok")

    # 6) 골든 없는 옛 패키지 → T2 SKIP, 비교표 머리줄 · 타임스탬프
    os.remove(os.path.join(pkg, "golden.json"))
    run("inventory", pkg, "--out", os.path.join(pkg, "package-files.tsv"))
    rc, r, out, err = compare("c6")
    assert r["golden"][0] == "SKIP" and rc == 0, (r, out, err)
    rows = list(csv.reader(open(os.path.join(d, "cmp.csv"))))
    assert rows[0][:5] == ["timestamp", "form", "source_form", "package", "test"], rows[0]
    assert {x[0] for x in rows[1:]} == {"2026-10-29 10:00:0%d" % i for i in range(1, 7)}
    print("c6 ok")

    # 6-1) files-check → compare --files-rows
    fr = os.path.join(d, "fr.tsv")
    rc, out, err = run("files-check", "--package", pkg, "--out", fr)
    assert rc == 0 and len(open(fr).read().splitlines()) == 2, (rc, err)
    rc, r, out, err = compare("c8", files_rows=fr)
    assert r["files:count"][0] == "PASS", r
    print("c6-1 ok")

    # 6-2) 대체 응답 — 근거 문서 없이 고정 문구로 답함 → FAIL
    run("inventory", pkg, "--out", os.path.join(pkg, "package-files.tsv"))
    shutil.copy(os.path.join(d, "golden.bak"), os.path.join(pkg, "golden.json"))
    STATE["temp"], STATE["seed"], STATE["answers"] = 0.0, 42, {}
    STATE["ids"] = {"Q1 같음": []}
    rc, r, out, err = compare("c9")
    assert r["q01"][0] == "FAIL" and "대체 응답" in r["q01"][1], r["q01"]
    STATE["ids"] = {}
    print("c6-2 ok")

    # 7) AI 서버 없음 → golden-build 종료코드 3
    rc, out, err = run("golden-build", "--url", "http://127.0.0.1:1", "--questions", qf, "--out", os.path.join(d, "x.json"))
    assert rc == 3, (rc, err)
    print("c7 ok")
    srv.shutdown()
    shutil.rmtree(d)
    print("ALL OK")


if __name__ == "__main__":
    main()
