# PR 2086 benchmark: KV offload to decode DRAM for hybrid sliding-window models (gpt-oss-120b)

PR: sgl-project/sglang-torchtpu#2086, branch `pd-dram-spill-swa`, head `54a80863a6` (the hybrid PR rebased on main
after PR 1992 merged). Three campaigns, each the same tree and settings with the switch unset ("off") and set on both
roles ("on", `SGLANG_ENABLE_PREFILL_KV_OFFLOAD_TO_DECODE_DRAM=1`), caches flushed before every point:

1. write-back 1P1D (`hicache_write_policy write_back` on both roles): done, both arms;
2. 2P2D sticky-pair transitions, write-back: queued (`j-dd3f6030-3b7a-4588-a5cd` on, `j-d8cc8f42-fbc3-4d35-afff` off);
3. write-through 1P1D: on arm running (`j-ca202e3d-91f2-44d7-991e`), off arm queued (`j-8c1912b8-b43d-463f-8d17`).

Status 2026-11-11 01:05Z. This file is updated as the campaigns land; `ISSUES-2026-11-11.md` has every system error
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

- **Prefill hit** = prefill-side: `sglang:cached_tokens_total` / `sglang:prompt_tokens_total` deltas of the prefill's
  `/metrics` between the two snapshots around the point (`harness/common.sh` `snap`, `point_metrics.py`). The
  client-side `token_hit_rate` is also in `results/*/points_fixed.jsonl` but never used here: with the switch off it
  counts decode-side hits.
- **Throughput**: `total_tok_s` = (prompt + output tokens) / wall of the point, `output_tok_s`, requests per minute;
  wall from the first request start to the last request end in the point's jsonl (the client's own wall for the static
  client).
- **Latency**: TTFT p50 / p95 and ITL p50 = (e2e - TTFT) / (completion tokens - 1) from the per-request records.
  The recall points generate 16 tokens, so ITL there is over 15 intervals.
- **Route**: per-engine `sglang:num_requests_total` deltas over the point, checked against the pair the point was
  pinned to (`route_ok` in the points file). Every 1P1D point was served by prefill 0 and decode 0.
- **Cached KV by tier**: the client's `cached_tokens_details` summed over the point: device = found in the prefill's
  HBM radix tree, host = found in the prefill's host tier (which is also where a branch recalled from decode DRAM
  lands, so on the on arm a recall shows up as a host hit).
