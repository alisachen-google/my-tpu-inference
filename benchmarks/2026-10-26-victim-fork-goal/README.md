# Spill-over KV cache (prefill RAM → decode RAM): before vs after

Written 2026-10-26, updated 2026-10-27 04:15 UTC. **Status: "before" complete (30 points); "after" is being swept
on two pairs** (see the two tables below). The comparison is between upstream main and the fork with its two
fixes from this campaign: the eviction-order fix that stops the hang, and the restored sliding-window half of the
push, without which nothing is ever pulled back on gpt-oss. Tables are regenerated from the run logs with
`harness/compare_goal.py before <run>` (`results/compare_table_*.md`).

## The configurations

| | Code | Transfer library | What it does |
|---|---|---|---|
| **Before** | upstream main `49ddede7` (the fork's base), `recipes/v6c_long/base/gpt-oss_C_victim.json` | installed tpu-sync wheel | HBM + host HiCache on each role; nothing crosses between hosts except the normal KV send |
| **After** | fork [`pd-victim-prefix-cache`](https://github.com/sgl-project/sglang-torchtpu/compare/main...alisachen-google:sglang-torchtpu:pd-victim-prefix-cache) (`c0e561665c`) + `patches/fork_uuid0_compat.patch` + `patches/fork_fix_and_window_push.patch`, `recipes/v6c_long/victim/gpt-oss_C_victim*.json` | [tpu-sync `759530c7`](https://github.com/google/tpu-sync/commit/759530c7fb0a5f7c38114187e1bcde745f709f24) from source + `patches/tpu_sync_h2h_push.patch` | victim push of a cold session's full-attention pages and its last SWA window, RAM to RAM, into the decode's host pools; the decode offers the prefix back and the prefill pulls it when the session returns |

gpt-oss-120b alternates full-attention and sliding-window layers. A cached prefix is only reusable together with
its window, which the normal prefill-to-decode KV send carries on a separate SWA engine. The fork branch pushed the
full-attention pages only (its docstring deferred the window), so every prefix offer from the decode was empty
(`pages=0`) and nothing could be pulled; the version we originally cloned had the window. The restored window
push mirrors the normal send: `swa_blocks` travel with the push, the decode lands them in its SWA host pool and
names both pools in the ack, and the landed path is committed with its window so `offer_resident_prefix` can
offer it. The fork also keeps each path's last SWA window in the prefill's own host RAM
(`SGLANG_TPU_ENABLE_PD_PREFILL_SWA_PATH_END_BACKUP`), which upstream does not; on gpt-oss that makes the
prefill's own host tier usable for hits as well, so part of the gain below the ~1.5M-token working set comes from
that local tier and the rest, from about 12 docs or 12 sessions at 128k, from the decode's RAM.

## Setup

gpt-oss-120b, 1P1D, one tpu7x host per role (a = prefill, b = decode), TP8/EP8 each. Identical budgets in both
configs (`recipes/v6c_long/`): fp8 KV, page 64, context 327,680, `max_running_requests` 4; HBM pool 786,432 tokens
per role; HiCache via Raiden write-through, prefill ratio 1.2, decode ratio 3.5 (2.75M host tokens); decode radix
cache on in both.

**Cache wipe before every point.** Both engines' `/flush_cache` (device and host tiers) runs before each benchmark
point. Once per config the wipe is verified on hardware: 12 sessions of 128k are filled, both caches are flushed,
and the oldest session is re-sent. It must report 0 cached tokens on both prefill and decode. Both configs passed
(`WIPE CHECK` lines in `results/goal_*.log`).

**Workloads** (static prompt files, seeded per-session salt, identical token ids in both configs, 1,024 output
tokens per request, concurrency 4):
- **Recall:** fill N sessions in order (prefix + new block + question), wait for pushes to settle, then recall every
  session oldest first (fill prompt + fixed answer + another new block + question). Measured phase: recall.
- **Static prefix reuse:** K documents, each visited 3 times with a different new block, one shuffled order, no
  session history. The hit ceiling is 62.7% (first visits are cold by construction).

**Metrics.** Prefill hit = prefill `/metrics` cached/prompt delta over the measured phase; every point was
cross-checked against the prefill log's per-batch `#cached-token` sum and the two agree exactly. Decode reuse is
the decode's own radix match (saves transfer, not prefill compute). TTFT and end-to-end latency are client-side;
throughput is (prompt + output tokens) / phase wall time.

## The hang and its fix

Every "after" run hung within about 80 s of the first point past prefill capacity (8 to 12 documents at 128k), with
all prefill ranks waiting on a device-to-host result copy, and libtpu's telemetry harvester aborting them minutes
later. Per-rank tracing of every CPU collective (`harness/collective_trace.py`, diffed with
`harness/collective_diff.py`) showed the ranks in lockstep until their KV allocators drifted apart after an
eviction; the repo's rank-consensus checker (`SGLANG_ENABLE_RANK_CONSENSUS_CHECKER=1`) then caught it directly:
`evict_for_alloc` returned different results on different ranks with identical inputs (8320+256 vs 8448+384 tokens
evicted). Cause: after a stored push the fork stamped every node of the victim path with `last_access_time = 0`;
the eviction heap orders `(last_access_time, node)` over a set of leaves, so tied nodes pop in each rank's memory
order and the ranks evict different nodes. Upstream never ties (its access counter is unique per call), which is why
the "before" run never hung. Fix: unique, increasing stamps far below any live node's counter value. Regression
test: `test_stored_victim_path_evicts_in_the_same_order_on_every_rank` (fails on the old code with "victim nodes
tie"). Validation: the fixed sweep ran 8 to 28 documents with the checker on and zero divergence; a "before" control
with the checker on was clean. The lockstep harness `test_pd_victim_lockstep.py` (8 cases) covers the other
per-rank branches of the push and pull paths.

## Before vs after: checker-on run (pair 2, `results/goal_win_after_1.log`)

This run validates the fix (rank-consensus checker on, zero divergence over all 30 points). The checker
serializes every cache call's parameters, including each request's full token list, on every rank; at 256k that
cost shows up as lower throughput and higher TTFT even at the hit ceiling (2 docs: 30,073 → 15,315 tok/s with the
checker, 26,229 without), so for the 256k rows read the hit and pull columns and take latency and throughput
from the checker-off run below.

Static prefix reuse (K documents × 3 visits, shuffled; the hit ceiling is 62.7%):

| Prefix+new | N | Prefill hit before → after | Hit gain (pts, relative) | TTFT p50 | TTFT speedup | E2E p50 | Total tok/s | Throughput | KV offloaded to decode RAM | KV pulled from decode RAM | Pulled share of prompt | Pulls |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Prefix+new | Docs | Prefill hit before → after | Hit gain | TTFT p50 before → after | TTFT speedup | E2E p50 before → after | Total tok/s before → after | Throughput gain | KV offloaded to decode DRAM (after) | KV pulled from decode DRAM (after) | Pulled share of prompt | Pulls (after) |
| 128k+8k | 4 | 62.7% → 62.7% | -0.0 pts (1.00x) | 6.9 s → 5.9 s | 1.18x | 14.3 s → 14.3 s | 37,557 → 36,830 | 0.98x | 10.09M (605 pushes) | 4.54M | 271.4% | 39 |
| 128k+8k | 8 | 60.5% → 62.5% | +1.9 pts (1.03x) | 6.7 s → 6.4 s | 1.04x | 14.6 s → 14.3 s | 37,044 → 37,149 | 1.00x | 10.96M (628 pushes) | 4.73M | 141.4% | 41 |
| 128k+8k | 12 | 35.6% → 60.5% | +25.0 pts (1.70x) | 9.6 s → 3.7 s | 2.61x | 17.6 s → 12.4 s | 31,181 → 36,005 | 1.15x | 1.66M (78 pushes) | 1.46M | 29.2% | 12 |
| 128k+8k | 16 | 28.2% → 59.7% | +31.5 pts (2.12x) | 12.0 s → 6.6 s | 1.81x | 18.6 s → 14.8 s | 29,961 → 35,417 | 1.18x | 4.82M (228 pushes) | 4.01M | 60.0% | 33 |
| 128k+8k | 20 | 23.0% → 54.7% | +31.8 pts (2.38x) | 12.6 s → 6.7 s | 1.89x | 19.5 s → 15.4 s | 27,272 → 34,813 | 1.28x | 2.95M (166 pushes) | 2.59M | 31.0% | 22 |
| 128k+8k | 24 | 14.7% → 47.1% | +32.4 pts (3.20x) | 13.1 s → 7.0 s | 1.87x | 19.8 s → 15.4 s | 25,856 → 33,259 | 1.29x | 3.82M (209 pushes) | 3.61M | 36.0% | 34 |
| 128k+8k | 28 | 14.1% → 38.5% | +24.4 pts (2.73x) | 17.4 s → 10.5 s | 1.66x | 24.2 s → 19.0 s | 25,700 → 30,582 | 1.19x | 5.94M (311 pushes) | 3.36M | 28.7% | 32 |
| 256k+16k | 2 | 62.7% → 62.7% | +0.0 pts (1.00x) | 18.8 s → 34.9 s | 0.54x | 26.9 s → 54.2 s | 30,073 → 15,315 | 0.51x | 0.00M (5 pushes) | 0.00M | 0.0% | 0 |
| 256k+16k | 4 | 49.7% → 52.9% | +3.2 pts (1.06x) | 38.2 s → 58.3 s | 0.66x | 46.2 s → 89.9 s | 22,594 → 12,903 | 0.57x | 1.15M (26 pushes) | 0.49M | 14.7% | 2 |
| 256k+16k | 6 | 37.9% → 59.3% | +21.4 pts (1.57x) | 45.3 s → 44.6 s | 1.01x | 54.4 s → 78.0 s | 20,311 → 15,826 | 0.78x | 1.66M (54 pushes) | 1.89M | 37.7% | 8 |
| 256k+16k | 8 | 29.4% → 58.2% | +28.8 pts (1.98x) | 51.1 s → 54.5 s | 0.94x | 59.4 s → 86.3 s | 19,466 → 13,483 | 0.69x | 2.31M (70 pushes) | 1.99M | 29.8% | 10 |
| 256k+16k | 10 | 31.8% → 53.7% | +22.0 pts (1.69x) | 50.7 s → 54.5 s | 0.93x | 58.8 s → 86.0 s | 19,373 → 13,031 | 0.67x | 3.28M (103 pushes) | 2.09M | 25.0% | 10 |
| 256k+16k | 12 | 9.8% → 45.7% | +35.9 pts (4.66x) | 64.2 s → 54.8 s | 1.17x | 72.5 s → 87.3 s | 16,529 → 12,460 | 0.75x | 4.41M (115 pushes) | 3.79M | 37.8% | 17 |
| 256k+16k | 14 | 14.1% → 36.2% | +22.1 pts (2.56x) | 55.3 s → 58.4 s | 0.95x | 63.3 s → 90.9 s | 16,580 → 11,727 | 0.71x | 5.46M (199 pushes) | 3.37M | 28.8% | 15 |

Recall (fill N sessions, recall oldest first; measured phase is the recall; the pulled tokens include the fill):

| Prefix+new | N | Prefill hit before → after | Hit gain (pts, relative) | TTFT p50 | TTFT speedup | E2E p50 | Total tok/s | Throughput | KV offloaded to decode RAM | KV pulled from decode RAM | Pulled share of prompt | Pulls |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Prefix+new | Sessions | Prefill hit before → after | Hit gain | TTFT p50 before → after | TTFT speedup | E2E p50 before → after | Total tok/s before → after | Throughput gain | KV offloaded to decode DRAM (after) | KV pulled from decode DRAM (after) | Pulled share of prompt | Pulls (after) |
| 128k+8k | 8 | 36.7% → 93.0% | +56.3 pts (2.53x) | 14.7 s → 3.0 s | 4.86x | 21.4 s → 11.5 s | 27,142 → 50,373 | 1.86x | 0.97M (31 pushes) | 0.73M | 61.8% | 7 |
| 128k+8k | 10 | 0.0% → 77.1% | +77.1 pts (-) | 20.4 s → 7.2 s | 2.84x | 26.6 s → 16.2 s | 20,245 → 35,894 | 1.77x | 1.29M (59 pushes) | 0.86M | 58.2% | 7 |
| 128k+8k | 12 | 0.0% → 64.7% | +64.7 pts (-) | 20.6 s → 8.0 s | 2.58x | 27.0 s → 17.1 s | 20,403 → 34,031 | 1.67x | 37.12M (1594 pushes) | 28.29M | 1597.3% | 192 |
| 128k+8k | 16 | 0.0% → 66.9% | +66.9 pts (-) | 20.5 s → 7.9 s | 2.60x | 26.8 s → 16.5 s | 20,856 → 36,635 | 1.76x | 2.29M (156 pushes) | 1.58M | 66.9% | 12 |
| 128k+8k | 20 | 0.0% → 55.2% | +55.2 pts (-) | 20.5 s → 8.4 s | 2.43x | 27.0 s → 17.4 s | 21,078 → 31,517 | 1.50x | 7.17M (494 pushes) | 4.35M | 147.5% | 36 |
| 128k+8k | 24 | 0.0% → 39.1% | +39.1 pts (-) | 20.4 s → 11.3 s | 1.81x | 27.0 s → 19.9 s | 21,229 → 28,577 | 1.35x | 4.33M (291 pushes) | 1.38M | 39.1% | 13 |
| 128k+8k | 28 | 0.0% → 13.0% | +13.0 pts (-) | 20.4 s → 14.4 s | 1.42x | 26.9 s → 22.6 s | 21,338 → 23,954 | 1.12x | 6.68M (383 pushes) | 0.54M | 13.0% | 5 |
| 128k+8k | 32 | 0.0% → 13.6% | +13.6 pts (-) | 20.5 s → 18.2 s | 1.13x | 27.0 s → 25.7 s | 21,420 → 24,077 | 1.12x | 7.38M (511 pushes) | 0.64M | 13.6% | 6 |
| 256k+16k | 4 | 51.3% → 93.7% | +42.4 pts (1.82x) | 32.5 s → 41.9 s | 0.78x | 39.0 s → 49.5 s | 21,571 → 22,730 | 1.05x | 1.27M (18 pushes) | 0.56M | 47.2% | 3 |
| 256k+16k | 5 | 6.1% → 56.1% | +50.0 pts (9.20x) | 57.1 s → 56.7 s | 1.01x | 65.3 s → 62.8 s | 14,358 → 12,377 | 0.86x | 1.14M (44 pushes) | 0.79M | 53.3% | 3 |
| 256k+16k | 6 | 20.8% → 92.5% | +71.7 pts (4.45x) | 45.4 s → 42.2 s | 1.07x | 53.4 s → 49.9 s | 16,018 → 18,877 | 1.18x | 1.70M (46 pushes) | 1.38M | 77.7% | 5 |
| 256k+16k | 8 | 0.0% → 63.9% | +63.9 pts (-) | 71.8 s → 61.8 s | 1.16x | 78.2 s → 96.1 s | 14,268 → 13,457 | 0.94x | 2.11M (98 pushes) | 1.51M | 63.9% | 6 |
| 256k+16k | 10 | 0.0% → 63.9% | +63.9 pts (-) | 71.4 s → 50.6 s | 1.41x | 78.1 s → 82.7 s | 14,358 → 13,342 | 0.93x | 2.91M (120 pushes) | 1.88M | 63.9% | 9 |
| 256k+16k | 12 | 0.0% → 27.5% | +27.5 pts (-) | 71.7 s → 67.1 s | 1.07x | 79.7 s → 98.4 s | 14,430 → 11,866 | 0.82x | 4.65M (162 pushes) | 0.97M | 27.5% | 5 |
| 256k+16k | 14 | 0.0% → 6.9% | +6.9 pts (-) | 71.7 s → 74.9 s | 0.96x | 79.6 s → 109.7 s | 14,492 → 11,085 | 0.76x | 6.82M (249 pushes) | 0.29M | 6.9% | 3 |
| 256k+16k | 16 | 0.0% → 1.2% | +1.2 pts (-) | 71.8 s → 75.6 s | 0.95x | 79.8 s → 110.9 s | 14,539 → 10,847 | 0.75x | 8.39M (277 pushes) | 0.06M | 1.2% | 1 |
## Before vs after: checker-off run (pair 1, `results/goal_winnc_after_1.log`)

The same sweep with the consensus checker off; this is the definitive "after" column (all 30 points).

Static prefix reuse:

| Prefix+new | N | Prefill hit before → after | Hit gain (pts, relative) | TTFT p50 | TTFT speedup | E2E p50 | Total tok/s | Throughput | KV offloaded to decode RAM | KV pulled from decode RAM | Pulled share of prompt | Pulls |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Prefix+new | Docs | Prefill hit before → after | Hit gain | TTFT p50 before → after | TTFT speedup | E2E p50 before → after | Total tok/s before → after | Throughput gain | KV offloaded to decode DRAM (after) | KV pulled from decode DRAM (after) | Pulled share of prompt | Pulls (after) |
| 128k+8k | 4 | 62.7% → 62.7% | +0.0 pts (1.00x) | 6.9 s → 7.0 s | 1.00x | 14.3 s → 15.0 s | 37,557 → 36,690 | 0.98x | 1.25M (66 pushes) | 0.00M | 0.0% | 0 |
| 128k+8k | 8 | 60.5% → 60.5% | -0.0 pts (1.00x) | 6.7 s → 6.7 s | 1.00x | 14.6 s → 14.3 s | 37,044 → 36,094 | 0.97x | 0.87M (33 pushes) | 0.17M | 5.1% | 2 |
| 128k+8k | 12 | 35.6% → 58.9% | +23.3 pts (1.66x) | 9.6 s → 5.8 s | 1.66x | 17.6 s → 13.8 s | 31,181 → 35,384 | 1.13x | 1.59M (87 pushes) | 1.30M | 26.0% | 12 |
| 128k+8k | 16 | 28.2% → 60.5% | +32.3 pts (2.15x) | 12.0 s → 6.6 s | 1.82x | 18.6 s → 13.8 s | 29,961 → 36,720 | 1.23x | 2.27M (132 pushes) | 2.27M | 34.0% | 19 |
| 128k+8k | 20 | 23.0% → 54.0% | +31.1 pts (2.35x) | 12.6 s → 6.7 s | 1.86x | 19.5 s → 14.8 s | 27,272 → 35,370 | 1.30x | 2.92M (161 pushes) | 3.03M | 36.2% | 27 |
| 128k+8k | 24 | 14.7% → 55.0% | +40.3 pts (3.74x) | 13.1 s → 6.7 s | 1.97x | 19.8 s → 14.7 s | 25,856 → 35,823 | 1.39x | 3.59M (192 pushes) | 3.76M | 37.5% | 31 |
| 128k+8k | 28 | 14.1% → 40.9% | +26.8 pts (2.90x) | 17.4 s → 7.9 s | 2.21x | 24.2 s → 15.8 s | 25,700 → 32,343 | 1.26x | 5.00M (285 pushes) | 2.99M | 25.6% | 30 |
| 256k+16k | 2 | 62.7% → 62.7% | +0.0 pts (1.00x) | 18.8 s → 21.9 s | 0.86x | 26.9 s → 29.9 s | 30,073 → 26,229 | 0.87x | 0.00M (2 pushes) | 0.00M | 0.0% | 0 |
| 256k+16k | 4 | 49.7% → 57.8% | +8.1 pts (1.16x) | 38.2 s → 32.3 s | 1.18x | 46.2 s → 41.9 s | 22,594 → 24,106 | 1.07x | 1.11M (23 pushes) | 0.97M | 28.9% | 5 |
| 256k+16k | 6 | 37.9% → 56.0% | +18.1 pts (1.48x) | 45.3 s → 35.9 s | 1.26x | 54.4 s → 44.3 s | 20,311 → 24,459 | 1.20x | 1.49M (36 pushes) | 1.48M | 29.6% | 6 |
| 256k+16k | 8 | 29.4% → 58.9% | +29.5 pts (2.00x) | 51.1 s → 31.4 s | 1.63x | 59.4 s → 40.7 s | 19,466 → 25,827 | 1.33x | 2.17M (73 pushes) | 1.80M | 26.9% | 8 |
| 256k+16k | 10 | 31.8% → 57.3% | +25.6 pts (1.80x) | 50.7 s → 32.7 s | 1.55x | 58.8 s → 41.2 s | 19,373 → 24,563 | 1.27x | 3.05M (109 pushes) | 2.36M | 28.2% | 10 |
| 256k+16k | 12 | 9.8% → 48.2% | +38.4 pts (4.92x) | 64.2 s → 36.6 s | 1.76x | 72.5 s → 45.4 s | 16,529 → 22,140 | 1.34x | 4.36M (147 pushes) | 3.69M | 36.7% | 16 |
| 256k+16k | 14 | 14.1% → 35.6% | +21.5 pts (2.52x) | 55.3 s → 46.2 s | 1.20x | 63.3 s → 55.1 s | 16,580 → 19,823 | 1.20x | 5.99M (232 pushes) | 3.18M | 27.2% | 16 |

Recall:

| Prefix+new | N | Prefill hit before → after | Hit gain (pts, relative) | TTFT p50 | TTFT speedup | E2E p50 | Total tok/s | Throughput | KV offloaded to decode RAM | KV pulled from decode RAM | Pulled share of prompt | Pulls |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Prefix+new | Sessions | Prefill hit before → after | Hit gain | TTFT p50 before → after | TTFT speedup | E2E p50 before → after | Total tok/s before → after | Throughput gain | KV offloaded to decode DRAM (after) | KV pulled from decode DRAM (after) | Pulled share of prompt | Pulls (after) |
| 128k+8k | 8 | 36.7% → 88.1% | +51.4 pts (2.40x) | 14.7 s → 4.3 s | 3.43x | 21.4 s → 12.8 s | 27,142 → 46,257 | 1.70x | 0.99M (39 pushes) | 0.61M | 51.4% | 6 |
| 128k+8k | 10 | 0.0% → 81.4% | +81.4 pts (-) | 20.4 s → 4.9 s | 4.15x | 26.6 s → 13.2 s | 20,245 → 38,698 | 1.91x | 1.28M (60 pushes) | 1.08M | 73.1% | 9 |
| 128k+8k | 12 | 0.0% → 69.7% | +69.7 pts (-) | 20.6 s → 5.1 s | 4.00x | 27.0 s → 12.4 s | 20,403 → 34,760 | 1.70x | 1.60M (105 pushes) | 1.20M | 67.8% | 10 |
| 128k+8k | 16 | 0.0% → 77.9% | +77.9 pts (-) | 20.5 s → 2.9 s | 7.06x | 26.8 s → 11.6 s | 20,856 → 40,299 | 1.93x | 2.17M (143 pushes) | 1.84M | 77.9% | 14 |
| 128k+8k | 20 | 0.0% → 62.0% | +62.0 pts (-) | 20.5 s → 7.0 s | 2.92x | 27.0 s → 14.3 s | 21,078 → 34,359 | 1.63x | 2.66M (200 pushes) | 1.83M | 62.0% | 15 |
| 128k+8k | 24 | 0.0% → 30.8% | +30.8 pts (-) | 20.4 s → 12.0 s | 1.70x | 27.0 s → 21.2 s | 21,229 → 26,856 | 1.27x | 4.54M (346 pushes) | 1.09M | 30.8% | 12 |
| 128k+8k | 28 | 0.0% → 19.9% | +19.9 pts (-) | 20.4 s → 14.1 s | 1.44x | 26.9 s → 22.0 s | 21,338 → 25,417 | 1.19x | 6.49M (392 pushes) | 0.82M | 19.9% | 8 |
| 128k+8k | 32 | 0.0% → 10.6% | +10.6 pts (-) | 20.5 s → 16.6 s | 1.23x | 27.0 s → 24.7 s | 21,420 → 23,356 | 1.09x | 7.79M (561 pushes) | 0.50M | 10.6% | 6 |
| 256k+16k | 4 | 51.3% → 94.4% | +43.1 pts (1.84x) | 32.5 s → 14.3 s | 2.27x | 39.0 s → 22.2 s | 21,571 → 48,139 | 2.23x | 1.11M (14 pushes) | 0.46M | 38.9% | 3 |
| 256k+16k | 5 | 6.1% → 94.4% | +88.3 pts (15.48x) | 57.1 s → 15.0 s | 3.82x | 65.3 s → 21.1 s | 14,358 → 44,722 | 3.11x | 1.42M (36 pushes) | 1.11M | 75.5% | 4 |
| 256k+16k | 6 | 20.8% → 82.3% | +61.5 pts (3.96x) | 45.4 s → 19.1 s | 2.37x | 53.4 s → 26.9 s | 16,018 → 32,774 | 2.05x | 1.70M (59 pushes) | 1.37M | 77.2% | 5 |
| 256k+16k | 8 | 0.0% → 65.9% | +65.9 pts (-) | 71.8 s → 32.9 s | 2.18x | 78.2 s → 41.6 s | 14,268 → 25,116 | 1.76x | 2.29M (118 pushes) | 1.56M | 65.9% | 6 |
| 256k+16k | 10 | 0.0% → 45.5% | +45.5 pts (-) | 71.4 s → 39.7 s | 1.80x | 78.1 s → 48.2 s | 14,358 → 19,619 | 1.37x | 3.55M (156 pushes) | 1.34M | 45.5% | 6 |
| 256k+16k | 12 | 0.0% → 33.9% | +33.9 pts (-) | 71.7 s → 54.5 s | 1.32x | 79.7 s → 60.5 s | 14,430 → 18,247 | 1.26x | 4.92M (181 pushes) | 1.20M | 33.9% | 8 |
| 256k+16k | 14 | 0.0% → 7.9% | +7.9 pts (-) | 71.7 s → 67.5 s | 1.06x | 79.6 s → 76.6 s | 14,492 → 15,056 | 1.04x | 6.93M (265 pushes) | 0.33M | 7.9% | 5 |
| 256k+16k | 16 | 0.0% → 1.0% | +1.0 pts (-) | 71.8 s → 70.9 s | 1.01x | 79.8 s → 79.3 s | 14,539 → 14,584 | 1.00x | 8.37M (367 pushes) | 0.05M | 1.0% | 1 |
## Reading the results so far

- **128k static:** with the window push the prefill hit stays at 55 to 62% up to 20 docs, where the HBM-only cache
  has fallen to 23%, and is still 39 to 47% at 24 to 28 docs; TTFT is 1.7 to 2.6x faster and throughput 15 to 25%
  higher from 12 docs on. At 4 and 8 docs (inside HBM) nothing changes.
- **128k recall:** sessions that were evicted from the prefill come back from the decode's RAM: 0% → 57% hit at 12
  sessions (TTFT 20.6 → 7.6 s, 1.55x throughput) and 0% → 74% at 16 sessions (20.5 → 4.7 s, 1.74x).
- **256k static (checker off):** the hit rises from 10 to 50% ("before") to 48 to 59% at 4 to 12 docs, TTFT is
  1.2 to 1.8x faster and throughput 7 to 34% higher from 4 docs on. Inside HBM (2 docs) the fork costs 13% at 256k
  (0 to 3% at 128k): the prefill's per-chunk backup of each path's SWA window to host RAM and the pusher's
  bookkeeping, not pushes or pulls (none happen at 2 docs).
- **256k recall (checker off):** 51% → 94% at 4 sessions, 6% → 94% at 5, 21% → 82% at 6, 0% → 66% at 8, 0% → 45% at
  10, 0% → 34% at 12; 8% and 1% at 14 and 16 sessions, where the working set (3.9M to 4.5M tokens) exceeds what the
  two RAM tiers hold together (about 3.6M).
- **128k recall (checker off):** 37% → 88% at 8 sessions, then 81%, 70%, 78%, 62% at 10 to 20 sessions (0% before
  from 10 on), 31% at 24 and 20% at 28; 11% at 32 sessions.
- Each pull reads a 131,072-token prefix plus its 128-token window in 0.5 to 0.7 s; per point 1.5M to 4.7M tokens
  come back from the decode's RAM and 2M to 6M tokens are offloaded to it.

## Branch tip (PR #1789) sweep, 2026-10-27: `results/compare_table_tip_after.md`

The same 30 points re-run on the branch as submitted (five commits, fixes folded in; recalls land in the
prefill's RAM, host copies reclaimed tip first), consensus checker off, caches wiped before every point;
no engine error on either role across the sweep. Headlines against upstream main with the feature off:
static 128k 12/16/20/24/28 docs 35.6->59.1, 28.2->55.3, 23.0->42.5, 14.7->46.5, 14.1->38.7% hit;
recall 128k 8/10/12/16 sessions 94.4/94.4/94.4/85.3% hit with TTFT 7x to 12x faster; 256k static 4..10 docs
57.6/51.6/49.5/53.6%, 256k recall 4..8 sessions 90.2/75.5/62.9/58.7%. Compared with the earlier build that
landed recalls in HBM (tables above), the branch is equal or better up to 16 sessions and 16 docs and trails
at the heaviest points (for example 128k recall 24 sessions 23.5% vs 30.8%, 256k static 12 docs 29.5% vs
48.2%), where the prefill's RAM has no room to land recalls. Defects found and fixed on the way, the byte-level
transfer verification, the probe-free output check and the live edge cases are in `FIXES-2026-10-27.md`.

## Files

- [FIXES-2026-10-27.md](FIXES-2026-10-27.md): defects found by the branch-tip validation and how each was fixed.

- `results/goal_before_1.log`, `results/goal_after_1.log`: one `POINT {...}` JSON line per point (prefill hit from
  metrics and from the log, decode reuse, latency, throughput, victim counters), plus the wipe-check lines.
- `results/summaries/`: the client summaries per phase; `results/compare_table.md`: generated comparison.
- `harness/chain_goal.sh`: the driver (wipe, wipe check, recall points, static points); `victim_recall.py`,
  `static_reuse.py`: the workloads; `compare_goal.py`: the table; `pd_fork.sh` / `pd_base49.sh`: launchers.
- `patches/tpu_sync_h2h_push.patch`: the fork's tpu-sync API patch; `patches/fork_uuid0_compat.patch`: the
  uuid-0 compatibility change for `759530c7`.
- The earlier `6c60fd77` benchmark, the H2H microbenchmark (3.1–3.5 GiB/s per rank, 18–20 GiB/s for 8 ranks) and
  the D2D/H2H concurrency audit are in [`../2026-10-26-victim-6c60/`](../2026-10-26-victim-6c60/README.md).
- `results/goal_win_after_1.log`, `results/compare_table_after_window.md`: the window-push run (pair 2);
  `results/goal_ctrl_before_1.log`: the "before" control with the consensus checker.
- `patches/fork_fix_and_window_push.patch`: the exact fork diff that ran (eviction-order fix, window push, the
  lockstep and regression tests, plus the diagnostics: collective trace hook, consensus assertions, state notes).
- `harness/chain_pair.sh`: the pair-agnostic driver (A_IP/B_IP/LAUNCHER/RECIPE/TOK/NAME/SKIP_START);
  `harness/collective_trace.py`, `collective_diff.py`, `hang_capture.sh`: the hang tooling.
- `results/goal_win_after_1.log`, `results/compare_table_after_window.md`: the checker-on run (pair 2);
  `results/goal_winnc_after_1.log`, `results/compare_table_after_window_nocheck.md`: the checker-off run (pair 1);
  `results/goal_ctrl_before_1.log`: the "before" control with the checker; `results/goal_after_1.log`: the
  abandoned full-KV-only run (no window, so no pulls), kept for reference.
- `patches/fork_fix_and_window_push.patch`: the exact fork diff that ran (eviction-order fix, window push, the
  lockstep and regression tests, plus the diagnostics: collective trace hook, consensus assertions, state notes).
- `harness/chain_pair.sh`: the pair-agnostic driver (A_IP/B_IP/LAUNCHER/RECIPE/TOK/NAME/SKIP_START);
  `harness/collective_trace.py`, `collective_diff.py`, `hang_capture.sh`: the hang tooling.
- `recipes/`: the exact recipes (`*_nocheck` = consensus checker off; `*_localtier` = fork with push and pull off).
