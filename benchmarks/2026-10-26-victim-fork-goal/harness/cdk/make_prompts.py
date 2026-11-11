#!/usr/bin/env python3
"""Deterministic prompt corpus for the P/D workload clients: <N>.jsonl files whose rows tokenize to at least N tokens.
make_prompts.py --tokenizer <dir> --out <dir> [--sizes 1024,8192,32768,131072,262144] [--rows 3] [--seed 1]
The clients send token-exact prompts as input_ids with a per-session salt, so the text only has to be long enough and
reproducible; it is pseudo-English built from a fixed word list with a seeded RNG."""
import argparse, json, os, random
from pathlib import Path

WORDS = ("the of and to in a is that for it as was with be by on not he this are or his from at which but have an had "
         "they you were their one all we can her has there been if more when will would who so no she other its may "
         "these than new some could time these two very first into our only over like also years people after through "
         "between most where many well being under those should such however system data model cache memory host page "
         "device transfer request session token prefix window branch node tree pool engine router prefill decode batch "
         "server client result value state change order process block layer rank group plan report study measure point "
         "agent tool answer question document event detail story summary context length limit budget policy write read "
         "load store push pull offer land settle flush idle queue wait start stop run begin end next last first early late "
         "small large long short high low fast slow warm cold hot cool near far open close full empty new old same other "
         "north south east west river mountain valley forest field city village road bridge harbor island coast desert "
         "morning evening winter summer spring autumn history science nature culture market journey letter number table").split()


def row_text(rng, tok, n):
    """Pseudo-English of at least n tokens; counts tokens per chunk so the cost stays linear."""
    parts, count = [], 0
    while count < n:
        chunk = []
        for _ in range(200):
            sent = " ".join(rng.choice(WORDS) for _ in range(rng.randint(6, 18))).capitalize() + "."
            if rng.random() < 0.08:
                sent += "\n\n"
            chunk.append(sent)
        text = " ".join(chunk)
        parts.append(text)
        count += len(tok(text, add_special_tokens=False)["input_ids"])
    text = " ".join(parts)
    while len(tok(text, add_special_tokens=False)["input_ids"]) < n:
        text += " " + " ".join(rng.choice(WORDS) for _ in range(2000))
    return text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tokenizer", required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--sizes", default="1024,8192,32768,131072,262144")
    ap.add_argument("--rows", type=int, default=3)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    os.environ.setdefault("HF_HUB_OFFLINE", "1"); os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
    from transformers import AutoTokenizer
    tok = AutoTokenizer.from_pretrained(a.tokenizer)
    a.out.mkdir(parents=True, exist_ok=True)
    for n in (int(s) for s in a.sizes.split(",")):
        rng = random.Random(a.seed * 1000003 + n)
        with (a.out / f"{n}.jsonl").open("w") as f:
            for r in range(a.rows):
                t = row_text(rng, tok, n + 64)
                f.write(json.dumps({"text": t, "tokens": len(tok(t, add_special_tokens=False)["input_ids"])}) + "\n")
        print(f"{n}.jsonl: {a.rows} rows")


if __name__ == "__main__":
    main()
