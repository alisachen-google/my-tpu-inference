# KV offload behind a pipeline-parallel prefill (draft PR 2202): off vs on, gpt-oss-120b and Qwen3-30B, 2026-11-17

The full 1P1D case set of the tensor-parallel campaign, run with a pipeline-parallel prefill (PP8, TP1, EP1) feeding a
tensor-parallel decode (TP8, EP8) over the Raiden pipeline transfer. One prefill host and one decode host (tpu7x
2x2x1, 8 TensorCores each), write-back HiCache, bf16 KV, `SGLANG_HICACHE_SKIP_HOST_DUPLICATE_RECLAIM` unset, client
concurrency 4, caches wiped before every point, single runs. Off = `SGLANG_ENABLE_PREFILL_KV_OFFLOAD_TO_DECODE_DRAM`
unset; on = `1` with a 40 GB stage store per decode rank.

**Cache hit** is the client-side figure: cached prompt tokens over prompt tokens, as each response reports them, over
the requests that returned output. An earlier version of this file used the prefill's `cached_tokens_total` counter,
which undercounts on gpt-oss-120b in 15 of 22 points (by up to 46 points; cause not traced) and combines the two streams of
the mixed case. The Qwen3-30B rows are the same under both definitions except the mixed case. Latency and throughput
columns are unchanged.

**Tree:** PR 2202 head `c61131c7` plus two local commits that are not in the PR (`159d45b7`, `2cf5a10d`, branch
`pipeline-transfer-page-cap`): they cap the size of one native pipeline transfer. Without them every prompt above about
131k tokens fails on this path with `Byte span plan exceeds the repeat expansion bound`, offload on or off.

**Summary**

| | gpt-oss-120b | Qwen3-30B |
|---|---|---|
| Recall, 16 sessions | hit +41.5 pts, TTFT 1.18x, throughput +38% | hit +55.1 pts, TTFT 1.61x, throughput +56% |
| Recall, 12 sessions | hit +42.0 pts, TTFT 1.70x, throughput +55% | hit -2.1 pts, TTFT 0.89x, throughput -2% (still fits without the offload) |
| Recall, 8 sessions (everything fits) | hit +0.0 pts, TTFT 0.64x, throughput -31% | hit +0.0 pts, TTFT 1.01x, throughput -1% |
| Static 128k+8k, 28 documents | hit +7.5 pts, TTFT 1.10x, throughput +1% | hit +19.7 pts, TTFT 1.19x, throughput +14% |
| Static 256k+16k | hit -5.8 to +15.0 pts, throughput -12% to +2% | not applicable |
| Mixed sizes, long / short stream | hit +12.9 / +18.0 pts, throughput +7% / +9% | hit +15.2 / +15.9 pts, throughput +8% / +4% |
| Output integrity (16 recalled sessions vs recompute) | 16 of 16 identical | byte check 0 mismatched of 15,632 pages per stage; answers 16 of 16 in one run, 13 of 16 in another |

**Where the offload is worse, and why.** Offload activity on the prefill during each point, from the stage counters
(stage 0) between the point's start and end:

| Point | Hit off → on | Throughput gain | Pushes started | Pushes abandoned as stale | Recalls pulled | Recalls failed (no host memory) | Push timeouts |
|---|---|---|---|---|---|---|---|
| gpt-oss, recall 8 sessions | 94.3% → 94.4% | -31% | 7 | 20 | 1 | 0 | 0 |
| gpt-oss, static 128k+8k, 8 docs | 62.6% → 62.6% | -6% | 12 | 51 | 0 | 0 | 0 |
| gpt-oss, static 256k+16k, 4 docs | 61.0% → 55.1% | -12% | 6 | 29 | 0 | 0 | 0 |
| gpt-oss, static 256k+16k, 10 docs | 33.1% → 41.0% | -7% | 18 | 327 | 2 | 1 | 5 |
| Qwen, recall 12 sessions | 74.1% → 71.9% | -2% | 12 | 9 | 0 | 0 | 0 |
| Qwen, static 128k+8k, 12 docs | 60.1% → 55.6% | -3% | 12 | 0 | 4 | 0 | 0 |
| Shared-prefix rows, both models | 5.5% → 5.5% | -0% to -4% | 1 | 0 | 0 | 0 | 0 |
| For comparison: gpt-oss, recall 16 sessions | 0.0% → 41.5% | +38% | 18 | 255 | 8 | 0 | 0 |

