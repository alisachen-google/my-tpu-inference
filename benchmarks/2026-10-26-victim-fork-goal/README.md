# Spill-over KV cache (prefill RAM → decode RAM): before vs after

Written 2026-10-26 (UTC). **Status: the "before" side is complete (30 points). The "after" side started at
18:39 UTC and is running; its column below is filled in as points land.** The table is regenerated from the run
logs with `harness/compare_goal.py`; the latest copy is `results/compare_table.md`.

## The feature under test

| | Code | Transfer library | Flags |
|---|---|---|---|
| **After** | fork branch [`pd-victim-prefix-cache`](https://github.com/sgl-project/sglang-torchtpu/compare/main...alisachen-google:sglang-torchtpu:pd-victim-prefix-cache) (`c0e561665c`) | [tpu-sync `759530c7`](https://github.com/google/tpu-sync/commit/759530c7fb0a5f7c38114187e1bcde745f709f24) built from source, plus the fork's `h2h_push` Python patch | victim push + reverse prefix pull on both roles; prefill SWA path-end backup; decode 128 SWA host windows |
| **Before** | the fork's base, upstream main `49ddede7` | installed tpu-sync wheel | all off |

Under prefill host-memory pressure the fork pushes a cold cached session RAM-to-RAM into the decode's HiCache host
pool (`push_host_pages` → `h2h_push` → native `push_registered_plan`). When that session returns, the prefill pulls
the pages back from the decode instead of recomputing them.

**Compatibility patch (uncommitted, `patches/fork_uuid0_compat.patch`).** tpu-sync `759530c7` rejects a push whose
uuid has no receive session open on the peer (`No active receive session for uuid=…`) unless the uuid is 0. The fork
pushes without opening one, so `push_host_pages` passes `uuid=0`. Verified byte-correct on hardware with
`h2h_push_check.py` (every pushed page compared), about 1 GiB/s per rank at the fork's single stream.

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

## Before vs after

### Recall workload (recall phase)

| Prefix+new | Sessions | Working set | Prefill hit before → after | Recall TTFT p50 before → after | E2E p50 before → after | Total tok/s before → after | Victim push / pull (after) |
|---|---|---|---|---|---|---|---|
| 128k+8k | 8 | 1.11M | 36.7% → pending | 14.7 s → pending | 21.4 s → pending | 27,142 → pending | pending |
| | 10 | 1.39M | 0.0% → pending | 20.4 s → pending | 26.6 s → pending | 20,245 → pending | pending |
| | 12 | 1.67M | 0.0% → pending | 20.6 s → pending | 27.0 s → pending | 20,403 → pending | pending |
| | 16 | 2.23M | 0.0% → pending | 20.5 s → pending | 26.8 s → pending | 20,856 → pending | pending |
| | 20 | 2.79M | 0.0% → pending | 20.5 s → pending | 27.0 s → pending | 21,078 → pending | pending |
| | 24 | 3.34M | 0.0% → pending | 20.4 s → pending | 27.0 s → pending | 21,229 → pending | pending |
| | 28 | 3.90M | 0.0% → pending | 20.4 s → pending | 26.9 s → pending | 21,338 → pending | pending |
| | 32 | 4.46M | 0.0% → pending | 20.5 s → pending | 27.0 s → pending | 21,420 → pending | pending |
| 256k+16k | 4 | 1.11M | 51.3% → pending | 32.5 s → pending | 39.0 s → pending | 21,571 → pending | pending |
| | 5 | 1.39M | 6.1% → pending | 57.1 s → pending | 65.3 s → pending | 14,358 → pending | pending |
| | 6 | 1.67M | 20.8% → pending | 45.4 s → pending | 53.4 s → pending | 16,018 → pending | pending |
| | 8 | 2.23M | 0.0% → pending | 71.8 s → pending | 78.2 s → pending | 14,268 → pending | pending |
| | 10 | 2.79M | 0.0% → pending | 71.4 s → pending | 78.1 s → pending | 14,358 → pending | pending |
| | 12 | 3.34M | 0.0% → pending | 71.7 s → pending | 79.7 s → pending | 14,430 → pending | pending |
| | 14 | 3.90M | 0.0% → pending | 71.7 s → pending | 79.6 s → pending | 14,492 → pending | pending |
| | 16 | 4.46M | 0.0% → pending | 71.8 s → pending | 79.8 s → pending | 14,539 → pending | pending |

Before-side p95 TTFT: 16.4 s at 8 sessions, then 20.6–27.4 s at 128k; 49–80 s at 256k. Decode's own reuse in
"before": 94.4% up to 2.23M tokens, 61–66% at 2.79M, 0% from 3.34M.

### Static prefix-reuse workload

| Prefix+new | Docs | Unique prefixes | Prefill hit before → after | TTFT p50 before → after | E2E p50 before → after | Total tok/s before → after |
|---|---|---|---|---|---|---|
| 128k+8k | 4 | 0.52M | 62.7% → pending | 6.9 s → pending | 14.3 s → pending | 37,557 → pending |
| | 8 | 1.05M | 60.5% → pending | 6.7 s → pending | 14.6 s → pending | 37,044 → pending |
| | 12 | 1.57M | 35.6% → pending | 9.6 s → pending | 17.6 s → pending | 31,181 → pending |
| | 16 | 2.10M | 28.2% → pending | 12.0 s → pending | 18.6 s → pending | 29,961 → pending |
| | 20 | 2.62M | 23.0% → pending | 12.6 s → pending | 19.5 s → pending | 27,272 → pending |
| | 24 | 3.15M | 14.7% → pending | 13.1 s → pending | 19.8 s → pending | 25,856 → pending |
| | 28 | 3.67M | 14.1% → pending | 17.4 s → pending | 24.2 s → pending | 25,700 → pending |
| 256k+16k | 2 | 0.52M | 62.7% → pending | 18.8 s → pending | 26.9 s → pending | 30,073 → pending |
| | 4 | 1.05M | 49.7% → pending | 38.2 s → pending | 46.2 s → pending | 22,594 → pending |
| | 6 | 1.57M | 37.9% → pending | 45.3 s → pending | 54.4 s → pending | 20,311 → pending |
| | 8 | 2.10M | 29.4% → pending | 51.1 s → pending | 59.4 s → pending | 19,466 → pending |
| | 10 | 2.62M | 31.8% → pending | 50.7 s → pending | 58.8 s → pending | 19,373 → pending |
| | 12 | 3.15M | 9.8% → pending | 64.2 s → pending | 72.5 s → pending | 16,529 → pending |
| | 14 | 3.67M | 14.1% → pending | 55.3 s → pending | 63.3 s → pending | 16,580 → pending |

## Reading the "before" side

- **Prefill alone reuses old sessions only up to about 1.1–1.3M tokens.** On this sliding-window model a host copy
  without its SWA window cannot serve a hit, so the usable prefill cache is effectively its HBM pool. From 10
  sessions at 128k (5 at 256k) every recall is a full recompute: TTFT ~20 s at 128k, ~72 s at 256k, and throughput
  drops 25–35% against the 8-session point.
- **Decode's own reuse does not help prefill.** It stays at 94% up to 2.2M tokens while prefill hit is 0%, and
  recall TTFT equals the cold-compute TTFT, because the decode's copy is only consulted after prefill has already
  computed the prompt.
- **Static workload:** the hit rate falls from the 62.7% ceiling at 4 docs to 14% at 28 docs (128k) and 10–14% at
  12–14 docs (256k), with TTFT rising from 7 s to 17 s (128k) and 19 s to 64 s (256k).
- **Where the feature can win:** working sets between prefill's ~1.2M and prefill + decode RAM (~3.6M): 10–28
  sessions at 128k, 5–14 at 256k; from 12 docs at 128k and 4 docs at 256k on the static workload.
- **Reproducibility:** this run repeats an earlier before-run of the same points within ~1% on every metric except
  the 8-session/128k hit (36.7% vs 40.9%) and the 4-session/256k hit (51% vs 74%), both of which depend on how
  the 4 concurrent recalls interleave with evictions.

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
