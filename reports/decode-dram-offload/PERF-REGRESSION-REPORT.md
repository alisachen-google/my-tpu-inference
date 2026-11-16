# KV offload to decode DRAM: performance regression test report

Every performance measurement taken to verify the feature (`SGLANG_ENABLE_PREFILL_KV_OFFLOAD_TO_DECODE_DRAM=1`,
[PR 1992](https://github.com/sgl-project/sglang-torchtpu/pull/1992) and
[PR 2086](https://github.com/sgl-project/sglang-torchtpu/pull/2086)), 2026-11-06 to 2026-11-16. The question each
table answers is the same: with the switch on, is any case worse than with it off, and where does it gain. The
companion `HARDENING-REPORT.md` covers correctness and robustness.

## 1. Verdict

| Configuration | Regression with the switch on? | Gain |
|---|---|---|
| gpt-oss-120b (hybrid), write-through, 1P1D | None | Recall 4.1x to 10.7x TTFT; static reuse at 12 and 16 documents 2.1x and 1.7x TTFT, +44% and +41% throughput |
| gpt-oss-120b, write-back, 1P1D, merged head | One point: 8-session return at the host-capacity edge (86.8% vs 93.7% hit in one CDK run; level or ahead in the author's 6 runs). Open as issue 2107 | Recall 16: 0.3% to 55.5% hit, 2.7x TTFT, 2.0x throughput; static 16: +20% throughput |
| gpt-oss-120b, write-back, 2P2D | None on sticky and cross-prefill returns; cross-decode returns are level (cold on both arms) | Same pair 2.9x TTFT, other prefill 2.9x |
| Qwen3-30B (full attention), write-back, 1P1D | About -8% throughput where everything fits in the prefill (recall 8); none beyond | Recall 16 to 24: 0% to 58-75% hit; static 12 to 28: +5 to +15% throughput |
| Qwen3-30B, 1P2D, 2P1D, 2P2D | None | Sticky 7% to 50% hit; cross-prefill under pressure 0% to 64% |
| Cold prefill (fill phases), all configurations | None: pushes in flight do not slow the prefill that issues them | |

First head of PR 2086 (`54a80863a6`) did regress: write-back static reuse lost 13 to 23% throughput at 8 to 16
documents. That was found by this campaign and fixed before merge (section 4).

Caveat that applies to every write-back number below except section 5: the recipes set
`SGLANG_HICACHE_SKIP_HOST_DUPLICATE_RECLAIM=1`, which was later found to hold the feature back. Section 5 shows the
ladder without it.

## 2. Method

- Workloads (128k-token prefix + 8k new tokens per request): **recall ladder**, N sessions filled, then returned
  oldest first, with N = 8, 12, 16 (to 24 on Qwen3); **static-reuse ladder**, 4 to 16 (to 28) documents visited 3
  times each; **mixed sizes**, a 128k stream and a 32k stream concurrently; **2P2D transitions**, fill on one pair,
  return on each of the four pairs, a four-leg chain, and random routing.
- Arms: the same tree with the switch off and on. Caches flushed before every point. One request stream at
  concurrency 4 unless stated.
- Metrics: prefill-side hit (cached over prompt tokens from the prefill's own counters), TTFT p50, total tokens
  per second, requests per minute. Client-reported cached tokens are not used: in P/D they come from the decode.
- Run-to-run spread, measured by running the off arm on two heads: most points within 1 s TTFT p50 and 6%
  throughput; outliers up to 28% throughput on the 8-session return and 3 s on the 12-session return. Differences of
  that size between single runs are not findings.

## 3. Merged head `83198bc912`, gpt-oss-120b, CDK tpu7x (2026-11-11)

### 3.1 Write-back, 1P1D (on `j-4b873230-04db-418e-969d`, off `j-2ac625fd-2bad-4c86-abaa`)

| Point | Prefill-side hit off -> on | Total tok/s off -> on | Gain | TTFT p50 off -> on |
|---|---|---|---|---|
| recall 8, fill (cold) | 0.0% -> 0.0% | 22,360 -> 22,250 | -0% | 23.4 -> 23.5 s |
| recall 8, return | 93.7% -> 86.8% | 169,638 -> 88,363 | **-48%** | 2.4 -> 4.3 s |
| recall 12, fill (cold) | 0.0% -> 0.0% | 22,986 -> 22,956 | -0% | 23.6 -> 23.7 s |
| recall 12, return | 25.8% -> 55.5% | 27,696 -> 43,148 | +56% | 22.0 -> 11.9 s |
| recall 16, fill (cold) | 0.0% -> 0.0% | 22,999 -> 23,039 | +0% | 23.7 -> 23.6 s |
| recall 16, return | 0.3% -> 55.5% | 22,286 -> 44,879 | +101% | 26.0 -> 9.5 s |
| static 4 docs | 62.7% -> 62.7% | 50,767 -> 51,908 | +2% | 10.3 -> 10.6 s |
| static 8 docs | 62.5% -> 62.5% | 53,063 -> 52,153 | -2% | 6.9 -> 7.2 s |
| static 12 docs | 50.9% -> 55.3% | 42,310 -> 44,583 | +5% | 7.5 -> 8.2 s |
| static 16 docs | 39.5% -> 53.9% | 36,114 -> 43,477 | +20% | 11.5 -> 7.1 s |
| mixed, long stream | 21.9% -> 50.0% | 25,398 -> 29,232 | +15% | 19.2 -> 17.2 s |
| mixed, short stream | 21.9% -> 50.0% | 19,287 -> 25,312 | +31% | 9.2 -> 4.5 s |

The recall 8 return is the one regression (issue 2107, section 6).

### 3.2 Write-through, 1P1D (on `j-c1ee04fe-4082-4d27-9bbc`, off `j-b7fb2b34-631a-46bd-be27`)

| Point | Prefill-side hit off -> on | TTFT p50 off -> on | Speedup |
|---|---|---|---|
| recall 8, return | 36.7% -> 94.4% | 17.2 -> 2.4 s | 7.2x |
| recall 12, return | 0.0% -> 56.3% | 25.7 -> 9.0 s | 2.9x |
| recall 16, return | 0.0% -> 88.5% | 25.7 -> 2.4 s | 10.7x |
| static 4 docs | 62.7% -> 62.7% | 7.0 -> 7.1 s | 1.0x |
| static 8 docs | 60.8% -> 61.2% | 6.7 -> 7.9 s | 0.8x |
| static 12 docs | 35.8% -> 60.4% | 12.5 -> 5.6 s | 2.2x |
| static 16 docs | 28.6% -> 58.3% | 15.8 -> 7.0 s | 2.3x |
| mixed, long stream | 11.7% -> 41.4% | 24.4 -> 15.1 s | 1.6x |
| mixed, short stream | 11.7% -> 41.4% | 8.9 -> 8.4 s | 1.1x |

Fill phases level (23.4 to 23.6 s on both arms). Static 8 is 1.2 s slower at the median with equal hit and equal
throughput (within spread).

### 3.3 Write-back, 2P2D sticky-pair transitions (on `j-81cfa513-52b7-47f1-b22c`, off `j-31bd8af0-64b9-4002-b91b`)

| Return on | Prefill-side hit off -> on | TTFT p50 off -> on | Speedup |
|---|---|---|---|
| T1 same pair (p0,d0) | 0.0% -> 78.2% | 26.2 -> 8.9 s | 2.9x |
| T2 other prefill, same decode (p1,d0) | 0.0% -> 62.4% | 25.8 -> 8.9 s | 2.9x |
| T3 same prefill, other decode (p0,d1) | 0.0% -> 11.1% | 26.1 -> 23.5 s | 1.1x |
| T4 both switched (p1,d1) | 0.0% -> 0.0% | 25.9 -> 25.8 s | 1.0x |
| chain leg 1 (p0,d0) | 0.0% -> 77.2% | 26.1 -> 8.4 s | 3.1x |
| chain leg 2 (p1,d0) | 0.0% -> 70.8% | 25.8 -> 8.2 s | 3.1x |
| chain leg 3 (p0,d1) | 22.5% -> 24.5% | 23.4 -> 20.3 s | 1.2x |
| chain leg 4 (p1,d1) | 27.7% -> 44.4% | 20.2 -> 14.4 s | 1.4x |
| random routing, return | 53.1% -> 47.2% | 7.8 -> 7.4 s | 1.1x |

20 points and 288 requests per arm, 0 errors, every pinned point served by its expected pair. The random row depends on
the random split of each run and is a sanity case.

## 4. Head-to-head: first head `54a80863a6` vs merged head `83198bc912` (on arm)

| Case | First head | Merged head |
|---|---|---|
| Integrity, write-back on (used / fresh engines) | 12 / 16, 13 / 16 | 16 / 16, 16 / 16 |
| Write-back static 8 / 12 / 16 docs, hit off -> on | 62.3 -> 55.6, 50.4 -> 32.2, 39.8 -> 27.1% | 62.5 -> 62.5, 50.9 -> 55.3, 39.5 -> 53.9% |
| Write-back static 8 / 12 / 16 docs, throughput on vs off | -13%, -23%, -15% | -2%, +5%, +20% |
| Write-back recall 16 return, TTFT off -> on | 26.1 -> 8.0 s, hit 64.9% | 26.0 -> 9.5 s, hit 55.5% |
| Write-back recall 12 return | 19.3 -> 18.6 s, hit 37.1% | 22.0 -> 11.9 s, hit 55.5% |
| Write-back recall 8 return | 2.5 -> 2.6 s, hit 92.3 -> 94.4% | 2.4 -> 4.3 s, hit 93.7 -> 86.8% |
| Write-back mixed, hit off -> on | 21.9 -> 39.7% | 21.9 -> 50.0% |
| Write-through recall 8 / 12 / 16 return, hit on | 82.6 / 66.0 / 88.5% | 94.4 / 56.3 / 88.5% |
| Write-through static 12 / 16 docs, hit on | 61.4 / 54.5% | 60.4 / 58.3% |
| 2P2D T1 / T2 return | 78.6% 3.1x / 62.9% 2.5x | 78.2% 2.9x / 62.4% 2.9x |

Full per-point tables for both heads: `benchmarks/2026-11-10-pr2086-bench/README.md` and
`results/h83198bc/delta_*.md` there.

## 5. Author's validation of the merged head on bare metal (2026-11-11), and the effect of the reclaim flag

Hosts: prefill and decode on dedicated tpu7x hosts, gpt-oss-120b, TP8 per role.

| Point | Write-back hit off -> on | TTFT p50 | Write-through hit off -> on | TTFT p50 |
|---|---|---|---|---|
| Recall 8 | 84.0% -> 94.4% | 2.4 -> 2.1 s | 24.2% -> 94.4% | 10.8 -> 2.8 s |
| Recall 12 | 24.9% -> 60.1% | 14.9 -> 6.3 s | 0.0% -> 67.9% | 18.4 -> 3.3 s |
| Recall 16 | 0.0% -> 45.4% | 18.6 -> 9.1 s | 0.0% -> 78.7% | 18.5 -> 3.9 s |
| Static 4 | 62.7% -> 62.7% | 4.7 -> 6.7 s | 62.7% -> 62.7% | 6.7 -> 6.7 s |
| Static 8 | 62.5% -> 62.5% | 6.1 -> 6.2 s | 60.5% -> 61.9% | 6.4 -> 6.4 s |
| Static 12 | 51.8% -> 55.4% | 6.4 -> 6.3 s | 35.6% -> 58.9% | 8.0 -> 3.7 s |
| Static 16 | 40.7% -> 52.3% | 10.2 -> 6.7 s | 28.2% -> 58.8% | 10.4 -> 3.5 s |

Write-back, switch on, with and without `SGLANG_HICACHE_SKIP_HOST_DUPLICATE_RECLAIM=1`:

| Point | Flag set (as in every campaign above) | Flag unset (upstream default) |
|---|---|---|
| Recall 8 | 94.4%, 2.1 s | 94.4%, 2.5 s |
| Recall 12 | 60.1%, 6.3 s | 86.9%, 4.5 s |
| Recall 16 | 45.4%, 9.1 s | 77.4%, 3.5 s |
| Static 12 docs | 55.4%, 6.3 s | 60.1%, 2.0 s |
| Static 16 docs | 52.3%, 6.7 s | 52.8%, 6.7 s |

So the write-back gains in sections 3 and 4 understate the feature. The switch-off arm has not been re-measured
without the flag.

## 6. The open point: 8-session return at the host-capacity edge (issue 2107)

| Source | Runs | Switch off | Switch on |
|---|---|---|---|
| CDK, merged head (section 3.1) | 1 | 93.7%, 2.4 s | 86.8%, 4.3 s |
| CDK, first head | 1 | 92.3%, 2.5 s | 94.4%, 2.6 s |
| Bare metal, merged main, A/B #1 | 3 | | 94.4 / 93.7 / 91.6% |
| Bare metal, merged main, A/B #2 | 3 | 84.0 / 84.7 / 84.0% | 88.1 / 86.0 / 91.6% |
| Bare metal, candidate fix (no next-victim stamp), A/B #1 | 3 | | 94.4 / 94.4 / 88.1% |

The loss appears only in runs where pushes fire inside the return and take the session that returns next. It is
timing dependent, small in absolute terms (1.9 s on a 2.4 s return), and bounded to the point where the working set
just fits the prefill's device plus host tier. The same A/B showed a gain for the candidate fix at 9 sessions (63.5%
to 85.7%, one run) and no clear change at 12 and 16. A fix with repeated runs per arm is in progress (2026-11-16).

## 7. Qwen3-30B-A3B (full attention), PR 1992, bare metal (2026-11-06 to 11-10)

1P1D, write-back, switch off -> on:

| Workload | Points | Prefill-side hit | TTFT p50 | Input tok/s |
|---|---|---|---|---|
| Recall | 8 / 12 / 16 / 20 / 24 sessions | 83.1 -> 94.4 / 27.0 -> 53.4 / 0 -> 65.0 / 0 -> 75.4 / 0 -> 58.5% | 4.8 -> 10.0 / 18.4 -> 8.3 / 24.0 -> 9.1 / 23.9 -> 4.8 / 23.2 -> 10.6 s | 32.3k -> 28.1k / 21.8k -> 23.7k / 17.7k -> 26.9k / 17.8k -> 30.8k / 18.0k -> 26.9k |
| Static | 4 / 8 / 12 / 16 / 20 / 24 / 28 docs | 62.7 -> 62.7 / 62.7 -> 62.7 / 51.3 -> 61.4 / 39.2 -> 62.1 / 34.1 -> 55.1 / 24.6 -> 54.5 / 24.7 -> 48.3% | 8.2 -> 8.3 / 7.7 -> 7.7 / 7.8 -> 4.1 / 13.8 -> 5.3 / 14.3 -> 8.2 / 14.8 -> 7.9 / 14.5 -> 9.0 s | about -8% where everything fits, +5 to +15% beyond |

The 8-session recall point on Qwen3 shows the same capacity-edge cost as issue 2107 (hit up, TTFT 4.8 -> 10.0 s,
input throughput -13%). Write-through, switch on: recall 12 / 16 / 20 = 62.4 / 72.8 / 64.4%, static 12 / 16 / 24 = 62.7 /
62.5 / 51.3%.

Multi-engine layouts, write-back, prefill-side hit off -> on:

| Layout | Case | Off -> on |
|---|---|---|
| 1P2D | sticky decode A / B | 7.1 / 7.0% -> 50.7 / 49.3% |
| 1P2D | random decode | 0.0% -> 45.0% |
| 2P1D | random | 33.4% on |
| 2P1D | cross-prefill under pressure, other prefill / back through the first | 65.2% / 76.8% on |
| 2P2D bare metal | pairs (b,v7) / (a,g) / (b,g) / random 16 sessions | 0.0 -> 7.9 / 27.5 -> 50.1 / 24.0 -> 61.3 / 17.7 -> 30.8% |
| 2P2D under pressure | (b,v7) / (a,v7) / (a,g) | 0.0 -> 64.1% (TTFT 31.7 -> 12.3 s) / 0.0 -> 48.7% (31.7 -> 16.4 s) / 0.0 -> 0.0% (that decode never held the sessions) |

The same four layouts were repeated on the CDK cluster for Qwen3 and gpt-oss (2026-11-09 and 11-10) with the results
posted on the PR conversations.

## 8. Load beyond the benchmark points

The 3-hour mixed-load stress (Qwen3-VL-8B, 1P1D, two-host TP16 engines, write-back, switch on) is a saturation
test, not an off-versus-on comparison; it bounds where the pair stops scaling:

| Concurrency | Requests | Errors | TTFT p50 s | Decode host RSS, host 0 / host 1 GB |
|---|---|---|---|---|
| 2 | 33 | 0 | 8.9 | 468 / 477 |
| 9 | 61 | 0 | 44.6 | 479 / 541 |
| 21 | 65 | 0 | 62.9 | 488 / 589 |
| 32 | 80 | 0 | 120.9 | 505 / 606 |
| 48 | 87 | 2 | 217.7 | 510 / 729 |
| 72 | 43 | 0 | 336.5 | ramp stopped: `/health` unanswered |

A single prefill serving 256k-token prompts is prefill-bound from about 6 concurrent requests. Details in
`benchmarks/2026-11-10-pr2086-bench/STRESS-2026-11-11.md`.

## 9. What is still to measure

1. The 2107 fix: repeated runs per arm at 8, 9 and 12 sessions and five runs of the typical cases (in progress).
2. All write-back points, both arms, without the duplicate-reclaim flag.
3. 2P2D on the merged head under write-through.
4. Stress on 2P2D with TP16 engines, and a 6-hour run at fixed concurrency.