- **Pushes start before anything is lost.** In every losing point the prefill pushed sessions to the decode while the
  same sessions were still being served from its own cache: the hit rate is equal or nearly equal in both arms and few
  or no recalls were pulled, so the push work bought nothing in that point and ran alongside the requests. This is the
  likely cost; it is inferred from the counters, not isolated by an experiment.
- **gpt-oss recall 8 is the clearest case:** identical cached tokens in both arms (974,720 vs 974,848), TTFT p50 7.4 s →
  11.6 s. Eight sessions of 139k tokens sit near the prefill's host capacity, so the pressure trigger fires although
  nothing has to be evicted.
- **Two points also lose hit rate** (gpt-oss 256k+16k 4 docs, Qwen static 12 docs: -5.8 and -4.5 pts). Not traced. In
  the gpt-oss point no recall was pulled, so the lost tokens were not recovered from the decode.
- **gpt-oss 256k+16k 10 docs gains hit (+7.9 pts) and still loses TTFT (0.76x):** 5 pushes timed out unpulled and one
  recall failed for lack of host memory on the prefill.
- **Shared-prefix rows:** one push and no recall per point, so the 0 to 4% is not push work. It is within the run-to-run
  spread seen on points with no offload activity at all (static 4 docs moves -4% on Qwen and -1% on gpt-oss), so it is
  not established as a real cost.
- Candidate fixes, none tested: push only while the prefill is idle; skip sessions used recently; start pushing at a
  lower free-space threshold.

## 1. gpt-oss-120b

Ladders and shared-prefix cases: off `j-190d5442-0d74-4460-886e`, on `j-6438382c-0208-4258-b045`. Mixed sizes and
integrity: off `j-6a209369-e308-44e4-a9ef`, on `j-0a91f98f-3679-4dda-a725`.

**Recall ladder (128k+8k sessions, return phase)**

| Case | Cache hit off → on | Hit gain | TTFT p50 off → on | TTFT speedup | E2E p50 off → on | E2E speedup | Total tok/s off → on | Throughput gain |
|---|---|---|---|---|---|---|---|---|
| 8 sessions | 94.3% → 94.4% | +0.0 pts | 7.4 s → 11.6 s | 0.64x | 8.4 s → 11.8 s | 0.71x | 63,660 → 44,118 | -31% |
| 12 sessions | 7.9% → 49.8% | +42.0 pts | 25.5 s → 15.0 s | 1.70x | 25.6 s → 15.1 s | 1.70x | 22,566 → 34,939 | +55% |
| 16 sessions | 0.0% → 41.5% | +41.5 pts | 25.7 s → 21.8 s | 1.18x | 25.8 s → 21.9 s | 1.18x | 22,334 → 30,893 | +38% |

**Static prefix reuse**

