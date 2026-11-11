# CDK runs, 2026-11-09: sticky-route layouts on tpu7x (PR 1992 head 72ac13d3bf, Qwen3-30B-A3B FP8, write-back)

Cluster cloud-devkit-gke, one TP8/EP8 engine per 2x2x1 tpu7x host, recipe `recipes/cdk/pd1992-qwen3-30b-xpyd.jsonnet`,
stage `harness/cdk/stage_layout.sh` (same seeds and sizes as `harness/goal/goal_baseline.sh`: 128k+8k sessions, 16
output tokens, concurrency 4). Prefill-side hit = prefill `/metrics` cached/prompt delta over the case. Outputs synced
under `~/cloud-devkit-data/job-outputs/<job>/pd1992/` on the launch VM.

## 1P2D, switch on (j-9d10ae8e-8b7f-405f-b13c, 06:57-07:06 UTC)

| Case | Requests | Prefill-side hit | Client-side hit | TTFT p50 / p95 |
|---|---|---|---|---|
| sticky: 8 sessions pinned to decode 0 | 16/16 | 48.5% | 100.0% | 5.6 s / 7.7 s |
| sticky: 8 sessions pinned to decode 1 | 16/16 | 46.0% | 94.7% | 10.9 s / 11.2 s |
| random decode: 16 sessions | 32/32 | 18.9% | 38.8% | 19.4 s / 28.1 s |

Engine health: 0 exceptions on all three engines. Transfers: prefill started=130 stored=130; decode-0 landed 77
(2,092,160 tokens), decode-1 landed 53 (1,745,792 tokens); 0 refused pulls, 0 warnings. Bare metal (a -> v7 + b, 11-07)
measured 50.7 / 49.3% sticky and 45.0% random.
B3 rank consistency (`harness/cdk/rank_consistency.py` over the three server logs): started/stored on the prefill and
received/granted/landed/landed_tokens on both decodes are identical on all 8 ranks (verdict EQUAL).

## Infrastructure notes

- Smoke j-932a1497: every rank died creating the Raiden host pool, `ImportError: libibverbs.so.1`: tpu-sync-torch >=
  dev20261029's torch extension links libibverbs, which the sglang-torchtpu:20261103 image lacks. The recipe installs
  libibverbs1 and fail-fast loads the extension at container start.
- 1P1D j-5f9763b7: the prefill's TPU init failed with `START_SESSION failed` on a host another job had just left (the
  teardown race, I1); the server script now retries init up to three times, 120 s apart. CDK rejects hostname
  node-affinity rules, so a host cannot be excluded from a recipe.

## 2P1D, switch on, no keep-alive (j-c8ba3c67-9137-42a2-a550, 07:16-07:24 UTC)

| Case | Requests | Prefill-side hit | Client-side hit | TTFT p50 / p95 |
|---|---|---|---|---|
| fill via prefill 0, 12 sessions | 12/12 | 0.0% (cold) | | |
| cross-prefill return via prefill 1 | 12/12 | 0.0% | 0.0% | 32.5 s / 34.3 s |
| return via prefill 0 again | 12/12 | 52.9% | 56.9% | 15.2 s / 28.9 s |
| random prefill: 16 sessions | 32/32 | 28.3% | 58.4% | 10.8 s / 19.6 s |

0 exceptions. Transfers: prefill-0 started=46 stored=45, prefill-1 started=11 stored=10; decode received=53 granted=51
no_room=2 (declined pushes, back-pressure) landed=49 (1,828,608 tokens); 0 refused pulls. B3: EQUAL on all 8 ranks of
all three engines (6 pulls per rank on prefill-0). The 0% cross-prefill hit right after the fill is the same
observation as bare metal on 11-07 (the decode had landed nothing yet: pushes need host pressure and a serving
prefill; bare metal naive: 0% then 70.6% back through the first prefill; with the keep-alive procedure 65.2% / 76.8%).
The rerun g1992b_2p1d_2 adds the keep-alive step before the cross-prefill return.

