# KV offload to decode DRAM (spill-over): off vs on, gpt-oss-120b and Qwen3-30B, 2026-11-17

Every table compares `SGLANG_ENABLE_PREFILL_KV_OFFLOAD_TO_DECODE_DRAM` unset (off) against `=1` (on) and gives the gain per
metric. All runs are single runs on the shared CDK tpu7x cluster, 1 prefill + 1 decode, one 2x2x1 host (8 TensorCores)
per engine, write-back HiCache on both roles, recipe `pd1992-qwen3-30b-xpyd`, harness `pd2086-harness`.

**Summary**

| Model | Workload | Offload gain | Where |
|---|---|---|---|
| gpt-oss-120b | Static reuse, 128k+8k | none up to 8 documents; from 12 documents +5.5 to +24.9 pts of hit, up to 1.63x TTFT and +38% throughput | section 1 |
| gpt-oss-120b | Static reuse, 256k+16k | none up to 4 documents; from 6 documents +1.8 to +13.5 pts of hit, up to 1.37x TTFT and +18% throughput | section 1 |
| gpt-oss-120b | Recall ladder, 128k+8k | 12 and 16 sessions: +38 and +58 pts of hit, 2.2x and 2.9x TTFT; 8 sessions: a loss (off baseline from another day) | section 2 |
| gpt-oss-120b | Shared 8k prefix above each session | none on upstream (PR 2086 alone equals off); with the PR 2052 fix +31 to +89 pts of hit | section 3 |
| Qwen3-30B FP8 | Shared 8k prefix above each session, with the PR 2052 fix | +54 to +79 pts of hit, 2.0x to 2.8x TTFT, +78% to +117% throughput | section 4 |
| Qwen3-30B, pipeline-parallel prefill | Recall and static, 24.6k+2k sessions | hit rises, latency and throughput do not (recompute of a 27k prompt takes about 2.4 s) | section 5 |

Columns: prefill-side hit = cached / prompt tokens on the prefill during the measured phase; TTFT and E2E are client
p50; total tok/s = (prompt + output tokens) / wall. Gains: hit in points, latency as off / on, throughput in percent.
Recall and shared-prefix rows are the return phase (the fill phase is cold by construction).

## 1. gpt-oss-120b, static prefix reuse (PR 1789's ladders)

K documents x 3 visits, shuffled, concurrency 4, 256 output tokens, caches wiped before every point. Tree: PR 2086 head
`83198bc9` (its offload code is identical to upstream main `82e2b973`), TP8 per role, fp8 KV,
`SGLANG_HICACHE_SKIP_HOST_DUPLICATE_RECLAIM=1` as in the original PR 1789 runs. Off `j-ade6c98d-55f1-4225-83a0`,
on `j-3b4f7b55-8424-4b2b-b7ae`.

