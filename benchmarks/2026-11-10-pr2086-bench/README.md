# PR 2086 benchmark: KV offload to decode DRAM for hybrid sliding-window models (gpt-oss-120b)

PR: sgl-project/sglang-torchtpu#2086, branch `pd-dram-spill-swa`. Two heads were measured with the same recipe,
harness, image and settings:

- **`83198bc912` (current, 2026-11-11 07:51Z push)**: the results below. Relative to the first head its three commits
  drop the prefill's path-end-only SWA host tier (a PD prefill now keeps upstream's rule, the window of every evicted
  node, so requests that fork from a shared prefix resume at the fork), and compute page hashes on a recall only when
  the tree keeps them (no native hash extension load per pull).
- **`54a80863a6` (first head, 2026-11-10)**: kept in full in the appendix at the end of this file.

Three campaigns, each the same tree and settings with the switch unset ("off") and set on both roles ("on",
`SGLANG_ENABLE_PREFILL_KV_OFFLOAD_TO_DECODE_DRAM=1`), caches flushed before every point:

1. write-back 1P1D (`hicache_write_policy write_back` on both roles);
2. 2P2D sticky-pair transitions, write-back;
3. write-through 1P1D.

Status 2026-11-11 10:00Z: all three campaigns complete on head `83198bc912`, both arms, all jobs deleted; a long
mixed-load stress stage (2P2D, two-host TP16 engines, text and images) is queued and will be reported separately.
`ISSUES-2026-11-11.md` has every system error met and the status of each on the new head.

## Head 83198bc912 in one paragraph

The two defects reported on the first head are gone and the write-back regression is reversed. Single-request
equivalence is **16 of 16 on every arm**, including the write-back on arm after the ladders and on fresh engines (first
head: 12 of 16 and 13 of 16, ISSUES I5, closed). The per-pull JIT rebuild of `hicache_hash_cpp` no longer happens
(0 lines on every arm, first head 560 to 936 per on arm, I7, closed). Under write-back the static-reuse ladder, which
lost 13 to 23% throughput with the switch on at 8 to 16 documents on the first head, now gains with the switch on
(prefill-side hit 62.5 / 55.3 / 53.9% against 62.5 / 50.9 / 39.5% off at 8 / 12 / 16 documents, TTFT p50 7.1 s
against 11.5 s at 16, +20% throughput at 16), because the prefill's host tier again serves a fork. The sticky recall
returns are unchanged within noise in 1P1D and 2P2D (2P2D T1 78.2% hit and 2.9x TTFT, T2 62.4% and 2.9x; write-through
recall 16 return 88.5% and 10.7x). Two things to keep in view: the refused subtree drops under write-back (I4) still
occur and are more frequent (168 lines on the 1P1D on arm, 144 on 2P2D), and at the capacity edge of 8 recall
sessions the write-back on arm now sits below the off arm (86.8% against 93.7% hit, TTFT p50 4.3 against 2.4 s)
where the first head had it level. A new minor decode-side warning (I8: an offer the prefill declined times out
after 60 s and delays a cache flush) appeared once on the write-through on arm.

## Where it ran and why

The live v7x hosts of the brief no longer exist at their addresses (ISSUES I1), so everything ran on the shared CDK
GKE cluster: tpu7x single-host nodes (2x2x1, 4 chips), one TP8/EP8 engine per host, prefill and decode each on their
own host, mini-lb routers on a CPU pod, the client on another CPU pod in the same JobSet. Recipe
`recipes/pd1992-qwen3-30b-xpyd.jsonnet` (`MODEL_PROFILE=gpt-oss-120b TREE_DIR=/workspace/sglang-2086`, stages
`bench` for 1P1D and `transitions` for 2P2D), harness under `harness/` (clients, `common.sh`, `point_metrics.py`,
`offload_counters.py`, `stage_bench.sh`, `stage_transitions.sh`). Image `sglang-torchtpu:20261103` with the PR tree
installed editable, `tpu-sync-torch 0.0.1.dev20261103081657`, `torch_tpu 0.2.1.dev20261028201649`.

Engine settings (both roles): gpt-oss-120b bf16, fp8 e4m3 KV, page size 64, context 327,680, max total tokens 786,432,
max running 4, chunked prefill 8,192, `pallas_tpu_rpa_v3`, hierarchical cache over raiden, `page_first_fused`,
hicache ratio 1.2 (prefill) / 3.5 (decode), 128 GB raiden host pool, decode radix cache on, `SGLANG_TPU_FUSED_MOE_SC_GATHER=0`.

Workloads (PR 1798's, 128k + 8k): recall ladder N = 8, 12, 16 sessions (fill phase, 20 s settle, return phase; each
phase its own point so the return's hit, throughput and latency are bracketed exactly), static-reuse ladder 4, 8, 12,
16 documents (3 visits each, 256 output tokens), mixed sizes (128k+8k, 8 documents x 3 visits at concurrency 4,
concurrent with 32k+4k, 48 sessions at concurrency 8), single-request output equivalence (16 sessions, recall one
request at a time, every output compared token for token with a recompute after a flush of both engines).

## How the numbers are computed

- **Prefill-side hit**: cached tokens over prompt tokens from the prefill's `/metrics` counters, bracketed by a
  snapshot before and after the point; this is the saving the prefill actually got. **Client-reported hit** is the
  `cached_tokens` field of the responses, which in P/D comes from the decode's own prefix cache and is not a prefill
  saving (it is shown for completeness and is the same on both arms in several rows).
- **TTFT, E2E, ITL**: client-side percentiles over the point's requests. **Wall**: first request start to last request
  end of the point as a batch, from client timestamps; **req/min** = requests / wall. **Warm returns**: requests
  whose TTFT is below the warm threshold of the point (`warm_threshold_s` in `points_fixed.jsonl`). **Prefill tokens
  computed per request**: prompt tokens minus cached tokens, per request, on the prefill.
- **Recalled from decode DRAM**: TP0 deltas of the PR's `[dram-offload] recall` counters over the point (`pulls`,
  `pulled_tokens`, `pulled_swa_tokens`); pushes and landings the same way. `offload_counters.py` also checks that
  every rank reports the same final counters.
- **Equivalence (integrity)**: 16 sessions of 128k + 8k, each returned one request at a time after the fill and
  compared token for token with a recompute after a flush of both engines (`victim_integrity.py`).
- Tables are generated by `harness/build_report.py` (off and on arm of a stage), `harness/build_transitions.py`
  (routing per point) and `harness/build_delta.py` (one campaign on two heads).

## Campaign 1 (head 83198bc912): write-back, 1P1D

Jobs: on `j-4b873230-04db-418e-969d` (stage 08:33-09:30Z, second attempt after one spot preemption), off
`j-2ac625fd-2bad-4c86-abaa` (08:51-09:21Z, second attempt). 396 of 396 requests completed on each arm, 0 request
errors. Full tables in `results/h83198bc/table_write_back.md`; head-to-head with the first head in
`results/h83198bc/delta_write_back.md`.

**Gain summary, spill-over off -> on** (prefill-side hit, total throughput, requests per minute and TTFT p50 per point; the fill rows are cold by construction, the return and static rows are where the feature acts).

| Point | Prefill-side hit off -> on | Gain | Total tok/s off -> on | Gain | Req/min off -> on | Gain | TTFT p50 off -> on | Gain |
|---|---|---|---|---|---|---|---|---|
| recall 8, fill (cold) | 0.0% -> 0.0% | +0.0 pp | 22,360 -> 22,250 | -0% | 9.6 -> 9.6 | -1% | 23.4 -> 23.5 s | -0% |
| recall 8, return | 93.7% -> 86.8% | -6.9 pp | 169,638 -> 88,363 | -48% | 69.0 -> 35.9 | -48% | 2.4 -> 4.3 s | -83% |
| recall 12, fill (cold) | 0.0% -> 0.0% | +0.0 pp | 22,986 -> 22,956 | -0% | 9.9 -> 9.9 | -0% | 23.6 -> 23.7 s | -0% |
| recall 12, return | 25.8% -> 55.5% | +29.6 pp | 27,696 -> 43,148 | +56% | 11.3 -> 17.5 | +56% | 22.0 -> 11.9 s | +46% |
| recall 16, fill (cold) | 0.0% -> 0.0% | +0.0 pp | 22,999 -> 23,039 | +0% | 9.9 -> 9.9 | +0% | 23.7 -> 23.6 s | +0% |
| recall 16, return | 0.3% -> 55.5% | +55.2 pp | 22,286 -> 44,879 | +101% | 9.1 -> 18.2 | +101% | 26.0 -> 9.5 s | +64% |
| static 4 docs | 62.7% -> 62.7% | +0.0 pp | 50,767 -> 51,908 | +2% | 21.8 -> 22.3 | +2% | 10.3 -> 10.6 s | -3% |
| static 8 docs | 62.5% -> 62.5% | +0.0 pp | 53,063 -> 52,153 | -2% | 22.8 -> 22.4 | -2% | 6.9 -> 7.2 s | -5% |
| static 12 docs | 50.9% -> 55.3% | +4.4 pp | 42,310 -> 44,583 | +5% | 18.2 -> 19.2 | +5% | 7.5 -> 8.2 s | -8% |
| static 16 docs | 39.5% -> 53.9% | +14.4 pp | 36,114 -> 43,477 | +20% | 15.5 -> 18.7 | +20% | 11.5 -> 7.1 s | +38% |
| mixed, long stream | 21.9% -> 50.0% | +28.1 pp | 25,398 -> 29,232 | +15% | 10.9 -> 12.6 | +15% | 19.2 -> 17.2 s | +10% |
| mixed, short stream | 21.9% -> 50.0% | +28.1 pp | 19,287 -> 25,312 | +31% | 29.7 -> 38.9 | +31% | 9.2 -> 4.5 s | +52% |

Gains appear once the working set exceeds the prefill's HBM plus host tier (recall 12 and 16, static 16, the mixed block); nothing moves while everything fits (static 4 and 8, the cold fills); the one loss is the 8-session return at the capacity edge, discussed under Reading.

**Performance gain** (what a user of the pair sees; return rows are the requests whose prefix the previous turn produced).

| Point | TTFT p50 off -> on | Speedup | TTFT p95 off -> on | Speedup | E2E p50 off -> on | Wall s off -> on | Gain | Req/min off -> on | Gain | Warm returns off -> on | Prefill tokens computed per request, off -> on |
|---|---|---|---|---|---|---|---|---|---|---|---|
| recall 8, fill (cold) | 23.4 -> 23.5 s | 1.0x | 25.8 -> 26.0 s | 1.0x | 23.5 -> 23.6 s | 49.8 -> 50.1 | -1% | 9.6 -> 9.6 | -1% | 0 / 8 -> 0 / 8 | 139,298 -> 139,298 |
| recall 8, return | 2.4 -> 4.3 s | 0.5x | 3.2 -> 7.3 s | 0.4x | 3.1 -> 5.3 s | 7.0 -> 13.4 | -91% | 69.0 -> 35.9 | -48% | 8 / 8 -> 7 / 8 | 9,345 -> 19,561 |
| recall 12, fill (cold) | 23.6 -> 23.7 s | 1.0x | 24.0 -> 24.0 s | 1.0x | 23.8 -> 23.8 s | 72.7 -> 72.8 | -0% | 9.9 -> 9.9 | -0% | 0 / 12 -> 0 / 12 | 139,298 -> 139,298 |
| recall 12, return | 22.0 -> 11.9 s | 1.9x | 23.4 -> 19.8 s | 1.2x | 22.2 -> 12.0 s | 63.9 -> 41.0 | +36% | 11.3 -> 17.5 | +56% | 1 / 12 -> 2 / 12 | 109,449 -> 65,705 |
| recall 16, fill (cold) | 23.7 -> 23.6 s | 1.0x | 24.0 -> 24.0 s | 1.0x | 23.9 -> 23.8 s | 96.9 -> 96.8 | +0% | 9.9 -> 9.9 | +0% | 0 / 16 -> 0 / 16 | 139,298 -> 139,298 |
| recall 16, return | 26.0 -> 9.5 s | 2.7x | 26.1 -> 20.1 s | 1.3x | 26.2 -> 9.6 s | 106.0 -> 52.6 | +50% | 9.1 -> 18.2 | +101% | 0 / 16 -> 4 / 16 | 147,077 -> 65,597 |
| static 4 docs | 10.3 -> 10.6 s | 1.0x | 16.4 -> 16.6 s | 1.0x | 13.3 -> 12.9 s | 33.0 -> 32.3 | +2% | 21.8 -> 22.3 | +2% | 5 / 12 -> 5 / 12 | 51,968 -> 51,968 |
| static 8 docs | 6.9 -> 7.2 s | 1.0x | 16.4 -> 16.3 s | 1.0x | 9.2 -> 9.5 s | 63.1 -> 64.2 | -2% | 22.8 -> 22.4 | -2% | 9 / 24 -> 9 / 24 | 52,248 -> 52,208 |
| static 12 docs | 7.5 -> 8.2 s | 0.9x | 22.0 -> 22.2 s | 1.0x | 9.9 -> 10.4 s | 118.7 -> 112.7 | +5% | 18.2 -> 19.2 | +5% | 10 / 36 -> 13 / 36 | 68,322 -> 62,222 |
| static 16 docs | 11.5 -> 7.1 s | 1.6x | 21.5 -> 21.3 s | 1.0x | 14.0 -> 9.8 s | 185.5 -> 154.1 | +17% | 15.5 -> 18.7 | +20% | 7 / 48 -> 14 / 48 | 84,213 -> 64,157 |
| mixed, long stream | 19.2 -> 17.2 s | 1.1x | 26.6 -> 26.6 s | 1.0x | 21.8 -> 20.1 s | 131.9 -> 114.6 | +13% | 10.9 -> 12.6 | +15% | 1 / 24 -> 4 / 24 | 230,667 -> 147,569 |
| mixed, short stream | 9.2 -> 4.5 s | 2.1x | 26.8 -> 26.5 s | 1.0x | 9.3 -> 4.6 s | 194.1 -> 147.9 | +24% | 29.7 -> 38.9 | +31% | 2 / 96 -> 33 / 96 | 57,667 -> 36,892 |