## 1P1D, switch on (j-ab845772-718f-428c-83b1, 07:36-07:44 UTC; first attempt lost its spot node, auto-retried)

| Case | Requests | Prefill-side hit | Client-side hit | TTFT p50 / p95 |
|---|---|---|---|---|
| sticky fill (p0,d0), 12 sessions | 12/12 | 0.0% (cold) | | |
| sticky return (p0,d0) | 12/12 | 53.8% | 57.0% | 15.0 s / 21.3 s |
| 16 sessions fill+recall via lb | 32/32 | 29.8% | 80.1% | 15.8 s / 21.9 s |

0 exceptions. Transfers: prefill started=94 stored=94; decode received=94 granted=94 landed=94 (2,919,296 tokens);
17 recall commits, 1,367,808 tokens pulled from decode DRAM; 0 refused pulls. B3: EQUAL on all 8 ranks (17 pulls per rank).

## 1P1D, switch off (j-929dec4a-9beb-4002-931d, 07:36-07:45 UTC): 56/56 requests, 0 exceptions, no pushes (switch off)

## Switch on vs off, write-back on both arms (`harness/cdk/compare_cdk.py`, prefill-side hit)

1P2D off: j-71c8baa2-69ae-4970-bc8f (07:55-08:04 UTC), 64/64 requests, 0 exceptions. 2P2D off: j-7a4f2a3f-43fa-4ffb-a9c4
(09:19-09:31 UTC, with keep-alive), 92/92 requests, 0 exceptions. 2P1D: on arm = the keep-alive rerun g1992b_2p1d_2
(j-06f7f9de-b73d-4b71-9d71, 09:42-09:50 UTC, 92/92, 0 exceptions, B3 EQUAL), off arm = j-51058d22 (keep-alive). Where the sessions fit in the serving prefill's own
host tier (8-session sticky cases; 16 random sessions spread over two prefills) the off arm matches or beats the on arm,
which pays push work for no gain: the plan's open item A6. Where the serving prefill no longer holds the branch (1P1D
and 1P2D overflow cases, every cross-prefill route in 2P2D) the on arm recalls from decode DRAM and the off arm recomputes.

| Layout | Case | Requests on / off (failed) | Prefill-side hit on -> off | TTFT p50 on -> off | TTFT p95 on -> off | E2E p50 on -> off |
|---|---|---|---|---|---|---|
| 1P1D | sticky: 12 sessions on the pair | 12 / 12 (0 / 0) | 53.8% -> 27.0% | 15.0 s -> 26.4 s | 21.3 s -> 32.9 s | 15.2 s -> 26.6 s |
| 1P1D | 16 sessions via the lb | 32 / 32 (0 / 0) | 29.8% -> 0.0% | 15.8 s -> 32.4 s | 21.9 s -> 33.4 s | 16.0 s -> 32.5 s |
| 1P2D | sticky: 8 sessions pinned to decode 0 | 16 / 16 (0 / 0) | 48.5% -> 47.0% | 5.6 s -> 3.5 s | 7.7 s -> 4.4 s | 7.1 s -> 4.3 s |
| 1P2D | sticky: 8 sessions pinned to decode 1 | 16 / 16 (0 / 0) | 46.0% -> 48.5% | 10.9 s -> 3.2 s | 11.2 s -> 4.8 s | 11.8 s -> 3.5 s |
| 1P2D | random decode: 16 sessions | 32 / 32 (0 / 0) | 18.9% -> 0.0% | 19.4 s -> 32.4 s | 28.1 s -> 33.5 s | 19.6 s -> 32.6 s |
| 2P1D | cross-prefill: filled via prefill 0, returned via prefill 1 | 12 / 12 (0 / 0) | 54.9% -> 0.0% | 13.1 s -> 32.5 s | 24.4 s -> 34.4 s | 13.3 s -> 32.6 s |
| 2P1D | returned via prefill 0 again | 12 / 12 (0 / 0) | 73.9% -> 0.0% | 12.0 s -> 32.4 s | 12.4 s -> 33.4 s | 12.2 s -> 32.6 s |
| 2P1D | random prefill: 16 sessions | 32 / 32 (0 / 0) | 29.1% -> 30.3% | 9.5 s -> 8.7 s | 23.1 s -> 17.9 s | 9.6 s -> 8.9 s |
| 2P2D | other prefill, same decode | 12 / 12 (0 / 0) | 47.5% -> 0.0% | 13.3 s -> 32.5 s | 31.6 s -> 34.2 s | 13.5 s -> 32.6 s |
| 2P2D | same prefill, other decode | 12 / 12 (0 / 0) | 2.2% -> 0.0% | 32.5 s -> 32.4 s | 33.0 s -> 33.4 s | 32.6 s -> 32.6 s |
| 2P2D | other prefill, other decode | 12 / 12 (0 / 0) | 48.5% -> 25.3% | 14.4 s -> 27.6 s | 29.6 s -> 32.4 s | 14.5 s -> 27.8 s |
| 2P2D | random prefill and decode: 16 sessions | 32 / 32 (0 / 0) | 17.2% -> 21.2% | 13.6 s -> 9.7 s | 19.7 s -> 25.2 s | 13.7 s -> 9.8 s |


