# PR 2086 benchmark: KV offload to decode DRAM for hybrid sliding-window models (gpt-oss-120b)

PR: sgl-project/sglang-torchtpu#2086, branch `pd-dram-spill-swa`, head `54a80863a6` (the hybrid PR rebased on main
after PR 1992 merged). Three campaigns, each the same tree and settings with the switch unset ("off") and set on both
roles ("on", `SGLANG_ENABLE_PREFILL_KV_OFFLOAD_TO_DECODE_DRAM=1`), caches flushed before every point:

1. write-back 1P1D (`hicache_write_policy write_back` on both roles): done, both arms;
2. 2P2D sticky-pair transitions, write-back: queued (`j-dd3f6030-3b7a-4588-a5cd` on, `j-d8cc8f42-fbc3-4d35-afff` off);
3. write-through 1P1D: done, both arms.

Status 2026-11-11 02:05Z. This file is updated as the campaigns land; `ISSUES-2026-11-11.md` has every system error
met.

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
| recall 16, return | 10 / 10 | 12 / 12 | 11 / 12 | 1,531,904 | 1,408 | 0 / 0 / 0 |
| static 4 docs | 2 / 2 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| static 8 docs | 0 / 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| static 12 docs | 16 / 16 | 16 / 16 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| static 16 docs | 35 / 35 | 35 / 35 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| mixed, long stream | 93 / 93 | 65 / 65 | 43 / 43 | 1,585,152 | 5,504 | 0 / 0 / 0 |
| mixed, short stream | 93 / 93 | 65 / 65 | 43 / 43 | 1,585,152 | 5,504 | 0 / 0 / 0 |

Final counters, on arm: prefill push started 204, stored 204; decode landing received 204, granted 204, landed 204
(11,889,024 tokens); recall offers 150, pulls 71, pulled 5,271,232 tokens plus 9,088 SWA window tokens, 78 offers
skipped because the prefill still held the branch in its own host tier, 1 over budget, 0 failed, 0 refused; push,
landing and recall counters identical on all 8 ranks of both engines. Off arm: no offload lines, as expected.

**Equivalence (integrity, run last on the same engines):** off arm 16 of 16 identical (all 16 served from the
prefill's host tier). On arm **12 of 16**: sessions 6, 11 and 14, served from the host tier with 139,264 cached
tokens, diverge from their recompute at tokens 5, 5 and 19; session 15, served from nowhere (0 cached tokens, a full
recompute), diverges at token 22. The same prefill logged 96 `subtree drop declined (node locked)` lines during this
job (none on the off arm). See ISSUES I4 and I5; a fresh-engine integrity run of the on arm
(`j-c909ba56-55e8-4b10-8eb3`) is queued to tell a state-dependent divergence from a transfer defect.

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

## Campaign 2: 2P2D sticky-pair transitions, write-back (queued)

Procedure per transition (`harness/stage_transitions.sh`): wipe both prefills and both decodes; fill 12 sessions on
(p0,d0) through the mini-lb pinned to that pair; 24 short sessions (32k+4k) through prefill 0 so write-back evicts the
filled branches from its host tier and the pushes to decode 0 happen; return the 12 sessions on the target pair. Points:
T1 (p0,d0), T2 (p1,d0) other prefill same decode, T3 (p0,d1) same prefill other decode, T4 (p1,d1) both switched, a
four-leg chain (one fill, returns on (p0,d0), (p1,d0), (p0,d1), (p1,d1) in turn), and a random-routed 16-session fill
and return. Every point records the per-engine request deltas and `route_ok`.

## Campaign 3: write-through, 1P1D (done)

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
| recall 8, return | 8 / 8 (0/0) | 34.0% -> 82.6% | +48.6 pp | 94.4% -> 82.6% | 0.88M / 0.24M -> 0.28M / 0.70M | 0 |
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
| recall 8, return | 0 / 0 | 10 / 10 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall 12, fill (cold) | 68 / 69 | 69 / 69 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall 12, return | 18 / 18 | 19 / 19 | 10 / 10 | 1,047,680 | 1,280 | 0 / 0 / 0 |
| recall 16, fill (cold) | 138 / 138 | 133 / 135 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall 16, return | 13 / 13 | 13 / 13 | 15 / 16 | 2,088,960 | 1,920 | 0 / 0 / 0 |
| static 4 docs | 0 / 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| static 8 docs | 33 / 33 | 31 / 31 | 2 / 3 | 32,768 | 256 | 0 / 0 / 0 |
| static 12 docs | 105 / 105 | 107 / 107 | 14 / 17 | 1,497,792 | 1,792 | 0 / 0 / 0 |
| static 16 docs | 137 / 137 | 127 / 130 | 15 / 17 | 1,796,672 | 1,920 | 0 / 0 / 0 |
| mixed, long stream | 321 / 321 | 298 / 299 | 37 / 39 | 1,688,384 | 4,736 | 0 / 0 / 0 |
| mixed, short stream | 321 / 321 | 298 / 299 | 37 / 39 | 1,688,384 | 4,736 | 0 / 0 / 0 |

Final counters, on arm: push started 1,042, stored 1,042; landing received 1,042, granted 1,042, landed 1,042
(16,885,056 tokens); recall offers 205, pulls 118, pulled 10,741,504 tokens plus 15,104 SWA window tokens, 86 offers
skipped (branch still local), 1 over budget, 0 failed, 0 refused; counters identical on all 8 ranks of both engines.

**Equivalence (integrity, run last on the same engines): 16 of 16 identical on both arms**, all 16 recalled (on arm:
served from the host tier after the recall from decode DRAM).

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

- `results/<arm>/`: per-point client jsonl + summary json, `points_fixed.jsonl` (one line per point, every number of
  the tables), `stage.log`, the integrity json.
- `evidence/<arm>/`: the `/metrics` snapshots around every point (`*.m0`, `*.m1`), both server logs (gzip),
  `offload_counters.txt/json` (final counters, rank check, per-point deltas), `invalidating_lines.txt`.
- `recipes/pd1992-qwen3-30b-xpyd.jsonnet`, `harness/`: what ran.