**Cache (mechanism)**: prefill-side hit, client-reported cached tokens, where the prefix was found, and what the on arm recalled from decode DRAM.

| Point | Requests on / off (errors) | Prefill-side hit off -> on | Gain | Client-reported hit off -> on | Cached by tier device / host, off -> on | Recalled from decode DRAM (on) |
|---|---|---|---|---|---|---|
| recall 8, fill (cold) | 8 / 8 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| recall 8, return | 8 / 8 (0/0) | 93.7% -> 86.8% | -6.9 pp | 94.4% -> 86.8% | 0.26M / 0.85M -> 0.16M / 0.86M | 0 |
| recall 12, fill (cold) | 12 / 12 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| recall 12, return | 12 / 12 (0/0) | 25.8% -> 55.5% | +29.6 pp | 94.4% -> 55.5% | 1.21M / 0.46M -> 0.00M / 0.98M | 295,488 tok in 5 pulls + 640 SWA |
| recall 16, fill (cold) | 16 / 16 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| recall 16, return | 16 / 16 (0/0) | 0.3% -> 55.5% | +55.2 pp | 94.4% -> 61.5% | 2.22M / 0.01M -> 0.14M / 1.31M | 1,188,544 tok in 11 pulls + 1,408 SWA |
| static 4 docs | 12 / 12 (0/0) | 62.7% -> 62.7% | +0.0 pp | 62.7% -> 62.7% | 1.05M / 0.00M -> 1.05M / 0.00M | 0 |
| static 8 docs | 24 / 24 (0/0) | 62.5% -> 62.5% | +0.0 pp | 62.7% -> 62.5% | 1.85M / 0.25M -> 1.74M / 0.35M | 0 |
| static 12 docs | 36 / 36 (0/0) | 50.9% -> 55.3% | +4.4 pp | 62.6% -> 58.8% | 1.93M / 1.20M -> 1.79M / 1.16M | 417,216 tok in 7 pulls + 896 SWA |
| static 16 docs | 48 / 48 (0/0) | 39.5% -> 53.9% | +14.4 pp | 62.7% -> 62.1% | 3.11M / 1.08M -> 2.38M / 1.77M | 771,136 tok in 12 pulls + 1,536 SWA |
| mixed, long stream | 24 / 24 (0/0) | 21.9% -> 50.0% | +28.1 pp | 62.7% -> 62.5% | 1.20M / 0.90M -> 1.15M / 0.94M | 1,802,880 tok in 47 pulls + 6,016 SWA |
| mixed, short stream | 96 / 96 (0/0) | 21.9% -> 50.0% | +28.1 pp | 34.5% -> 40.9% | 1.29M / 0.00M -> 0.00M / 1.53M | 1,802,880 tok in 47 pulls + 6,016 SWA |

The fill rows are the cold phase: both engines are wiped before the point and every session has a new 128k prefix, so a 0% hit there is by construction on both arms; they are kept for the cold prefill's throughput and latency (whether pushes in flight slow the prefill that issues them). The mixed rows share one metrics window, so their hit and recall columns are the same block.

**Throughput** (gain = on vs off, higher is better).

| Point | Total tok/s off | on | Gain | Output tok/s off | on | Gain | Req/min off | on | Gain |
|---|---|---|---|---|---|---|---|---|---|
| recall 8, fill (cold) | 22360 | 22250 | -0% | 2.6 | 2.6 | +0% | 9.6 | 9.6 | -1% |
| recall 8, return | 169638 | 88363 | -48% | 18.4 | 9.6 | -48% | 69.0 | 35.9 | -48% |
| recall 12, fill (cold) | 22986 | 22956 | -0% | 2.6 | 2.6 | +0% | 9.9 | 9.9 | -0% |
| recall 12, return | 27696 | 43148 | +56% | 3.0 | 4.7 | +57% | 11.3 | 17.5 | +56% |
| recall 16, fill (cold) | 22999 | 23039 | +0% | 2.6 | 2.6 | +0% | 9.9 | 9.9 | +0% |
| recall 16, return | 22286 | 44879 | +101% | 2.4 | 4.9 | +104% | 9.1 | 18.2 | +101% |
| static 4 docs | 50767 | 51908 | +2% | 93.1 | 95.2 | +2% | 21.8 | 22.3 | +2% |
| static 8 docs | 53063 | 52153 | -2% | 97.3 | 95.7 | -2% | 22.8 | 22.4 | -2% |
| static 12 docs | 42310 | 44583 | +5% | 77.6 | 81.8 | +5% | 18.2 | 19.2 | +5% |
| static 16 docs | 36114 | 43477 | +20% | 66.2 | 79.8 | +21% | 15.5 | 18.7 | +20% |
| mixed, long stream | 25398 | 29232 | +15% | 46.6 | 53.6 | +15% | 10.9 | 12.6 | +15% |
| mixed, short stream | 19287 | 25312 | +31% | 7.9 | 10.4 | +32% | 29.7 | 38.9 | +31% |

**Latency** (gain = reduction on vs off, positive means the on arm is faster).

| Point | TTFT p50 off | on | Gain | TTFT p95 off | on | Gain | ITL p50 off | on | Gain |
|---|---|---|---|---|---|---|---|---|---|
| recall 8, fill (cold) | 23.4 s | 23.5 s | -0% | 25.8 s | 26.0 s | -1% | 0.009 s | 0.009 s | +2% |
| recall 8, return | 2.4 s | 4.3 s | -83% | 3.2 s | 7.3 s | -125% | 0.019 s | 0.075 s | -283% |
| recall 12, fill (cold) | 23.6 s | 23.7 s | -0% | 24.0 s | 24.0 s | -0% | 0.009 s | 0.009 s | +4% |
| recall 12, return | 22.0 s | 11.9 s | +46% | 23.4 s | 19.8 s | +15% | 0.009 s | 0.010 s | -6% |
| recall 16, fill (cold) | 23.7 s | 23.6 s | +0% | 24.0 s | 24.0 s | +0% | 0.010 s | 0.009 s | +4% |
| recall 16, return | 26.0 s | 9.5 s | +64% | 26.1 s | 20.1 s | +23% | 0.010 s | 0.010 s | +2% |
| static 4 docs | 10.3 s | 10.6 s | -3% | 16.4 s | 16.6 s | -1% | 0.009 s | 0.009 s | +1% |
| static 8 docs | 6.9 s | 7.2 s | -5% | 16.4 s | 16.3 s | +1% | 0.009 s | 0.009 s | +2% |
| static 12 docs | 7.5 s | 8.2 s | -8% | 22.0 s | 22.2 s | -1% | 0.009 s | 0.009 s | +2% |
| static 16 docs | 11.5 s | 7.1 s | +38% | 21.5 s | 21.3 s | +1% | 0.009 s | 0.009 s | -3% |
| mixed, long stream | 19.2 s | 17.2 s | +10% | 26.6 s | 26.6 s | -0% | 0.010 s | 0.010 s | -6% |
| mixed, short stream | 9.2 s | 4.5 s | +52% | 26.8 s | 26.5 s | +1% | 0.010 s | 0.012 s | -19% |

**Offload counters on the on arm, per point** (TP0 deltas from the server logs; every push and landing is a 128k-session branch with its SWA window).

| Point | Pushes stored / started | Landings landed / received | Recalls pulls / offers | Pulled tokens | SWA tokens | Failed / refused / no room |
|---|---|---|---|---|---|---|
| recall 8, fill (cold) | 0 / 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall 8, return | 4 / 4 | 4 / 4 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall 12, fill (cold) | 0 / 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall 12, return | 40 / 40 | 40 / 40 | 5 / 5 | 295,488 | 640 | 0 / 0 / 0 |
| recall 16, fill (cold) | 45 / 45 | 45 / 45 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall 16, return | 32 / 32 | 32 / 32 | 11 / 12 | 1,188,544 | 1,408 | 0 / 0 / 0 |
| static 4 docs | 0 / 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| static 8 docs | 0 / 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| static 12 docs | 49 / 49 | 49 / 49 | 7 / 10 | 417,216 | 896 | 0 / 0 / 0 |
| static 16 docs | 107 / 107 | 107 / 107 | 12 / 17 | 771,136 | 1,536 | 0 / 0 / 0 |
| mixed, long stream | 191 / 191 | 191 / 191 | 47 / 48 | 1,802,880 | 6,016 | 0 / 0 / 0 |
| mixed, short stream | 191 / 191 | 191 / 191 | 47 / 48 | 1,802,880 | 6,016 | 0 / 0 / 0 |

Final counters, on arm: prefill push started 574, stored 574; decode landing received 574, granted 574, landed 574
(11,390,464 tokens); recall offers 184, pulls 103, pulled 6,490,496 tokens plus 13,184 SWA window tokens, 80 offers
skipped because the prefill still held the branch in its own host tier, 1 over budget, 0 failed, 0 refused; push,
landing and recall counters identical on all 8 ranks of both engines. Off arm: no offload lines.

**Equivalence (integrity, run last on the same engines): 16 of 16 identical on both arms.** On arm: 13 of 16 returns
served from the prefill's host tier with the full 139,264 tokens after the recall from decode DRAM, 3 with a partial
host hit (106,496, 57,344 and 32,768 tokens), all exact. Off arm: all 16 from device. The fresh-engine run of the same
case (`j-cd086d8e-ccfa-4a6c-a82b`, `STAGE=edges EDGES=E1`, 09:08-09:15Z): **16 of 16**, 15 of 16 sessions pulled from
decode DRAM (21 pulls over 93 offers, 72 offers skipped because the host tier already held the pages), 14 served with
139,264 host tokens, 2 with 114,688 and 131,072. On the first head these were 12 of 16 and 13 of 16 with session 6
diverging at token 5 in every run; on this head session 6 is exact in both runs (ISSUES I5, closed).

### Reading

- **Recall ladder.** 16 sessions (2.2M tokens): the off arm has evicted everything by the return (0.3% hit, 26.0 s
  TTFT); the on arm pushed 45 branches during the fill and 32 more during the return, recalled 11 of 12 offers (1.19M
  tokens) and returns at 55.5% hit, TTFT p50 9.5 s (2.7x), 2.0x the throughput. 12 sessions, the transition regime on
  the first head (37.1%), is now 55.5% (5 pulls, TTFT 22.0 -> 11.9 s): the prefill's own host tier, which again keeps
  a window for every evicted node, serves what the pushes were too late for. 8 sessions (1.1M tokens) fit the host
  tier on both arms, and here the on arm is below the off arm (86.8% against 93.7%, TTFT p50 4.3 against 2.4 s, 4
  pushes, 0 recalls); on the first head both arms were at 92 to 94%. The on arm's host tier holds the pushed branches'
  windows as well as its own, so at the capacity edge it spills a little earlier; the 4 evicted branches were pushed
  but the return did not recall them (the offers came after the requests had started). Worth a look by the author,
  small in absolute terms (1.9 s on a 2.4 s return).
- **Static ladder.** The first head's regression is gone. 4 documents sit at the 62.7% ceiling on both arms; at 8 the
  arms are level (62.5%); at 12 and 16 the on arm is above the off arm (55.3 against 50.9%, 53.9 against 39.5%), with
  7 and 12 recalls (0.42M and 0.77M tokens) on top of a host tier that now serves the forks (1.16M and 1.77M
  host-cached tokens against 0.00M on the first head). TTFT p50 at 16 documents 11.5 -> 7.1 s, throughput +20%,
  warm visits 7 -> 14 of 48. At 12 documents the TTFT p50 is 0.7 s worse on the on arm while the throughput is 5%
  better (p95 equal): the hit is spread differently over the visits.
- **Mixed sizes.** 120 of 120 on both arms; prefill-side hit 21.9 -> 50.0% (first head 39.7%), 47 of 48 offers
  recalled (1.80M tokens plus 6,016 SWA tokens), 191 of 191 pushes landed. The long stream's TTFT p50 19.2 -> 17.2 s
  and throughput +15%; the short stream's TTFT p50 9.2 -> 4.5 s and +31% requests per minute.
- **Fill phases** are the same on both arms (22.3k-23.0k tok/s, TTFT p50 23.4-23.7 s): pushes in flight do not slow
  the prefill that issues them.
- **Validity.** No `Scheduler hit an exception`, `out of memory`, `malformed` or `DEADLINE_EXCEEDED` on either arm.
  The on arm's prefill logged 168 `subtree drop declined (node locked)` lines (21 per rank, ISSUES I4) in three
  bursts on TP0: 1 at 09:11:49 (recall 12 return), 14 at 09:22:43 (mixed block), 6 at 09:26:53 (integrity recall
  phase). Those points carry that flag; no request failed in them and the counters balance. First head: 96 lines.

