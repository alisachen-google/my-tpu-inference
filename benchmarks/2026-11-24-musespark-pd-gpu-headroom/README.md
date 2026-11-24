# Muse Spark P/D on TPU7x against the GPU curve, with a headroom analysis (2026-11-24)

Two full AgentX runs of Muse Spark P/D on TPU7x with prefill write-back and KV offload to decode DRAM both on
(concurrency 32 and 48), compared with the published GPU P/D curve, and an analysis of where the gap comes from.

- **Setup:** Muse-Spark-Open-816B-A42B (NVFP4) with the windowed DFlash draft, SGLang P/D over Raiden on two tpu7x
  2x2x1 hosts (8 chips): PP8 prefill on one host, TP8 decode on the other. The server admits 32 requests at a time.
- **Workload:** AgentX trace replay through aiperf (`agentic_traces`), 3600 s measured after a warm-up phase.
- **Venue:** cdk, recipe `musespark-pd-agentx-alisachen`, image `sglang-torchtpu:muse-disagg`, tpu-sync wheel
  `0.0.1.dev20261112081648`.
- **Tree:** `agentx-offload-scaleout` at `12a73c2d` (the owner's `agentx-13-recipe` stack plus the offload port).
  **Not** `inferencex/musespark_submission`: its P/D prefill hangs at warm-up (section 6), and it has no offload code.

## 1. Summary

| Question | Answer |
|---|---|
| Per chip, how far is TPU P/D from the GPU P/D curve? | 17,774 tok/s per chip at concurrency 32. VR200 4+4 is 9.3x higher, GB300 8+16 is 2.6x higher. |
| Per dollar? | 52.9M tokens per dollar. VR200 4+4 is 3.1x better, the best GB300 point 1.6x better. TPU beats the decode-heavy GPU points (GB300 8+32, 8+40; VR200 8+40). |
| Interactivity? | p90 60.5 tok/s at concurrency 32 and 50.0 at 48. Every GPU P/D point is at 120 or above. |
| Do write-back and decode DRAM help? | Both on, at 32: no change (-0.9%). At 48: **+15% throughput**, mean TTFT 1.85x faster, p90 TTFT 2.42x faster. |
| Which of the two helps? | Write-back. Write-back alone (2026-11-19) is the best TPU point: 18,697 tok/s per chip at 32 and 18,190 at 48 (+23.7% over off). Adding decode DRAM on top costs 4.9% at 32 and 7.0% at 48. |
| What limits the curve? | The decode. Its output rate is flat at about 950 tok/s on 4 chips from concurrency 32 to 48, so the request rate stays at 0.95 per second whatever the concurrency. |
| Second limit | Decode HBM for KV: about 4.4M tokens, 29 mean-length sessions. At 48 a request waits about 11 s for decode memory. |
| Is prefill the limit? | Not at 32 (queue 0.27 on average). At 48 its HBM cache thrashes (77% of hits come from host memory) but the queue is still short. |

## 2. Today's runs

Both runs: write-back on the prefill (`MUSE_PREFILL_WRITE_POLICY=write_back`), offload to decode DRAM on both roles
(`SGLANG_ENABLE_PREFILL_KV_OFFLOAD_TO_DECODE_DRAM=1`), decode host cache 32 GB and stage store 36 GB per rank.

| Concurrency | Job | Tok/s per chip | Total tok/s | Output tok/s | Requests per s | Successful / total | Errors | p90 interactivity | p50 interactivity | TTFT mean | TTFT p50 | TTFT p90 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 32 | `j-92cade4b-aa0e-4eac-902d` | 17,774 | 142,190 | 933 | 0.946 | 3,427 / 3,782 | 1 | 60.5 | 91.4 | 6.2 s | 5.3 s | 10.8 s |
| 48 | `j-7cc4852a-5c96-4ab9-977c` | 16,922 | 135,376 | 953 | 0.962 | 3,487 / 4,018 | 0 | 50.0 | 64.4 | 21.2 s | 19.4 s | 37.6 s |

- The single error at 32 is a client-side connection write failure, not a server error.
- "Total" requests include the warm-up phase; the difference from "successful" is warm-up records, not failures.
- Mean prompt: 149,308 tokens at 32, 139,857 at 48. Theoretical cache hit 97.6% and 97.2%.

### Off vs on

The off arm is from 2026-11-19 (same recipe, same owner stack, cdk): `j-d087a056-f4f6-4e97-80f4` at 32 and
`j-7d9c883d-ceec-418f-b4f0` at 48. The on arm is today. The off arm had neither write-back nor the offload.

| Concurrency | Tok/s per chip off → on | Throughput gain | Successful requests off → on | Requests gain | TTFT mean off → on | Mean speedup | TTFT p50 off → on | p50 speedup | TTFT p90 off → on | p90 speedup |
|---|---|---|---|---|---|---|---|---|---|---|
| 32 | 17,936 → 17,774 | -0.9% | 3,432 → 3,427 | -0.1% | 6.9 s → 6.2 s | 1.12x | 5.0 s → 5.3 s | 0.95x | 12.8 s → 10.8 s | 1.18x |
| 48 | 14,703 → 16,922 | **+15.1%** | 2,939 → 3,487 | **+18.6%** | 39.3 s → 21.2 s | 1.85x | 28.4 s → 19.4 s | 1.46x | 91.0 s → 37.6 s | 2.42x |

### Write-back alone against both on

Write-back alone was measured on 2026-11-19 (tree `sglang-agentx-wb`, prefill `MUSE_PREFILL_WRITE_POLICY=write_back`,
no offload to decode DRAM): `j-c7068825-9edb-4f75-bcf4` at 32 and `j-b79b6fed-ab27-4012-8846` at 48. Figures are the
job results stored in cdk.

| Concurrency | Arm | Job | Tok/s per chip | Output tok/s | Successful / total | p90 interactivity | TTFT mean | TTFT p50 | TTFT p90 |
|---|---|---|---|---|---|---|---|---|---|
| 32 | Off | `j-d087a056-f4f6-4e97-80f4` | 17,936 | 936 | 3,432 / 3,787 | 62.1 | 6.9 s | 5.0 s | 12.8 s |
| 32 | Write-back only | `j-c7068825-9edb-4f75-bcf4` | 18,697 | 964 | 3,538 / 3,892 | 62.6 | 5.6 s | 4.5 s | 10.2 s |
| 32 | Write-back + decode DRAM | `j-92cade4b-aa0e-4eac-902d` | 17,774 | 933 | 3,427 / 3,782 | 60.5 | 6.2 s | 5.3 s | 10.8 s |
| 48 | Off | `j-7d9c883d-ceec-418f-b4f0` | 14,703 | 809 | 2,939 / 3,471 | 74.2 | 39.3 s | 28.4 s | 91.0 s |
| 48 | Write-back only | `j-b79b6fed-ab27-4012-8846` | 18,190 | 1,027 | 3,706 / 4,238 | 53.3 | 19.1 s | 16.9 s | 33.2 s |
| 48 | Write-back + decode DRAM | `j-7cc4852a-5c96-4ab9-977c` | 16,922 | 953 | 3,487 / 4,018 | 50.0 | 21.2 s | 19.4 s | 37.6 s |

| Concurrency | Write-back only vs off, throughput | TTFT mean speedup | TTFT p90 speedup | Both on vs write-back only, throughput | TTFT mean speedup | TTFT p90 speedup |
|---|---|---|---|---|---|---|
| 32 | +4.2% | 1.23x | 1.25x | -4.9% | 0.91x | 0.94x |
| 48 | **+23.7%** | 2.06x | 2.74x | -7.0% | 0.90x | 0.88x |

- The gain at 48 comes from write-back. With decode DRAM added, throughput and TTFT are both worse than write-back alone.
- The two on arms ran on different trees (`sglang-agentx-wb` and `agentx-offload-scaleout`), so the difference is not
  proven to come from the offload switch alone.
- Today's both-on runs reproduce the both-on runs of 2026-11-19 (`j-40188fb3-0ae0-4e07-ad9b` 17,702 at 32,
  `j-4b22f5e5-d352-494a-b4cf` 16,834 at 48).
