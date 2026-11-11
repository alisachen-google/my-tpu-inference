#!/usr/bin/env python3
"""GSM8K quality gate through a P/D router (OpenAI chat endpoint, greedy).

gsm8k_eval.py --lb URL --model NAME --gsm8k data/gsm8k_test.jsonl [--n 100] [--seed 0] [--conc 16] [--out file.json]
Prints one JSON line {"acc": .., "n": .., "errors": .., "outputs": [...]} and writes it to --out. The question
sample is fixed by --seed, so two runs are comparable question by question; the driver compares each check with
the idle-server baseline (accuracy drop and per-question output changes)."""
from __future__ import annotations
import argparse, json, random, re, sys, time
from concurrent.futures import ThreadPoolExecutor
import requests

PROMPT = ("Solve the following math problem. Reason step by step, briefly, then give the final answer on the last "
          "line in the form '#### <number>'.\n\nProblem: {q}")
NUM = re.compile(r"-?\d[\d,]*(?:\.\d+)?")


def load(path, n, seed):
    rows = [json.loads(l) for l in open(path) if l.strip()]
    rng = random.Random(seed)
    rng.shuffle(rows)
    out = []
    for r in rows[:n]:
        gold = r["answer"].split("####")[-1].strip().replace(",", "")
        out.append({"question": r["question"], "gold": gold})
    return out


def parse_answer(text):
    if "####" in text:
        tail = text.rsplit("####", 1)[1]
        m = NUM.search(tail)
        if m:
            return m.group(0).replace(",", "")
    m = NUM.findall(text)
    return m[-1].replace(",", "") if m else None


def same(a, b):
    if a is None or b is None:
        return False
    try:
        return abs(float(a) - float(b)) < 1e-6
    except ValueError:
        return a == b


def ask(lb, model, q, max_tokens, timeout):
    body = {"model": model, "messages": [{"role": "user", "content": PROMPT.format(q=q["question"])}],
            "temperature": 0, "max_tokens": max_tokens, "stream": False}
    t0 = time.perf_counter()
    try:
        r = requests.post(lb.rstrip("/") + "/v1/chat/completions", json=body, timeout=timeout)
        if r.status_code != 200:
            return {"error": f"http {r.status_code}: {r.text[:200]}", "e2e_s": time.perf_counter() - t0}
        d = r.json()
        text = d["choices"][0]["message"].get("content") or ""
        usage = d.get("usage") or {}
        pred = parse_answer(text)
        return {"text": text, "pred": pred, "correct": same(pred, q["gold"]), "e2e_s": time.perf_counter() - t0,
                "completion_tokens": usage.get("completion_tokens"),
                "cached_tokens": (usage.get("prompt_tokens_details") or {}).get("cached_tokens")}
    except Exception as e:  # noqa: BLE001
        return {"error": repr(e)[:200], "e2e_s": time.perf_counter() - t0}


def run(lb, model, questions, conc=16, max_tokens=512, timeout=900):
    with ThreadPoolExecutor(max_workers=conc) as ex:
        res = list(ex.map(lambda q: ask(lb, model, q, max_tokens, timeout), questions))
    n = len(questions)
    errors = sum(1 for r in res if "error" in r)
    correct = sum(1 for r in res if r.get("correct"))
    return {"acc": correct / n if n else None, "n": n, "correct": correct, "errors": errors,
            "e2e_p50": sorted(r["e2e_s"] for r in res)[n // 2] if n else None,
            "outputs": [{"gold": q["gold"], "pred": r.get("pred"), "correct": bool(r.get("correct")),
                         "error": r.get("error"), "text": (r.get("text") or "")[:400]} for q, r in zip(questions, res)]}


def compare(base, cur):
    """Per-question agreement of two runs on the same sample: how many predictions changed."""
    bo, co = base.get("outputs") or [], cur.get("outputs") or []
    n = min(len(bo), len(co))
    changed = sum(1 for i in range(n) if bo[i].get("pred") != co[i].get("pred"))
    return {"compared": n, "pred_changed": changed}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--lb", required=True); ap.add_argument("--model", required=True); ap.add_argument("--gsm8k", required=True)
    ap.add_argument("--n", type=int, default=100); ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--conc", type=int, default=16); ap.add_argument("--max-tokens", type=int, default=512)
    ap.add_argument("--timeout", type=float, default=900); ap.add_argument("--out")
    a = ap.parse_args()
    res = run(a.lb, a.model, load(a.gsm8k, a.n, a.seed), a.conc, a.max_tokens, a.timeout)
    if a.out:
        json.dump(res, open(a.out, "w"), indent=1)
    print(json.dumps({k: v for k, v in res.items() if k != "outputs"}))
    return 0 if res["acc"] is not None else 1


if __name__ == "__main__":
    sys.exit(main())