## Campaign 2 (head 83198bc912): 2P2D sticky-pair transitions, write-back

Jobs: on `j-81cfa513-52b7-47f1-b22c` (stage 08:31-08:55Z, first attempt), off `j-31bd8af0-64b9-4002-b91b` (08:55-09:25Z,
second attempt after one spot preemption). 20 points per arm, 288 requests per arm, 0 errors, `route_ok` true on every
pinned point of both arms. Full tables in `results/h83198bc/table_transitions_write_back.md`; head-to-head in
`results/h83198bc/delta_transitions_write_back.md`. Procedure as in the appendix (wipe, fill 12 sessions on (p0,d0),
24 short sessions through prefill 0 so write-back evicts and pushes, return on the target pair).

**Performance gain** (what a user of the pair sees; return rows are the requests whose prefix the previous turn produced).

| Point | TTFT p50 off -> on | Speedup | TTFT p95 off -> on | Speedup | E2E p50 off -> on | Wall s off -> on | Gain | Req/min off -> on | Gain | Warm returns off -> on | Prefill tokens computed per request, off -> on |
|---|---|---|---|---|---|---|---|---|---|---|---|
| T1_p0d0_fill (fill) | 23.7 -> 23.7 s | 1.0x | 24.1 -> 24.0 s | 1.0x | 23.9 -> 23.8 s | 74.2 -> 74.3 | -0% | 9.7 -> 9.7 | +0% | 0 / 12 -> 0 / 12 | 139,298 -> 139,298 |
| T1_p0d0_ka (fill) | 7.9 -> 7.8 s | 1.0x | 8.0 -> 7.9 s | 1.0x | 8.1 -> 8.0 s | 25.4 -> 25.2 | +1% | 56.7 -> 57.1 | +1% | 1 / 24 -> 1 / 24 | 36,898 -> 36,898 |
| T1_p0d0_ret (recall) | 26.2 -> 8.9 s | 3.0x | 26.2 -> 9.5 s | 2.8x | 26.3 -> 9.0 s | 80.4 -> 22.7 | +72% | 9.0 -> 31.7 | +254% | 0 / 12 -> 4 / 12 | 147,577 -> 32,228 |
| T2_p1d0_fill (fill) | 23.7 -> 23.7 s | 1.0x | 24.0 -> 24.0 s | 1.0x | 23.9 -> 23.8 s | 73.0 -> 72.8 | +0% | 9.9 -> 9.9 | +0% | 0 / 12 -> 0 / 12 | 139,298 -> 139,298 |
| T2_p1d0_ka (fill) | 7.9 -> 7.8 s | 1.0x | 8.0 -> 8.1 s | 1.0x | 8.0 -> 8.0 s | 25.4 -> 25.2 | +1% | 56.7 -> 57.1 | +1% | 1 / 24 -> 1 / 24 | 36,898 -> 36,898 |
| T2_p1d0_ret (recall) | 25.8 -> 8.9 s | 2.9x | 26.1 -> 13.6 s | 1.9x | 26.0 -> 9.0 s | 80.7 -> 33.5 | +58% | 8.9 -> 21.5 | +141% | 0 / 12 -> 5 / 12 | 147,577 -> 55,438 |
| T3_p0d1_fill (fill) | 23.7 -> 23.7 s | 1.0x | 24.0 -> 24.0 s | 1.0x | 23.9 -> 23.8 s | 72.9 -> 72.8 | +0% | 9.9 -> 9.9 | +0% | 0 / 12 -> 0 / 12 | 139,298 -> 139,298 |
| T3_p0d1_ka (fill) | 7.9 -> 7.8 s | 1.0x | 8.0 -> 7.9 s | 1.0x | 8.1 -> 8.0 s | 25.3 -> 25.2 | +0% | 57.0 -> 57.1 | +0% | 1 / 24 -> 1 / 24 | 36,898 -> 36,898 |
| T3_p0d1_ret (recall) | 26.1 -> 23.5 s | 1.1x | 26.2 -> 25.5 s | 1.0x | 26.2 -> 23.6 s | 80.3 -> 74.3 | +7% | 9.0 -> 9.7 | +8% | 0 / 12 -> 0 / 12 | 147,577 -> 131,273 |
| T4_p1d1_fill (fill) | 23.7 -> 23.7 s | 1.0x | 24.1 -> 24.0 s | 1.0x | 23.9 -> 23.8 s | 72.9 -> 72.9 | +0% | 9.9 -> 9.9 | -0% | 0 / 12 -> 0 / 12 | 139,298 -> 139,298 |
| T4_p1d1_ka (fill) | 7.9 -> 7.8 s | 1.0x | 8.0 -> 7.9 s | 1.0x | 8.1 -> 8.0 s | 25.3 -> 25.2 | +0% | 57.0 -> 57.1 | +0% | 1 / 24 -> 1 / 24 | 36,898 -> 36,898 |
| T4_p1d1_ret (recall) | 25.9 -> 25.8 s | 1.0x | 26.1 -> 26.1 s | 1.0x | 26.0 -> 26.0 s | 79.3 -> 79.4 | -0% | 9.1 -> 9.1 | -0% | 0 / 12 -> 0 / 12 | 147,577 -> 147,577 |
| chain_fill (fill) | 23.7 -> 23.7 s | 1.0x | 24.0 -> 24.0 s | 1.0x | 23.9 -> 23.9 s | 72.8 -> 72.9 | -0% | 9.9 -> 9.9 | -0% | 0 / 12 -> 0 / 12 | 139,298 -> 139,298 |
| chain_ka (fill) | 7.9 -> 7.8 s | 1.0x | 8.0 -> 7.9 s | 1.0x | 8.1 -> 8.0 s | 25.3 -> 25.2 | +0% | 56.9 -> 57.2 | +0% | 1 / 24 -> 1 / 24 | 36,898 -> 36,898 |
| chain_l1_p0d0 (recall) | 26.1 -> 8.4 s | 3.1x | 26.3 -> 9.9 s | 2.7x | 26.2 -> 8.5 s | 79.9 -> 22.9 | +71% | 9.0 -> 31.4 | +248% | 0 / 12 -> 5 / 12 | 147,577 -> 33,614 |
| chain_l2_p1d0 (recall) | 25.8 -> 8.2 s | 3.1x | 26.2 -> 9.0 s | 2.9x | 26.0 -> 8.9 s | 79.3 -> 29.1 | +63% | 9.1 -> 24.8 | +173% | 0 / 12 -> 0 / 12 | 147,577 -> 43,140 |
| chain_l3_p0d1 (recall) | 23.4 -> 20.3 s | 1.1x | 23.8 -> 26.5 s | 0.9x | 23.5 -> 20.5 s | 66.6 -> 61.7 | +7% | 10.8 -> 11.7 | +8% | 1 / 12 -> 0 / 12 | 114,356 -> 111,385 |
| chain_l4_p1d1 (recall) | 20.2 -> 14.4 s | 1.4x | 23.6 -> 23.2 s | 1.0x | 20.3 -> 14.5 s | 61.6 -> 48.6 | +21% | 11.7 -> 14.8 | +27% | 1 / 12 -> 1 / 12 | 106,713 -> 82,094 |
| random_fill (fill) | 11.7 -> 11.7 s | 1.0x | 17.7 -> 17.6 s | 1.0x | 11.8 -> 11.9 s | 54.9 -> 49.9 | +9% | 17.5 -> 19.2 | +10% | 0 / 16 -> 0 / 16 | 139,298 -> 139,298 |
| random_ret (recall) | 7.8 -> 7.4 s | 1.1x | 13.3 -> 13.6 s | 1.0x | 8.1 -> 7.6 s | 37.8 -> 37.3 | +1% | 25.4 -> 25.7 | +1% | 5 / 16 -> 4 / 16 | 69,241 -> 77,945 |

**Routing and recall per point** (expected pair from the brief; served = requests per engine on the on arm; recalled = tokens the on arm's prefills pulled from decode DRAM during the point).

| Point | Expected pair | route_ok off / on | Served (on) | Prefill-side hit off -> on | TTFT p50 off -> on | Speedup | Wall s off -> on | Recalled from decode DRAM (on) |
|---|---|---|---|---|---|---|---|---|
| T1_p0d0_fill (fill) | p0d0 | True / True | d0:12 p0:12 | 0.0% -> 0.0% | 23.7 -> 23.7 s | 1.0x | 74.2 -> 74.3 | 0 |
| T1_p0d0_ka (fill) | any | None / None | d0:24 p0:24 | 0.0% -> 0.0% | 7.9 -> 7.8 s | 1.0x | 25.4 -> 25.2 | 0 |
| T1_p0d0_ret (recall) | p0d0 | True / True | d0:12 p0:12 | 0.0% -> 78.2% | 26.2 -> 8.9 s | 3.0x | 80.4 -> 22.7 | 1,523,456 tok in 11 pulls + 1,408 SWA |
| T2_p1d0_fill (fill) | p0d0 | True / True | d0:12 p0:12 | 0.0% -> 0.0% | 23.7 -> 23.7 s | 1.0x | 73.0 -> 72.8 | 0 |
| T2_p1d0_ka (fill) | any | None / None | d0:24 p0:24 | 0.0% -> 0.0% | 7.9 -> 7.8 s | 1.0x | 25.4 -> 25.2 | 0 |
| T2_p1d0_ret (recall) | p1d0 | True / True | d0:12 p1:12 | 0.0% -> 62.4% | 25.8 -> 8.9 s | 2.9x | 80.7 -> 33.5 | 1,105,664 tok in 8 pulls + 1,024 SWA |
| T3_p0d1_fill (fill) | p0d0 | True / True | d0:12 p0:12 | 0.0% -> 0.0% | 23.7 -> 23.7 s | 1.0x | 72.9 -> 72.8 | 0 |
| T3_p0d1_ka (fill) | any | None / None | d0:24 p0:24 | 0.0% -> 0.0% | 7.9 -> 7.8 s | 1.0x | 25.3 -> 25.2 | 0 |
| T3_p0d1_ret (recall) | p0d1 | True / True | d1:12 p0:12 | 0.0% -> 11.1% | 26.1 -> 23.5 s | 1.1x | 80.3 -> 74.3 | 0 |
| T4_p1d1_fill (fill) | p0d0 | True / True | d0:12 p0:12 | 0.0% -> 0.0% | 23.7 -> 23.7 s | 1.0x | 72.9 -> 72.9 | 0 |
| T4_p1d1_ka (fill) | any | None / None | d0:24 p0:24 | 0.0% -> 0.0% | 7.9 -> 7.8 s | 1.0x | 25.3 -> 25.2 | 0 |
| T4_p1d1_ret (recall) | p1d1 | True / True | d1:12 p1:12 | 0.0% -> 0.0% | 25.9 -> 25.8 s | 1.0x | 79.3 -> 79.4 | 0 |
| chain_fill (fill) | p0d0 | True / True | d0:12 p0:12 | 0.0% -> 0.0% | 23.7 -> 23.7 s | 1.0x | 72.8 -> 72.9 | 0 |
| chain_ka (fill) | any | None / None | d0:24 p0:24 | 0.0% -> 0.0% | 7.9 -> 7.8 s | 1.0x | 25.3 -> 25.2 | 0 |
| chain_l1_p0d0 (recall) | p0d0 | True / True | d0:12 p0:12 | 0.0% -> 77.2% | 26.1 -> 8.4 s | 3.1x | 79.9 -> 22.9 | 1,785,408 tok in 13 pulls + 1,664 SWA |
| chain_l2_p1d0 (recall) | p1d0 | True / True | d0:12 p1:12 | 0.0% -> 70.8% | 25.8 -> 8.2 s | 3.1x | 79.3 -> 29.1 | 1,253,248 tok in 9 pulls + 1,152 SWA |
| chain_l3_p0d1 (recall) | p0d1 | True / True | d1:12 p0:12 | 22.5% -> 24.5% | 23.4 -> 20.3 s | 1.1x | 66.6 -> 61.7 | 900,928 tok in 7 pulls + 896 SWA |
| chain_l4_p1d1 (recall) | p1d1 | True / True | d1:12 p1:12 | 27.7% -> 44.4% | 20.2 -> 14.4 s | 1.4x | 61.6 -> 48.6 | 466,368 tok in 4 pulls + 512 SWA |
| random_fill (fill) | any | None / None | d0:9 d1:7 p0:8 p1:8 | 0.0% -> 0.0% | 11.7 -> 11.7 s | 1.0x | 54.9 -> 49.9 | 0 |
| random_ret (recall) | any | None / None | d0:5 d1:11 p0:9 p1:7 | 53.1% -> 47.2% | 7.8 -> 7.4 s | 1.1x | 37.8 -> 37.3 | 139,264 tok in 1 pulls + 128 SWA |

### Reading

- **Same pair (T1) and other prefill, same decode (T2)** recall as on the first head: 78.2% and 62.4% hit, TTFT p50
  26.2 -> 8.9 s and 25.8 -> 8.9 s (2.9x both), batch wall 79.9 -> 22.7 s and 80.3 -> 33.5 s. Chain legs 1 and 2 at
  77.2% and 70.8% (3.1x and 3.1x). First head: 78.6 / 62.9 / 78.6 / 80.0%.
- **Other decode (T3, T4).** T4 is cold on both arms as before (0.0%, 26 s): the recall is decode-affine. T3 (same
  prefill, other decode) now shows 11.1% hit and 26.1 -> 23.5 s on the on arm, from the prefill's own host tier
  rather than a recall (0 pulls): the windows it keeps for every evicted node serve part of the returning prefix.
  Chain legs 3 and 4: 24.5% and 44.4% (first head 25.0 and 40.3%).
- **Random routing**: 47.2% hit on the on arm's return against 53.1% off, with p50 TTFT equal (7.4 against 7.8 s)
  and the on arm's wall 37.3 against 31.5 s. The random split differs per arm and per head (this head: fills 8/8
  over the prefills on the on arm, 7/9 off; returns 9/7 against 10/6), so the random rows are a sanity case, not a
  comparison; the first head happened to fall the other way (53.1% on, 47.2% off).