| Case | Prefill-side hit off → on | Hit gain | TTFT p50 off → on | TTFT speedup | E2E p50 off → on | E2E speedup | Total tok/s off → on | Throughput gain |
|---|---|---|---|---|---|---|---|---|
| 128k+8k, 4 docs | 62.7% → 62.7% | +0.0 pts | 9.6 s → 8.6 s | 1.11x | 13.6 s → 11.7 s | 1.16x | 47,760 → 47,312 | -1% |
| 128k+8k, 8 docs | 62.5% → 62.5% | +0.0 pts | 6.8 s → 7.4 s | 0.91x | 9.0 s → 9.8 s | 0.92x | 54,078 → 51,870 | -4% |
| 128k+8k, 12 docs | 51.5% → 57.0% | +5.5 pts | 10.8 s → 6.5 s | 1.67x | 13.0 s → 8.7 s | 1.49x | 43,292 → 46,515 | +7% |
| 128k+8k, 16 docs | 39.6% → 55.5% | +15.9 pts | 11.7 s → 8.4 s | 1.40x | 14.1 s → 10.8 s | 1.30x | 36,164 → 44,445 | +23% |
| 128k+8k, 20 docs | 33.9% → 54.4% | +20.5 pts | 15.3 s → 9.4 s | 1.63x | 17.5 s → 11.9 s | 1.48x | 33,500 → 45,320 | +35% |
| 128k+8k, 24 docs | 24.7% → 49.6% | +24.9 pts | 16.5 s → 10.5 s | 1.57x | 18.7 s → 13.0 s | 1.44x | 29,816 → 41,170 | +38% |
| 128k+8k, 28 docs | 24.7% → 44.9% | +20.2 pts | 16.6 s → 11.5 s | 1.44x | 18.8 s → 14.2 s | 1.33x | 29,821 → 38,716 | +30% |
| 256k+16k, 2 docs | 62.7% → 62.7% | -0.0 pts | 20.0 s → 21.5 s | 0.93x | 22.1 s → 23.8 s | 0.93x | 37,264 → 34,936 | -6% |
| 256k+16k, 4 docs | 62.5% → 62.5% | +0.0 pts | 22.7 s → 22.4 s | 1.01x | 25.4 s → 25.2 s | 1.01x | 36,174 → 35,394 | -2% |
| 256k+16k, 6 docs | 52.1% → 58.2% | +6.0 pts | 31.5 s → 23.5 s | 1.34x | 34.2 s → 27.4 s | 1.25x | 28,962 → 31,694 | +9% |
| 256k+16k, 8 docs | 50.5% → 52.3% | +1.8 pts | 38.2 s → 37.8 s | 1.01x | 41.0 s → 40.5 s | 1.01x | 28,710 → 28,537 | -1% |
| 256k+16k, 10 docs | 43.4% → 55.7% | +12.3 pts | 38.1 s → 30.8 s | 1.24x | 40.8 s → 34.3 s | 1.19x | 25,770 → 30,358 | +18% |
| 256k+16k, 12 docs | 27.7% → 41.2% | +13.5 pts | 53.4 s → 39.1 s | 1.37x | 56.2 s → 41.6 s | 1.35x | 20,485 → 23,519 | +15% |
| 256k+16k, 14 docs | 26.8% → 38.2% | +11.5 pts | 52.7 s → 43.0 s | 1.23x | 55.6 s → 46.0 s | 1.21x | 20,301 → 22,862 | +13% |

Offload activity on the on run: 1,367 pushes stored, 136 recalls, 15.7M tokens recalled; 0 request errors and no engine
exception in either arm; 216 "subtree drop declined" lines on the on run's prefill (the known effect of the
duplicate-reclaim flag). The off run was preempted three times; its points are the last clean attempt of each. The
12-document off TTFT varied between attempts (7.1 to 10.8 s).

## 2. gpt-oss-120b, recall ladder

N sessions of 131,072 + 8,192 tokens filled at concurrency 4, 20 s settle, then returned oldest first; 16 output tokens.
Same tree and settings as section 1. On `j-fc37a8f9-6529-44d2-b15d` (2026-11-17). **The off column is from the
2026-11-11 campaign on the same tree and settings** (`../2026-11-10-pr2086-bench/results/h83198bc/wb_off`), not a
same-day run.

| Case | Prefill-side hit off → on | Hit gain | TTFT p50 off → on | TTFT speedup | E2E p50 off → on | E2E speedup | Total tok/s off → on | Throughput gain |
|---|---|---|---|---|---|---|---|---|
| 8 sessions | 93.7% → 89.6% | -4.1 pts | 2.4 s → 3.6 s | 0.66x | 3.1 s → 4.3 s | 0.73x | 169,638 → 96,031 | -43% |
| 12 sessions | 25.8% → 63.4% | +37.6 pts | 22.0 s → 10.1 s | 2.17x | 22.2 s → 10.3 s | 2.16x | 27,696 → 51,932 | +88% |
| 16 sessions | 0.3% → 57.9% | +57.5 pts | 26.0 s → 8.9 s | 2.93x | 26.2 s → 9.0 s | 2.90x | 22,286 → 46,926 | +111% |

At 8 sessions everything still fits in the prefill's own tiers, so the offload has nothing to add; the lower on values
there mix the cost of pushing with day-to-day difference between the two runs.

## 3. gpt-oss-120b, sessions behind a shared 8k prefix (the PR 2052 case)

Each session is a shared 8,192-token prefix, then its own tokens up to 131,072, then 8,192 new; filled, 60 s settle,
returned oldest first; 64 output tokens. Off `j-c42230ac-adfe-4eb3-9172`.

**3a. Upstream as it is (PR 2086 head), on `j-a9e5fd90-6cb2-430c-a5b7`:** the offload does nothing for the shared-prefix
cases (issue 2051); only the independent-session case gains.

