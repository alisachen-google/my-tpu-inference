# Muse Spark AgentX on TPU7x: reproduction, KV offload to decode DRAM, high concurrency (2026-11-16 to 2026-11-19)

Every Muse Spark run made in this campaign, what it showed, and every problem met on the way, with what was done about
each. Earlier analysis of the dashboard (GPU vs TPU, cost, megakernel notes) is in `../2026-11-16-musespark-disagg/`.

- **Model and setup:** Muse Spark (Muse-Spark-Open-816B-A42B, NVFP4) with the windowed DFlash draft, SGLang P/D over
  Raiden on two tpu7x 2x2x1 hosts (8 chips): PP8 prefill on one host, TP8 decode on the other.
- **Workload:** AgentX trace replay through aiperf (`semianalysis_cc_traces_weka_062126`), one hour measured after a
  warm-up phase. Mean prompt about 150k tokens; the trace's theoretical cache hit is about 97%.
- **Dashboard:** http://go/cdk-portal/dash/d-026c5a6c-5efd-439d-86ef. The rows of this file are on the sheets
  `alisachen-muse-tpu7x-pd-pp8tp8-agentx-junyan-offload-off` and `...-offload-on`; the reproduction is on
  `...-ref-repro`, next to the reference point `j-ec9464b2-4aaf-46fe-af8a` from dash `d-19d6aedd-af5d-481d-9929`.
- **Recipe:** `musespark-pd-agentx-alisachen` (copy in `recipes/musespark-pd-agentx.jsonnet`).

## Summary

| | Result |
|---|---|
| Reproduce the dashboard point | Done: 17,924 tok/s per chip against 18,326, on the owner's branch. Not reproducible on upstream main. |
| Port the KV offload onto that branch | Done locally (branch `agentx-offload`, 10 commits); offload off keeps the baseline (17,936 tok/s per chip). |
| Offload at concurrency 32 | No gain, no loss (-1.4%). The prefill cache already holds everything; 11 recalls in an hour. |
| Offload at concurrency 64 | **+97% throughput** (3,470 → 6,852 tok/s per chip), mean TTFT 1.76x faster, p90 TTFT 2.31x faster. Without the offload the system collapses between 48 and 64. |
| Offload at concurrency 96 | Not measured: the offload-on decode crashed after 3.5 h. Offload off at 96 was still running when this was written. |

## 1. Reproducing the dashboard point

The reference point `j-ec9464b2-4aaf-46fe-af8a` (concurrency 32, 18,326 tok/s per chip) did not run upstream main.

- **Where it ran:** the owner's stack of 13 open PRs (2014–2026), top branch `junyanxu/agentx-13-recipe`, head
  `4b280e15`, based on main `eb503fb3` (2026-11-07, before the offload PRs 1992 and 2086 merged).
- **What that stack adds over main:** fp8 KV in a sequence-along-lane layout (256 B per token, 256-token pages), the
  batched ragged-paged-attention kernel for long contexts, a windowed DFlash draft, a 1M-token context, 32 running
  requests per role, session radix cache, and its own P/D prefix pull (off by default).

| Run | Job | Tree | Tok/s per chip | Successful requests | Errors | TTFT p50 |
|---|---|---|---|---|---|---|
| Reference (owner) | `j-ec9464b2-4aaf-46fe-af8a` | `junyanxu/agentx-13-recipe` | 18,326 | — | — | 5.2 s |
| Reproduction | `j-7bce803b-5910-48c5-938f` | same branch, `4b280e15` | 17,924 | 3,439 | 0 | 5.0 s |
| Upstream main attempt | `j-58c2ef95-db91-41d6-9bb1` | upstream main | 799 (partial) | measured phase cancelled | — | 68.9 s |

How the reproduction is run: recipe `musespark-pd-agentx-alisachen` with `OWNER_LAUNCHER=true` (the tree's own
`benchmark/tpu/recipe/muse_spark_agentx_launcher.sh prefill|decode 32`), the tree staged with `--map-dir`,
`SERVER_IMAGE=.../sglang-torchtpu:muse-disagg`, `TPU_SYNC_VERSION=0.0.1.dev20261029081917`,
`MODEL_STORAGE_CLASS=hyperdisk-balanced MODEL_STORAGE_SIZE=700Gi`, `MAX_RESTARTS=2`.

## 2. Porting the KV offload onto the owner's branch

Local branch `agentx-offload` at `be53364f`, 10 commits on `4b280e15`, not pushed anywhere:

| Commit | Content |
|---|---|
| `40522a63` | PR 1992 (offload base), cherry-picked |
| `3bb5cc88` | PR 2086 (hybrid sliding-window models), cherry-picked |
| `8e6eae55`, `dbaac1a7`, `a63e3c8a` | PR 2202 (pipeline-parallel prefill), adapted to this branch's pipeline module |
| `3b811a0e` | PR 2234 (re-measure the window shortage after full host eviction) |
| `49f6554b` | An engine without the switch is unchanged |
| `170df798` | Branches of a million tokens (push search, digests, two tuning settings) |
| `e9a94b52` | The Muse Spark AgentX pairing (validation, decode host tier, README) |
| `be53364f` | Tests |

- **Kernels and model code are byte-identical** to the owner's branch; `git diff 4b280e15 HEAD -- python/ benchmark/` is
  empty apart from the local override in section 5.
- **Not ported:** the pipeline transfer page cap (not needed: this layout costs one repeat per page, so a 1M-token
  prompt is about 33k repeats against a bound near 2^20) and three main commits that change eviction with the switch off.
- **Refused at start-up with the switch on:** the owner's prefix pull, and decode draft prefill with a draft.
- **CPU tests:** offload suites 237 passed; branch pipeline suites 388 passed; whole-directory failure sets identical to
  the base branch.

Offload settings used for the on arm (`recipes/offload_env.sh`): both roles `SGLANG_ENABLE_PREFILL_KV_OFFLOAD_TO_DECODE_DRAM=1`,
`SGLANG_PD_OFFLOAD_ALLOW_DRAFT=1` and 60 s Raiden socket timeouts; prefill `SGLANG_PD_OFFLOAD_PUSH_FREE_TOKENS=2097152`;
decode `SGLANG_PD_OFFLOAD_STAGE_PAGES_PER_WINDOW_PAGE=32` and `SGLANG_PD_OFFLOAD_STAGE_STORE_GB` as given per run below.

## 3. All runs on the ported tree

Same recipe and settings as the reproduction, except `TPU_SYNC_VERSION=0.0.1.dev20261112081648` (section 6, issue 5).
The server runs 32 requests at a time in every run; client concurrency above 32 queues the rest.

| Concurrency | Arm | Job | Decode own cache / store, per rank | Tok/s per chip | Successful / total requests | Errors | TTFT mean | TTFT p50 | TTFT p90 | Status |
|---|---|---|---|---|---|---|---|---|---|---|
| 32 | Off | `j-d087a056-f4f6-4e97-80f4` | 56 GB / — | 17,936 | 3,432 / 3,787 | 1 | 6.9 s | 5.0 s | 12.8 s | valid |
| 32 | On | `j-4989fb1e-71c3-4f0a-8822` | 56 GB / 24 GB | — | — | — | — | — | — | decode died twice at about 105 min (memory), deleted |
| 32 | On | `j-660f5a88-5c55-4379-8a80` | 56 GB / 6 GB | 17,676 | 3,394 / 3,748 | 0 | 6.7 s | 5.2 s | 12.2 s | valid |
| 48 | Off | `j-7d9c883d-ceec-418f-b4f0` | 56 GB / — | 14,703 | 2,939 / 3,471 | 1 | 39.3 s | 28.4 s | 91.0 s | valid |
| 64 | Off | `j-7d9c883d-ceec-418f-b4f0` | 56 GB / — | 3,470 | 873 / 1,580 | 0 | 274.2 s | 15.5 s | 699.1 s | valid (ran right after 48 in the same job) |
| 48, 64 | On | `j-13ee609f-2102-4324-aeec` | 56 GB / 6 GB | — | — | — | — | — | — | deleted before it ran (store too small, see 96 probe) |
| 96 | On (probe) | `j-668fa780-d0c5-4027-8906` | 56 GB / 6 GB | 9,094 (partial) | — | — | — | 8.2 s | — | warm-up 3.3 h, decode died 9 min into the measured phase |
| 64 | On | `j-e772083d-7caf-4e3d-b938` | 32 GB / 36 GB | 6,852 | 1,568 / 2,275 | 0 | 155.6 s | 163.8 s | 302.7 s | valid |
| 96 | On | `j-b28a2501-fd34-4a68-a42f` | 32 GB / 36 GB | 10,210 (partial) | 517 / 1,650 | 72 | — | 7.7 s | 37.0 s | decode died at about 3.5 h; not usable |
| 96 | Off | `j-dab053e3-f09d-4578-af38` | 56 GB / — | — | — | — | — | — | — | running when this was written |

### Off vs on, gains

