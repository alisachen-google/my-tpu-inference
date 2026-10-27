# Spill-over KV cache (prefill RAM → decode RAM): before vs after

Written 2026-10-26, updated 2026-10-27 01:20 UTC. **Status: "before" complete (30 points); "after" is being swept
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

This run validates the fix (rank-consensus checker on, zero divergence) and carries the first complete static
series. The checker serializes every cache call's parameters, including each request's full token list, on every
rank; at 256k that cost shows up as lower throughput and higher TTFT even at the hit ceiling, so for the 256k
rows read the hit and pull columns and take the latency and throughput from the checker-off run below.

Static prefix reuse (K documents × 3 visits, shuffled; the hit ceiling is 62.7%):

| Prefix+new | N | Prefill hit before → after | TTFT p50 | TTFT speedup | E2E p50 | Total tok/s | Throughput | KV offloaded to decode RAM | KV pulled from decode RAM | Pulled share of prompt | Pulls |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Prefix+new | Docs | Prefill hit before → after | TTFT p50 before → after | TTFT speedup | E2E p50 before → after | Total tok/s before → after | Throughput gain | KV offloaded to decode DRAM (after) | KV pulled from decode DRAM (after) | Pulled share of prompt | Pulls (after) |
| 128k+8k | 4 | 62.7% → 62.7% | 6.9 s → 5.9 s | 1.18x | 14.3 s → 14.3 s | 37,557 → 36,830 | 0.98x | 1.25M (70 pushes) | 0.00M | 0.0% | 0 |
| 128k+8k | 8 | 60.5% → 62.5% | 6.7 s → 6.4 s | 1.04x | 14.6 s → 14.3 s | 37,044 → 37,149 | 1.00x | 10.96M (628 pushes) | 4.73M | 141.4% | 41 |
| 128k+8k | 12 | 35.6% → 60.5% | 9.6 s → 3.7 s | 2.61x | 17.6 s → 12.4 s | 31,181 → 36,005 | 1.15x | 1.66M (78 pushes) | 1.46M | 29.2% | 12 |
| 128k+8k | 16 | 28.2% → 59.7% | 12.0 s → 6.6 s | 1.81x | 18.6 s → 14.8 s | 29,961 → 35,417 | 1.18x | 4.82M (228 pushes) | 4.01M | 60.0% | 33 |
| 128k+8k | 20 | 23.0% → 54.7% | 12.6 s → 6.7 s | 1.89x | 19.5 s → 15.4 s | 27,272 → 34,813 | 1.28x | 2.95M (166 pushes) | 2.59M | 31.0% | 22 |
| 128k+8k | 24 | 14.7% → 47.1% | 13.1 s → 7.0 s | 1.87x | 19.8 s → 15.4 s | 25,856 → 33,259 | 1.29x | 3.82M (209 pushes) | 3.61M | 36.0% | 34 |
| 128k+8k | 28 | 14.1% → 38.5% | 17.4 s → 10.5 s | 1.66x | 24.2 s → 19.0 s | 25,700 → 30,582 | 1.19x | 5.94M (311 pushes) | 3.36M | 28.7% | 32 |
| 256k+16k | 2 | 62.7% → 62.7% | 18.8 s → 34.9 s | 0.54x | 26.9 s → 54.2 s | 30,073 → 15,315 | 0.51x | 0.00M (5 pushes) | 0.00M | 0.0% | 0 |
| 256k+16k | 4 | 49.7% → 52.9% | 38.2 s → 58.3 s | 0.66x | 46.2 s → 89.9 s | 22,594 → 12,903 | 0.57x | 1.15M (26 pushes) | 0.49M | 14.7% | 2 |
| 256k+16k | 6 | 37.9% → 59.3% | 45.3 s → 44.6 s | 1.01x | 54.4 s → 78.0 s | 20,311 → 15,826 | 0.78x | 1.66M (54 pushes) | 1.89M | 37.7% | 8 |
| 256k+16k | 8 | 29.4% → 58.2% | 51.1 s → 54.5 s | 0.94x | 59.4 s → 86.3 s | 19,466 → 13,483 | 0.69x | 2.31M (70 pushes) | 1.99M | 29.8% | 10 |
| 256k+16k | 10 | 31.8% → 53.7% | 50.7 s → 54.5 s | 0.93x | 58.8 s → 86.0 s | 19,373 → 13,031 | 0.67x | 3.28M (103 pushes) | 2.09M | 25.0% | 10 |
| 256k+16k | 12 | 9.8% → 45.7% | 64.2 s → 54.8 s | 1.17x | 72.5 s → 87.3 s | 16,529 → 12,460 | 0.75x | 4.41M (115 pushes) | 3.79M | 37.8% | 17 |
| 256k+16k | 14 | 14.1% → 36.2% | 55.3 s → 58.4 s | 0.95x | 63.3 s → 90.9 s | 16,580 → 11,727 | 0.71x | 5.46M (199 pushes) | 3.37M | 28.8% | 15 |

