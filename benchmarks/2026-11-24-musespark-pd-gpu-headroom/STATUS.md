# Muse Spark P/D on TPU7x: goal, status and findings (2026-11-24, 22:30 UTC)

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
| P/D on the latest branch | **Not done.** Every measured point uses a tree forked around 2026-11-05. |
| Stage attribution at concurrency 48 | Done for `j-b79b6fed-ab27-4012-8846` (section 3.3). |
| Decode running-cap tuning | 4 jobs running since 21:33 UTC, results expected about 23:40 UTC. |
| Megakernel prefill in P/D | Prefill program builds on a TP8 prefill. First probe failed at warm-up; second probe running. |
| The lever estimates and stage analysis of this page in the report | Not yet in README.md. |

Jobs running now:

| Job | What | Client concurrency |
|---|---|---|
| `j-cbc456fe-e1f2-4d0d-b98a` | write-back, decode running cap 12 | 32 |
| `j-1d0961a6-c1fb-44d8-a6ce` | write-back, decode running cap 12 | 48 |
| `j-8ce1e047-ed6d-459c-9c86` | write-back, decode running cap 16 | 32 |
| `j-1260b1e4-306e-4e96-9edf` | write-back, decode running cap 16 | 48 |
| `j-0288781c-5975-45b9-9407` | probe: TP8 megakernel prefill to TP8 decode, submission branch, 600 s | 32 |

Dashboards: `d-026c5a6c-5efd-439d-86ef` (all TPU P/D arms; the cap runs land on sheets `...-wb-decode-run12` and
`...-wb-decode-run16`), `d-c48f8e92-e88b-460e-9b93` (TPU arms against the VR200 and GB300 sheets of 2026-11-03).

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
  - Probe 2 `j-0288781c-5975-45b9-9407`: ships the draft KV instead (`--sal-draft`). Running.
  - Not yet verified: KV layout check between the two engines, the first real TP8-to-TP8 transfer.

## 4. Mistakes made today

- First batch of five tuning jobs was submitted without `OWNER_LAUNCHER=true` and served the nightly configuration
  (decode KV pool 618K tokens instead of 4.41M). `j-ebf05308-7a33-40bd-a3eb` failed at warm-up with HTTP 400; all
  five were deleted and resubmitted. About one hour on 40 chips was lost. The pre-submit comparison had covered the
  environment and not the start script.
- The report first said write-back and decode DRAM were not separated; the write-back-only arm of 2026-11-19 existed.

## 5. Next steps

1. Read the four cap runs: check that p90 interactivity rises at near-constant throughput, and what TTFT does.
2. Follow the probe until a TP8 megakernel prefill serves requests in P/D, then run a full c32 point.
3. Next tuning candidates, one change at a time: decode host cache size, verify width, prefill HBM cache size,
   1 prefill to 2 decode hosts.
4. Move sections 3.2 to 3.4 of this page into the report.