- **Validity.** No exception, OOM, malformed or deadline line on either arm. The on arm logged 144 `subtree drop
  declined (node locked)` lines (112 on prefill-0, 32 on prefill-1; I4) during the recalling returns, no request
  failed. Counters identical on all 8 ranks of all four engines; 681 pushes stored and landed (10.0M tokens on
  decode 0, 1.9M on decode 1, against 154 pushes on the first head: the prefill now pushes every evicted node rather
  than one branch per path end), 43 pulls of 5.8M tokens, 5 offers over budget, 0 failed.

## Campaign 3 (head 83198bc912): write-through, 1P1D

Jobs: on `j-c1ee04fe-4082-4d27-9bbc` (stage 08:25-09:20Z, second attempt after one spot preemption), off
`j-b7fb2b34-631a-46bd-be27` (08:25-09:31Z, second attempt). 396 of 396 requests completed on each arm, 0 request
errors. Full tables in `results/h83198bc/table_write_through.md`; head-to-head in `results/h83198bc/delta_write_through.md`.

**Performance gain** (what a user of the pair sees; return rows are the requests whose prefix the previous turn produced).

| Point | TTFT p50 off -> on | Speedup | TTFT p95 off -> on | Speedup | E2E p50 off -> on | Wall s off -> on | Gain | Req/min off -> on | Gain | Warm returns off -> on | Prefill tokens computed per request, off -> on |
|---|---|---|---|---|---|---|---|---|---|---|---|
| recall 8, fill (cold) | 23.4 -> 23.4 s | 1.0x | 25.9 -> 26.0 s | 1.0x | 23.5 -> 23.5 s | 49.8 -> 49.8 | +0% | 9.6 -> 9.6 | +0% | 0 / 8 -> 0 / 8 | 139,298 -> 139,298 |
| recall 8, return | 17.2 -> 2.4 s | 7.2x | 22.1 -> 3.2 s | 7.0x | 17.4 -> 2.7 s | 37.0 -> 6.0 | +84% | 13.0 -> 80.6 | +521% | 2 / 8 -> 8 / 8 | 93,425 -> 8,313 |
| recall 12, fill (cold) | 23.6 -> 23.5 s | 1.0x | 23.6 -> 23.6 s | 1.0x | 23.8 -> 23.7 s | 72.4 -> 72.1 | +0% | 9.9 -> 10.0 | +0% | 0 / 12 -> 0 / 12 | 139,298 -> 139,298 |
| recall 12, return | 25.7 -> 9.0 s | 2.9x | 25.8 -> 16.2 s | 1.6x | 25.9 -> 9.1 s | 78.8 -> 38.8 | +51% | 9.1 -> 18.5 | +103% | 0 / 12 -> 1 / 12 | 147,577 -> 64,446 |
| recall 16, fill (cold) | 23.6 -> 23.5 s | 1.0x | 23.6 -> 23.6 s | 1.0x | 23.8 -> 23.7 s | 96.4 -> 96.1 | +0% | 10.0 -> 10.0 | +0% | 0 / 16 -> 0 / 16 | 139,298 -> 139,298 |
| recall 16, return | 25.7 -> 2.4 s | 10.9x | 25.8 -> 8.6 s | 3.0x | 25.9 -> 2.5 s | 104.8 -> 17.1 | +84% | 9.2 -> 56.0 | +512% | 0 / 16 -> 12 / 16 | 147,577 -> 17,017 |
| static 4 docs | 7.0 -> 7.1 s | 1.0x | 15.5 -> 16.5 s | 0.9x | 10.1 -> 9.3 s | 33.8 -> 34.2 | -1% | 21.3 -> 21.1 | -1% | 5 / 12 -> 5 / 12 | 51,963 -> 51,963 |
| static 8 docs | 6.7 -> 7.9 s | 0.8x | 18.7 -> 18.9 s | 1.0x | 9.1 -> 10.3 s | 66.6 -> 66.4 | +0% | 21.6 -> 21.7 | +0% | 10 / 24 -> 9 / 24 | 54,675 -> 54,013 |
| static 12 docs | 12.5 -> 5.6 s | 2.2x | 22.0 -> 21.9 s | 1.0x | 14.8 -> 8.1 s | 145.0 -> 101.4 | +30% | 14.9 -> 21.3 | +43% | 4 / 36 -> 19 / 36 | 89,470 -> 55,198 |
| static 16 docs | 15.8 -> 7.0 s | 2.3x | 21.8 -> 21.6 s | 1.0x | 17.9 -> 9.2 s | 211.7 -> 141.7 | +33% | 13.6 -> 20.3 | +49% | 1 / 48 -> 18 / 48 | 99,451 -> 58,148 |
| mixed, long stream | 24.4 -> 15.1 s | 1.6x | 31.3 -> 26.5 s | 1.2x | 26.8 -> 17.9 s | 160.9 -> 116.5 | +28% | 8.9 -> 12.4 | +38% | 0 / 24 -> 1 / 24 | 260,665 -> 173,014 |
| mixed, short stream | 8.9 -> 8.4 s | 1.1x | 31.7 -> 28.5 s | 1.1x | 9.1 -> 8.6 s | 216.6 -> 163.5 | +25% | 26.6 -> 35.2 | +32% | 2 / 96 -> 14 / 96 | 65,166 -> 43,254 |

**Cache (mechanism)**: prefill-side hit, client-reported cached tokens, where the prefix was found, and what the on arm recalled from decode DRAM.

| Point | Requests on / off (errors) | Prefill-side hit off -> on | Gain | Client-reported hit off -> on | Cached by tier device / host, off -> on | Recalled from decode DRAM (on) |
|---|---|---|---|---|---|---|
| recall 8, fill (cold) | 8 / 8 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| recall 8, return | 8 / 8 (0/0) | 36.7% -> 94.4% | +57.7 pp | 94.4% -> 94.4% | 0.80M / 0.32M -> 0.22M / 0.89M | 394,560 tok in 7 pulls + 896 SWA |
| recall 12, fill (cold) | 12 / 12 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| recall 12, return | 12 / 12 (0/0) | 0.0% -> 56.3% | +56.3 pp | 94.4% -> 72.1% | 1.67M / 0.00M -> 0.34M / 0.94M | 883,840 tok in 8 pulls + 1,024 SWA |
| recall 16, fill (cold) | 16 / 16 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| recall 16, return | 16 / 16 (0/0) | 0.0% -> 88.5% | +88.5 pp | 94.4% -> 94.4% | 2.23M / 0.00M -> 0.14M / 2.09M | 2,088,960 tok in 15 pulls + 1,920 SWA |
| static 4 docs | 12 / 12 (0/0) | 62.7% -> 62.7% | +0.0 pp | 62.7% -> 62.7% | 1.05M / 0.00M -> 1.05M / 0.00M | 0 |
| static 8 docs | 24 / 24 (0/0) | 60.8% -> 61.2% | +0.5 pp | 62.7% -> 62.0% | 1.83M / 0.27M -> 1.87M / 0.20M | 65,536 tok in 2 pulls + 256 SWA |
| static 12 docs | 36 / 36 (0/0) | 35.8% -> 60.4% | +24.6 pp | 62.7% -> 62.7% | 2.90M / 0.25M -> 1.57M / 1.58M | 1,203,200 tok in 14 pulls + 1,792 SWA |
| static 16 docs | 48 / 48 (0/0) | 28.6% -> 58.3% | +29.7 pp | 62.6% -> 61.0% | 3.90M / 0.28M -> 1.64M / 2.43M | 2,253,568 tok in 19 pulls + 2,432 SWA |
| mixed, long stream | 24 / 24 (0/0) | 11.7% -> 41.4% | +29.7 pp | 62.7% -> 61.5% | 1.93M / 0.16M -> 1.10M / 0.96M | 1,563,520 tok in 41 pulls + 5,248 SWA |
| mixed, short stream | 96 / 96 (0/0) | 11.7% -> 41.4% | +29.7 pp | 13.8% -> 30.0% | 0.52M / 0.00M -> 0.17M / 0.95M | 1,563,520 tok in 41 pulls + 5,248 SWA |

The fill rows are the cold phase: both engines are wiped before the point and every session has a new 128k prefix, so a 0% hit there is by construction on both arms; they are kept for the cold prefill's throughput and latency (whether pushes in flight slow the prefill that issues them). The mixed rows share one metrics window, so their hit and recall columns are the same block.

**Throughput** (gain = on vs off, higher is better).

| Point | Total tok/s off | on | Gain | Output tok/s off | on | Gain | Req/min off | on | Gain |
|---|---|---|---|---|---|---|---|---|---|
| recall 8, fill (cold) | 22367 | 22362 | -0% | 2.6 | 2.6 | +0% | 9.6 | 9.6 | +0% |
| recall 8, return | 31955 | 198305 | +521% | 3.5 | 21.5 | +514% | 13.0 | 80.6 | +521% |
| recall 12, fill (cold) | 23088 | 23175 | +0% | 2.7 | 2.7 | +0% | 9.9 | 10.0 | +0% |
| recall 12, return | 22479 | 45612 | +103% | 2.4 | 4.9 | +104% | 9.1 | 18.5 | +103% |
| recall 16, fill (cold) | 23132 | 23192 | +0% | 2.7 | 2.7 | +0% | 10.0 | 10.0 | +0% |
| recall 16, return | 22523 | 137881 | +512% | 2.4 | 14.9 | +521% | 9.2 | 56.0 | +512% |
| static 4 docs | 49576 | 48958 | -1% | 90.9 | 89.8 | -1% | 21.3 | 21.1 | -1% |
| static 8 docs | 50271 | 50478 | +0% | 92.2 | 92.6 | +0% | 21.6 | 21.7 | +0% |
| static 12 docs | 34637 | 49554 | +43% | 63.5 | 90.9 | +43% | 14.9 | 21.3 | +43% |
| static 16 docs | 31639 | 47289 | +49% | 58.0 | 86.7 | +49% | 13.6 | 20.3 | +49% |
| mixed, long stream | 20818 | 28746 | +38% | 38.2 | 52.7 | +38% | 8.9 | 12.4 | +38% |
| mixed, short stream | 17285 | 22898 | +32% | 7.1 | 9.4 | +32% | 26.6 | 35.2 | +32% |

**Latency** (gain = reduction on vs off, positive means the on arm is faster).

| Point | TTFT p50 off | on | Gain | TTFT p95 off | on | Gain | ITL p50 off | on | Gain |
|---|---|---|---|---|---|---|---|---|---|
| recall 8, fill (cold) | 23.4 s | 23.4 s | -0% | 25.9 s | 26.0 s | -0% | 0.012 s | 0.010 s | +15% |
| recall 8, return | 17.2 s | 2.4 s | +86% | 22.1 s | 3.2 s | +86% | 0.010 s | 0.016 s | -67% |
| recall 12, fill (cold) | 23.6 s | 23.5 s | +0% | 23.6 s | 23.6 s | -0% | 0.012 s | 0.010 s | +16% |
| recall 12, return | 25.7 s | 9.0 s | +65% | 25.8 s | 16.2 s | +37% | 0.010 s | 0.011 s | -14% |
| recall 16, fill (cold) | 23.6 s | 23.5 s | +0% | 23.6 s | 23.6 s | +0% | 0.012 s | 0.011 s | +9% |
| recall 16, return | 25.7 s | 2.4 s | +91% | 25.8 s | 8.6 s | +67% | 0.009 s | 0.011 s | -18% |
| static 4 docs | 7.0 s | 7.1 s | -1% | 15.5 s | 16.5 s | -6% | 0.012 s | 0.009 s | +25% |
| static 8 docs | 6.7 s | 7.9 s | -18% | 18.7 s | 18.9 s | -1% | 0.009 s | 0.009 s | +0% |
| static 12 docs | 12.5 s | 5.6 s | +56% | 22.0 s | 21.9 s | +0% | 0.009 s | 0.009 s | -6% |
| static 16 docs | 15.8 s | 7.0 s | +56% | 21.8 s | 21.6 s | +1% | 0.009 s | 0.009 s | -6% |
| mixed, long stream | 24.4 s | 15.1 s | +38% | 31.3 s | 26.5 s | +15% | 0.010 s | 0.011 s | -7% |
| mixed, short stream | 8.9 s | 8.4 s | +6% | 31.7 s | 28.5 s | +10% | 0.010 s | 0.012 s | -17% |

**Offload counters on the on arm, per point** (TP0 deltas from the server logs; every push and landing is a 128k-session branch with its SWA window).