## gpt-oss-120b hybrid (PR 1991 dd9a2784f7), 1P1D, switch on, edges stage (j-3ce93d4a-b86e-4bf1-9f44, 07:53-08:02 UTC)

Startup clean on the hybrid tree: SWA KV pool 628,736 tokens, host SWA pool with 128 path-end windows on the decode,
Raiden SWA engine up on both roles, 0 exceptions. E1 (victim_integrity.py, 16 sessions 128k+8k): fill 16/16, recall
16/16 with 15 of 16 served from host RAM (139,264 cached tokens each) and 3 of those from the device tree; prefill
pushed started=33 stored=33, decode landed 33 (3,350,528 tokens). Recall-vs-recompute: 0/16 exact, agreement 5-27 of 64
tokens on the recalled sessions, but also only 46/64 on the one session that was NOT recalled, and 14-27 on the three
served from the device tree without any host or DRAM transfer. The recall phase ran at concurrency 4 and the recompute
one request at a time, and the prompts (139k tokens) exceed the model's derived context of 131,072 (engine warning
"may lead to incorrect model outputs"), so this comparison is not an exactness test (I7): the mismatch is not
attributable to the offload. Concurrent probes: 76/84 exact (first divergence at tokens 12-119). E2 ran into a spot
preemption of the prefill host (TerminationByKubelet) and the job was deleted; rerun g1991h_edges_c1 runs E1 with a
single-request recall phase plus E6 (hybrid_window_edges.py, single request throughout), and the same stage runs on the
Qwen PR 1992 tree as a control.

## 2P2D, switch on, with keep-alive (j-d84ed13e-8d17-438e-9a46, attempt 2 08:39-08:50 UTC; attempt 1 lost a spot host)

A5 on four hosts: prefills p0, p1 and decodes d0, d1; fill 12 sessions via (p0,d0), 24 short keep-alive sessions on
p0 so it pushes the filled branches, then the returns through the other routes, then random routing.

| Case | Requests | Prefill-side hit | TTFT p50 / p95 |
|---|---|---|---|
| fill (p0,d0), 12 sessions | 12/12 | 0.0% (cold) | |
| keep-alive on p0, 24 short sessions | 24/24 | 0.0% | |
| return (p1,d0): other prefill, same decode | 12/12 | 47.5% | 13.3 s / 27.0 s |
| return (p0,d1): same prefill, other decode | 12/12 | 2.2% | 32.5 s / 33.0 s |
| return (p1,d1): other prefill, other decode | 12/12 | 48.5% | 14.4 s / 29.6 s |
| random prefill and decode, 16 sessions | 32/32 | 17.2% | 13.6 s / 19.7 s |