- **Recalled KV from decode DRAM**: the prefill's `recall pulled_tokens` and `pulled_swa_tokens` counter deltas over
  the point (full-attention tokens pulled from the decode's DRAM, plus the SWA window tokens that travelled with them),
  and the number of pulls. Off arm: no such path exists.
- **Offload counters**: the PR logs cumulative `[dram-offload] push | landing | recall k=v` lines every 30 s per
  rank; `offload_counters.py` takes the TP0 deltas between a point's start and its end plus 45 s, and checks that
  every rank reports the same final counters.
- **Validity**: after every point the bench greps both server logs for `Scheduler hit an exception`, `out of memory`,
  `malformed`, `DEADLINE_EXCEEDED` and `subtree drop declined`. Hits are listed per arm in
  `evidence/*/invalidating_lines.txt` and discussed under the campaign.

## Campaign 1: write-back, 1P1D (done)

on `j-74143469-8c3a-4bd6-9575` (00:05-00:33Z), off `j-ae4dd88f-6893-4c7d-8796` (00:22-00:51Z). 396 of 396 requests
completed on each arm, 0 request errors.

| Point | Requests on / off (errors) | Prefill hit off -> on | Cached KV by tier, device / host, off -> on | Recalled KV from decode DRAM (on) | Total tok/s off -> on | Output tok/s off -> on | Req/min off -> on | TTFT p50 / p95 off -> on | ITL p50 off -> on | Push / landing counters (on, this point) |
|---|---|---|---|---|---|---|---|---|---|---|
| recall 8, fill | 8 / 8 (0/0) | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 | 22328 -> 22283 | 2.6 -> 2.6 | 9.6 -> 9.6 | 23.5 / 25.8 s -> 23.5 / 25.7 s | 0.009 -> 0.010 s | none |
| recall 8, return | 8 / 8 (0/0) | 92.3% -> 94.4% | 0.24M / 0.88M -> 0.42M / 0.70M | 0 | 132883 -> 134261 | 14.4 -> 14.6 | 54.0 -> 54.6 | 2.5 / 3.4 s -> 2.6 / 4.6 s | 0.076 -> 0.072 s | none |
| recall 12, fill | 12 / 12 (0/0) | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 | 22906 -> 22845 | 2.6 -> 2.6 | 9.9 -> 9.8 | 23.8 / 24.1 s -> 23.8 / 24.1 s | 0.010 -> 0.009 s | none |
| recall 12, return | 12 / 12 (0/0) | 28.2% -> 37.1% | 1.17M / 0.50M -> 0.10M / 0.56M | 57,024 tok in 1 pulls + 128 SWA | 29500 -> 32656 | 3.2 -> 3.5 | 12.0 -> 13.3 | 19.3 / 24.9 s -> 18.6 / 20.7 s | 0.009 -> 0.010 s | push 9/9 stored; land 9/9; recall 1/2 offers skipped_local 1 |
| recall 16, fill | 16 / 16 (0/0) | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 | 22919 -> 22852 | 2.6 -> 2.6 | 9.9 -> 9.8 | 23.9 / 24.1 s -> 24.0 / 24.1 s | 0.010 -> 0.009 s | push 6/9 stored; land 6/6; recall 0/4 offers |
| recall 16, return | 16 / 16 (0/0) | 0.0% -> 64.9% | 2.23M / 0.00M -> 0.14M / 1.53M | 1,531,904 tok in 11 pulls + 1,408 SWA | 22230 -> 56723 | 2.4 -> 6.1 | 9.0 -> 23.1 | 26.1 / 26.1 s -> 8.0 / 19.7 s | 0.010 -> 0.010 s | push 12/12 stored; land 12/12; recall 11/12 offers |
| static 4 | 12 / 12 (0/0) | 62.7% -> 62.7% | 1.05M / 0.00M -> 1.05M / 0.00M | 0 | 51369 -> 51056 | 94.2 -> 93.7 | 22.1 -> 21.9 | 7.2 / 16.3 s -> 6.5 / 18.8 s | 0.009 -> 0.009 s | push 2/2 stored |
| static 8 | 24 / 24 (0/0) | 62.3% -> 55.6% | 1.85M / 0.25M -> 1.86M / 0.00M | 0 | 52414 -> 45568 | 96.2 -> 83.6 | 22.5 -> 19.6 | 6.4 / 18.9 s -> 9.5 / 18.7 s | 0.009 -> 0.009 s | none |
| static 12 | 36 / 36 (0/0) | 50.4% -> 32.2% | 1.80M / 1.34M -> 2.43M / 0.00M | 0 | 42076 -> 32246 | 77.2 -> 59.2 | 18.1 -> 13.9 | 7.2 / 22.0 s -> 15.1 / 22.1 s | 0.009 -> 0.009 s | push 16/16 stored; land 16/16 |
| static 16 | 48 / 48 (0/0) | 39.8% -> 27.1% | 3.09M / 1.10M -> 3.73M / 0.00M | 0 | 35744 -> 30296 | 65.6 -> 55.6 | 15.4 -> 13.0 | 12.1 / 21.7 s -> 15.8 / 21.9 s | 0.009 -> 0.009 s | push 35/35 stored; land 35/35 |
| mixed, long stream | 24 / 24 (0/0) | 21.9% -> 39.7% | 0.91M / 1.18M -> 1.89M / 0.00M | 1,585,152 tok in 43 pulls + 5,504 SWA | 25182 -> 22846 | 46.2 -> 41.9 | 10.8 -> 9.8 | 21.0 / 26.6 s -> 20.9 / 26.5 s | 0.010 -> 0.010 s | push 93/93 stored; land 93/93; recall 43/43 offers |
| mixed, short stream (same window) | 96 / 96 (0/0) | 21.9% -> 39.7% | 1.22M / 0.00M -> 0.00M / 1.59M | 1,585,152 tok in 43 pulls + 5,504 SWA | 19277 -> 22807 | 7.9 -> 9.4 | 29.6 -> 35.1 | 9.2 / 26.8 s -> 5.3 / 26.7 s | 0.010 -> 0.011 s | push 93/93 stored; land 93/93; recall 43/43 offers |

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
- **Static ladder.** 4 documents: identical (62.7%, no pushes needed beyond 2). From 8 documents on the on arm loses
  hits and throughput (8: 62.3 -> 55.6%, 12: 50.4 -> 32.2%, 16: 39.8 -> 27.1%; total tok/s 52k -> 46k, 42k -> 32k,
  36k -> 30k; TTFT p50 6.4 -> 9.5 s, 7.2 -> 15.1 s, 12.1 -> 15.8 s). The counters show why: pushes stored and landed
  (16 and 35 at 12 and 16 documents) but **no recall at all** on these points. This is the PR's documented write-back
  limitation: a pushed branch carries the one window that ends where it ends; the static requests share a document
  prefix and then diverge, so the offloaded branch cannot be recalled for them, while the write-back eviction that
  pushed it also removed it from the prefill's host tier, where the off arm still found the shared prefix. The same
  shape as the PR description's g + v7 run (62.5 -> 55.8, 50.9 -> 30.4, 39.6 -> 21.3%). Write-through (campaign 3) is
  the policy the PR pairs with such workloads.
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

## Campaign 3: write-through, 1P1D (running)

Same stage as campaign 1 with `hicache_write_policy write_through` on both roles.

## Files

- `results/<arm>/`: per-point client jsonl + summary json, `points_fixed.jsonl` (one line per point, every number of
  the tables), `stage.log`, the integrity json.
- `evidence/<arm>/`: the `/metrics` snapshots around every point (`*.m0`, `*.m1`), both server logs (gzip),
  `offload_counters.txt/json` (final counters, rank check, per-point deltas), `invalidating_lines.txt`.
- `recipes/pd1992-qwen3-30b-xpyd.jsonnet`, `harness/`: what ran.