| Point | Pushes stored / started | Landings landed / received | Recalls pulls / offers | Pulled tokens | SWA tokens | Failed / refused / no room |
|---|---|---|---|---|---|---|
| recall 8, fill (cold) | 8 / 8 | 8 / 8 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall 8, return | 8 / 8 | 8 / 8 | 7 / 8 | 394,560 | 896 | 0 / 0 / 0 |
| recall 12, fill (cold) | 70 / 70 | 70 / 70 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall 12, return | 26 / 26 | 26 / 26 | 8 / 10 | 883,840 | 1,024 | 0 / 0 / 0 |
| recall 16, fill (cold) | 137 / 137 | 137 / 137 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall 16, return | 17 / 17 | 17 / 17 | 15 / 16 | 2,088,960 | 1,920 | 0 / 0 / 0 |
| static 4 docs | 0 / 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| static 8 docs | 36 / 36 | 36 / 36 | 2 / 5 | 65,536 | 256 | 0 / 0 / 0 |
| static 12 docs | 111 / 111 | 111 / 111 | 14 / 17 | 1,203,200 | 1,792 | 0 / 0 / 0 |
| static 16 docs | 146 / 146 | 146 / 146 | 19 / 21 | 2,253,568 | 2,432 | 0 / 0 / 0 |
| mixed, long stream | 342 / 342 | 342 / 342 | 41 / 45 | 1,563,520 | 5,248 | 0 / 0 / 0 |
| mixed, short stream | 342 / 342 | 342 / 342 | 41 / 45 | 1,563,520 | 5,248 | 0 / 0 / 0 |

Final counters, on arm: push started 1,090, stored 1,090; landing received 1,090, granted 1,090, landed 1,090
(16,945,280 tokens); recall offers 222, pulls 127, pulled 10,705,984 tokens plus 16,256 SWA window tokens, 92 offers
skipped (branch still local), 1 declined for memory, 2 over budget, 0 failed, 0 refused; counters identical on all 8
ranks of both engines.

**Equivalence (integrity, run last on the same engines): 16 of 16 identical on both arms**; on arm all 16 returns
served from the prefill's host tier after the recall from decode DRAM, off arm all 16 from device.

### Reading

- **Recall ladder.** As on the first head, with the 8-session return better: 94.4% hit and TTFT p50 2.4 s (first
  head 82.6%, 4.3 s), 12 sessions 56.3% and 9.0 s (66.0%, 7.5 s), 16 sessions 88.5% and 2.4 s (10.7x, unchanged).
  The 12-session return is the one point of this campaign that moved against the on arm between heads (-9.7 pp,
  +1.5 s); it recalled 8 of 10 offers (first head 10 of 10), the rest is in what the host tier kept.
- **Static ladder.** No loss at 4 and 8 documents, a gain at 12 and 16 (60.4% against 35.8%, 58.3% against 28.6%;
  TTFT p50 12.5 -> 5.6 s and 15.8 -> 7.0 s), the same picture as on the first head with 16 documents slightly better
  (54.5 -> 58.3%).
- **Mixed sizes.** 120 of 120 on both arms; long stream TTFT p50 24.4 -> 15.1 s, short stream 8.9 -> 8.4 s, prefill-side
  hit 11.7 -> 41.4%.
- **Validity.** No invalidating line on the prefill of either arm. The on arm's decode logged, once, `Raiden host
  transfer <id>#px / #pxs failed (DEADLINE_EXCEEDED, await_pull): Transfer session timed out` (8 + 8 lines, one per
  rank) at 08:59:45 during the wipe before the 16-session fill: the prefill had declined that offer for lack of memory
  (`no_memory=1`) and never pulled, the decode's offer session waited for its 60 s deadline and held `flush_cache` off
  until it expired (ISSUES I8, new, minor). No request was affected.

## Change from head 54a80863a6 to 83198bc912

Per point, the off -> on numbers on each head and the on arm's change, in `results/h83198bc/delta_write_back.md`,
`delta_write_through.md`, `delta_transitions_write_back.md`. The off arms are the same configuration on both heads and
show the run-to-run spread of these points: most off-arm TTFT p50 within 1 s and throughput within 6%; the outliers
are write-back recall 8 return (throughput 133k -> 170k tok/s at 2.5 -> 2.4 s), recall 12 return (19.3 -> 22.0 s),
static 4 (12-request p50 7.2 -> 10.3 s, p95 and throughput unchanged) and 2P2D chain leg 3 (19.9 -> 23.4 s). On-arm
moves of that size are noise; the static-ladder and integrity changes are far outside it.

| Case | First head (54a80863a6) | Current head (83198bc912) |
|---|---|---|
| Integrity, write-back on, after ladders | 12 / 16 (sessions 6, 11, 14, 15) | **16 / 16** |
| Integrity, write-back on, fresh engines | 13 / 16 (sessions 6, 9, 11 at token 5) | **16 / 16** |
| Integrity, other three arms | 16 / 16 | 16 / 16 |
| Write-back static 8 / 12 / 16 docs, prefill-side hit off -> on | 62.3 -> 55.6, 50.4 -> 32.2, 39.8 -> 27.1% | 62.5 -> 62.5, 50.9 -> 55.3, 39.5 -> 53.9% |
| Write-back static 8 / 12 / 16 docs, throughput on vs off | -13%, -23%, -15% | -2%, +5%, +20% |
| Write-back recall 16 return, TTFT p50 off -> on | 26.1 -> 8.0 s (3.3x), hit 64.9% | 26.0 -> 9.5 s (2.7x), hit 55.5% |
| Write-back recall 12 return | 19.3 -> 18.6 s, hit 37.1% | 22.0 -> 11.9 s, hit 55.5% |
| Write-back recall 8 return | 2.5 -> 2.6 s, hit 92.3 -> 94.4% | 2.4 -> 4.3 s, hit 93.7 -> 86.8% |
| Write-back mixed, prefill-side hit off -> on | 21.9 -> 39.7% | 21.9 -> 50.0% |
| 2P2D T1 / T2 return, hit and TTFT speedup | 78.6% 3.1x / 62.9% 2.5x | 78.2% 2.9x / 62.4% 2.9x |
| 2P2D T3 / T4 return | 0.0% / 0.0% | 11.1% (host tier) / 0.0% |
| Write-through recall 8 / 12 / 16 return, hit on | 82.6 / 66.0 / 88.5% | 94.4 / 56.3 / 88.5% |
| Write-through static 12 / 16 docs, hit on | 61.4 / 54.5% | 60.4 / 58.3% |
| `hicache_hash_cpp` JIT rebuild lines (I7) | 560 / 936 / 128 per on arm | 0 everywhere |
| `subtree drop declined` lines (I4), 1P1D wb on / 2P2D wb on / E1 fresh | 96 / 40 / 0 | 168 / 144 / 8 |
| Pushes stored, 1P1D wb on / 2P2D wb on / wt on | 204 / 154 / 1,042 | 574 / 681 / 1,090 |

# Appendix: results on the first head 54a80863a6 (2026-11-10/11)

Same recipe, harness, image and settings. Jobs: write-back 1P1D on `j-74143469-8c3a-4bd6-9575`, off
`j-ae4dd88f-6893-4c7d-8796`; 2P2D on `j-dd3f6030-3b7a-4588-a5cd`, off `j-d8cc8f42-fbc3-4d35-afff`; write-through
1P1D on `j-ca202e3d-91f2-44d7-991e`, off `j-8c1912b8-b43d-463f-8d17`; fresh-engine integrity `j-c909ba56-55e8-4b10-8eb3`.
Results under `results/<arm>/` and `evidence/<arm>/` (no `h83198bc/` prefix). The equivalence and static-ladder
findings below were reported to the author and are fixed on head 83198bc912 (see above).

## First head, campaign 1: write-back, 1P1D

- **Performance gain** (what a user of the pair sees; return rows are the requests whose prefix the previous turn produced).

| Point | TTFT p50 off -> on | Speedup | TTFT p95 off -> on | Speedup | E2E p50 off -> on | Wall s off -> on | Gain | Req/min off -> on | Gain | Warm returns off -> on | Prefill tokens computed per request, off -> on |
|---|---|---|---|---|---|---|---|---|---|---|---|
| recall 8, fill (cold) | 23.5 -> 23.5 s | 1.0x | 25.8 -> 25.7 s | 1.0x | 23.7 -> 23.7 s | 49.9 -> 50.0 | -0% | 9.6 -> 9.6 | -0% | 0 / 8 -> 0 / 8 | 139,298 -> 139,298 |
| recall 8, return | 2.5 -> 2.6 s | 1.0x | 3.4 -> 4.6 s | 0.7x | 4.0 -> 4.5 s | 8.9 -> 8.8 | +1% | 54.0 -> 54.6 | +1% | 8 / 8 -> 8 / 8 | 11,393 -> 8,313 |
| recall 12, fill (cold) | 23.8 -> 23.8 s | 1.0x | 24.1 -> 24.1 s | 1.0x | 23.9 -> 23.9 s | 73.0 -> 73.2 | -0% | 9.9 -> 9.8 | -0% | 0 / 12 -> 0 / 12 | 139,298 -> 139,298 |
| recall 12, return | 19.3 -> 18.6 s | 1.0x | 24.9 -> 20.7 s | 1.2x | 19.5 -> 18.7 s | 60.0 -> 54.2 | +10% | 12.0 -> 13.3 | +11% | 2 / 12 -> 2 / 12 | 105,972 -> 92,868 |
| recall 16, fill (cold) | 23.9 -> 24.0 s | 1.0x | 24.1 -> 24.1 s | 1.0x | 24.0 -> 24.1 s | 97.3 -> 97.5 | -0% | 9.9 -> 9.8 | -0% | 0 / 16 -> 0 / 16 | 139,298 -> 139,298 |
| recall 16, return | 26.1 -> 8.0 s | 3.3x | 26.1 -> 19.7 s | 1.3x | 26.2 -> 8.2 s | 106.2 -> 41.6 | +61% | 9.0 -> 23.1 | +155% | 0 / 16 -> 5 / 16 | 147,577 -> 51,833 |
| static 4 docs | 7.2 -> 6.5 s | 1.1x | 16.3 -> 18.8 s | 0.9x | 9.5 -> 8.7 s | 32.6 -> 32.8 | -1% | 22.1 -> 21.9 | -1% | 5 / 12 -> 6 / 12 | 51,963 -> 51,963 |
| static 8 docs | 6.4 -> 9.5 s | 0.7x | 18.9 -> 18.7 s | 1.0x | 8.7 -> 11.7 s | 63.9 -> 73.5 | -15% | 22.5 -> 19.6 | -13% | 10 / 24 -> 6 / 24 | 52,584 -> 61,861 |
| static 12 docs | 7.2 -> 15.1 s | 0.5x | 22.0 -> 22.1 s | 1.0x | 9.5 -> 17.3 s | 119.4 -> 155.8 | -30% | 18.1 -> 13.9 | -23% | 7 / 36 -> 2 / 36 | 69,079 -> 94,491 |
| static 16 docs | 12.1 -> 15.8 s | 0.8x | 21.7 -> 21.9 s | 1.0x | 14.4 -> 17.9 s | 187.4 -> 221.1 | -18% | 15.4 -> 13.0 | -15% | 7 / 48 -> 0 / 48 | 83,903 -> 101,611 |
| mixed, long stream | 21.0 -> 20.9 s | 1.0x | 26.6 -> 26.5 s | 1.0x | 23.3 -> 23.6 s | 133.0 -> 146.6 | -10% | 10.8 -> 9.8 | -9% | 0 / 24 -> 0 / 24 | 230,611 -> 178,038 |
| mixed, short stream | 9.2 -> 5.3 s | 1.7x | 26.8 -> 26.7 s | 1.0x | 9.4 -> 5.5 s | 194.2 -> 164.2 | +15% | 29.6 -> 35.1 | +18% | 1 / 96 -> 28 / 96 | 57,653 -> 44,510 |

**Cache (mechanism)**: prefill-side hit, client-reported cached tokens, where the prefix was found, and what the on arm recalled from decode DRAM.

| Point | Requests on / off (errors) | Prefill-side hit off -> on | Gain | Client-reported hit off -> on | Cached by tier device / host, off -> on | Recalled from decode DRAM (on) |
|---|---|---|---|---|---|---|
| recall 8, fill (cold) | 8 / 8 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| recall 8, return | 8 / 8 (0/0) | 92.3% -> 94.4% | +2.1 pp | 94.4% -> 94.4% | 0.24M / 0.88M -> 0.42M / 0.70M | 0 |
| recall 12, fill (cold) | 12 / 12 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| recall 12, return | 12 / 12 (0/0) | 28.2% -> 37.1% | +8.9 pp | 94.4% -> 37.1% | 1.17M / 0.50M -> 0.10M / 0.56M | 57,024 tok in 1 pulls + 128 SWA |
| recall 16, fill (cold) | 16 / 16 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| recall 16, return | 16 / 16 (0/0) | 0.0% -> 64.9% | +64.9 pp | 94.4% -> 70.8% | 2.23M / 0.00M -> 0.14M / 1.53M | 1,531,904 tok in 11 pulls + 1,408 SWA |
| static 4 docs | 12 / 12 (0/0) | 62.7% -> 62.7% | +0.0 pp | 62.7% -> 62.7% | 1.05M / 0.00M -> 1.05M / 0.00M | 0 |
| static 8 docs | 24 / 24 (0/0) | 62.3% -> 55.6% | -6.7 pp | 62.7% -> 55.6% | 1.85M / 0.25M -> 1.86M / 0.00M | 0 |
| static 12 docs | 36 / 36 (0/0) | 50.4% -> 32.2% | -18.2 pp | 62.6% -> 48.5% | 1.80M / 1.34M -> 2.43M / 0.00M | 0 |
| static 16 docs | 48 / 48 (0/0) | 39.8% -> 27.1% | -12.7 pp | 62.7% -> 55.8% | 3.09M / 1.10M -> 3.73M / 0.00M | 0 |
| mixed, long stream | 24 / 24 (0/0) | 21.9% -> 39.7% | +17.8 pp | 62.7% -> 56.5% | 0.91M / 1.18M -> 1.89M / 0.00M | 1,585,152 tok in 43 pulls + 5,504 SWA |
| mixed, short stream | 96 / 96 (0/0) | 21.9% -> 39.7% | +17.8 pp | 32.5% -> 42.4% | 1.22M / 0.00M -> 0.00M / 1.59M | 1,585,152 tok in 43 pulls + 5,504 SWA |

