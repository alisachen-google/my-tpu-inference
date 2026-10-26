# Victim prefix cache (sglang-torchtpu 6c60fd77): before/after benchmark and H2H microbenchmark

Written 2026-10-26. Status: **the "before" side and the microbenchmark are complete; the "after" sweep is still
running** and this note will be updated with its numbers. Everything below was measured, unless marked otherwise.

## What is being compared

| | Code | tpu-sync | Feature flags |
|---|---|---|---|
| **Before** | parent `49ddede7` (upstream main of 2026-10-22) | installed wheel `0.0.1.dev20261002213151` | off |
| **After** | `6c60fd77` "[TPU] Use decode DRAM as a spill tier for prefill prefix cache" | `759530c7` (alisachen-google/h2h `ram2ram`), built from source | `SGLANG_DISAGG_PREFILL_PULL_DECODE_PREFIX=1`, `SGLANG_DISAGG_PREFIX_VICTIM_PUSH=1`, prefill `SGLANG_TPU_ENABLE_PD_PREFILL_SWA_PATH_END_BACKUP=1`, decode `SGLANG_TPU_PD_DECODE_SWA_HOST_WINDOWS=128` |

`6c60fd77` makes prefill RAM the primary prefix cache. It pushes cold host-backed branches RAM to RAM into the
decode that served them, using tpu-sync's `register_read(source="host")` and `start_read(destination="host")`.
It pulls them back through the reverse prefix pull when the session returns.

**Setup.** gpt-oss-120b on 1P1D, one tpu7x host per role (hosts a = prefill, b = decode), each role TP8/EP8.
Both configs use identical budgets (recipes in `recipes/v6c_long/`; the two differ only in the flags above):
- fp8 e4m3 KV, page 64, context 327,680, `max_running_requests` 4, chunked prefill 8,192;
- HBM pool 786,432 full-attention tokens per role;
- HiCache via Raiden, write-through: prefill ratio 1.2 (943,744 full + 754,496 SWA host tokens), decode ratio 3.5
  (2,752,576 full host tokens);
- decode radix cache on in both configs.

## Workloads (static prompts, identical token ids in both configs)

Prompt text comes from `~/pd_disagg/prompts/gpt-oss/{131072,262144,32768,1024}.jsonl`. Every session or document
gets a seeded salt, so no two share a page. Every request generates 1,024 tokens (greedy, `ignore_eos`).