- `j-7d9c883d-ceec-418f-b4f0` ran 48 and then 64 in one job. cdk keeps only the last level in the job result, so its
  48 figures come from the archived bench log, and the dashboard shows only its 64 point.
- Dashboard: `d-026c5a6c-5efd-439d-86ef`.

A second off reference at 32 ran today on the ubench cluster (owner tree, neither feature). It was suspended 4 minutes
before the end of the measured phase (section 6), so it is partial: 56 of 60 minutes, computed from the per-request
records.

| Concurrency 32 | Tok/s per chip | p90 interactivity | TTFT mean | TTFT p50 | TTFT p90 |
|---|---|---|---|---|---|
| Off, partial (`alisachen-muse-pd-ctl2-c32`, ubench) | 17,848 | 61.1 | 6.2 s | 4.6 s | 11.2 s |
| On (`j-92cade4b-aa0e-4eac-902d`, cdk) | 17,774 | 60.5 | 6.2 s | 5.3 s | 10.8 s |
| Gain | -0.4% | -1.0% | 1.01x | 0.87x | 1.03x |

## 3. Comparison with the GPU curve

### Is it the same test?

| Item | GPU rows | TPU rows | Same? |
|---|---|---|---|
| Source | InferenceX API, `model=Muse-Spark-Open`, pulled 2026-11-24 | this report | — |
| Benchmark | `agentic_traces`, 3600 s measured | same | yes |
| Concurrency | concurrent replay sessions | same | yes |
| Throughput | total tok/s (input including cached, plus output) ÷ all chips, prefill and decode | same | yes |
| Interactivity | `p90_intvty` = 1 / p90 TPOT | `p90_interactivity_tok_s`, same formula | yes |
| Mean prompt | 126k–184k tokens depending on the point | 140k–149k | yes |
| Speculative decoding | draft model, real acceptance | draft model, **acceptance pinned** (accept length 4.05 in the decode log) | **no** |
| Client version | Nov 10 (GB300), Nov 19 (VR200) | Sep 22 build | **no** |
| KV offload | on (host DRAM) | on (decode DRAM) | yes |