The fill rows are the cold phase: both engines are wiped before the point and every session has a new 128k prefix, so a 0% hit there is by construction on both arms; they are kept for the cold prefill's throughput and latency (whether pushes in flight slow the prefill that issues them). The mixed rows share one metrics window, so their hit and recall columns are the same block.

**Throughput** (gain = on vs off, higher is better).

| Point | Total tok/s off | on | Gain | Output tok/s off | on | Gain | Req/min off | on | Gain |
|---|---|---|---|---|---|---|---|---|---|
| recall 8, fill (cold) | 22328 | 22283 | -0% | 2.6 | 2.6 | +0% | 9.6 | 9.6 | -0% |
| recall 8, return | 132883 | 134261 | +1% | 14.4 | 14.6 | +1% | 54.0 | 54.6 | +1% |
| recall 12, fill (cold) | 22906 | 22845 | -0% | 2.6 | 2.6 | +0% | 9.9 | 9.8 | -0% |
| recall 12, return | 29500 | 32656 | +11% | 3.2 | 3.5 | +9% | 12.0 | 13.3 | +11% |
| recall 16, fill (cold) | 22919 | 22852 | -0% | 2.6 | 2.6 | +0% | 9.9 | 9.8 | -0% |
| recall 16, return | 22230 | 56723 | +155% | 2.4 | 6.1 | +154% | 9.0 | 23.1 | +155% |
| static 4 docs | 51369 | 51056 | -1% | 94.2 | 93.7 | -1% | 22.1 | 21.9 | -1% |
| static 8 docs | 52414 | 45568 | -13% | 96.2 | 83.6 | -13% | 22.5 | 19.6 | -13% |
| static 12 docs | 42076 | 32246 | -23% | 77.2 | 59.2 | -23% | 18.1 | 13.9 | -23% |
| static 16 docs | 35744 | 30296 | -15% | 65.6 | 55.6 | -15% | 15.4 | 13.0 | -15% |
| mixed, long stream | 25182 | 22846 | -9% | 46.2 | 41.9 | -9% | 10.8 | 9.8 | -9% |
| mixed, short stream | 19277 | 22807 | +18% | 7.9 | 9.4 | +19% | 29.6 | 35.1 | +18% |

**Latency** (gain = reduction on vs off, positive means the on arm is faster).

| Point | TTFT p50 off | on | Gain | TTFT p95 off | on | Gain | ITL p50 off | on | Gain |
|---|---|---|---|---|---|---|---|---|---|
| recall 8, fill (cold) | 23.5 s | 23.5 s | +0% | 25.8 s | 25.7 s | +0% | 0.009 s | 0.010 s | -5% |
| recall 8, return | 2.5 s | 2.6 s | -4% | 3.4 s | 4.6 s | -37% | 0.076 s | 0.072 s | +6% |
| recall 12, fill (cold) | 23.8 s | 23.8 s | -0% | 24.1 s | 24.1 s | -0% | 0.010 s | 0.009 s | +5% |
| recall 12, return | 19.3 s | 18.6 s | +4% | 24.9 s | 20.7 s | +17% | 0.009 s | 0.010 s | -5% |
| recall 16, fill (cold) | 23.9 s | 24.0 s | -0% | 24.1 s | 24.1 s | -0% | 0.010 s | 0.009 s | +3% |
| recall 16, return | 26.1 s | 8.0 s | +69% | 26.1 s | 19.7 s | +25% | 0.010 s | 0.010 s | -3% |
| static 4 docs | 7.2 s | 6.5 s | +10% | 16.3 s | 18.8 s | -15% | 0.009 s | 0.009 s | +2% |
| static 8 docs | 6.4 s | 9.5 s | -49% | 18.9 s | 18.7 s | +1% | 0.009 s | 0.009 s | +1% |
| static 12 docs | 7.2 s | 15.1 s | -109% | 22.0 s | 22.1 s | -1% | 0.009 s | 0.009 s | +3% |
| static 16 docs | 12.1 s | 15.8 s | -31% | 21.7 s | 21.9 s | -1% | 0.009 s | 0.009 s | +3% |
| mixed, long stream | 21.0 s | 20.9 s | +0% | 26.6 s | 26.5 s | +1% | 0.010 s | 0.010 s | -3% |
| mixed, short stream | 9.2 s | 5.3 s | +43% | 26.8 s | 26.7 s | +0% | 0.010 s | 0.011 s | -15% |

**Offload counters on the on arm, per point** (TP0 deltas from the server logs; every push and landing is a 128k-session branch with its SWA window).

| Point | Pushes stored / started | Landings landed / received | Recalls pulls / offers | Pulled tokens | SWA tokens | Failed / refused / no room |
|---|---|---|---|---|---|---|
| recall 8, fill (cold) | 0 / 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall 8, return | 0 / 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall 12, fill (cold) | 0 / 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall 12, return | 9 / 9 | 9 / 9 | 1 / 2 | 57,024 | 128 | 0 / 0 / 0 |
| recall 16, fill (cold) | 6 / 6 | 6 / 6 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall 16, return | 12 / 12 | 12 / 12 | 11 / 12 | 1,531,904 | 1,408 | 0 / 0 / 0 |
| static 4 docs | 0 / 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| static 8 docs | 0 / 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| static 12 docs | 16 / 16 | 16 / 16 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| static 16 docs | 35 / 35 | 35 / 35 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| mixed, long stream | 93 / 93 | 93 / 93 | 43 / 43 | 1,585,152 | 5,504 | 0 / 0 / 0 |
| mixed, short stream | 93 / 93 | 93 / 93 | 43 / 43 | 1,585,152 | 5,504 | 0 / 0 / 0 |

Final counters, on arm: prefill push started 204, stored 204; decode landing received 204, granted 204, landed 204
(11,889,024 tokens); recall offers 150, pulls 71, pulled 5,271,232 tokens plus 9,088 SWA window tokens, 78 offers
skipped because the prefill still held the branch in its own host tier, 1 over budget, 0 failed, 0 refused; push,
landing and recall counters identical on all 8 ranks of both engines. Off arm: no offload lines, as expected.

**Equivalence (integrity):** off arm 16 of 16 identical (all 16 served from the prefill's device cache). On arm,
run last on the same engines, **12 of 16**: sessions 6, 11 and 14, served from the host tier with 139,264 cached
tokens after the recall from decode DRAM, diverge from their recompute at tokens 5, 5 and 19; session 15, served from
nowhere (0 cached tokens, a full recompute), diverges at token 22. On **fresh engines** of the on arm
(`j-c909ba56-55e8-4b10-8eb3`, `STAGE=edges EDGES=E1`, no ladders before it, zero `subtree drop declined` lines):
**13 of 16**, sessions 6, 9 and 11 at token 5, all three host-served after a pull; a first attempt of the same job,
preempted after 8 verifies, had 7 of 8 with session 6 at token 5. Session 6 diverges at the same token in three
independent runs, so this is a deterministic, prompt-specific difference between the recalled and the recomputed
path, present only under write-back with the switch on: the write-through on arm, whose returns were also host-served
after a pull, is 16 of 16. Details, controls and the code paths that differ in ISSUES I5 (open, reported as a PR
defect); the refused subtree drops (I4) are not the cause.

### Reading

- **Recall ladder.** 8 sessions (1.1M tokens) fit the prefill's own host tier: both arms hit above 92% and no push is
  needed (none happened). At 16 sessions (2.2M tokens) the off arm has evicted everything by the time the sessions
  return (0.0%, every return a 26 s cold prefill); the on arm pushed the evicted branches to decode DRAM during the
  fill (6 stored, then 12 more as the return evicted the rest) and recalled 11 of 12 offers with their windows:
  64.9% hit, TTFT p50 26.1 -> 8.0 s, total throughput 22k -> 57k tok/s, 2.5x the requests per minute. 12 sessions is
  the transition regime: during the fill nothing was evicted, so nothing was pushed; the pushes (9) only started when
  the return itself evicted branches, too late for most returning sessions (1 recall of 57k tokens). Both arms sit at
  28-37% there; per session the on arm served 4 sessions from host, 2 partially from device, 6 missed.
- **Static ladder.** Each document is visited 3 times (the first cold), so the ceiling is 62.7% (2 of 3 visits, a
  131k document in a 139k prompt); 4 documents (0.56M tokens) sit at it on both arms. Two effects then stack. (a)
  Capacity, on both arms: from 8 documents (1.1M, 1.7M, 2.2M tokens) the set spills from the 786k-token HBM pool to
  the host tier, and a host hit has to be loaded back before it counts: the off arm still reports every repeat visit
  as a hit (15 of 16, 24 of 24, 32 of 32 at 8, 12, 16) but its prefill-side hit falls 62.3 -> 50.4 -> 39.8%. (b) On
  the on arm the hybrid host tier is window-at-the-end only: with the switch on the prefill's host RAM keeps only the
  last SWA window of each path, and a pushed branch in decode DRAM carries only that window; a static revisit forks
  from the shared document prefix (each visit appends a different 8k block), and at the fork there is no window, so
  neither the host tier nor decode DRAM can serve it. The counters say exactly that: host hits 0.00M on every static
  point of the on arm (0.25M, 1.34M, 1.10M off) and 0 recalls although 16 and 35 branches were pushed at 12 and 16
  documents. Only the device tier serves the on arm, so repeat visits hit 13 of 16, 16 of 24, 25 of 32 and the hit
  reads 55.6 -> 32.2 -> 27.1%, with TTFT p50 6.4 -> 9.5 s, 7.2 -> 15.1 s, 12.1 -> 15.8 s. This is the PR's documented
  write-back limitation, the same shape as its own g + v7 run (62.5 -> 55.8, 50.9 -> 30.4, 39.6 -> 21.3%); campaign 3
  shows write-through removes it.
- **Mixed sizes.** 120 of 120 on both arms. The long stream's 24 requests kept their latency (TTFT p50 21.0 -> 20.9
  s); the short stream gained (TTFT p50 9.2 -> 5.3 s, 19.3k -> 22.8k tok/s, 29.6 -> 35.1 requests per minute). The
  prefill-side hit over the whole block rose from 21.9% to 39.7%, with 43 of 43 offers recalled (1.59M tokens plus
  5,504 SWA tokens) and 93 of 93 pushes stored and landed.
- **Throughput and latency in the fill phases** are the same on both arms (22.3k-22.9k tok/s, TTFT p50 23.5-24.0 s):
  pushes in flight did not slow the prefill that issued them.
- **Validity.** No `Scheduler hit an exception`, `out of memory`, `malformed` or `DEADLINE_EXCEEDED` on either arm.
  The on arm's prefill logged `subtree drop declined (node locked)` in three bursts (ISSUES I4): during the 12-session
  return (6 lines on TP0 at 00:08:54), the 16-session return (1) and the integrity recall phase (5 at 00:29:43). Those
  three points are therefore marked: the numbers above are reported with that flag, no request failed in them and the
  counters of the points balance.

## First head, campaign 2: 2P2D sticky-pair transitions, write-back

Jobs: on `j-dd3f6030-3b7a-4588-a5cd` (03:56-04:29Z, fifth attempt after four spot preemptions), off
`j-d8cc8f42-fbc3-4d35-afff` (04:56-05:31Z, third attempt after two). 20 points per arm, 288 requests per arm, 0 errors,
`route_ok` true on every pinned point of both arms. Full tables (performance, cache, throughput, latency, counters,
routing) in `results/table_transitions_write_back.md`; below the return rows.

Procedure per transition (`harness/stage_transitions.sh`): wipe both prefills and both decodes; fill 12 sessions on
(p0,d0) through the mini-lb pinned to that pair; 24 short sessions (32k+4k) through prefill 0 so write-back evicts the
filled branches from its host tier and the pushes to decode 0 happen; return the 12 sessions on the target pair. Points:
T1 (p0,d0), T2 (p1,d0) other prefill same decode, T3 (p0,d1) same prefill other decode, T4 (p1,d1) both switched, a
four-leg chain (one fill, returns on (p0,d0), (p1,d0), (p0,d1), (p1,d1) in turn), and a random-routed 16-session fill
and return. Every point records the per-engine request deltas and `route_ok`.

**Performance gain** (what a user of the pair sees; return rows are the requests whose prefix the previous turn produced).