| Case | Cache hit off → on | Hit gain | TTFT p50 off → on | TTFT speedup | E2E p50 off → on | E2E speedup | Total tok/s off → on | Throughput gain |
|---|---|---|---|---|---|---|---|---|
| 128k+8k, 4 docs | 62.7% → 62.7% | +0.0 pts | 9.6 s → 7.7 s | 1.25x | 13.8 s → 10.0 s | 1.37x | 45,374 → 44,818 | -1% |
| 128k+8k, 8 docs | 62.6% → 62.6% | +0.0 pts | 7.6 s → 9.0 s | 0.85x | 10.0 s → 11.3 s | 0.88x | 46,408 → 43,720 | -6% |
| 128k+8k, 12 docs | 44.4% → 48.2% | +3.9 pts | 12.2 s → 13.0 s | 0.94x | 14.4 s → 15.7 s | 0.92x | 34,133 → 34,303 | +0% |
| 128k+8k, 16 docs | 37.2% → 41.4% | +4.2 pts | 14.6 s → 14.9 s | 0.98x | 17.0 s → 17.0 s | 1.00x | 32,031 → 32,308 | +1% |
| 128k+8k, 20 docs | 29.7% → 36.4% | +6.7 pts | 16.1 s → 16.1 s | 1.00x | 18.4 s → 18.2 s | 1.01x | 30,126 → 30,055 | -0% |
| 128k+8k, 24 docs | 19.6% → 29.6% | +10.0 pts | 16.5 s → 17.3 s | 0.96x | 18.7 s → 19.4 s | 0.97x | 27,710 → 28,703 | +4% |
| 128k+8k, 28 docs | 21.2% → 28.7% | +7.5 pts | 19.4 s → 17.7 s | 1.10x | 21.6 s → 20.0 s | 1.08x | 27,486 → 27,798 | +1% |
| 256k+16k, 2 docs | 62.6% → 62.6% | +0.0 pts | 26.2 s → 28.4 s | 0.92x | 28.3 s → 30.6 s | 0.92x | 29,314 → 27,876 | -5% |
| 256k+16k, 4 docs | 61.0% → 55.1% | -5.8 pts | 49.5 s → 53.0 s | 0.93x | 52.3 s → 55.7 s | 0.94x | 20,993 → 18,559 | -12% |
| 256k+16k, 6 docs | 41.8% → 47.0% | +5.2 pts | 49.1 s → 48.6 s | 1.01x | 51.9 s → 51.3 s | 1.01x | 18,866 → 18,288 | -3% |
| 256k+16k, 8 docs | 34.9% → 41.5% | +6.6 pts | 60.4 s → 58.0 s | 1.04x | 63.1 s → 60.9 s | 1.04x | 17,580 → 17,712 | +1% |
| 256k+16k, 10 docs | 33.1% → 41.0% | +7.9 pts | 49.2 s → 64.7 s | 0.76x | 51.8 s → 67.5 s | 0.77x | 17,906 → 16,741 | -7% |
| 256k+16k, 12 docs | 11.2% → 22.5% | +11.2 pts | 83.9 s → 70.4 s | 1.19x | 86.5 s → 73.0 s | 1.19x | 14,152 → 14,366 | +2% |
| 256k+16k, 14 docs | 16.7% → 31.7% | +15.0 pts | 66.7 s → 68.3 s | 0.98x | 69.3 s → 71.0 s | 0.98x | 14,864 → 15,134 | +2% |

**Sessions behind a shared 8k prefix, and independent sessions (return phase)**

| Case | Cache hit off → on | Hit gain | TTFT p50 off → on | TTFT speedup | E2E p50 off → on | E2E speedup | Total tok/s off → on | Throughput gain |
|---|---|---|---|---|---|---|---|---|
| 16 sessions, shared prefix, 1 at a time | 5.5% → 5.5% | +0.0 pts | 8.0 s → 8.4 s | 0.95x | 8.4 s → 8.9 s | 0.95x | 17,176 → 16,413 | -4% |
| 16 sessions, shared prefix, 2 concurrent | 5.5% → 5.5% | +0.0 pts | 12.0 s → 12.0 s | 1.00x | 12.6 s → 12.6 s | 1.00x | 22,732 → 22,643 | -0% |
| 20 sessions, shared prefix, 4 concurrent | 5.5% → 5.5% | +0.0 pts | 24.8 s → 25.6 s | 0.97x | 25.3 s → 26.1 s | 0.97x | 22,821 → 22,079 | -3% |
| 24 sessions, shared prefix, 4 concurrent | 5.5% → 5.5% | +0.0 pts | 24.6 s → 25.6 s | 0.96x | 25.2 s → 26.2 s | 0.96x | 22,934 → 22,081 | -4% |
| 16 independent sessions, 1 at a time | 0.0% → 75.6% | +75.6 pts | 8.1 s → 4.4 s | 1.84x | 8.6 s → 4.9 s | 1.75x | 16,871 → 24,886 | +48% |

**Mixed sizes**

| Case | Cache hit off → on | Hit gain | TTFT p50 off → on | TTFT speedup | E2E p50 off → on | E2E speedup | Total tok/s off → on | Throughput gain |
|---|---|---|---|---|---|---|---|---|
| Long 128k+8k, 8 docs x 3, concurrency 4 | 43.1% → 56.0% | +12.9 pts | 20.0 s → 18.9 s | 1.06x | 22.9 s → 21.5 s | 1.06x | 24,325 → 26,012 | +7% |
| Short 32k+4k, 48 sessions, concurrency 8 | 0.0% → 18.0% | +18.0 pts | 5.7 s → 5.9 s | 0.96x | 5.8 s → 6.1 s | 0.96x | 21,310 → 23,195 | +9% |