0 exceptions on all four engines. Transfers: p0 started=184 stored=184, p1 started=69 stored=69; d0 landed 223
(3,086,208 tokens), d1 landed 30 (1,659,264 tokens); p1 committed 12 recalls (1,349,632 tokens pulled from decode
DRAM); 0 refused pulls, 0 warnings. B3: EQUAL on all 8 ranks of all four engines. Reading: the cross-prefill return
hits because d0 holds the pushed branches and offers them to whichever prefill serves the session; (p0,d1) finds
nothing because d1 never held them and p0 had evicted them; (p1,d1) hits because p1 had just pulled the branches into
its own host tier during the (p1,d0) case. The bench appended attempt 2's records to attempt 1's files (I13); the
synced jsonl files were trimmed to attempt 2 by t_start, and the stages now move earlier records aside at start.

## 2P1D, switch off, with keep-alive (j-51058d22-4092-43f8-8a0e, attempt 3 09:24-09:34 UTC; two spot preemptions before)

| Case | Requests | Prefill-side hit | TTFT p50 / p95 |
|---|---|---|---|
| fill via prefill 0, 12 sessions | 12/12 | 0.0% (cold) | |
| keep-alive on prefill 0, 24 short sessions | 24/24 | 0.0% | |
| cross-prefill return via prefill 1 | 12/12 | 0.0% | 32.5 s / 34.4 s |
| return via prefill 0 again | 12/12 | 0.0% | 32.4 s / 33.4 s |
| random prefill, 16 sessions | 32/32 | 30.3% | 8.7 s / 17.9 s |

0 exceptions. Without the offload the keep-alive load evicts the filled sessions from prefill 0's host tier for good
(0% on the return via prefill 0; the switch-on run without keep-alive still had 52.9% there, and the keep-alive
switch-on rerun g1992b_2p1d_2 is the matching on arm for the cross-prefill row).

## Output equivalence (B1/H3) on CDK: the probe thread makes the concurrent recall phase inexact

Qwen PR 1992, 1P1D, switch on, write-back (j-516ea799-78f9-435c-b7d7, 09:45-09:53 UTC): victim_integrity.py with a
single-request recall phase (--concurrency 1) but the background probes still running gave 11/16 recalls exact (the
five others agreed 11-41 of 64 tokens), 14 of 16 recalls served from host RAM, 0 exceptions. Every recall request
overlapped three in-flight probe requests, so recalls were batched with probes while the recompute ran alone: on TPU
that changes greedy outputs (I7), and the probe mismatch positions (11, 14, 16, 19, 24) show the same batch noise.
The gpt-oss hybrid run at 08:00 (0/16 exact at concurrency 4, including the session that was never recalled) has the
same explanation. victim_integrity.py now takes --probe-phases (default fill,settle,recall); the CDK edges stage
passes fill,settle so the recall phase runs with nothing else in flight. Quiet reruns: g1992b_edges_e1q
(j-138ee1b7-ca6a-44e5-a79b) and g1991h_edges_e1q with the hybrid window edges (j-66e98ce0-4f79-4b02-971c).

## gpt-oss-120b hybrid (PR 1991 dd9a2784f7), 1P1D, H1 ladder, write-back, switch on (j-b373b475-325d-4e56-8a37, 09:39-09:57 UTC)

| Point | Requests | Prefill-side hit | TTFT p50 / p95 | bare metal (11-07/08) |
|---|---|---|---|---|
| recall 8 sessions | 16/16 | 48.5% | 4.1 s / 4.8 s | 82.6% |
| recall 12 sessions | 24/24 | 28.6% | 13.8 s / 15.3 s | 55.0% |
| recall 16 sessions | 32/32 | 36.4% | 8.3 s / 9.1 s | 76.7% |
| static 4 docs | 12/12 | 62.7% (ceiling) | | 62.7% |
| static 8 docs | 24/24 | 56.1% | | 55.8% |
| static 12 docs | 36/36 | 34.4% | | 30.4% |
| static 16 docs | 48/48 | 28.3% | | 21.3% |