Prices used for the per-dollar column: $1.21 per TPU7x chip-hour, $3.61 per VR200 GPU-hour, $2.31 per GB300 GPU-hour.
Tokens per dollar = tok/s per chip × 3600 ÷ price.

### Curve

| System | Prefill + decode chips | Concurrency | Tok/s per chip | vs TPU c32 | M tokens per $ | vs TPU c32 | p90 interactivity | TTFT p50 | TTFT p90 | Output tok/s per decode chip |
|---|---|---|---|---|---|---|---|---|---|---|
| **TPU7x P/D, on** | 4 + 4 | 32 | 17,774 | 1.00x | 52.9 | 1.00x | 60.5 | 5.3 s | 10.8 s | 233 |
| **TPU7x P/D, on** | 4 + 4 | 48 | 16,922 | 0.95x | 50.3 | 0.95x | 50.0 | 19.4 s | 37.6 s | 238 |
| VR200 P/D | 4 + 4 | 264 | 165,142 | 9.29x | 164.7 | 3.11x | 120.3 | 2.4 s | 8.6 s | 2,349 |
| VR200 P/D | 16 + 24 | 576 | 92,457 | 5.20x | 92.2 | 1.74x | 277.8 | 1.6 s | 5.6 s | 1,085 |
| VR200 P/D | 12 + 32 | 474 | 73,532 | 4.14x | 73.3 | 1.39x | 400.0 | 1.2 s | 4.7 s | 717 |
| VR200 P/D | 8 + 40 | 334 | 46,985 | 2.64x | 46.9 | 0.89x | 568.2 | 2.2 s | 7.8 s | 397 |
| GB300 P/D | 24 + 32 | 672 | 53,930 | 3.03x | 84.0 | 1.59x | 136.4 | 2.4 s | 4.8 s | 740 |
| GB300 P/D | 16 + 24 | 352 | 49,554 | 2.79x | 77.2 | 1.46x | 155.3 | 2.3 s | 4.4 s | 608 |
| GB300 P/D | 8 + 16 | 224 | 45,416 | 2.56x | 70.8 | 1.34x | 177.0 | 2.2 s | 3.8 s | 518 |
| GB300 P/D | 8 + 16 | 160 | 41,057 | 2.31x | 64.0 | 1.21x | 200.0 | 1.5 s | 3.6 s | 444 |
| GB300 P/D | 8 + 24 | 224 | 34,617 | 1.95x | 53.9 | 1.02x | 224.2 | 2.3 s | 4.1 s | 350 |
| GB300 P/D | 8 + 32 | 112 | 18,847 | 1.06x | 29.4 | 0.56x | 311.5 | 0.9 s | 4.2 s | 174 |
| GB300 P/D | 8 + 32 | 56 | 11,334 | 0.64x | 17.7 | 0.33x | 404.9 | 0.4 s | 2.1 s | 94 |
| GB300 P/D | 8 + 32 | 32 | 6,488 | 0.37x | 10.1 | 0.19x | 442.5 | 0.3 s | 1.1 s | 48 |
| GB300 P/D | 8 + 40 | 120 | 16,383 | 0.92x | 25.5 | 0.48x | 334.4 | 0.8 s | 4.0 s | 148 |