| Point | TTFT p50 off -> on | Speedup | TTFT p95 off -> on | Speedup | E2E p50 off -> on | Wall s off -> on | Gain | Req/min off -> on | Gain | Warm returns off -> on | Prefill tokens computed per request, off -> on |
|---|---|---|---|---|---|---|---|---|---|---|---|
| T1_p0d0_ret (recall) | 26.2 -> 8.4 s | 3.1x | 26.3 -> 10.7 s | 2.5x | 26.3 -> 8.6 s | 79.9 -> 23.5 | +71% | 9.0 -> 30.6 | +240% | 0 / 12 -> 4 / 12 | 147,577 -> 31,524 |
| T2_p1d0_ret (recall) | 25.8 -> 10.5 s | 2.5x | 26.1 -> 14.0 s | 1.9x | 25.9 -> 10.6 s | 80.3 -> 34.9 | +57% | 9.0 -> 20.6 | +130% | 0 / 12 -> 1 / 12 | 147,577 -> 54,734 |
| T3_p0d1_ret (recall) | 26.1 -> 26.1 s | 1.0x | 26.2 -> 26.2 s | 1.0x | 26.3 -> 26.2 s | 79.8 -> 80.0 | -0% | 9.0 -> 9.0 | -0% | 0 / 12 -> 0 / 12 | 147,577 -> 147,577 |
| T4_p1d1_ret (recall) | 25.9 -> 25.9 s | 1.0x | 26.1 -> 26.3 s | 1.0x | 26.0 -> 26.1 s | 79.0 -> 79.5 | -1% | 9.1 -> 9.1 | -1% | 0 / 12 -> 0 / 12 | 147,577 -> 147,577 |
| chain_l1_p0d0 (recall) | 26.0 -> 8.5 s | 3.1x | 26.2 -> 8.9 s | 3.0x | 26.2 -> 8.7 s | 79.7 -> 21.7 | +73% | 9.0 -> 33.1 | +267% | 0 / 12 -> 4 / 12 | 147,577 -> 31,524 |
| chain_l2_p1d0 (recall) | 25.9 -> 7.6 s | 3.4x | 26.2 -> 8.1 s | 3.3x | 26.1 -> 7.7 s | 79.0 -> 20.6 | +74% | 9.1 -> 35.0 | +284% | 0 / 12 -> 4 / 12 | 147,577 -> 29,460 |
| chain_l3_p0d1 (recall) | 19.9 -> 19.8 s | 1.0x | 25.3 -> 26.6 s | 1.0x | 20.1 -> 19.9 s | 59.6 -> 60.6 | -2% | 12.1 -> 11.9 | -2% | 2 / 12 -> 0 / 12 | 105,230 -> 110,702 |
| chain_l4_p1d1 (recall) | 20.4 -> 13.7 s | 1.5x | 25.8 -> 14.5 s | 1.8x | 20.5 -> 13.9 s | 59.4 -> 50.0 | +16% | 12.1 -> 14.4 | +19% | 2 / 12 -> 0 / 12 | 105,316 -> 88,164 |
| random_fill (fill) | 12.3 -> 17.5 s | 0.7x | 18.5 -> 23.6 s | 0.8x | 12.4 -> 17.6 s | 61.1 -> 67.0 | -10% | 15.7 -> 14.3 | -9% | 0 / 16 -> 0 / 16 | 139,298 -> 139,298 |
| random_ret (recall) | 7.7 -> 7.3 s | 1.1x | 19.8 -> 13.3 s | 1.5x | 7.9 -> 7.5 s | 43.2 -> 31.5 | +27% | 22.2 -> 30.5 | +37% | 4 / 16 -> 6 / 16 | 77,945 -> 69,241 |