- Ladder on run: 357 pushes stored, 87 recalls, 13 recalls failed for lack of host memory on the prefill, 96 pushes held
  by the decode and timed out unpulled (768 `DEADLINE_EXCEEDED` lines over 8 stages). No engine exception.
- One request of the 8-session return came back with no output in both arms (no error reported, not traced); hit and
  throughput for that point are over the other 7 requests.
- Integrity: 16 sessions of 128k+8k, each returned and compared with a recompute after a flush, 64 output tokens: off
  16 of 16 identical (nothing recalled), on 16 of 16 identical (all 16 recalled from the decode host).
- The shared-prefix rows show no gain: this tree does not contain the PR 2052 fix.

## 2. Qwen3-30B-A3B

Ladders and shared-prefix cases: off `j-74df7346-8440-49ef-9111`, on `j-2d367b10-18d6-4858-933a`. Mixed sizes and
integrity: off `j-78ae0c2c-80d7-4a2c-ab0d`, on `j-9d52ec13-4f5d-40e2-b25d`. Byte check: `j-cc6256d5-75b5-48cd-a10f`.
The 256k+16k ladder does not apply: the model's context is 262,144 tokens.

**Recall ladder (128k+8k sessions, return phase)**

| Case | Cache hit off → on | Hit gain | TTFT p50 off → on | TTFT speedup | E2E p50 off → on | E2E speedup | Total tok/s off → on | Throughput gain |
|---|---|---|---|---|---|---|---|---|
| 8 sessions | 94.4% → 94.4% | +0.0 pts | 7.0 s → 6.9 s | 1.01x | 7.2 s → 7.1 s | 1.01x | 82,658 → 81,905 | -1% |
| 12 sessions | 74.1% → 71.9% | -2.1 pts | 13.0 s → 14.6 s | 0.89x | 13.1 s → 14.8 s | 0.89x | 40,504 → 39,822 | -2% |
| 16 sessions | 0.0% → 55.1% | +55.1 pts | 29.1 s → 18.1 s | 1.61x | 29.2 s → 18.2 s | 1.60x | 19,554 → 30,575 | +56% |

**Static prefix reuse**

| Case | Cache hit off → on | Hit gain | TTFT p50 off → on | TTFT speedup | E2E p50 off → on | E2E speedup | Total tok/s off → on | Throughput gain |
|---|---|---|---|---|---|---|---|---|
| 128k+8k, 4 docs | 62.7% → 62.7% | +0.0 pts | 10.7 s → 12.7 s | 0.84x | 14.5 s → 16.9 s | 0.86x | 39,678 → 38,006 | -4% |
| 128k+8k, 8 docs | 62.7% → 62.7% | +0.0 pts | 9.6 s → 9.7 s | 0.99x | 12.4 s → 12.5 s | 0.99x | 40,881 → 40,208 | -2% |
| 128k+8k, 12 docs | 60.1% → 55.6% | -4.6 pts | 10.4 s → 12.0 s | 0.87x | 14.6 s → 14.9 s | 0.98x | 35,032 → 33,848 | -3% |
| 128k+8k, 16 docs | 43.2% → 59.6% | +16.4 pts | 15.4 s → 12.0 s | 1.29x | 18.1 s → 14.9 s | 1.22x | 31,019 → 34,835 | +12% |
| 128k+8k, 20 docs | 40.5% → 46.3% | +5.8 pts | 14.3 s → 14.2 s | 1.01x | 16.9 s → 16.6 s | 1.01x | 30,279 → 31,155 | +3% |
| 128k+8k, 24 docs | 30.6% → 44.8% | +14.2 pts | 18.1 s → 14.9 s | 1.21x | 20.1 s → 18.3 s | 1.10x | 27,619 → 29,793 | +8% |
| 128k+8k, 28 docs | 28.0% → 47.7% | +19.7 pts | 18.4 s → 15.4 s | 1.19x | 20.5 s → 18.2 s | 1.13x | 27,087 → 30,749 | +14% |

