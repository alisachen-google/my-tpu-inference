#!/usr/bin/env python3
"""Session-sweep workload in the shape of the victim prefix cache benchmark.

N sessions, each with its own unique prefix (default 4,096 tokens, salted so no two
sessions share a page). A session has T turns (default 4): each turn appends a
64-token question and the model answers with 128 tokens (greedy, ignore_eos).
Conversation history is kept (KV_CHAIN): turn t's prompt is the prefix, then the
earlier questions and the model's own earlier answers, then question t.

The workload runs in passes. Pass p runs turn (p-1) % T of every session, with a
fixed client concurrency. Round 1 is passes 1..T; round 2 (passes T+1..2T)
replays the same conversation from turn 0 with the same recorded answers, so its
prompts are identical to round 1's and every hit or miss is a cache fact. Pass 1
is the cold pass and is reported separately.

Per request: prompt_tokens, cached_tokens (and the tier details), completion
tokens, TTFT, end-to-end time. The summary reports, over the measured window
(passes 2..2T) and per pass: token cache hit rate (cached / prompt, each logical
token once), request hit rate (requests with any cached token / successes),
failures, total tokens/s (prompt + completion over wall), output tokens/s,
TTFT and e2e p50/p95, and the pass wall times.
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import requests  # noqa: E402

from spill_bench import scrape  # noqa: E402


def generate(lb: str, input_ids, max_new_tokens: int, timeout: float) -> dict:
    """Stream one request; return timings, meta and the full generated text."""
    body = {"input_ids": input_ids, "sampling_params": {"temperature": 0, "max_new_tokens": max_new_tokens, "ignore_eos": True}, "stream": True}
    t0 = time.perf_counter()
    ttft = None
    last = None
    with requests.post(lb.rstrip("/") + "/generate", json=body, stream=True, timeout=timeout) as r:
        r.raise_for_status()
        for line in r.iter_lines():
            if not line or not line.startswith(b"data:"):
                continue
            payload = line[5:].strip()
            if payload == b"[DONE]":
                break
            last = json.loads(payload)
            if ttft is None:
                ttft = time.perf_counter() - t0
    e2e = time.perf_counter() - t0
    meta = (last or {}).get("meta_info", {})
    comp = meta.get("completion_tokens")
    return {"ttft_s": ttft, "e2e_s": e2e, "decode_tok_s": (comp - 1) / (e2e - ttft) if comp and ttft and e2e > ttft else None,
            "prompt_tokens": meta.get("prompt_tokens"), "completion_tokens": comp, "cached_tokens": meta.get("cached_tokens"),
            "cached_tokens_details": meta.get("cached_tokens_details"), "text": (last or {}).get("text", "")}


def pct(values, p):
    if not values:
        return None
    s = sorted(values)
    k = max(0, min(len(s) - 1, int(round((len(s) - 1) * p))))
    return s[k]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lb", default="http://10.128.15.217:8080")
    ap.add_argument("--prefill-url", default="http://10.128.15.217:30000")
    ap.add_argument("--decode-url", default="http://10.128.0.90:30000")
    ap.add_argument("--prompts", type=Path, default=Path.home() / "pd_disagg/prompts/gpt-oss")
    ap.add_argument("--tokenizer", default="/mnt/data/tt/hf-cache/hub/models--openai--gpt-oss-120b/snapshots/b5c939de8f754692c1647ca79fbf85e8c1e70f8a")
    ap.add_argument("--sessions", type=int, required=True)
    ap.add_argument("--turns", type=int, default=4)
    ap.add_argument("--rounds", type=int, default=2)
    ap.add_argument("--prefix", type=int, default=4096)
    ap.add_argument("--question", type=int, default=64)
    ap.add_argument("--answer", type=int, default=128)
    ap.add_argument("--concurrency", type=int, default=8)
    ap.add_argument("--timeout", type=float, default=600)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--run", required=True)
    ap.add_argument("--label", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    from transformers import AutoTokenizer

    tok = AutoTokenizer.from_pretrained(args.tokenizer)
    rows = [json.loads(l) for l in (args.prompts / "32768.jsonl").open()]
    pool = []
    for r in rows:
        pool += tok(r["text"], add_special_tokens=False)["input_ids"]
    # Unique prefix per session: a salt line, then a distinct slice of the pool.
    need = args.sessions * args.prefix
    while len(pool) < need + args.prefix:
        pool = pool + pool
    questions = [
        tok(f"\n\nQuestion {t + 1}: given the document above, summarize the part most relevant to step {t + 1} and name one risk. ", add_special_tokens=False)["input_ids"]
        for t in range(args.turns)
    ]
    q_pad = tok(" Please be specific and concrete in your answer.", add_special_tokens=False)["input_ids"]
    questions = [(q + q_pad * 8)[: args.question] for q in questions]

    sessions = []
    for sid in range(args.sessions):
        salt = tok(f"Session {uuid.uuid4().hex} seed {args.seed} user {sid}\n", add_special_tokens=False)["input_ids"]
        body = pool[sid * args.prefix : sid * args.prefix + args.prefix]
        prefix = (salt + body)[: args.prefix]
        sessions.append({"sid": sid, "prefix": prefix, "answers": [None] * args.turns})

    out = open(args.out, "a")
    lock = threading.Lock()
    records = []

    def prompt_for(s, turn):
        ids = list(s["prefix"])
        for t in range(turn):
            ids += questions[t]
            ans = s["answers"][t]
            ids += ans if ans else []
        ids += questions[turn]
        return ids

    def one(s, turn, rnd, pas):
        ids = prompt_for(s, turn)
        rec = {"run": args.run, "label": args.label, "sessions": args.sessions, "session": s["sid"],
               "round": rnd, "turn": turn, "pass": pas, "prompt_len": len(ids)}
        try:
            res = generate(args.lb, ids, args.answer, args.timeout)
            rec.update({k: res.get(k) for k in ("ttft_s", "e2e_s", "prompt_tokens", "completion_tokens", "cached_tokens", "cached_tokens_details", "decode_tok_s")})
            if rnd == 0 and s["answers"][turn] is None:
                text = res.get("text") or res.get("text_head") or ""
                ans = tok(text, add_special_tokens=False)["input_ids"][: args.answer]
                if len(ans) < args.answer:
                    ans += tok(" ok", add_special_tokens=False)["input_ids"] * (args.answer - len(ans))
                s["answers"][turn] = ans[: args.answer]
        except Exception as e:  # noqa: BLE001
            rec["error"] = str(e)[:200]
            if rnd == 0 and s["answers"][turn] is None:
                s["answers"][turn] = tok(" ok", add_special_tokens=False)["input_ids"] * args.answer
        with lock:
            records.append(rec)
            out.write(json.dumps(rec) + "\n")
            out.flush()
        return rec

    m0 = {"prefill": scrape(args.prefill_url), "decode": scrape(args.decode_url)}
    passes = []
    t_all = time.perf_counter()
    pas = 0
    with ThreadPoolExecutor(max_workers=args.concurrency) as ex:
        for rnd in range(args.rounds):
            for turn in range(args.turns):
                pas += 1
                t0 = time.perf_counter()
                futs = [ex.submit(one, s, turn, rnd, pas) for s in sessions]
                recs = [f.result() for f in futs]
                wall = time.perf_counter() - t0
                ok = [r for r in recs if "error" not in r]
                prompt = sum(r.get("prompt_tokens") or 0 for r in ok)
                cached = sum(r.get("cached_tokens") or 0 for r in ok)
                comp = sum(r.get("completion_tokens") or 0 for r in ok)
                p = {"pass": pas, "round": rnd + 1, "turn": turn + 1, "wall_s": round(wall, 1),
                     "requests": len(recs), "ok": len(ok), "failed": len(recs) - len(ok),
                     "prompt_tokens": prompt, "cached_tokens": cached, "completion_tokens": comp,
                     "token_hit_rate": round(cached / prompt, 4) if prompt else None,
                     "request_hit_rate": round(sum(1 for r in ok if (r.get("cached_tokens") or 0) > 0) / len(ok), 4) if ok else None,
                     "total_tok_s": round((prompt + comp) / wall, 1), "output_tok_s": round(comp / wall, 1),
                     "ttft_p50": pct([r["ttft_s"] for r in ok if r.get("ttft_s")], 0.5),
                     "ttft_p95": pct([r["ttft_s"] for r in ok if r.get("ttft_s")], 0.95),
                     "e2e_p50": pct([r["e2e_s"] for r in ok if r.get("e2e_s")], 0.5),
                     "e2e_p95": pct([r["e2e_s"] for r in ok if r.get("e2e_s")], 0.95)}
                passes.append(p)
                print("PASS " + json.dumps(p), flush=True)
    wall_all = time.perf_counter() - t_all
    m1 = {"prefill": scrape(args.prefill_url), "decode": scrape(args.decode_url)}

    measured = [r for r in records if r["pass"] > 1 and "error" not in r]
    m_wall = sum(p["wall_s"] for p in passes if p["pass"] > 1)
    prompt = sum(r.get("prompt_tokens") or 0 for r in measured)
    cached = sum(r.get("cached_tokens") or 0 for r in measured)
    comp = sum(r.get("completion_tokens") or 0 for r in measured)
    tiers = {"device": 0, "host": 0, "storage": 0}
    for r in measured:
        d = r.get("cached_tokens_details") or {}
        for k in tiers:
            tiers[k] += d.get(k) or 0
    summary = {
        "run": args.run, "label": args.label, "sessions": args.sessions, "turns": args.turns, "rounds": args.rounds,
        "prefix": args.prefix, "question": args.question, "answer": args.answer, "concurrency": args.concurrency,
        "wall_s_total": round(wall_all, 1), "wall_s_measured": round(m_wall, 1), "cold_pass_wall_s": passes[0]["wall_s"] if passes else None,
        "requests_total": len(records), "failures_total": sum(1 for r in records if "error" in r),
        "measured_requests": len(measured), "measured_prompt_tokens": prompt, "measured_cached_tokens": cached,
        "measured_completion_tokens": comp,
        "token_hit_rate": round(cached / prompt, 4) if prompt else None,
        "request_hit_rate": round(sum(1 for r in measured if (r.get("cached_tokens") or 0) > 0) / len(measured), 4) if measured else None,
        "total_tok_s": round((prompt + comp) / m_wall, 1) if m_wall else None,
        "output_tok_s": round(comp / m_wall, 1) if m_wall else None,
        "ttft_p50": pct([r["ttft_s"] for r in measured if r.get("ttft_s")], 0.5),
        "ttft_p95": pct([r["ttft_s"] for r in measured if r.get("ttft_s")], 0.95),
        "e2e_p50": pct([r["e2e_s"] for r in measured if r.get("e2e_s")], 0.5),
        "e2e_p95": pct([r["e2e_s"] for r in measured if r.get("e2e_s")], 0.95),
        "cached_tokens_by_tier": tiers,
        "round2_token_hit_rate": (lambda rs: round(sum(r.get("cached_tokens") or 0 for r in rs) / max(1, sum(r.get("prompt_tokens") or 0 for r in rs)), 4))([r for r in measured if r["round"] == 1]),
        "passes": passes,
        "metrics_delta": {
            side: {k: (m1[side].get(k, 0) - m0[side].get(k, 0)) for k in set(m0[side]) | set(m1[side])}
            for side in ("prefill", "decode")
        },
    }
    with open(args.out.replace(".jsonl", "") + f".{args.label}.summary.json", "w") as f:
        json.dump(summary, f, indent=1)
    print("SUMMARY " + json.dumps({k: v for k, v in summary.items() if k != "passes"}), flush=True)


if __name__ == "__main__":
    main()