1. **Victim recall** (`harness/victim_recall.py`), aimed at the case the feature exists for.
   - **Fill:** N sessions in order, each prefix + new block + question. Prefill overflows, so old sessions become victims.
   - **Settle:** wait until the push counters stop moving.
   - **Recall:** the same sessions oldest first (worst case for prefill's LRU), each the fill prompt + a fixed
     64-token answer + another new block + question.
   - Sizes: 128k prefix + 8k new at N = 8, 10, 12, 16, 20, 24, 28, 32; 256k prefix + 16k new at N = 4, 5, 6, 8, 10, 12, 14, 16.
2. **Static prefix reuse** (`harness/static_reuse.py`): K documents × 3 visits in one seeded shuffled order, each
   request a document + a unique new block, with no session history. It is queued for both configs; no results yet.
3. **Short-context sweep** (`harness/victim_sessions.py`, an early run on the after config only): 4k unique prefix,
   4 turns × 2 rounds, 64/128 tokens, concurrency 8.

**Metrics.**
- **Prefill hit rate** comes from prefill `/metrics` deltas (`sglang:cached_tokens_total / prompt_tokens_total`).
  This is the number that matters: it is the compute prefill skipped.
- **Decode reuse** is the `cached_tokens` the router returns. It comes from decode's own radix match, which saves
  KV transfer bytes but no prefill compute.
- **TTFT and end-to-end latency** are client-side.
- **Throughput** is (prompt + output tokens) / wall time of the phase.

## Results: before (feature off), recall phase

Built with `harness/recall_table.py`; raw data in `results/recall/` and `results/logs/`.

| Prefix + new | Sessions | Working set | Prefill hit | Decode reuse | Recall TTFT p50 / p95 | Total tok/s | Recall wall |
|---|---|---|---|---|---|---|---|
| 128k + 8k | 8 | 1.11M | **40.9%** | 94.4% | 11.8 / 17.2 s | 28,646 | 41.5 s |
| | 10 | 1.39M | **0%** | 94.4% | 20.1 / 27.4 s | 20,163 | 73.7 s |
| | 12 | 1.67M | 0% | 94.4% | 20.2 / 20.9 s | 20,403 | 87.4 s |
| | 16 | 2.23M | 0% | 94.4% | 20.4 / 20.7 s | 20,838 | 114.1 s |
| | 20 | 2.79M | 0% | 56.6% | 20.4 / 20.9 s | 21,033 | 141.3 s |
| | 24 | 3.34M | 0% | 0% | 20.0 / 20.8 s | 21,216 | 168.1 s |
| | 28 | 3.90M | 0% | 0% | 20.3 / 20.8 s | 21,338 | 195.0 s |
| | 32 | 4.46M | 0% | 0% | 20.0 / 20.3 s | 21,410 | 222.1 s |
| 256k + 16k | 4 | 1.11M | **74.3%** | 94.4% | 29.9 / 34.2 s | 29,025 | 40.8 s |
| | 5 | 1.39M | 7.2% | 94.4% | 56.3 / 76.5 s | 14,470 | 102.3 s |
| | 6 | 1.67M | 20.8% | 94.4% | 39.0 / 71.0 s | 16,966 | 104.7 s |
| | 8 | 2.23M | 0% | 94.4% | 71.1 / 80.7 s | 14,242 | 166.3 s |
| | 12 | 3.34M | 0% | 7.9% | 71.5 / 71.7 s | 14,430 | 246.2 s |
| | 16 | 4.46M | 0% | 0% | 71.4 / 71.7 s | 14,526 | 326.1 s |

The fill phase TTFT p50 is about 17.7 s at 128k + 8k and 55–64 s at 256k + 16k, a full compute. Its hit rate is
0% by construction. There were no request errors at any point. The 256k + 16k points at 10 and 14 sessions were
still running when this was written.

**Reading the "before" curve.**
- **Prefill alone stops reusing old sessions at about 1.2–1.4M tokens** (9–10 sessions at 128k, 5 at 256k). That is
  roughly its HBM pool: on this sliding-window model a host copy without its SWA window can't serve a hit, and
  path-end SWA backup is off in "before".
- **Decode keeps its own copy up to about 2.75M tokens** (its host pool), then loses it as well. That copy only
  shortens the KV transfer; prefill still recomputes the whole prompt, which is why recall TTFT equals the
  cold-compute TTFT.
- **The window where the feature can win is therefore roughly 1.2M to 3.6–3.9M tokens:** about 9–28 sessions at
  128k and 5–14 at 256k. Above it, prefill + decode RAM overflow too. Expected; the "after" side is not measured yet.

## Results: after (feature on) — partial

**Short-context sweep, 2026-10-26 05:53–06:05** (run `v6c_victim_1`, hosts a+b; raw data in `results/short_sweep/`):

| Sessions (4k prefix) | Token hit | Request hit | Total tok/s | TTFT p50 | Measured wall |
|---|---|---|---|---|---|
| 16 | 87.8% | 91.1% | 29,550 | 0.17 s | 17.5 s |
| 32 | 87.1% | 90.2% | 31,823 | 0.12 s | 32.5 s |
| 64 | 85.3% | 88.2% | 31,774 | 0.11 s | 65.1 s |
| 96 | 86.3% | 89.3% | 32,354 | 0.11 s | 95.9 s |
| 128 | 83.8% | 86.5% | 31,798 | 0.10 s | 130.1 s |
| 192 | 96.6% | 100% | 30,934 | 0.11 s | 200.6 s |

- **First hardware run of the RAM-to-RAM push.** By 192 sessions, 345 pushes had started, 343 were stored on
  decode, 2 were refused for lack of room, and none failed. 916,288 tokens landed in decode host RAM. No pulls
  happened, because these sessions still fitted prefill.
- **Hit-rate hole at round 2, turn 1.** Under 192 sessions that pass hits only 36% (other passes hit 95–96%).
  That pass re-asks a prefix of a longer cached path, and with path-end SWA backup prefill keeps a window only at
  each path's end.

**Crash in the "after" config.**
- **What happened:** run `static_after_1` (128k + 8k, 8 sessions, 4 turns), 2026-10-26 06:32–06:41.
  - Prefill logged `[prefix-pull] room=8143948309899068678 ranks planned different pulls, giving up`.
  - That room stalled.
  - About 9 minutes later every prefill rank aborted natively with
    `F... throw_delegate.cc:107] RAW: absl::container_internal::raw_hash_map<>::at`.
  - The same pattern killed the original victim-cache branch at 256 sessions on 2026-10-24.
- **Why the ranks can disagree:** `DecodePrefixPuller._plan` (`sglang_tpu/disaggregation/raiden/prefix_pull.py:365`)
  works from per-rank state: the decode's offer and the rank's own `match_prefix` / `host_hit_length`. It then
  sends `PREFIX_PULL` to the decode (`:419`) **before** `_agree_on_plans` (`:248`) compares plans across ranks.
  On a mismatch, decode ranks that already registered reads keep them until the native deadline.
- **Proposed fix, not applied:** make `_plan` side-effect free, agree on the candidate (including whether to pull at
  all), and only then lock and ask on every rank.
- **The native abort is not in tpu-sync.** A code and binary audit found no `.at()` in the tpu-sync paths these
  transfers use that could throw (details in "Code audit"). It probably comes from libtpu, PJRT or torch_tpu.
  The re-run "after" chain saves `/proc/<pid>/maps` of every scheduler, so a repeat can be symbolized.

## H2H microbenchmark (tpu-sync 759530c7)

Harness in `harness/h2h_loop_tpu.py` and `harness/h2h_xhost.py`; raw data in `results/microbench/`.
- **Calls under test:** the victim path's own: `register_read(source="host")`, then `start_read(destination="host",
  local_host_block_ids=…)`, then `poll_stats_with_details` until the read settles.
- **Managers:** full torch managers with small TPU buffers and a real-size host pool: 18 layers × 8 KiB per 64-token
  page, which is one gpt-oss rank. The host-only test manager has no read path in this build.
- **Bytes checked:** source pages hold seeded random bytes, and the first transfer of every size is checked byte
  for byte. **Every case was correct.**
- **Sizes:** 2,176 pages = one rank's share of a 128k victim (306 MiB); 4,352 = a 256k victim (612 MiB).

**Loopback on host w8, one pair (one rank):**

| Pages (size) | 1 stream: p50 latency | 1 stream: GiB/s | 4 streams: p50 latency | 4 streams: GiB/s |
|---|---|---|---|---|
| 16 (2.25 MiB) | 2.3 ms | 0.95 | 2.5 ms | 0.88 |
| 128 (18 MiB) | 7.2 ms | 2.45 | 6.7 ms | 2.64 |
| 512 (72 MiB) | 24.0 ms | 2.93 | 20.8 ms | 3.39 |
| 2,176 (306 MiB) | 101 ms | 2.97 | 84 ms | 3.54 |
| 4,352 (612 MiB) | 188 ms | 3.18 | 170 ms | 3.52 |

**Loopback on w8, eight pairs at once (all ranks pushing):**

| Pages per pair | 1 stream: p50 latency | 1 stream: aggregate GiB/s | 4 streams: p50 latency | 4 streams: aggregate GiB/s |
|---|---|---|---|---|
| 16 | 5.6 ms | 3.2 | 4.9 ms | 3.6 |
| 128 | 10.0 ms | 14.0 | 10.2 ms | 13.8 |
| 512 | 30.4 ms | 18.5 | 34.2 ms | 16.5 |
| 2,176 | 130 ms | 18.4 | 141 ms | 17.0 |
| 4,352 | 240 ms | 19.9 | 263 ms | 18.2 |

**Cross-host v7 → w8, one pair** (p50 latency, with min–max in parentheses). v7 was loaded by another user's build,
with disk pressure around 50%.

| Pages | 1 stream | 4 streams | 4 streams: GiB/s |
|---|---|---|---|
| 16 | 5.1 ms (4.6–5.1) | 5.4 ms (5.2–6.1) | 0.41 |
| 128 | 8.0 ms (7.7–17.6) | 8.9 ms (8.3–9.1) | 1.97 |
| 512 | 21.5 ms (20.3–22.8) | 24.8 ms (22.5–24.9) | 2.84 |
| 2,176 | 1,297 ms (76–2,529) | 94.7 ms (89–98) | 3.16 |
| 4,352 | 1,662 ms (164–3,169) | 194 ms (192–202) | 3.08 |

Raw TCP between the same two hosts (iperf3): 4.77 GiB/s with 1 stream, 20.2 GiB/s with 8 streams.

**Takeaways.**
- **One rank's H2H read settles at about 3.1–3.5 GiB/s** (about 65% of a single TCP stream), with a fixed cost of
  about 2 ms on loopback and 5 ms cross-host.
- **Use several streams.** With 1 stream, large cross-host reads stalled for 1.3–3.2 s in some repetitions.
- **Eight ranks scale to about 18–20 GiB/s,** about the NIC's 8-stream limit. A whole 128k victim (about 2.4 GiB
  across 8 ranks) should move in 0.15–0.25 s, against the 20 s recompute in the "before" table. The 8-pair
  cross-host case was not measured.

## Code audit of concurrent D2D and H2H (static, no confirmed race)

- **No shared native state.** The P/D engine and the HiCache host-pool managers are separate tpu-sync managers,
  each with its own transport, control server and session maps. The only process-wide statics are metrics
  counters and an executor that nothing calls.
- **Within one host-pool manager**, H2H sessions and HiCache D2H/H2D are serialized by the manager mutex, and
  completion reports are drained once. HiCache's own copies wait on futures, so they can't take the victim
  wrapper's reports.
- **Page lifetimes are correct on both sides.** Prefill sources stay pinned (`inc_host_lock_ref`) until every
  native outcome is terminal. Decode landing pages stay outside the tree until insert and are freed only on a
  terminal report.
- **Risks found:**
  - `TPU_RAIDEN_DYNAMIC_HOST_STAGING=1` is set for the whole process, so a `start_read` to device without host ids
    could take staging pages from the HiCache host pool. The victim code always passes `destination="host"`.
  - With uneven P/D rank counts, victim push ids can collide.
  - The prefix-pull ordering bug above.
  - `_host_transfers` grows without bound.

## Host memory (measured during the runs)

- **Fixed at startup.** Each role's host memory is fixed when it starts and does not grow with traffic:
  - The P/D staging is `num_slots × max_blocks` blocks, allocated when the engine is built. That is 2 slots ×
    2,880 MB per rank for the full-attention engine, about 46 GB per host.
    `SGLANG_RAIDEN_HOST_POOL_GB=128` is only the cap the slot count is derived from.
  - The HiCache pools are 8.7 + 7.0 GB on prefill and 25.4 GB on decode.
- **H2H allocates nothing.** It moves pages between the existing HiCache pools, so D2D and H2H together cannot push
  a host out of memory.
- **The tightest host is a.** Its `/dev/shm` compile caches use 445 GB, leaving about 272 GB available.

## Reproducing

- **Build tpu-sync `759530c7`** with `./build.sh torch` (Bazel output in `/dev/shm`). The pip step is skipped so the
  shared venv's jax and libtpu stay unchanged.
- **Patch the glue library name:** `patchelf --replace-needed libpywrap_torch_tpu_common.so libpywrap_2_11_0_common.so`
  on `_tpu_raiden_torch.so` and `_torch_raw_transfer.so`, to match the installed torch_tpu.
- **Load it** via `PYTHONPATH=<tpu-sync checkout>`; see `harness/pd_6c60.sh`.
- **Queue:** `harness/queue_ab.sh` runs "before" recall, "before" static, "after" recall and "after" static in order.
  `harness/recall_table.py` prints the comparison.
- **Debug CRC patch:** `patches/debug_victim_crc.patch` (env `SGLANG_TPU_DEBUG_VICTIM_CRC=1`, off by default, not
  committed upstream). It logs a CRC32 of the victim pages on both sides, which `harness/crc_compare.sh` joins. It
  was not used for the timing runs.

## Still to do

- **The "after" recall and static sweeps** are queued on a+b. Add their table here, with prefill hit, TTFT and
  throughput side by side with "before".
- **Data-integrity run on hardware** (`harness/victim_integrity.py` with the CRC patch): planned for pair 2 (v7 + w8),
  which was blocked by v7's disk starvation.
- **The prefix-pull fix**, pending the owner's decision.
