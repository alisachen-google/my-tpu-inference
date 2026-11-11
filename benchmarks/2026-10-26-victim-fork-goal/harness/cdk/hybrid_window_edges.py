#!/usr/bin/env python3
"""H5 window edges, and KV-transfer correctness of the offload on a hybrid SWA + full-attention model (gpt-oss).

Greedy, single request at a time (the only exact test on TPU). N sessions are filled so the prefill overflows and
pushes cold branches (full-attention pages plus the branch's last SWA window) to the decode DRAM; then one session
each takes an edge-shaped return, and after a flush of both engines every return prompt is recomputed from scratch
and must give the same output ids:
  W1 exact     : the standard return (fill prompt + answer + new block)                 -> recall expected
  W2 page+1    : the fill prompt extended by exactly one page                            -> recall expected
  W3 superseded: the session is first extended (new window at the longer length), then returns with the SHORTER
                 fill prompt: a prompt that shares only the beginning gets no recall under write_back, but the
                 output must still be exact
  W4 short+long: a 4k prompt first, then the 128k fill prompt of the same session, then its return
  W5 mid-window: the fill prompt cut back by half a page (ends inside the held window)  -> no recall, exact output
Output: one JSON line per case in --out (cached tokens at the return, agreement length, exact) and a SUMMARY line.
"""
import argparse, json, os, sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from spill_bench import load_ids  # noqa: E402
from victim_integrity import gen  # noqa: E402


def agree(a, b):
    n = 0
    for x, y in zip(a or [], b or []):
        if x != y:
            break
        n += 1
    return n


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--lb", required=True)
    ap.add_argument("--flush", nargs="+", required=True)
    ap.add_argument("--prompts", type=Path, required=True)
    ap.add_argument("--tokenizer", required=True)
    ap.add_argument("--sessions", type=int, default=16)
    ap.add_argument("--prefix", type=int, default=131072)
    ap.add_argument("--new", type=int, default=8192)
    ap.add_argument("--page", type=int, default=64)
    ap.add_argument("--out-tokens", type=int, default=64)
    ap.add_argument("--settle", type=float, default=90)
    ap.add_argument("--seed", type=int, default=17)
    ap.add_argument("--out", type=Path, required=True)
    a = ap.parse_args()
    os.environ.setdefault("HF_HUB_OFFLINE", "1"); os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
    from transformers import AutoTokenizer
    tok = AutoTokenizer.from_pretrained(a.tokenizer)
    enc = lambda t: tok(t, add_special_tokens=False)["input_ids"]  # noqa: E731
    sizes = sorted(int(f.stem) for f in a.prompts.glob("*.jsonl") if f.stem.isdigit())
    prefix = load_ids(tok, a.prompts / f"{next(n for n in sizes if n >= a.prefix)}.jsonl", a.prefix)
    pool = enc(json.loads(open(a.prompts / "32768.jsonl").readline())["text"])
    while len(pool) < 3 * a.new + 4 * a.page:
        pool += pool
    answer = load_ids(tok, a.prompts / "1024.jsonl", 64)
    q = enc("\n\nBased on everything above, what should the agent do next? Answer briefly.")

    def block(s, k):
        off = (s * 7919 + k * 104729) % (len(pool) - a.new - 2 * a.page)
        return enc(f"\n\n[tool result {k}]\n") + pool[off: off + a.new]

    ctx = {s: enc(f"Hybrid edge session s{a.seed}-{s:04d}\n\n") + prefix for s in range(a.sessions)}
    fill = {s: ctx[s] + block(s, 0) + q for s in range(a.sessions)}
    a.out.parent.mkdir(parents=True, exist_ok=True)
    rec = []

    def log(**kw):
        rec.append(kw); print(json.dumps(kw), flush=True)
        with a.out.open("a") as f:
            f.write(json.dumps(kw) + "\n")

    # Fill: every session once, one at a time (pressure comes from the count, not the concurrency).
    print(f"fill {a.sessions} sessions", flush=True)
    for s in range(a.sessions):
        r = gen(a.lb, fill[s], 16)
        log(phase="fill", session=s, prompt_tokens=len(fill[s]), cached=r["cached_tokens"], e2e_s=round(r["e2e_s"], 1))
    # W4 part 1: a short prompt in a fresh session, before its long fill.
    s4 = a.sessions  # one more session
    short4 = enc(f"Hybrid edge session s{a.seed}-{s4:04d}\n\n") + prefix[: 4096] + q
    r = gen(a.lb, short4, 16); log(phase="w4_short", session=s4, prompt_tokens=len(short4), cached=r["cached_tokens"])
    ctx[s4] = enc(f"Hybrid edge session s{a.seed}-{s4:04d}\n\n") + prefix; fill[s4] = ctx[s4] + block(s4, 0) + q
    r = gen(a.lb, fill[s4], 16); log(phase="w4_long_fill", session=s4, prompt_tokens=len(fill[s4]), cached=r["cached_tokens"])
    # W3 part 1: extend session 2 so its branch grows (new window at the longer length).
    ext3 = fill[2] + answer + block(2, 1) + q
    r = gen(a.lb, ext3, 16); log(phase="w3_extend", session=2, prompt_tokens=len(ext3), cached=r["cached_tokens"])
    print(f"settle {a.settle}s", flush=True); time.sleep(a.settle)

    returns = {
        "w1_exact": fill[0] + answer + block(0, 1) + q,
        "w2_page_plus_one": fill[1] + pool[: a.page],
        "w3_superseded_shorter": fill[2],
        "w4_short_then_long_return": fill[s4] + answer + block(s4, 1) + q,
        "w5_mid_window": fill[3][: len(fill[3]) - a.page // 2],
    }
    outs = {}
    for name, ids in returns.items():
        r = gen(a.lb, ids, a.out_tokens); outs[name] = r
        log(phase="return", case=name, prompt_tokens=len(ids), cached=r["cached_tokens"], details=r["details"], e2e_s=round(r["e2e_s"], 1))
        if r["out"] is None:
            sys.exit("server did not return output_ids; cannot compare")
    print("verify: flush both engines, recompute", flush=True)
    import requests
    for u in a.flush:
        for _ in range(30):
            if requests.post(u.rstrip("/") + "/flush_cache", timeout=300).status_code == 200:
                break
            time.sleep(10)
    summary = {}
    for name, ids in returns.items():
        r = gen(a.lb, ids, a.out_tokens)
        n = agree(outs[name]["out"], r["out"]); exact = n == a.out_tokens and len(outs[name]["out"]) == len(r["out"])
        summary[name] = {"cached_at_return": outs[name]["cached_tokens"], "cached_recompute": r["cached_tokens"], "agree": n, "exact": exact}
        log(phase="verify", case=name, **summary[name])
    print("SUMMARY " + json.dumps({"exact": sum(v["exact"] for v in summary.values()), "cases": len(summary), "per_case": summary}), flush=True)
    sys.exit(0 if all(v["exact"] for v in summary.values()) else 1)


if __name__ == "__main__":
    main()