| Case | Prefill-side hit off → on | Hit gain | TTFT p50 off → on | TTFT speedup | E2E p50 off → on | E2E speedup | Total tok/s off → on | Throughput gain |
|---|---|---|---|---|---|---|---|---|
| 16 sessions, shared 8k prefix, 1 at a time | 5.5% → 5.5% | +0.0 pts | 6.5 s → 6.6 s | 0.99x | 7.0 s → 7.1 s | 0.99x | 20,508 → 20,522 | +0% |
| 16 sessions, shared prefix, 2 concurrent | 5.5% → 5.5% | +0.0 pts | 12.0 s → 12.1 s | 1.00x | 12.6 s → 12.6 s | 1.00x | 22,920 → 22,961 | +0% |
| 20 sessions, shared prefix, 4 concurrent | 5.5% → 5.5% | +0.0 pts | 24.9 s → 24.6 s | 1.01x | 25.5 s → 25.2 s | 1.01x | 22,879 → 23,032 | +1% |
| 24 sessions, shared prefix, 4 concurrent | 5.5% → 5.5% | +0.0 pts | 24.9 s → 24.7 s | 1.01x | 25.5 s → 25.2 s | 1.01x | 22,883 → 23,076 | +1% |
| 16 independent sessions, 1 at a time | 0.0% → 67.7% | +67.7 pts | 6.7 s → 1.8 s | 3.72x | 7.2 s → 2.3 s | 3.14x | 19,954 → 38,437 | +93% |

**3b. With the PR 2052 fix, on `j-e49f6c9a-df73-43cd-ac72`** (PR 2086 head + the PR 2052 commit + a five-line guard that
holds the push candidate while host room is made; without the guard PR 2052 makes no pushes on this base):

| Case | Prefill-side hit off → on | Hit gain | TTFT p50 off → on | TTFT speedup | E2E p50 off → on | E2E speedup | Total tok/s off → on | Throughput gain |
|---|---|---|---|---|---|---|---|---|
| 16 sessions, shared 8k prefix, 1 at a time | 5.5% → 75.3% | +69.7 pts | 6.5 s → 1.7 s | 3.90x | 7.0 s → 2.2 s | 3.20x | 20,508 → 43,656 | +113% |
| 16 sessions, shared prefix, 2 concurrent | 5.5% → 94.4% | +88.8 pts | 12.0 s → 1.8 s | 6.75x | 12.6 s → 2.4 s | 5.31x | 22,920 → 108,891 | +375% |
| 20 sessions, shared prefix, 4 concurrent | 5.5% → 62.0% | +56.5 pts | 24.9 s → 9.3 s | 2.68x | 25.5 s → 9.9 s | 2.58x | 22,879 → 48,689 | +113% |
| 24 sessions, shared prefix, 4 concurrent | 5.5% → 36.5% | +30.9 pts | 24.9 s → 18.7 s | 1.34x | 25.5 s → 19.2 s | 1.32x | 22,883 → 31,663 | +38% |
| 16 independent sessions, 1 at a time | 0.0% → 60.7% | +60.7 pts | 6.7 s → 1.6 s | 4.12x | 7.2 s → 2.2 s | 3.30x | 19,954 → 36,394 | +82% |

The on run logged 48 `DEADLINE_EXCEEDED` lines (offers the prefill declined and never pulled) and 16 refused drops; no
request failed.

## 4. Qwen3-30B-A3B FP8, sessions behind a shared 8k prefix, with the PR 2052 fix

Same workload as section 3, TP8 per role, fp8 KV, PR 2086 head + PR 2052 + the guard. Off `j-b956931a-b498-4899-bbed`,
on `j-dd4fe7c9-de61-4f6b-8294`.

| Case | Prefill-side hit off → on | Hit gain | TTFT p50 off → on | TTFT speedup | E2E p50 off → on | E2E speedup | Total tok/s off → on | Throughput gain |
|---|---|---|---|---|---|---|---|---|
| 16 sessions, shared 8k prefix, 1 at a time | 5.5% → 84.3% | +78.8 pts | 7.9 s → 2.8 s | 2.82x | 8.4 s → 3.3 s | 2.55x | 17,199 → 35,753 | +108% |
| 16 sessions, shared prefix, 2 concurrent | 5.5% → 67.5% | +61.9 pts | 14.9 s → 7.3 s | 2.02x | 15.4 s → 8.3 s | 1.84x | 18,890 → 37,142 | +97% |
| 20 sessions, shared prefix, 4 concurrent | 5.5% → 64.9% | +59.4 pts | 30.4 s → 11.7 s | 2.59x | 30.9 s → 12.7 s | 2.43x | 18,898 → 41,048 | +117% |
| 24 sessions, shared prefix, 4 concurrent | 5.5% → 59.2% | +53.6 pts | 30.3 s → 12.1 s | 2.49x | 30.9 s → 12.7 s | 2.42x | 18,930 → 35,411 | +87% |
| 16 independent sessions, 1 at a time | 0.0% → 69.7% | +69.7 pts | 8.1 s → 2.9 s | 2.80x | 8.6 s → 3.8 s | 2.28x | 16,842 → 30,053 | +78% |

