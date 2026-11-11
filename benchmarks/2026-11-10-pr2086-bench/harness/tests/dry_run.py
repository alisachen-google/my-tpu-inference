#!/usr/bin/env python3
"""Dry run of stress_driver.py against tests/mock_pd.py with a stand-in tokenizer (no transformers needed).
dry_run.py --lb http://127.0.0.1:18080 --out /tmp/dry [--duration 120] [--multimodal]"""
import argparse, json, os, sys, types
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))


class FakeTok:
    """Word-level tokenizer: ids are hashes of words; decode joins them back."""

    def __init__(self):
        self.words = {}

    def __call__(self, text, add_special_tokens=False):
        ids = []
        for w in text.split():
            i = (hash(w) & 0xFFFF) + 10
            self.words[i] = w
            ids.append(i)
        return {"input_ids": ids}

    def decode(self, ids, skip_special_tokens=True):
        return " ".join(self.words.get(i, "w%d" % i) for i in ids)


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--lb", default="http://127.0.0.1:18080"); ap.add_argument("--out", default="/tmp/dry")
    ap.add_argument("--duration", type=float, default=120); ap.add_argument("--multimodal", action="store_true")
    ap.add_argument("--conc-max", type=int, default=24); ap.add_argument("--max-input", type=int, default=4096)
    d = ap.parse_args()
    out = Path(d.out); out.mkdir(parents=True, exist_ok=True)
    prompts = out / "prompts"; prompts.mkdir(exist_ok=True)
    tok = FakeTok()
    words = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon".split()
    import random
    rng = random.Random(1)
    with open(prompts / "8192.jsonl", "w") as f:
        for _ in range(3):
            f.write(json.dumps({"text": " ".join(rng.choice(words) + str(rng.randint(0, 99)) for _ in range(8300))}) + "\n")
    # transformers shim so stress_driver.main() can run
    fake = types.ModuleType("transformers")
    fake.AutoTokenizer = types.SimpleNamespace(from_pretrained=lambda *a, **k: tok)
    sys.modules["transformers"] = fake
    import stress_driver
    argv = ["stress_driver", "--lb", d.lb, "--pins", f"p0d0={d.lb},p0d1={d.lb}", "--prefill-urls", d.lb, "--decode-urls", f"{d.lb} {d.lb}",
            "--tokenizer", "x", "--prompts", str(prompts), "--gsm8k", str(HERE.parent / "data/gsm8k_test.jsonl"), "--out", str(out),
            "--run", "dry", "--served-model", "mock", "--duration", str(d.duration), "--max-input", str(d.max_input), "--max-images", "6",
            "--max-output", "48", "--conc-start", "2", "--conc-max", str(d.conc_max), "--step-seconds", "15", "--step-min-requests", "6",
            "--hang-seconds", "20", "--ttft-sat-seconds", "20", "--request-timeout", "60", "--drain-seconds", "60",
            "--verify-n", "8", "--verify-conc", "4", "--gsm8k-n", "12", "--gsm8k-conc", "4", "--context-len", str(d.max_input + 512), "--ttft-timeout", "20"]
    if d.multimodal:
        argv.append("--multimodal")
    sys.argv = argv
    rc = stress_driver.main()
    print("dry run rc", rc)
    v = json.load(open(out / "dry_stress_verdict.json"))
    print(json.dumps({k: v[k] for k in ("ok", "reasons", "cycles", "last_good_conc", "failed_at", "fail_reasons", "gsm8k_baseline_acc")}))
    return rc


if __name__ == "__main__":
    sys.exit(main())