Recall (fill N sessions, recall oldest first; measured phase is the recall; the pulled tokens include the fill):

| Prefix+new | N | Prefill hit before → after | TTFT p50 | TTFT speedup | E2E p50 | Total tok/s | Throughput | KV offloaded to decode RAM | KV pulled from decode RAM | Pulled share of prompt | Pulls |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Prefix+new | Sessions | Prefill hit before → after | TTFT p50 before → after | TTFT speedup | E2E p50 before → after | Total tok/s before → after | Throughput gain | KV offloaded to decode DRAM (after) | KV pulled from decode DRAM (after) | Pulled share of prompt | Pulls (after) |
| 128k+8k | 12 | 0.0% → 57.2% | 20.6 s → 7.6 s | 2.71x | 27.0 s → 15.4 s | 20,403 → 31,673 | 1.55x | 6.71M (384 pushes) | 2.80M | 157.9% | 25 |
| 128k+8k | 16 | 0.0% → 73.8% | 20.5 s → 4.7 s | 4.32x | 26.8 s → 13.7 s | 20,856 → 36,189 | 1.74x | 2.12M (151 pushes) | 1.74M | 73.7% | 14 |

## Before vs after: checker-off run (pair 1, `results/goal_winnc_after_1.log`)

The same sweep with the consensus checker off; this is the definitive "after" column once it is complete.

Static prefix reuse:

| Prefix+new | N | Prefill hit before → after | TTFT p50 | TTFT speedup | E2E p50 | Total tok/s | Throughput | KV offloaded to decode RAM | KV pulled from decode RAM | Pulled share of prompt | Pulls |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Prefix+new | Docs | Prefill hit before → after | TTFT p50 before → after | TTFT speedup | E2E p50 before → after | Total tok/s before → after | Throughput gain | KV offloaded to decode DRAM (after) | KV pulled from decode DRAM (after) | Pulled share of prompt | Pulls (after) |

Recall:

| Prefix+new | N | Prefill hit before → after | TTFT p50 | TTFT speedup | E2E p50 | Total tok/s | Throughput | KV offloaded to decode RAM | KV pulled from decode RAM | Pulled share of prompt | Pulls |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Prefix+new | Sessions | Prefill hit before → after | TTFT p50 before → after | TTFT speedup | E2E p50 before → after | Total tok/s before → after | Throughput gain | KV offloaded to decode DRAM (after) | KV pulled from decode DRAM (after) | Pulled share of prompt | Pulls (after) |

## Reading the results so far

- **128k static:** with the window push the prefill hit stays at 55 to 62% up to 20 docs, where the HBM-only cache
  has fallen to 23%, and is still 39 to 47% at 24 to 28 docs; TTFT is 1.7 to 2.6x faster and throughput 15 to 25%
  higher from 12 docs on. At 4 and 8 docs (inside HBM) nothing changes.
- **128k recall:** sessions that were evicted from the prefill come back from the decode's RAM: 0% → 57% hit at 12
  sessions (TTFT 20.6 → 7.6 s, 1.55x throughput) and 0% → 74% at 16 sessions (20.5 → 4.7 s, 1.74x).
- **256k static:** the hit rises from 10 to 38% ("before") to 46 to 59% at 6 to 12 docs; latency and throughput
  for these rows come from the checker-off run.
- Each pull reads a 131,072-token prefix plus its 128-token window in 0.5 to 0.7 s; per point 1.5M to 4.7M tokens
  come back from the decode's RAM and 2M to 6M tokens are offloaded to it.

## Files

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