On PR 2086 head without the fix the first case measured 0 pushes, 5.6% hit, TTFT p50 8.0 s with the offload on
(`j-be162f1a-f0f9-4cf8-a05f`), the same as off. Every request completed in both arms; every push was stored.

## 5. Qwen3-30B-A3B, pipeline-parallel prefill (PP8, TP1) to tensor-parallel decode (TP8)

Draft PR 2202 tree `c61131c7`, bf16 KV, Raiden pipeline transfer, duplicate-reclaim flag unset. Sessions are
24,576 + 2,048 tokens with the device pool cut to 147,456 tokens, because prompts above about 131k tokens fail on this
transfer path (`Byte span plan exceeds the repeat expansion bound`; a fix is in test). Recall ladder as in section 2,
static ladder as in section 1. Off `j-98ae993a-ee51-42a7-b3db`, on `j-b7ab1318-89f2-4022-93e4`.

| Case | Prefill-side hit off → on | Hit gain | TTFT p50 off → on | TTFT speedup | E2E p50 off → on | E2E speedup | Total tok/s off → on | Throughput gain |
|---|---|---|---|---|---|---|---|---|
| Recall, 8 sessions | 45.4% → 92.5% | +47.1 pts | 1.6 s → 3.2 s | 0.49x | 1.8 s → 3.4 s | 0.52x | 56,003 → 40,735 | -27% |
| Recall, 12 sessions | 38.5% → 51.0% | +12.5 pts | 2.3 s → 2.4 s | 0.93x | 2.4 s → 2.5 s | 0.95x | 42,469 → 41,116 | -3% |
| Recall, 16 sessions | 0.0% → 13.1% | +13.1 pts | 2.4 s → 2.5 s | 0.97x | 2.6 s → 2.7 s | 0.96x | 39,654 → 37,043 | -7% |
| Static, 4 docs | 61.5% → 61.5% | +0.0 pts | 1.1 s → 1.1 s | 1.01x | 3.1 s → 3.0 s | 1.03x | 29,946 → 29,969 | +0% |
| Static, 8 docs | 61.5% → 61.5% | +0.0 pts | 1.4 s → 1.4 s | 0.98x | 3.2 s → 3.4 s | 0.93x | 30,760 → 28,986 | -6% |
| Static, 12 docs | 56.8% → 58.4% | +1.6 pts | 1.3 s → 1.5 s | 0.87x | 3.6 s → 3.7 s | 0.97x | 27,792 → n/a | n/a |
| Static, 16 docs | 41.9% → 51.8% | +9.8 pts | 1.4 s → 1.4 s | 1.01x | 3.7 s → 3.8 s | 0.98x | 27,822 → 27,465 | -1% |

- The on run made 58 pushes (52 stored) and 15 recalls; 6 pushes timed out unpulled on the decode
  (48 `DEADLINE_EXCEEDED, await_pull` lines). No request failed in either arm.
- The 8-session off row recorded 11 requests for 8 sessions (a point mixed across a spot restart): its hit and TTFT are
  not reliable. The 12-document on throughput spanned a restart and is omitted.
- Recomputing a 27k-token prompt takes about 2.4 s on this prefill, about what a recall costs, so a higher hit rate does
  not become a faster response at this size.

## Not in this file

- Muse Spark AgentX with the offload: no valid point yet (PP8 prefill runs fail on prompts above about 131k tokens).
- PR 2086 against PR 2086 + PR 2052 on the static and recall ladders (PR 2052 regresses the static ladder; a rule that
  limits the ancestor backup to short prefixes is in test).

## Files

- `results/<job id>/`: `points.jsonl` (one record per measured point), `stage.log`, and `evidence.txt` (offload counters
  per point) of every job cited above, plus `j-0c68b7a6-1fb2-47ca-abb5` (the ladders with PR 2052 applied).
- `harness/`: the stage scripts and clients these runs used (`stage_shared.sh`, `stage_static1789.sh`, `stage_bench.sh`,
  `common.sh`, `victim_recall.py`, `static_reuse.py`, `point_metrics.py`) and `mk_onoff_md.py`, which builds the tables
  from the points files.
