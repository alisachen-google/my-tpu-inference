# Spill-over KV cache (prefill RAM → decode RAM): before vs after

Written 2026-10-26, updated 23:45 UTC. **Interim status.** The "before" side is complete (30 points). The "after"
side was blocked for most of the day by a hang that turned out to be a bug in the fork's eviction bookkeeping
(root cause, fix and regression test below); with the fix it is sweeping on pair 1. A second variant, "after +
window push", restores the sliding-window half of the push that the fork had lost, and it is the first
configuration in which the decode's RAM actually serves prefixes back to the prefill; it is sweeping on pair 2.
Tables are regenerated from the run logs with `harness/compare_goal.py` (`results/compare_table_*.md`).

## The configurations

| | Code | Transfer library | What it does |
|---|---|---|---|
| **Before** | upstream main `49ddede7` (the fork's base) | installed tpu-sync wheel | HBM + host HiCache on each role, nothing crosses between hosts except the normal KV send |
| **After** | fork [`pd-victim-prefix-cache`](https://github.com/sgl-project/sglang-torchtpu/compare/main...alisachen-google:sglang-torchtpu:pd-victim-prefix-cache) (`c0e561665c`) + `patches/fork_uuid0_compat.patch` + the eviction-order fix | [tpu-sync `759530c7`](https://github.com/google/tpu-sync/commit/759530c7fb0a5f7c38114187e1bcde745f709f24) from source + `patches/tpu_sync_h2h_push.patch` | victim push of full-attention KV pages RAM-to-RAM into the decode's host pool; reverse prefix pull |
| **After + window push** | the above + the SWA window half of the push (`patches/fork_fix_and_window_push.patch`) | same | the push also carries the path's last 128 tokens of sliding-window KV, so the decode can offer the prefix back and the prefill pulls it |

gpt-oss-120b alternates full-attention and sliding-window layers. A cached prefix is only reusable together with
its window, which the normal prefill-to-decode KV send carries on a separate SWA engine. The fork branch pushed the
full-attention pages only, so every prefix offer from the decode was empty (`pages=0`) and nothing could be pulled:
"after" measures the cost of pushing without any gain. The window push mirrors the normal send: `swa_blocks` travel
with the push, the decode lands them in its SWA host pool and names both pools in the ack, and the landed path is
committed with its window so `offer_resident_prefix` can offer it. The version we originally cloned had this half;
the fork branch lost it when it was rebuilt on the `759530c7` API.

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

## Before vs after (plain fork, no window)

Static prefix reuse (K documents × 3 visits, shuffled; the hit ceiling is 62.7%):

| Prefix+new | N | Prefill hit | TTFT p50 | TTFT speedup | E2E p50 | Total tok/s | Throughput | KV offloaded to decode RAM | KV pulled from decode RAM | Pulled share of prompt | Pulls |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Prefix+new | Docs | Prefill hit before → after | TTFT p50 before → after | TTFT speedup | E2E p50 before → after | Total tok/s before → after | Throughput gain | KV offloaded to decode DRAM (after) | KV pulled from decode DRAM (after) | Pulled share of prompt | Pulls (after) |
| 128k+8k | 8 | 60.5% → 58.3% | 6.7 s → 6.4 s | 1.04x | 14.6 s → 15.1 s | 37,044 → 34,719 | 0.94x | 1.86M (112 pushes) | 0.00M | 0.0% | 0 |
| 128k+8k | 12 | 35.6% → 32.8% | 9.6 s → 9.7 s | 0.99x | 17.6 s → 18.0 s | 31,181 → 29,057 | 0.93x | 1.73M (182 pushes) | 0.00M | 0.0% | 0 |
| 128k+8k | 16 | 28.2% → 28.1% | 12.0 s → 10.9 s | 1.10x | 18.6 s → 18.9 s | 29,961 → 28,854 | 0.96x | 2.17M (346 pushes) | 0.00M | 0.0% | 0 |
| 128k+8k | 20 | 23.0% → 19.8% | 12.6 s → 11.6 s | 1.08x | 19.5 s → 19.9 s | 27,272 → 26,834 | 0.98x | 3.08M (441 pushes) | 0.00M | 0.0% | 0 |
| 128k+8k | 24 | 14.7% → 16.5% | 13.1 s → 12.6 s | 1.04x | 19.8 s → 20.5 s | 25,856 → 25,956 | 1.00x | 4.17M (631 pushes) | 0.00M | 0.0% | 0 |
| 128k+8k | 28 | 14.1% → 15.1% | 17.4 s → 13.8 s | 1.26x | 24.2 s → 21.8 s | 25,700 → 25,799 | 1.00x | 6.15M (698 pushes) | 0.00M | 0.0% | 0 |
| 256k+16k | 2 | 62.7% → 62.7% | 18.8 s → 52.9 s | 0.36x | 26.9 s → 60.3 s | 30,073 → 15,103 | 0.50x | 0.00M (12 pushes) | 0.00M | 0.0% | 0 |
| 256k+16k | 4 | 49.7% → 23.8% | 38.2 s → 68.1 s | 0.56x | 46.2 s → 96.9 s | 22,594 → 15,094 | 0.67x | 0.85M (11 pushes) | 0.00M | -0.0% | 0 |

The 256k 2- and 4-document points above ran while the prefill host's root disk was full (traces had filled it) and
will be re-run; treat them as invalid. Recall points for this configuration are pending.

Reading: without the window nothing is ever pulled, so the prefill hit tracks "before" within 2 to 3 points and
throughput pays 0 to 7% for the pushes (1.9M to 6.2M tokens offloaded per point).

## Before vs after + window push

Static prefix reuse:

| Prefix+new | N | Prefill hit | TTFT p50 | TTFT speedup | E2E p50 | Total tok/s | Throughput | KV offloaded to decode RAM | KV pulled from decode RAM | Pulled share of prompt | Pulls |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Prefix+new | Docs | Prefill hit before → after | TTFT p50 before → after | TTFT speedup | E2E p50 before → after | Total tok/s before → after | Throughput gain | KV offloaded to decode DRAM (after) | KV pulled from decode DRAM (after) | Pulled share of prompt | Pulls (after) |
| 128k+8k | 8 | 60.5% → 62.2% | 6.7 s → 6.7 s | 1.00x | 14.6 s → 15.5 s | 37,044 → 35,919 | 0.97x | 3.50M (164 pushes) | 0.00M | 0.0% | 2 |
| 128k+8k | 12 | 35.6% → 59.1% | 9.6 s → 4.0 s | 2.39x | 17.6 s → 13.3 s | 31,181 → 34,599 | 1.11x | 1.73M (105 pushes) | 0.00M | 0.0% | 13 |

Recall (fill N sessions, recall oldest first; measured phase is the recall; the pulled tokens include the fill):

| Prefix+new | N | Prefill hit | TTFT p50 | TTFT speedup | E2E p50 | Total tok/s | Throughput | KV offloaded to decode RAM | KV pulled from decode RAM | Pulled share of prompt | Pulls |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Prefix+new | Sessions | Prefill hit before → after | TTFT p50 before → after | TTFT speedup | E2E p50 before → after | Total tok/s before → after | Throughput gain | KV offloaded to decode DRAM (after) | KV pulled from decode DRAM (after) | Pulled share of prompt | Pulls (after) |
| 128k+8k | 12 | 0.0% → 57.2% | 20.6 s → 7.6 s | 2.71x | 27.0 s → 15.4 s | 20,403 → 31,673 | 1.55x | 1.49M (115 pushes) | 2.79M | 157.8% | 10 |

Reading: at 8 documents (inside HBM) nothing changes. At 12 documents, where the HBM-only cache has fallen to 36%,
the pulled prefixes keep the hit at 59% and halve TTFT (2.4x) with 11% more throughput. On the recall workload the
evicted sessions come back from the decode's RAM: 0% → 57% hit, TTFT 20.6 s → 7.6 s, throughput 1.55x. Each pull
reads a full 131,072-token prefix plus its 128-token window in 0.5 to 0.7 s. Remaining points are being swept.

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
