# Muse Spark P/D on TPU7x: goal, status and findings (2026-11-25, 03:40 UTC)

Working summary of the P/D tuning effort. Measurements and method are in [README.md](README.md).

## 1. Goal

Lift the whole TPU P/D curve of `metrics.token_throughput_per_chip` against `metrics.p90_interactivity_tok_s`
for Muse Spark on TPU7x (PP8 prefill on 4 chips, TP8 decode on 4 chips, AgentX trace replay), toward

- the GPU curve (VR200 and GB300), compared at the same concurrency, dataset and metrics, and
- TPU aggregated serving on the submission branch.

Sub-tasks:

1. Measure P/D with the latest prefill and decode optimizations (`inferencex/musespark_submission`).
2. Say which stage holds the gap: prefill, decode or P/D transfer.
3. Tune the P/D configuration per concurrency.
4. Get the megakernel prefill program running in P/D.

## 2. Status

| Item | Status |
|---|---|
| Report with GPU comparison and headroom analysis | Done, [README.md](README.md). Corrected once (write-back-only arm, megakernel lever). |
| P/D on the latest branch | Probe only (section 3.5). Every full measured point uses a tree forked around 2026-11-05. |
| Stage attribution at concurrency 48 | Done for `j-b79b6fed-ab27-4012-8846` (section 3.3). |
| Decode running-cap tuning | Done, 4 points (section 3.6). |
| Megakernel prefill in P/D | **Runs end to end** in the fourth probe, `j-261db35b-f3ff-4bc7-bf8c` (600 s). Not faster yet (section 3.5). |
| The lever estimates and stage analysis of this page in the report | Not yet in README.md. |

No job is running.

Dashboards: `d-026c5a6c-5efd-439d-86ef` (all TPU P/D arms; the cap runs are on sheets `...-wb-decode-run12` and
`...-wb-decode-run16`), `d-c48f8e92-e88b-460e-9b93` (TPU arms against the VR200 and GB300 sheets of 2026-11-03; the
cap 12 and cap 16 sheets were added on 2026-11-25).

## 3. Findings

### 3.1 Measured TPU P/D points (8 chips)

| Arm | c32 tok/s per chip | c32 p90 interactivity | c48 tok/s per chip | c48 p90 interactivity | c64 tok/s per chip |
|---|---|---|---|---|---|
| Off | 17,936 | 62.1 | 14,703 | 74.2 | 3,470 |
| Write-back only | **18,697** | 62.6 | **18,190** | 53.3 | **12,924** |
| Write-back + decode DRAM | 17,774 | 60.5 | 16,922 | 50.0 | 11,274 |

- Write-back is the gain (+23.7% at 48, 3.7x at 64 over off). Decode DRAM on top costs 5% to 13% at every
  concurrency. The two on arms ran on different trees, so the cost is not proven to come from the switch alone.
- Concurrency 64 is overloaded in every arm (TTFT mean 75 s or more).
- The c48 point is not tuned: the server runs the concurrency-32 configuration, and the c32 point beats it on
  throughput, interactivity and TTFT at once.
- Job ids: off `j-d087a056-f4f6-4e97-80f4`, `j-7d9c883d-ceec-418f-b4f0` (48 and 64 in one job; cdk stores only 64);
  write-back only `j-c7068825-9edb-4f75-bcf4`, `j-b79b6fed-ab27-4012-8846`, `j-1b7318e5-36fc-4210-bebc`;
  both on `j-92cade4b-aa0e-4eac-902d`, `j-7cc4852a-5c96-4ab9-977c`, `j-ccfafd49-1eda-431c-b27d`.

### 3.2 Against VR200 and TPU aggregated at the same concurrency

`j-f7a07815-5bd3-4ec1-9ca2` is VR200 aggregated on 4 GPUs at concurrency 96, so it is not a like-for-like
reference. At concurrency 48 the VR200 4-GPU aggregated point is `j-a3c27ac7-e8ca-425a-9c3e`.

| Per request cycle at concurrency 48 | TPU P/D `j-b79b6fed-ab27-4012-8846` | VR200 aggregated `j-a3c27ac7-e8ca-425a-9c3e` |
|---|---|---|
| Client idle | 13.5 s | 17.2 s |
| TTFT | 19.1 s | 0.84 s |
| Generation (about 1,000 tokens) | 14.3 s (ITL 13.2 ms) | 4.6 s (ITL 4.4 ms) |
| Cycle | 47.0 s | 22.7 s |
| Requests per s | 1.02 | 2.12 |
| Tok/s per chip | 18,190 (8 chips) | 85,017 (4 GPUs) |