Reading it:

- **The GPU curve moves with concurrency; the TPU curve does not.** GB300 8+32 goes from 6,488 to 18,847 tok/s per
  chip between concurrency 32 and 112. TPU goes from 17,774 to 16,922 between 32 and 48: it is already at its ceiling.
- **At equal concurrency TPU is ahead per chip** (17,774 against 6,488 for GB300 8+32 at 32), because it uses 8 chips
  where the GPU row uses 40. The GPU rows trade that for interactivity above 400.
- **No TPU P/D point reaches the GPU interactivity range.** The lowest GPU P/D point is 120.3; TPU P/D is at 60.5.
  A comparison at equal interactivity is not possible with today's P/D decode.
- **Per decode chip, TPU produces 233 output tok/s.** VR200 4+4 produces 10x that at twice the interactivity; GB300
  8+16 produces 2.2x that at three times the interactivity.

### The aggregated submission branch is ahead of P/D on TPU

From the results file of `inferencex/musespark_submission` (single host, 4 chips, megakernel v2 decode and the
megakernel prefill program; job ids are
abbreviated in that file, so they are not repeated here):

| TPU7x configuration | Chips | Concurrency | Tok/s per chip | M tokens per $ | p90 interactivity |
|---|---|---|---|---|---|
| P/D, owner stack, on (today) | 8 | 32 | 17,774 | 52.9 | 60.5 |
| Aggregated, submission branch | 4 | 22 | 31,039 | 92.3 | 115.8 |
| Aggregated, submission branch | 4 | 26 | 31,447 | 93.6 | 111.7 |

Four chips doing prefill and decode together on the submission branch deliver 87% of the total tokens of today's
8-chip P/D, at twice the interactivity. Per dollar that point is above every GB300 P/D point and at 56% of VR200 4+4.
Today's P/D decode already runs the decode megakernel, in the version of early November (the tree forked around
2026-11-05); the prefill runs without any megakernel. The P/D path has to pick up the newer decode and a megakernel
prefill before more chips pay off.

## 4. Headroom analysis

All figures in this section are from the prefill stage-0 and decode rank-0 logs of the two runs, inside the measured
hour. Times derived from queue lengths use requests in a state ÷ request rate.

### 4.1 Throughput is set by the decode output rate

Throughput per chip = request rate × mean tokens per request ÷ chips. The request rate cannot exceed the decode output
rate ÷ mean output tokens (about 990).

| | Concurrency 32 | Concurrency 48 | Change |
|---|---|---|---|
| Decode output tok/s (4 chips) | 933 | 953 | +2% |
| Requests per s | 0.946 | 0.962 | +2% |
| Requests decoding at a time, mean | 9.3 | 13.1 | +41% |
| Median per-request speed (tok/s) | 91.4 | 64.4 | -30% |

Adding sessions adds decode batch, and the decode gives each request proportionally less. Decode output rate against
batch size at concurrency 32:

| Requests decoding | Samples | Decode output tok/s | Tok/s per request |
|---|---|---|---|
| 1–3 | 331 | 637 | 425 |
| 4–7 | 633 | 869 | 158 |
| 8–11 | 535 | 931 | 98 |
| 12–15 | 488 | 990 | 73 |
| 16–19 | 198 | 1,053 | 60 |
| 20–23 | 55 | 1,137 | 53 |
| 24–27 | 18 | 1,184 | 46 |

- Batch grows 6x from the second row to the last; output grows 1.36x. The step time is close to linear in batch,
  about 4 ms per request per step at a 150k-token context (accept length 4.05).
- This is the main headroom item. The ceiling of this decode is about 1,000–1,200 output tok/s on 4 chips, which caps
  the 8-chip system near 18–22k tok/s per chip at any concurrency.

### 4.2 Decode HBM for KV runs out between 32 and 48

| Decode rank 0 | Concurrency 32 | Concurrency 48 |
|---|---|---|
| KV pool usage, mean | 58% | 83% |
| KV pool usage, p50 / p90 | 62% / 96% | 97% / 99% |
| Requests waiting for decode memory (pre-allocation), mean | 0.3 | 10.4 |
| Time waiting for decode memory per request (derived) | 0.3 s | 10.8 s |
| Requests in the transfer state, mean | 4.4 | 8.5 |
| Time in the transfer state per request (derived) | 4.7 s | 8.8 s |
| Retracted requests | 0 | 0 |