| Concurrency | Tok/s per chip off → on | Throughput gain | Successful requests off → on | Requests gain | TTFT mean off → on | Mean speedup | TTFT p90 off → on | p90 speedup | TTFT p50 off → on | p50 speedup |
|---|---|---|---|---|---|---|---|---|---|---|
| 32 | 17,936 → 17,676 | -1.4% | 3,432 → 3,394 | -1.1% | 6.9 s → 6.7 s | 1.03x | 12.8 s → 12.2 s | 1.05x | 5.0 s → 5.2 s | 0.97x |
| 64 | 3,470 → 6,852 | **+97%** | 873 → 1,568 | +80% | 274.2 s → 155.6 s | 1.76x | 699.1 s → 302.7 s | 2.31x | 15.5 s → 163.8 s | 0.09x |

No cache-hit rate is measured for these runs, so the tables have no hit column.

### Offload activity (prefill stage 0 and decode rank 0 counters at the end of each run)

| Run | Pushes started / stored | Recall offers | Recalls pulled | Offers declined as still local | Store size (sessions) | Stored sessions evicted by the decode |
|---|---|---|---|---|---|---|
| c32, 24 GB store (`j-4989fb1e-71c3-4f0a-8822`, before the crash) | 217 / 213 | 403 | 2 | 400 | — | 51,220 of 72,116 pages |
| c32, 6 GB store (`j-660f5a88-5c55-4379-8a80`) | 1,140 / 1,123 | 550 | 11 | 539 | — | — |
| c96 probe, 6 GB store (`j-668fa780-d0c5-4027-8906`) | 1,398 / 1,393 | 6 | 4 | 2 | 20 | 1,602 |
| c64, 36 GB store (`j-e772083d-7caf-4e3d-b938`) | 1,619 / 1,616 | 1,138 | 936 | 202 | 124 | 1,455 |

### Reading the results

- **Concurrency 32:** the prefill's own cache (about 8M tokens of host memory) holds the working set; 539 of 550 recall
  offers were declined because the prefill still had the session. The offload costs about 1% for pushes that are never
  needed; one run cannot separate that from noise.
- **Concurrency 48 to 64 without the offload:** throughput falls from 14,703 to 3,470 tok/s per chip and p90 TTFT
  reaches 11.7 minutes. The prefill cache thrashes.
- **Concurrency 64 with the offload:** the prefill pulled 936 sessions back from the decode in the hour, and throughput
  is twice the off arm. Mean and p90 TTFT also improve.
- **TTFT p50 at 64 is not a regression signal.** The off arm completed half as many requests and its latency is split
  between requests that get through quickly and ones that wait many minutes (p50 15.5 s, p90 699 s). Mean and p90 are
  the fairer comparison.
- **The store size decides whether recall happens.** With 6 GB per rank the store holds about 20 sessions; at 96
  concurrent sessions a pushed session was evicted from the decode long before it returned (6 offers in three hours).
  With 36 GB it holds about 124 and recalls became routine.

### Caveats

- **The two arms at 64 differ in more than the switch.** The on arm moved 24 GB per rank from the decode's own cache
  to the store (32 + 36 GB); the off arm keeps the owner's 56 GB decode cache. Same host memory, used two ways. An off
  run with a 32 GB decode cache would separate the two effects; not run.
- **The off arm at 64 ran right after 48 in the same job**, the on arm started fresh.
- **Single runs.** The reproduction and the off arm at concurrency 32 (different trees, different days) differ by
  0.1%, but nothing at 64 was repeated.
- **The ported tree has none of the pipeline-parallel recall fixes found on 2026-11-18** with gpt-oss-120b and Qwen3-30B
  (branch `offload-pp-recall-fixes`: lost push decisions, one proposal at a time, sessions evicted before pushing,
  missing sliding-window pages, dropped recall offers). On those models they raised recall hit from 12–47% to 79–94%,
  so the on arm here is probably understated.

## 4. Upstream main attempts (2026-11-16 to 2026-11-17)

Before the owner's branch was identified, the same workload was tried on upstream main with PP8 prefill and TP8 decode
and with PP offload on and off. None of these is a valid data point: 444 to 1,075 tok/s per chip, 27–50% of requests
failed, and the prefill cache hit was 14.5% against 79.5% theoretical in `j-58c2ef95-db91-41d6-9bb1`. Reasons, found
in the logs and code:

| Problem on upstream main | Effect |
|---|---|
| bf16 KV only through the PP8 → TP8 pipeline transfer | about 10x less KV room than the owner's fp8 layout; the decode admits about one request |
| Batched attention kernel limits the context to 130,816 tokens at batch 32 | AgentX prompts of 165k–237k tokens do not fit |
| Context 1,048,576 fails the attention kernel compile (SMEM) | the owner's context length cannot be used |
| DFlash draft on the batched kernel fails to compile (`_fused_rope_write` CompileTimeScopedVmemOom) | no speculative decoding with that kernel |
| Session-cache server arguments absent | the owner's config does not start |
| `agentic.get_config` P/D modes ask PP2 × TP4, refused by main's argument validation | the owner's launcher does not start on main |
| Pipeline transfer of prompts above about 131k tokens fails (`Byte span plan exceeds the repeat expansion bound`) | long prompts never reach the decode; fixed by the page cap (commits `159d45b7`, `2cf5a10d` on branch `pipeline-transfer-page-cap`), validated on TPU, not needed on the owner's layout |

The TP8 prefill to TP8 decode alternative and the PP8/TP8 sharding comparison from 2026-11-17 are on the same dashboard
(sheets `...-tp8tp8-fp8-agentx`, `...-upstream-refcfg`); none of them came close to the reference.

## 5. Problems met and what was done

| # | Problem | Fix or workaround | Status |
|---|---|---|---|
| 1 | Dashboard point not reproducible on upstream main (section 4) | Located the owner's branch; ran it with the owner's launcher (`OWNER_LAUNCHER=true` mode added to the recipe) | fixed, reproduced within 2.2% |
| 2 | Default server image with the upstream tree: `ImportError jax._src.tpu_info` | `SERVER_IMAGE=...:anvil-jax0112-97afaea9` for upstream, `...:muse-disagg` for the owner's branch | fixed |
| 3 | `cdk job retry` of the reference job stuck on VolumeBinding: premium-rwo SSD quota exhausted | Own recipe with `MODEL_STORAGE_CLASS=hyperdisk-balanced MODEL_STORAGE_SIZE=700Gi` | worked around |
| 4 | Offload PRs do not apply to the owner's base (it predates PR 1992 and 2086; pipeline modules renamed; merging main conflicts in 25 files) | Ported only what the offload needs, kernels and model code untouched (section 2) | fixed |
| 5 | The owner's pinned tpu-sync wheel (`...20261029081917`) has no host-to-host read API, so both engines refuse to start with the switch on | Both arms run main's wheel `0.0.1.dev20261112081648`; the off arm confirms the baseline still holds (17,936 vs 17,924) | fixed |
| 6 | `OWNER_LAUNCHER` mode had no way to pass offload settings | Recipe exports `PREFILL_ENV` / `DECODE_ENV` (JSON) per role before starting the launcher | fixed |
| 7 | Decode out of memory with a 24 GB store per rank: the pod reached 917 GiB of its 900 GiB limit; died twice at about 105 min | 6 GB store at first; later 36 GB with the decode's own cache cut from 56 to 32 GB per rank (`MUSE_DECODE_HICACHE_GB`, local override in `patches/agentic-decode-hicache-override.diff`, not in the owner's recipe) | worked around |
| 8 | No recall at concurrency 32 (the workload does not overflow the prefill cache) | Raised client concurrency | fixed: recall triggers at 64 |
| 9 | At 96 the 6 GB store holds 20 sessions, so pushed sessions are evicted before they return | 36 GB store (about 124 sessions) | fixed for 64 |
| 10 | Warm-up at concurrency 96 alone took 3.3 h | Dropped the planned levels 128, 192 and 256 | scope cut |
| 11 | Repeated preemptions (node termination, fair-share priority) restarted long jobs from the beginning | `MAX_RESTARTS`, long pending timeouts; reran | ongoing cost |
| 12 | Offload-on decode crashed at concurrency 96, both with the 6 GB and the 36 GB store; no error line found before the pods were removed | none | **open** |
| 13 | Muse Spark static prefix-reuse ladder (off and on) | Jobs failed on infrastructure and image, then were deleted to prioritise the reproduction | **not done** |

## 6. Open items

- Offload-off result at concurrency 96 (`j-dab053e3-f09d-4578-af38`).
- Off arm at 64 with the decode's own cache at 32 GB, to separate the cost of the smaller decode cache from the gain
  of the offload.
- Port the pipeline-parallel recall fixes (`offload-pp-recall-fixes`) onto `agentx-offload` and rerun concurrency 64.
- Cause of the decode crash at 96 with the offload on.
- Muse Spark static prefix-reuse ladder.

## Files

- `recipes/musespark-pd-agentx.jsonnet`: the recipe as used (owner-launcher mode, role env passthrough, storage class,
  restarts, failed-request threshold).
- `recipes/offload_env.sh`: the prefill and decode offload settings of the on arm (the decode store size was then
  set per run as in section 3).
- `patches/agentic-decode-hicache-override.diff`: the local override of the decode's own host cache size.