- Matching VR200's system throughput at 48 needs TTFT plus generation to fall from 33.4 s to about 9 s: ITL near
  4 to 5 ms and TTFT of 1 to 2 s.
- Matching it per chip at the same concurrency is not possible with 8 chips: it needs 4.24 requests per s and
  concurrency 48 allows at most about 3.6 with zero latency.
- TPU aggregated (4 chips, submission branch, `j-a42c4b09-2f0b-4151-839f`) at concurrency 32: 33,860 tok/s per chip,
  p90 interactivity 106.4, TTFT mean 13.7 s. P/D at 32 on 8 chips: 18,697, 62.6, 5.6 s. P/D delivers 1.10x the total
  tokens with twice the chips, and 2.4x better TTFT.
- Open differences: TPU draft acceptance is simulated (4.05), GPU acceptance is real; client versions and mean
  prompt length differ; the VR200 sheets are the 2026-11-03 curve.

### 3.3 Where the gap is (concurrency 48, write-back only)

Time per request by stage, from mean queue lengths in the server logs divided by the request rate:

| Stage | Owner | Time per request |
|---|---|---|
| Waiting for decode memory | decode | 9.0 s |
| Prefill queue | prefill | 2.2 s |
| Prefill compute and send | prefill | 3.3 s |
| Rest of the transfer state | transfer (upper bound) | 3.5 s |
| Generation | decode | 12.5 s |

Of the extra time against VR200 at 48: decode about 67%, prefill about 20%, transfer at most 13%.

- **Decode output saturates at 8 to 11 running requests.** Total output is 991 tok/s at 8-11 running and 1,133 at
  20-23, while per-request speed falls from 105 to 53 tok/s. More running requests only slow each one down.
- **Decode HBM for KV is full** (median usage 96%); 9.2 requests wait for memory on average.
- **Prefill is close to saturation**: a batch runs in 79% of the seconds, so its ceiling is about 1.3 requests
  per s. 74% of cache hits are read back from host memory.
- The prefill-compute and transfer split is not logged per request; the transfer figure is a remainder.

### 3.4 Two causes proposed by a colleague

| Claim | Verdict |
|---|---|
| The P/D config in `agentic.py` does not enable `MK_PREFILL` on the prefill | **True, and structural.** The prefill role sets `SGLANG_TPU_MUSE_MEGAKERNEL=0`, TP1, PP8; the prefill program only runs at TP8. |
| write_back and KVFreeFence serialize H2D reloads | **Not supported by our logs.** The prefill has no fence (overlap scheduling is off). On the decode the fence cost 38.7 ms over 77 minutes at c32. Prefill batches with host hits take 0.02 to 0.04 s longer than those with HBM hits. Measured on the offload tree, not the submission branch. |

### 3.5 Branch and megakernel

- All measured points: decode on the megakernel of early November, prefill without any megakernel, no block-256
  experts. The earlier estimate "megakernel decode doubles the ceiling" was wrong and was removed from the report.
- The submission branch cannot run P/D as is: its PP8 prefill hangs at warm-up
  (`j-c3c3e0c8-bbb3-4473-a584`, `j-3bed8d4e-9511-4a70-bb70`), and it has no write-back or offload code.