**Routing and recall per point** (expected pair from the brief; served = requests per engine on the on arm; recalled = tokens the on arm's prefills pulled from decode DRAM during the point).

| Point | Expected pair | route_ok off / on | Served (on) | Prefill-side hit off -> on | TTFT p50 off -> on | Speedup | Wall s off -> on | Recalled from decode DRAM (on) |
|---|---|---|---|---|---|---|---|---|
| T1_p0d0_ret (recall) | p0d0 | True / True | d0:12 p0:12 | 0.0% -> 78.6% | 26.2 -> 8.4 s | 3.1x | 79.9 -> 23.5 | 1,392,640 tok in 10 pulls + 1,280 SWA |
| T2_p1d0_ret (recall) | p1d0 | True / True | d0:12 p1:12 | 0.0% -> 62.9% | 25.8 -> 10.5 s | 2.5x | 80.3 -> 34.9 | 1,114,112 tok in 8 pulls + 1,024 SWA |
| T3_p0d1_ret (recall) | p0d1 | True / True | d1:12 p0:12 | 0.0% -> 0.0% | 26.1 -> 26.1 s | 1.0x | 79.8 -> 80.0 | 0 |
| T4_p1d1_ret (recall) | p1d1 | True / True | d1:12 p1:12 | 0.0% -> 0.0% | 25.9 -> 25.9 s | 1.0x | 79.0 -> 79.5 | 0 |
| chain_l1_p0d0 (recall) | p0d0 | True / True | d0:12 p0:12 | 0.0% -> 78.6% | 26.0 -> 8.5 s | 3.1x | 79.7 -> 21.7 | 1,392,640 tok in 10 pulls + 1,280 SWA |
| chain_l2_p1d0 (recall) | p1d0 | True / True | d0:12 p1:12 | 0.0% -> 80.0% | 25.9 -> 7.6 s | 3.4x | 79.0 -> 20.6 | 2,392,256 tok in 17 pulls + 2,176 SWA |
| chain_l3_p0d1 (recall) | p0d1 | True / True | d1:12 p0:12 | 28.7% -> 25.0% | 19.9 -> 19.8 s | 1.0x | 59.6 -> 60.6 | 417,792 tok in 3 pulls + 384 SWA |
| chain_l4_p1d1 (recall) | p1d1 | True / True | d1:12 p1:12 | 28.6% -> 40.3% | 20.4 -> 13.7 s | 1.5x | 59.4 -> 50.0 | 590,080 tok in 4 pulls + 512 SWA |
| random_fill (fill) | any | None / None | d0:9 d1:7 p0:5 p1:11 | 0.0% -> 0.0% | 12.3 -> 17.5 s | 0.7x | 61.1 -> 67.0 | 0 |
| random_ret (recall) | any | None / None | d0:7 d1:9 p0:9 p1:7 | 47.2% -> 53.1% | 7.7 -> 7.3 s | 1.1x | 43.2 -> 31.5 | 417,792 tok in 3 pulls + 384 SWA |

### Reading

- **Same pair (T1) and other prefill, same decode (T2) recall.** With the switch on, a return to (p0,d0) after the
  branches were evicted from the prefill finds 78.6% of its prefix (10 of 11 offers pulled from decode 0's DRAM,
  1.39M tokens) and its TTFT p50 falls 26.2 -> 8.4 s (3.1x), the batch clears in 23.5 s instead of 79.9 s. Returning
  on the **other prefill** with the same decode (T2) works the same way, because the KV lives in the decode: 62.9%
  hit (8 of 9 offers), TTFT 25.8 -> 10.5 s (2.5x). The four-leg chain confirms it: legs 1 and 2 at 78.6% and 80.0%,
  3.1x and 3.4x.
- **Other decode (T3, T4) is cold on both arms.** Only the decode that received a push can offer it, so a return
  routed to decode 1 after decode 0 held the KV finds nothing: 0.0% hit, 26 s TTFT, identical to the off arm. The
  recall is decode-affine; a router that moves a session between decodes gives the feature nothing to work with.
  Chain legs 3 and 4 (25.0% and 40.3%) show the partial case: once sessions have been served through decode 1 once,
  their new pushes land there and the next (p1,d1) return pulls them (4 pulls).
- **Random routing** over 16 sessions: 53.1% hit on the return (3 pulls), TTFT p95 19.8 -> 13.3 s, batch wall
  43.2 -> 31.5 s (+37% req/min). Its fill was slower on the on arm (17.5 vs 12.3 s TTFT p50) because the random
  split put 11 of 16 fills on one prefill versus 10 of 16 on the off arm.
- **Fill phases** are the same on both arms (23.7-23.8 s TTFT p50, 22.4k-23.0k tok/s), as in 1P1D: pushes in flight
  do not slow the prefill issuing them.
- **Client-reported hit is not a prefill saving in 2P2D.** The off arm's returns report 139,264 device-cached tokens
  on all 12 requests while 9 of 12 have a cold 26 s TTFT: the usage field comes from the decode, which still holds
  the branch it decoded. The prefill-side hit and the TTFT are the numbers to read; the on arm's cached-by-tier column
  (host 1.39M on T1) is the prefill's own report after the pull.
- **Validity.** No `Scheduler hit an exception`, `out of memory`, `malformed` or `DEADLINE_EXCEEDED` on either arm.
  The on arm logged 40 `subtree drop declined (node locked)` lines (ISSUES I4) during the T1, T2 and chain leg 1 and 2
  returns; those four points carry that flag, no request failed in them. Counters identical on all 8 ranks of all
  four engines; 154 pushes stored and landed (10.2M tokens on decode 0, 2.0M on decode 1), 45 pulls of 6.3M tokens,
  4 pulls refused as over budget (`over_budget=2` per prefill), 0 failed.

## First head, campaign 3: write-through, 1P1D

Same stage as campaign 1 with `hicache_write_policy write_through` on both roles. on `j-ca202e3d-91f2-44d7-991e`
(00:57-01:21Z), off `j-8c1912b8-b43d-463f-8d17` (01:21-01:53Z). 396 of 396 requests completed on each arm, 0 request
errors, **no invalidating log line on either arm** (the refused subtree drops of campaign 1 are write-back only).

**Performance gain** (what a user of the pair sees; return rows are the requests whose prefix the previous turn produced).

| Point | TTFT p50 off -> on | Speedup | TTFT p95 off -> on | Speedup | E2E p50 off -> on | Wall s off -> on | Gain | Req/min off -> on | Gain | Warm returns off -> on | Prefill tokens computed per request, off -> on |
|---|---|---|---|---|---|---|---|---|---|---|---|
| recall 8, fill (cold) | 23.4 -> 23.4 s | 1.0x | 25.7 -> 25.8 s | 1.0x | 23.5 -> 23.6 s | 49.6 -> 49.7 | -0% | 9.7 -> 9.7 | -0% | 0 / 8 -> 0 / 8 | 139,298 -> 139,298 |
| recall 8, return | 17.4 -> 4.3 s | 4.1x | 21.9 -> 7.4 s | 3.0x | 17.6 -> 6.2 s | 36.9 -> 15.2 | +59% | 13.0 -> 31.6 | +143% | 1 / 8 -> 7 / 8 | 97,481 -> 25,721 |
| recall 12, fill (cold) | 23.5 -> 23.6 s | 1.0x | 23.6 -> 23.7 s | 1.0x | 23.7 -> 23.8 s | 72.1 -> 72.2 | -0% | 10.0 -> 10.0 | -0% | 0 / 12 -> 0 / 12 | 139,298 -> 139,298 |
| recall 12, return | 25.7 -> 7.5 s | 3.4x | 25.7 -> 14.0 s | 1.8x | 25.8 -> 7.6 s | 78.6 -> 31.2 | +60% | 9.2 -> 23.1 | +152% | 0 / 12 -> 6 / 12 | 147,577 -> 50,116 |
| recall 16, fill (cold) | 23.5 -> 23.6 s | 1.0x | 23.6 -> 23.6 s | 1.0x | 23.7 -> 23.7 s | 96.2 -> 96.1 | +0% | 10.0 -> 10.0 | +0% | 0 / 16 -> 0 / 16 | 139,298 -> 139,298 |
| recall 16, return | 25.7 -> 2.4 s | 10.7x | 25.7 -> 8.4 s | 3.1x | 25.8 -> 2.6 s | 104.5 -> 17.8 | +83% | 9.2 -> 53.9 | +487% | 0 / 16 -> 12 / 16 | 147,577 -> 17,017 |
| static 4 docs | 7.0 -> 7.1 s | 1.0x | 15.5 -> 16.5 s | 0.9x | 10.1 -> 9.3 s | 34.9 -> 32.4 | +7% | 20.6 -> 22.2 | +8% | 5 / 12 -> 5 / 12 | 51,963 -> 51,963 |
| static 8 docs | 6.6 -> 7.7 s | 0.9x | 18.7 -> 16.4 s | 1.1x | 8.9 -> 10.4 s | 66.7 -> 66.4 | +0% | 21.6 -> 21.7 | +0% | 10 / 24 -> 9 / 24 | 54,672 -> 53,016 |
| static 12 docs | 12.4 -> 5.9 s | 2.1x | 21.8 -> 21.8 s | 1.0x | 14.6 -> 8.4 s | 145.0 -> 100.7 | +31% | 14.9 -> 21.4 | +44% | 4 / 36 -> 19 / 36 | 89,497 -> 53,829 |
| static 16 docs | 15.9 -> 9.6 s | 1.7x | 21.6 -> 21.4 s | 1.0x | 17.9 -> 12.0 s | 213.5 -> 151.5 | +29% | 13.5 -> 19.0 | +41% | 1 / 48 -> 17 / 48 | 100,392 -> 63,424 |
| mixed, long stream | 24.7 -> 15.7 s | 1.6x | 30.9 -> 26.7 s | 1.2x | 27.2 -> 18.8 s | 160.9 -> 112.2 | +30% | 8.9 -> 12.8 | +43% | 0 / 24 -> 4 / 24 | 261,761 -> 174,494 |
| mixed, short stream | 8.9 -> 8.9 s | 1.0x | 30.5 -> 28.1 s | 1.1x | 9.1 -> 9.1 s | 217.3 -> 161.3 | +26% | 26.5 -> 35.7 | +35% | 2 / 96 -> 7 / 96 | 65,440 -> 43,624 |

**Cache (mechanism)**: prefill-side hit, client-reported cached tokens, where the prefix was found, and what the on arm recalled from decode DRAM.

| Point | Requests on / off (errors) | Prefill-side hit off -> on | Gain | Client-reported hit off -> on | Cached by tier device / host, off -> on | Recalled from decode DRAM (on) |
|---|---|---|---|---|---|---|
| recall 8, fill (cold) | 8 / 8 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| recall 8, return | 8 / 8 (0/0) | 34.0% -> 82.6% | +48.6 pp | 94.4% -> 82.6% | 0.88M / 0.24M -> 0.28M / 0.70M | 467,520 tok in 6 pulls + 768 SWA |
| recall 12, fill (cold) | 12 / 12 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| recall 12, return | 12 / 12 (0/0) | 0.0% -> 66.0% | +66.0 pp | 94.4% -> 66.0% | 1.67M / 0.00M -> 0.06M / 1.10M | 1,047,680 tok in 10 pulls + 1,280 SWA |
| recall 16, fill (cold) | 16 / 16 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| recall 16, return | 16 / 16 (0/0) | 0.0% -> 88.5% | +88.5 pp | 94.4% -> 94.4% | 2.23M / 0.00M -> 0.14M / 2.09M | 2,088,960 tok in 15 pulls + 1,920 SWA |
| static 4 docs | 12 / 12 (0/0) | 62.7% -> 62.7% | +0.0 pp | 62.7% -> 62.7% | 1.05M / 0.00M -> 1.05M / 0.00M | 0 |
| static 8 docs | 24 / 24 (0/0) | 60.8% -> 61.9% | +1.2 pp | 62.7% -> 62.2% | 1.82M / 0.28M -> 1.84M / 0.24M | 32,768 tok in 2 pulls + 256 SWA |
| static 12 docs | 36 / 36 (0/0) | 35.8% -> 61.4% | +25.6 pp | 62.7% -> 62.7% | 2.83M / 0.32M -> 1.56M / 1.58M | 1,497,792 tok in 14 pulls + 1,792 SWA |
| static 16 docs | 48 / 48 (0/0) | 27.9% -> 54.5% | +26.5 pp | 62.6% -> 60.1% | 3.81M / 0.37M -> 1.90M / 2.11M | 1,796,672 tok in 15 pulls + 1,920 SWA |
| mixed, long stream | 24 / 24 (0/0) | 11.3% -> 40.9% | +29.6 pp | 62.6% -> 61.7% | 1.92M / 0.18M -> 1.21M / 0.86M | 1,688,384 tok in 37 pulls + 4,736 SWA |
| mixed, short stream | 96 / 96 (0/0) | 11.3% -> 40.9% | +29.6 pp | 12.8% -> 26.3% | 0.48M / 0.00M -> 0.12M / 0.86M | 1,688,384 tok in 37 pulls + 4,736 SWA |

The fill rows are the cold phase: both engines are wiped before the point and every session has a new 128k prefix, so a 0% hit there is by construction on both arms; they are kept for the cold prefill's throughput and latency (whether pushes in flight slow the prefill that issues them). The mixed rows share one metrics window, so their hit and recall columns are the same block.

**Throughput** (gain = on vs off, higher is better).

| Point | Total tok/s off | on | Gain | Output tok/s off | on | Gain | Req/min off | on | Gain |
|---|---|---|---|---|---|---|---|---|---|
| recall 8, fill (cold) | 22487 | 22435 | -0% | 2.6 | 2.6 | +0% | 9.7 | 9.7 | -0% |
| recall 8, return | 31988 | 77624 | +143% | 3.5 | 8.4 | +140% | 13.0 | 31.6 | +143% |
| recall 12, fill (cold) | 23176 | 23144 | -0% | 2.7 | 2.7 | +0% | 10.0 | 10.0 | -0% |
| recall 12, return | 22539 | 56798 | +152% | 2.4 | 6.2 | +158% | 9.2 | 23.1 | +152% |
| recall 16, fill (cold) | 23180 | 23187 | +0% | 2.7 | 2.7 | +0% | 10.0 | 10.0 | +0% |
| recall 16, return | 22589 | 132607 | +487% | 2.4 | 14.4 | +500% | 9.2 | 53.9 | +487% |
| static 4 docs | 47984 | 51686 | +8% | 88.0 | 94.8 | +8% | 20.6 | 22.2 | +8% |
| static 8 docs | 50214 | 50440 | +0% | 92.1 | 92.5 | +0% | 21.6 | 21.7 | +0% |
| static 12 docs | 34647 | 49890 | +44% | 63.6 | 91.5 | +44% | 14.9 | 21.4 | +44% |
| static 16 docs | 31375 | 44214 | +41% | 57.6 | 81.1 | +41% | 13.5 | 19.0 | +41% |
| mixed, long stream | 20816 | 29851 | +43% | 38.2 | 54.8 | +43% | 8.9 | 12.8 | +43% |
| mixed, short stream | 17231 | 23218 | +35% | 7.1 | 9.5 | +34% | 26.5 | 35.7 | +35% |

**Latency** (gain = reduction on vs off, positive means the on arm is faster).

| Point | TTFT p50 off | on | Gain | TTFT p95 off | on | Gain | ITL p50 off | on | Gain |
|---|---|---|---|---|---|---|---|---|---|
| recall 8, fill (cold) | 23.4 s | 23.4 s | -0% | 25.7 s | 25.8 s | -1% | 0.012 s | 0.009 s | +22% |
| recall 8, return | 17.4 s | 4.3 s | +76% | 21.9 s | 7.4 s | +66% | 0.010 s | 0.074 s | -645% |
| recall 12, fill (cold) | 23.5 s | 23.6 s | -0% | 23.6 s | 23.7 s | -0% | 0.012 s | 0.009 s | +23% |
| recall 12, return | 25.7 s | 7.5 s | +71% | 25.7 s | 14.0 s | +45% | 0.010 s | 0.010 s | -7% |
| recall 16, fill (cold) | 23.5 s | 23.6 s | -0% | 23.6 s | 23.6 s | -0% | 0.012 s | 0.010 s | +23% |
| recall 16, return | 25.7 s | 2.4 s | +91% | 25.7 s | 8.4 s | +67% | 0.010 s | 0.011 s | -18% |
| static 4 docs | 7.0 s | 7.1 s | -1% | 15.5 s | 16.5 s | -6% | 0.012 s | 0.009 s | +27% |
| static 8 docs | 6.6 s | 7.7 s | -16% | 18.7 s | 16.4 s | +12% | 0.009 s | 0.009 s | -2% |
| static 12 docs | 12.4 s | 5.9 s | +52% | 21.8 s | 21.8 s | -0% | 0.009 s | 0.009 s | -4% |
| static 16 docs | 15.9 s | 9.6 s | +40% | 21.6 s | 21.4 s | +1% | 0.009 s | 0.010 s | -10% |
| mixed, long stream | 24.7 s | 15.7 s | +37% | 30.9 s | 26.7 s | +14% | 0.011 s | 0.011 s | -2% |
| mixed, short stream | 8.9 s | 8.9 s | +0% | 30.5 s | 28.1 s | +8% | 0.011 s | 0.011 s | -9% |

**Offload counters on the on arm, per point** (TP0 deltas from the server logs; every push and landing is a 128k-session branch with its SWA window).

| Point | Pushes stored / started | Landings landed / received | Recalls pulls / offers | Pulled tokens | SWA tokens | Failed / refused / no room |
|---|---|---|---|---|---|---|
| recall 8, fill (cold) | 7 / 7 | 7 / 7 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall 8, return | 10 / 10 | 10 / 10 | 6 / 7 | 467,520 | 768 | 0 / 0 / 0 |
| recall 12, fill (cold) | 69 / 69 | 69 / 69 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall 12, return | 19 / 19 | 19 / 19 | 10 / 10 | 1,047,680 | 1,280 | 0 / 0 / 0 |
| recall 16, fill (cold) | 137 / 137 | 137 / 137 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall 16, return | 13 / 13 | 13 / 13 | 15 / 16 | 2,088,960 | 1,920 | 0 / 0 / 0 |
| static 4 docs | 0 / 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| static 8 docs | 33 / 33 | 33 / 33 | 2 / 3 | 32,768 | 256 | 0 / 0 / 0 |
| static 12 docs | 105 / 105 | 105 / 105 | 14 / 17 | 1,497,792 | 1,792 | 0 / 0 / 0 |
| static 16 docs | 137 / 137 | 137 / 137 | 15 / 17 | 1,796,672 | 1,920 | 0 / 0 / 0 |
| mixed, long stream | 321 / 321 | 321 / 321 | 37 / 39 | 1,688,384 | 4,736 | 0 / 0 / 0 |
| mixed, short stream | 321 / 321 | 321 / 321 | 37 / 39 | 1,688,384 | 4,736 | 0 / 0 / 0 |

Final counters, on arm: push started 1,042, stored 1,042; landing received 1,042, granted 1,042, landed 1,042
(16,885,056 tokens); recall offers 205, pulls 118, pulled 10,741,504 tokens plus 15,104 SWA window tokens, 86 offers
skipped (branch still local), 1 over budget, 0 failed, 0 refused; counters identical on all 8 ranks of both engines.

**Equivalence (integrity, run last on the same engines): 16 of 16 identical on both arms**. On arm: 15 of 16
returns served from the prefill's host tier after the recall from decode DRAM, 1 from device; off arm: all 16 from
device. This is the control for the write-back on arm's 13 of 16 (ISSUES I5): the pull and the host-tier serving are
exact under write-through.

### Reading

- **Recall ladder.** Under write-through every prefix is backed up to host RAM as it is produced, so the host copy
  duplicates the device copy and the off arm's warm working set is smaller than under write-back (8 sessions: 34.0%
  hit and TTFT p50 17.4 s, against 92.3% and 2.5 s with write-back; 12 and 16 sessions: 0.0%, every return cold).
  The on arm pushes the evicted backups at successive lengths during the fill (75 branches at 12 sessions, 138 at 16)
  and recalls them on the return: 82.6 / 66.0 / 88.5% hit, TTFT p50 4.3 / 7.5 / 2.4 s (4.1x / 3.4x / 10.7x), 7 / 6 /
  12 of the sessions back warm, wall of the return 37 -> 15 s, 79 -> 31 s, 105 -> 18 s, prompt tokens computed per
  return 97k -> 26k, 148k -> 50k, 148k -> 17k.
- **Static ladder.** No loss at 4 and 8 documents (62.7 -> 62.7%, 60.8 -> 61.9%) and a gain at 12 and 16 (35.8 ->
  61.4%, 27.9 -> 54.5%): because write-through offloads a growing branch at successive lengths, the forks keep a
  window and the static revisits recall (14 and 15 pulls, 1.50M and 1.80M tokens at 12 and 16 documents). TTFT p50
  12.4 -> 5.9 s and 15.9 -> 9.6 s, wall -31% and -29%, warm visits 4 -> 19 of 36 and 1 -> 17 of 48. This is the
  policy the PR pairs with prefix-sharing workloads, and the data bears it out.
- **Mixed sizes.** 120 of 120 on both arms; the long stream's TTFT p50 24.7 -> 15.7 s (1.6x), wall -30%, the short
  stream's TTFT unchanged at 8.9 s with wall -26%; 37 of 39 offers recalled (1.69M tokens plus 4,736 SWA tokens), 321
  of 321 pushes stored and landed during the block.
- **Fill phases** are again the same on both arms (23.4-23.6 s TTFT p50, 49.6-96.2 s wall), with 11 to 138 pushes in
  flight during the on arm's fills.

## Files

- `results/h83198bc/<arm>/` (head 83198bc912) and `results/<arm>/` (first head): per-point client jsonl + summary json,
  `points_fixed.jsonl` (one line per point, every number of the tables), `stage.log`, the integrity json; a
  preempted attempt's partial files under `attempt_<HHMMSS>/`. Arms: `wb_on`, `wb_off`, `wt_on`, `wt_off` (1P1D),
  `t_wb_on`, `t_wb_off` (2P2D transitions), `wb_on_e1fresh` (the fresh-engine integrity run of the write-back on arm).
- `results/h83198bc/table_*.md`: the generated tables of each campaign on the new head; `results/h83198bc/delta_*.md`:
  each campaign on the two heads side by side.
- `evidence/h83198bc/<arm>/` and `evidence/<arm>/`: the `/metrics` snapshots around every point (`*.m0`, `*.m1`), the
  server logs (gzip), `offload_counters.txt/json` (final counters, rank check, per-point deltas), `invalidating_lines.txt`.
- `recipes/pd1992-qwen3-30b-xpyd.jsonnet`, `harness/`: what ran (the recipe now also carries the two-host TP16 topology,
  the Qwen3-VL-8B profile and the `stress` stage of the stress test; those did not change the campaign runs, whose
  rendered JobSets differ from the first head's only by the explicit early-send env, which is upstream's default).