0 exceptions. Transfers: prefill started=104 stored=104; decode landed 104 (7,660,352 tokens); 15 recall commits,
2,080,960 full-attention tokens plus 1,920 SWA tokens pulled (15 x one 128-token window: each recalled branch came
back with its last sliding window, as the design says); 0 refused pulls, 0 warnings. B3: EQUAL on all 8 ranks of both
engines. The static points match bare metal; the recall points are lower than bare metal's and need the off arm
(j-948b5f8f, running) before reading anything into them.

## Qwen PR 1992, 1P1D, switch on, write-back, edges E2/E3 (j-516ea799-78f9-435c-b7d7, 09:53-10:00 UTC)

- E2 (C1): concurrent recalls after a prefill-only flush OK (149 s), client aborts mid-recall OK (79 s); 92 health
  samples all 200, 0 slow probes, 0 probe errors.
- E3 (C2): /flush_cache on both engines 30 s into a static run refused with 400 while transfers were in flight; the
  run completed 24/24 with 62.7% prefill-side hit; both engines healthy after.
- 0 exceptions throughout. (E1 of this job ran with probes in flight; see the equivalence section above.)

## Output equivalence, quiet recall phase (B1 / H3): PASS on both trees

With the probes confined to fill and settle and the recall phase one request at a time, recall equals recompute
token for token:

| Tree / model | Job | Recalls compared | Exact | From decode DRAM |
|---|---|---|---|---|
| PR 1992, Qwen3-30B-A3B FP8 (full attention) | j-138ee1b7-ca6a-44e5-a79b, 10:11-10:20 UTC | 16 | 16/16 (min agree 64/64) | 13 of 16 |
| PR 1991, gpt-oss-120b (hybrid SWA + full) | j-66e98ce0-4f79-4b02-971c, 10:13-10:20 UTC | 16 | 16/16 (min agree 64/64) | 14 of 16 |

Both runs: 0 request errors, 0 engine exceptions, probes during fill/settle 76/92 and 75/91 exact (concurrent, so
batch noise, as before). On the hybrid every recalled session came back with 139,264 cached tokens from host RAM, so
the full-attention pages and the SWA window recalled from decode DRAM reproduce the recompute exactly. This is the
KV-transfer correctness result for the SWA + full-attention offload; the earlier 0/16 and 11/16 figures were the
concurrent-batch artifact described above, not a transfer defect.

## gpt-oss-120b hybrid (PR 1991), 1P1D, H1 ladder, write-back on both arms: switch on vs off

Off arm: j-948b5f8f-9c08-4f4e-a89d (10:02-10:21 UTC, after two spot preemptions), 196/196 requests, 0 exceptions.

| Point | Requests on / off | Prefill-side hit on -> off | TTFT p50 on -> off | bare metal off -> on (11-07/08) |
|---|---|---|---|---|
| recall 8 sessions | 16 / 16 | 48.5% -> 36.7% | 4.1 s -> 3.0 s | 83.9 -> 82.6 |
| recall 12 sessions | 24 / 24 | 28.6% -> 12.1% | 13.8 s -> 19.7 s | 26.4 -> 55.0 |
| recall 16 sessions | 32 / 32 | 36.4% -> 0.0% | 8.3 s -> 25.7 s | 0 -> 76.7 |
| static 4 docs | 12 / 12 | 62.7% -> 62.7% | | 62.7 -> 62.7 |
| static 8 docs | 24 / 24 | 56.1% -> 54.3% | | 62.5 -> 55.8 |
| static 12 docs | 36 / 36 | 34.4% -> 30.0% | | 50.9 -> 30.4 |
| static 16 docs | 48 / 48 | 28.3% -> 21.7% | | 39.6 -> 21.3 |