- The pool holds about 4.41M tokens, which is 29 sessions of mean length. At 32 sessions it is full at the 90th
  percentile; at 48 it is full half the time.
- At 48, half of the 21.2 s mean TTFT is waiting for decode memory. The decode DRAM store keeps that from turning into
  the collapse seen without it (14,703 tok/s per chip at 48, 3,470 at 64 on 2026-11-19).
- At 32 the pool holds about 2.57M tokens for 9.3 decoding requests, so close to half of it is sessions that are not
  decoding at that moment.

### 4.3 Prefill is not the limit at 32, and is under cache pressure at 48

| Prefill stage 0 | Concurrency 32 | Concurrency 48 |
|---|---|---|
| Queue length, mean / p90 / max | 0.27 / 1 / 11 | 1.39 / 5 / 15 |
| Arrival to admission, mean / p90 | 1.6 s / 3 s | 3.3 s / 5 s |
| New tokens computed per s | 4,393 | 7,642 |
| Cache hit (prefill side) | 96.9% | 94.4% |
| Share of hits served from host memory | 34% | 77% |
| Cached tokens per request from HBM / from host | 96.5k / 48.3k | 30.4k / 101.7k |
| Write-back pushes done | 985 | 1,721 |
| Push duration, mean / p90 | 3.5 s / 4.5 s | 5.3 s / 6.5 s |
| Recall offers / pulled from the decode | 1,916 / 175 | 1,409 / 155 |

- At 32 the prefill is idle between requests most of the time. Its saturation point was not measured.
- At 48 the prefill HBM cache no longer holds the working set: most of each prompt comes back from host memory, the
  hit rate drops 2.5 points, and new tokens per second rise 74% for 2% more requests.
- About 90% of recall offers are declined because the prefill still has the session locally. The decode store is used for
  about 5% of requests at both levels.

### 4.4 Time to first token

| Component (derived) | Concurrency 32 | Concurrency 48 | VR200 4+4 at 264 |
|---|---|---|---|
| Prefill arrival to admission | 1.6 s | 3.3 s | — |
| Decode waiting for memory | 0.3 s | 10.8 s | — |
| Decode transfer state (prefill forward plus KV transfer) | 4.7 s | 8.8 s | — |
| TTFT mean, measured | 6.2 s | 21.2 s | 5.7 s |
| TTFT p50, measured | 5.3 s | 19.4 s | 2.4 s |

The components overlap (a request waits in the decode while the prefill runs), so they do not add up exactly. The
split between prefill forward and KV transfer inside the 4.7 s is not logged per request; it is the next thing to
measure. Raiden plan dispatch itself is small (15 ms median).

### 4.5 What each lever is worth

Estimates from the measurements above, not runs. Each assumes the other stages keep up.

| Lever | Stage | Evidence | Estimated effect on the 8-chip point |
|---|---|---|---|
| Current megakernel (v2, block-256 experts) in the P/D decode, megakernel prefill program on the prefill | decode, prefill | 4 aggregated chips do 31k tok/s per chip at p90 115.8 on the submission branch; today's decode already runs the early-November megakernel, and the prefill program needs TP8 while the P/D prefill is PP8 | Unknown until measured. The aggregated figure is not a P/D estimate |
| Drop idle sessions from decode HBM sooner (stage store is already there) | decode | half of the pool is non-decoding sessions at 32; 10.8 s memory wait at 48 | Removes most of the 10.8 s at 48; lets concurrency rise past 48 without the TTFT cliff |
| 1 prefill host to 2 decode hosts (4 + 8 chips) | topology | prefill queue 0.27 at 32; decode saturated | Up to about 24k tok/s per chip (+34%) if the prefill sustains 1.9 requests per s |
| Larger prefill HBM cache or session-affine eviction | prefill | 77% of hits from host memory at 48 | Lower TTFT at 48 and above; small throughput effect while the decode is the limit |
| Shorter transfer state | P/D transfer | 4.7 s per request at 32 against 2.4 s total TTFT p50 on VR200 | TTFT only; needs the per-request split first |

Distance to the GPU curve:

| Target | Needs, on 8 chips | Against today |
|---|---|---|
| Best GB300 point per dollar (84.0M tokens per $) | 28.2k tok/s per chip, 1.5 requests per s | 1.59x |
| VR200 4+4 per dollar (164.7M tokens per $) | 55.4k tok/s per chip, 2.95 requests per s, 2,900 output tok/s, at p90 interactivity 120 | 3.1x throughput and 2x interactivity |
| VR200 4+4 per chip (165k tok/s per chip) | 8.8 requests per s | 9.3x; not reachable by tuning this configuration |

No lever above is shown to reach the best GB300 point per dollar on its own.

## 5. Offload activity

| Run | Pushes proposed / done | Recall offers | Pulled | Declined (still local) | Prefill host evictions | Decode stage: landed / declined | Decode stage pages evicted |
|---|---|---|---|---|---|---|---|
| c32 `j-92cade4b-aa0e-4eac-902d` | 992 / 985 | 1,916 | 175 | 1,742 | 487 | 1,132 / 5 | 336,315 |
| c48 `j-7cc4852a-5c96-4ab9-977c` | 1,755 / 1,721 | 1,409 | 155 | 1,254 | 548 | 2,010 / 17 | 1,055,215 |

Decode-stage counters are totals at the end of each job (warm-up included); the others are for the measured hour.
At 48 some pushes ended with `DEADLINE_EXCEEDED, await_pull` (34 proposed pushes did not complete). No request failed.

## 6. Problems met, and where each one was

| # | Problem | Where | Cause | Outcome |
|---|---|---|---|---|
| 1 | Submission-branch decode exits at start-up with `KeyError: <PoolName.SWA: 'swa'>` | decode | the decode host cache is full-attention only and the all-SWA draft sidecar is registered into it | fixed locally by skipping the registration for an SWA draft (the owner stack already has the same fix) |
| 2 | Submission branch with the sequence-along-lane draft option: `ValueError: Raiden swa layers have differing page layouts` | P/D transfer set-up, decode side | layout mismatch between draft and main SWA pools | option dropped |
| 3 | Submission-branch PP8 prefill hangs at warm-up, all 8 chips reported stalled | prefill | not found. It hangs right after scheduling the program that relays auxiliary hidden states across pipeline stages. Same on tpu-sync wheels 1013 and 1029; the owner tree passes warm-up on the same cluster | **open**. P/D cannot run on the submission branch until this is fixed |
| 4 | Prefill exits with `UnsupportedDramOffloadConfig` after 22 minutes | P/D transfer, prefill-side start-up check | my submission used the image's tpu-sync wheel, which has no host-to-host read API | resubmitted with wheel `0.0.1.dev20261112081648` |
| 5 | Jobs on the ubench cluster killed after 8 and 26 minutes | infrastructure | the queue placed them on spot nodes when the reserved nodes were full, and the nodes were reclaimed | pinned the reservation in the port script |
| 6 | Control job on ubench suspended at 120 minutes, 4 minutes before the end | infrastructure | the namespace has a 120-minute limit; a full run needs about 125 | limit left alone; full runs moved to cdk |
| 7 | One job on ubench lost at 14 minutes | infrastructure | host maintenance on a reserved node | resubmitted |
| 8 | c48 job preempted once at start | infrastructure | spot node reclaimed | cdk retried it automatically; the measured run was not interrupted |

## 7. Caveats

- One run per point.
- The off arm at 48 is five days older than the on arm; the tree gained scale-out router commits in between.
- Sections 3 to 5 use today's both-on runs. Write-back alone is 5% to 7% faster (section 2), so the TPU points in the
  GPU comparison are slightly below the best measured TPU points (18,697 at 32: 55.6M tokens per dollar).
- All runs here use a tree forked around 2026-11-05: decode on the megakernel of that date, prefill without it.
- TPU acceptance is pinned; GPU acceptance is real. Interactivity and output rate depend on it directly.
- The lever estimates in 4.5 are not measurements.
- The aggregated submission-branch figures are taken from that branch's results file, not rerun here.

## 8. Next steps

1. Find the PP8 prefill warm-up hang on the submission branch (diff its PP relay path against the owner tree), so the
   current megakernel can be measured in P/D; or run the prefill at TP8 with the megakernel prefill program.
2. Log the per-request split of the transfer state (prefill forward against KV transfer).
3. Measure the prefill saturation point alone, to size a 4 + 8 configuration.
4. Rerun 32, 48 and 64 on the fixed branch with write-back alone and with both on, from one tree.