**Sessions behind a shared 8k prefix, and independent sessions (return phase)**

| Case | Cache hit off → on | Hit gain | TTFT p50 off → on | TTFT speedup | E2E p50 off → on | E2E speedup | Total tok/s off → on | Throughput gain |
|---|---|---|---|---|---|---|---|---|
| 16 sessions, shared prefix, 1 at a time | 5.5% → 5.5% | +0.0 pts | 9.9 s → 10.4 s | 0.96x | 10.4 s → 10.8 s | 0.96x | 13,972 → 13,401 | -4% |
| 16 sessions, shared prefix, 2 concurrent | 5.5% → 5.5% | +0.0 pts | 13.8 s → 13.8 s | 1.00x | 14.3 s → 14.3 s | 1.00x | 19,818 → 19,751 | -0% |
| 20 sessions, shared prefix, 4 concurrent | 5.5% → 5.5% | +0.0 pts | 28.3 s → 29.2 s | 0.97x | 28.8 s → 29.7 s | 0.97x | 19,920 → 19,256 | -3% |
| 24 sessions, shared prefix, 4 concurrent | 5.5% → 5.5% | +0.0 pts | 28.3 s → 29.6 s | 0.95x | 28.8 s → 30.1 s | 0.96x | 19,999 → 19,136 | -4% |
| 16 independent sessions, 1 at a time | 0.0% → 67.3% | +67.3 pts | 10.2 s → 6.4 s | 1.60x | 10.6 s → 6.8 s | 1.56x | 13,665 → 18,200 | +33% |

**Mixed sizes**

| Case | Cache hit off → on | Hit gain | TTFT p50 off → on | TTFT speedup | E2E p50 off → on | E2E speedup | Total tok/s off → on | Throughput gain |
|---|---|---|---|---|---|---|---|---|
| Long 128k+8k, 8 docs x 3, concurrency 4 | 47.6% → 62.7% | +15.2 pts | 22.2 s → 19.3 s | 1.15x | 25.0 s → 22.9 s | 1.09x | 23,284 → 25,112 | +8% |
| Short 32k+4k, 48 sessions, concurrency 8 | 0.0% → 15.9% | +15.9 pts | 7.5 s → 7.1 s | 1.06x | 7.7 s → 7.4 s | 1.04x | 19,657 → 20,474 | +4% |

- Ladder on run: 182 pushes stored, 89 recalls, 1 recall failed, 36 pushes held and timed out unpulled
  (288 `DEADLINE_EXCEEDED` lines). No engine exception; 0 request errors on every 128k point in both arms.
- Integrity, on arm `j-9d52ec13-4f5d-40e2-b25d`: 14 sessions recalled, 13 of 16 answers identical to a recompute; the
  3 that differ are recalled sessions and diverge at output token 11, 18 and 34. Off arm: 16 of 16 identical, but
  nothing was served from cache there.
- Byte check `j-cc6256d5-75b5-48cd-a10f` (`SGLANG_PD_OFFLOAD_VERIFY_PAGES=1`): 15,632 recalled pages per stage compared
  byte for byte with the pushed pages on all 8 stages, 0 mismatched; answers 16 of 16 identical in that run. So the
  transfer is byte-exact; the 3 differing answers did not reproduce and are consistent with batch-dependent numerics
  of the KV computed under concurrency (concurrent-phase probes differ in 15 to 20% of cases with the offload off too),
  but that is not proven.

## 3. Earlier, shorter runs on the same tree

- `j-5fa49d2d-a729-4d27-a612` (off) / `j-7a2d4243-be99-4bf5-a4f3` (on), Qwen3-30B, recall 8/12/16 and static 4 to 16 at
  128k+8k: recall 16 hit 0.7% → 47.3%, TTFT 1.48x, throughput +35%; recall 8 lost 27% throughput in that run (not seen
  in the full sweep above).
- `j-98ae993a-ee51-42a7-b3db` / `j-b7ab1318-89f2-4022-93e4`, 24.6k+2k sessions (before the page-cap fix): hit rises,
  latency and throughput do not; see `README.md` section 5.