On CDK the spill-over wins at every recall point past 8 sessions and does not lose on the static ladder, unlike the
bare-metal static loss ("one window per branch under write-back"). The difference is in the off arm: CDK's off arm
hits less than bare metal's (recall 8: 36.7 vs 83.9%; static 12: 30.0 vs 50.9%), while the on arms differ less on
the static points. The bare-metal off arm ran the pre-rename tree with SGLANG_TPU_ENABLE_PD_PREFILL_SWA_PATH_END_BACKUP=1
(the prefill keeps each path's last SWA window in its own host RAM, which upstream does not); on the dd9a2784f7
tree that env is gone, so whether the off arm's prefill host tier can serve hybrid hits at all is the thing to check
(see the SWA setup lines in the prefill logs, next section).

Checked: both arms' prefills set up the same SWA host tier ("Allocating swa hierarchical KV host pool: 754,496
tokens", "PD prefill SWA HiCache: host RAM keeps only the last SWA window of each path"), so the off arm does keep
path-end windows on the dd9a2784f7 tree and the comparison is like for like. Prefill batch sums over the whole
ladder: host-hit tokens 3,514,944 (on) vs 1,073,280 (off); HBM-hit tokens 6,793,280 vs 6,010,432. Why CDK's off arm
hits less than the bare-metal off arm (same engine flags and pool sizes) is open; the on-vs-off deltas above are the
result to carry, the absolute levels need a bare-metal rerun on the same head to compare.

## gpt-oss hybrid window edges (H5), single request throughout (j-66e98ce0-4f79-4b02-971c, E6 10:20-10:25 UTC)

16 sessions filled (pushes stored=53, decode landed 53, 5,218,368 tokens, B3 EQUAL), then one edge-shaped return per
case; after a flush of both engines every return prompt was recomputed from scratch and compared token for token:

| Case | Served from at the return (prefill log) | Agree | Exact |
|---|---|---|---|
| W1 standard return | pulled from decode DRAM, 139,264 tokens + 128-token SWA window ([prefix-pull], host-hit 139,264) | 64/64 | yes |
| W2 fill prompt + exactly one page | pulled from decode DRAM, 139,264 + SWA window (host-hit 139,264) | 64/64 | yes |
| W3 branch extended, then the shorter fill prompt returns | prefill device tree, hbm-hit 139,264 | 64/64 | yes |
| W4 4k prompt, then the 128k fill, then its return | prefill device tree, hbm-hit 139,264 (no transfer) | 0/64 | NO |
| W5 fill prompt cut back to mid-window | recomputed on the prefill (cached 0; the client-side 139,136 is the decode's view) | 64/64 | yes |

The only miss was served entirely from the prefill's own device tree (hbm-hit 139,264, no host or DRAM transfer), so
it is not a transfer defect; the two returns that did recall from decode DRAM with their SWA window were exact. It it points at the hybrid SWA device-cache match on a forked path (a 4k branch and a
128k branch sharing the first 4,096 tokens). Attribution runs: E6 alone with the switch off (g1991h_e6_false) and on
(g1991h_e6_true) on the same tree. 0 exceptions on both engines throughout.

Attribution (E6 alone, same tree, same seeds): switch on again (j-709deabb-541a-4450-950c, 10:36-10:41 UTC) and switch
OFF (j-3b2eb522-a670-4827-af6d, 10:38-10:43 UTC) both give 4/5 exact with the same miss, W4 at 0/64, in both cases
served from the prefill's device radix tree (hbm-hit 139,264; the long fill itself had matched 4,096 device tokens of
the earlier 4k branch). The W4 behaviour is therefore deterministic and unrelated to the KV offload to decode DRAM: it
reproduces with the switch off, where no push, offer or pull exists. It belongs to the hybrid SWA device-cache path
after a forked prefix (a 4k request, then a 128k request sharing its first 4,096 tokens, then the 128k request's
return) on the dd9a2784f7 tree; whether upstream main shows it too is the follow-up (run W4 on upstream, no P/D).
All five cases are exact when the return is served from host RAM, from decode DRAM (with its SWA window) or recomputed.

## gpt-oss-120b hybrid (PR 1991 dd9a2784f7), sticky-route layouts, write-back on both arms, switch on vs off (21:25-23:00 UTC)

Jobs: 1P2D on j-b52d12fe-1982-48d3-a8f6 / off j-03b2fc21-a6e8-4a12-b968; 2P1D on j-b75c8289-5922-4acf-8313 / off
j-45098ee9-85d1-4c3d-b105 (attempt 2; attempt 1 lost a spot host in the random case after the sticky cases, which gave the
same numbers); 2P2D on j-f7779c4e-8d89-4008-b14e (attempt 4 after three spot losses: one TerminationByKubelet mid-stage,
two UnschedulableOnAssignedNode right after placement) / off j-21fb1534-3f8a-4327-b9e9 (attempt 2). Same engine flags as
the H1 ladder (SGLANG_TPU_PD_SWA_HOST_WINDOWS=128 both roles, page 64), keep-alive on prefill 0 in 2P1D/2P2D. Every
request completed on both arms (1P2D 64, 2P1D 92, 2P2D 104 per arm), 0 engine exceptions, B3 EQUAL on every engine of
every on-arm job.

| Layout | Case | Prefill-side hit on -> off | TTFT p50 on -> off |
|---|---|---|---|
| 1P2D | sticky, 8 sessions pinned to decode 0 | 44.6% -> 47.5% | 3.7 s -> 2.6 s |
| 1P2D | sticky, 8 sessions pinned to decode 1 | 48.5% -> 42.5% | 2.8 s -> 2.9 s |
| 1P2D | random decode, 16 sessions | 27.3% -> 0.0% | 13.7 s -> 25.8 s |
| 2P1D | cross-prefill return via prefill 1 | 70.8% -> 0.0% | 9.4 s -> 25.8 s |
| 2P1D | return via prefill 0 again | 79.6% -> 0.0% | 7.8 s -> 25.7 s |
| 2P1D | random prefill, 16 sessions | 27.3% -> 18.2% | 6.7 s -> 12.6 s |
| 2P2D | (p1,d0) other prefill, same decode | 70.8% -> 0.0% | 9.3 s -> 25.8 s |
| 2P2D | (p0,d1) same prefill, other decode | 0.0% -> 0.0% | 25.7 s -> 25.7 s |
| 2P2D | (p1,d1) other prefill, other decode | 41.7% -> 25.0% | 13.4 s -> 19.4 s |
| 2P2D | random prefill and decode, 16 sessions | 24.3% -> 12.1% | 9.1 s -> 13.0 s |

Transfers (on arm): 1P2D prefill pushed 39/39, decodes landed 22 + 21 (4.45M tokens), 9 recalls with their SWA windows
(1,152 SWA tokens on TP0). 2P1D prefill 0 pushed 33/33 and prefill 1 8/8, decode landed 41 (3.45M tokens), 10 recall
commits on each prefill (1,280 SWA tokens each). 2P2D prefill 0 pushed 47/47 and prefill 1 14/14, decodes landed 46 + 15
(4.79M tokens), 14 recall commits on prefill 1 (1,792 SWA tokens), 0 on prefill 0. 0 refused pulls, 0 warnings anywhere.
Interrupted 2P2D attempt 1 (before the spot loss): (p1,d0) 78.6% / 8.1 s and (p0,d1) 0.0% / 25.7 s, consistent with
attempt 4. The (p0,d1) route is 0 by design on both arms (the pushed copy is in decode 0's DRAM and prefill 0's own host
tier was evicted by the keep-alive); (p1,d1) hits on the on arm because prefill 1 recalled the branches during (p1,d0).
Same shape as the Qwen PR 1992 layouts above; the 8-session sticky cases fit the prefill's host tier and show no delta.

## gpt-oss-120b hybrid, 1P1D, switch on, edges E2 + E3 (j-3c39a7a5-1a78-4261-8853, attempt 2, 22:20-22:27 UTC)

E2 (C1): concurrent recalls after a prefill-only flush OK (133 s), client aborts mid-recall OK (76 s); 84 health samples
all 200, 0 slow probes, 0 probe errors. E3 (C2): /flush_cache on both engines 30 s into a static run refused with 400 on
both while transfers were in flight; 24/24 requests complete, prefill-side hit 55.6%. 0 exceptions, B3 EQUAL on both
engines. With E1 and E6 earlier, the hybrid tree has passed E1, E2, E3 and E6 on CDK (E2/E3 had not run on it before).