- Path being tried: prefill at TP8 with the megakernel prefill program, decode at TP8, plain Raiden transfer
  (local switch `MUSE_PD_PREFILL_TP8`, worktree commit `e5aa49bfa2`, not pushed upstream). This also avoids the PP8 hang.
  - Probe 1 `j-d4a90bbb-4bc8-43b2-91f5`: the megakernel and the prefill program built
    (`Muse prefill program built: rows=4096`), then warm-up failed with `AssertionError: prefill stages hold every
    head`. The hidden-row draft path only supports a PP prefill.
  - Probe 2 `j-0288781c-5975-45b9-9407`: ships the draft KV instead (`--sal-draft`). Passed warm-up, then failed with
    `KVCacheManager.__init__() got an unexpected keyword argument 'num_staging_layers'`: the image's tpu-sync wheel
    (2026-10-13) is too old. Fixed with `TPU_SYNC_VERSION=0.0.1.dev20261112081648`.
  - Probe 3 `j-032a3580-61c9-402a-8cb4`: the prefill ran and transfers reached the decode, but every receive was
    rejected (`request needs N pages but a host staging slot holds 32`). The AgentX config leaves `context_length`
    empty, so Raiden sizes a slot for 8,192 tokens. Fixed with `SGLANG_RAIDEN_MAX_MODEL_LEN=1048576` and
    `SGLANG_RAIDEN_HOST_POOL_GB=96` on both engines.
  - Probe 4 `j-261db35b-f3ff-4bc7-bf8c`: **works end to end.** Zero transfer failures, warm-up 354 requests with no
    error, 600 s measured. Result at concurrency 32: 9,089 tok/s per chip, p90 interactivity 188.8, ITL 3.1 ms, TTFT
    mean 7.7 s (median 1.3 s), 512 requests, 28 cancelled in flight at the end.
  - Reading of probe 4: the prefill is the bottleneck (20 or more requests queued, 1 to 2 requests running on the
    decode). It computes 10,000 to 11,400 new tokens per s when saturated, about the same as the PP8 prefill of
    `j-b79b6fed-ab27-4012-8846` (estimated 10,500). So the megakernel prefill program at one 4,096-token chunk per
    step is not faster than PP8 here. The run is too short to compare: the prefix cache hit rate was still rising
    (0.34, 0.77, 0.91 over successive 10-minute windows) and warm-up took 1,582 s against 763 s on the write-back tree.
  - Open: prefill chunk and batch size for a prefill-only TP8 engine (it runs the mixed engine's 4,096-token limit),
    no write-back on this branch, a full 3600 s point.

### 3.6 Decode running cap (write-back only, 8 chips)

`MUSE_DECODE_MAX_RUNNING` caps the decode's running requests; the compile buckets are unchanged.

| Concurrency | Cap | Job | Tok/s per chip | Gain | p90 interactivity | Gain | TTFT mean | Change |
|---|---|---|---|---|---|---|---|---|
| 32 | none | `j-c7068825-9edb-4f75-bcf4` | 18,697 | | 62.6 | | 5.6 s | |
| 32 | 16 | `j-8ce1e047-ed6d-459c-9c86` | 18,666 | -0.2% | 70.1 | +12.0% | 6.3 s | 13% worse |
| 32 | 12 | `j-cbc456fe-e1f2-4d0d-b98a` | 18,704 | +0.0% | 88.7 | +41.7% | 7.7 s | 38% worse |
| 48 | none | `j-b79b6fed-ab27-4012-8846` | 18,190 | | 53.3 | | 19.1 s | |
| 48 | 16 | `j-1260b1e4-306e-4e96-9edf` | 17,876 | -1.7% | 65.6 | +23.1% | 21.4 s | 12% worse |
| 48 | 12 | `j-1d0961a6-c1fb-44d8-a6ce` | 17,747 | -2.4% | 83.1 | +55.9% | 24.9 s | 30% worse |

- A lower cap moves the points right on the curve at near-constant throughput, as section 3.3 predicted. The time
  moves from generation to the wait for a decode slot, so TTFT grows.
- One run per point; the cap 16 runs were preempted five times each before the run that counted.

## 4. Mistakes made today

- First batch of five tuning jobs was submitted without `OWNER_LAUNCHER=true` and served the nightly configuration
  (decode KV pool 618K tokens instead of 4.41M). `j-ebf05308-7a33-40bd-a3eb` failed at warm-up with HTTP 400; all
  five were deleted and resubmitted. About one hour on 40 chips was lost. The pre-submit comparison had covered the
  environment and not the start script.
- The report first said write-back and decode DRAM were not separated; the write-back-only arm of 2026-11-19 existed.

## 5. Next steps

1. Try cap 8 at concurrency 32 and 48: cap 12 beats cap 16 at both, the trend has not turned.
2. Megakernel prefill: find why the TP8 prefill computes no faster than PP8 (chunk size, batch of sequences per
   step), then run a full c32 point.
3. Next tuning candidates, one change at a time: decode host cache size, verify width, prefill HBM cache size,
   1 prefill to 2 decode hosts.
4. Move sections 3.2 to 3.6 of this page into the report.
