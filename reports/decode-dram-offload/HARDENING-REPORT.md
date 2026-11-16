# KV offload to decode DRAM: hardening report

Feature: `SGLANG_ENABLE_PREFILL_KV_OFFLOAD_TO_DECODE_DRAM=1` in `sgl-project/sglang-torchtpu`: a P/D prefill pushes
cold KV branches from its HiCache host tier to the host RAM of the decode that served them, and recalls them when
the session returns. Delivered by [PR 1992](https://github.com/sgl-project/sglang-torchtpu/pull/1992) (full-attention
models, merged as `3dabdc26`) and [PR 2086](https://github.com/sgl-project/sglang-torchtpu/pull/2086) (hybrid
sliding-window models, merged as `5c136df1`); earlier iterations were PR 1789 and PR 1991.

This report covers what was done to harden it between 2026-10-26 and 2026-11-16: every class of test run, every
defect found and how it was closed, and what is still open. Performance numbers are in the companion
`PERF-REGRESSION-REPORT.md`. Status as of 2026-11-16, against upstream main `82e2b973`.

**Sources** (all in this repo): `benchmarks/2026-10-26-victim-fork-goal/` (`FIXES-2026-10-27.md`,
`ISSUES-2026-11-06-09.md`, `PLAN-2026-11-09.md`), `benchmarks/2026-11-10-pr2086-bench/` (`README.md`,
`ISSUES-2026-11-11.md`, `STRESS-2026-11-11.md`, `REPORT-2026-11-11-author-session.md`, `author-session/`).

## 1. Summary

| Area | Result |
|---|---|
| Output correctness | A recalled request produces the same 64 greedy tokens as a recompute: 16 of 16 on every arm of the merged head (write-back and write-through, switch off and on, used and fresh engines). Byte-level: 5,520 of 5,520 transferred page sets CRC-equal on both roles. |
| Rank consistency | Push, landing and recall counters identical on all ranks of every engine in every campaign run; no divergence under the rank consensus checker. |
| Failure handling | Decode kill, prefill kill, client aborts mid-recall, flush under load, declined pushes, no host room, one-sided switch: all end with requests either served or failed loudly, engines flushable, nothing leaked. |
| Unsupported settings | Every unsupported setting stops the engine at start, naming the setting; a mismatched pair fails its requests with the reason. None runs silently without the offload. |
| Stress | 3 hours of mixed text and image load (1 to 261k tokens, 1 to 64 images) ramped to saturation three times: 1,841 requests, 0 hangs, 0 crashes, quality gate and leak check passed after every ramp. |
| Defects | 35 defects found and fixed before merge (section 4). 3 items open upstream (section 6). |

## 2. Test matrix

| Dimension | Covered |
|---|---|
| Models | Qwen3-30B-A3B FP8 (full attention), gpt-oss-120b (hybrid sliding-window + full attention), Qwen3-VL-8B (multimodal, stress only) |
| Layouts | 1P1D, 1P2D, 2P1D, 2P2D; TP8 single-host engines; TP16 two-host engines (stress) |
| HiCache write policy | `write_back` and `write_through`, on both roles |
| Arms | switch off vs on, same tree, caches flushed before every point |
| Routing | sticky pair (pinned router per prefill and decode pair), cross-prefill, cross-decode, four-leg chain, random |
| Platforms | bare-metal tpu7x hosts (October to 2026-11-10) and the shared CDK GKE cluster (2026-11-09 onward) |

## 3. Hardening cases and results

### 3.1 Correctness

| Case | How | Result |
|---|---|---|
| Single-request output equivalence | 16 sessions of 128k + 8k; each returns alone; both engines flushed; every return recomputed; 64 greedy tokens compared (`victim_integrity.py`) | PR 1992: 16 / 16 on write-back, write-through, 1P2D, 2P1D. PR 2086 first head: **12 / 16 and 13 / 16 under write-back** (defect I5). Merged head: 16 / 16 on all four arms, on used and on fresh engines. |
| Byte-level transfer check | CRC32 of every layer of every transferred page set, logged on both roles and joined across ranks (`SGLANG_TPU_DEBUG_VICTIM_CRC=1`) | 5,024 of 5,024 equal (2,400 full + 2,400 window pushes, 112 + 112 recalls); 5,520 of 5,520 over the soak |
| Why concurrent equality is not the oracle | Background probes disagree with their own reference in about 16 of 90 cases on every arm, including plain P/D without the feature (greedy decoding on TPU is not batch-invariant) | The exactness test is one request at a time |
| Rank consistency | Final counters per rank compared for every engine of every run (`offload_counters.py`); `SGLANG_ENABLE_RANK_CONSENSUS_CHECKER=1` runs | Equal on every engine; checker clean over 780 pushes and 61 recalls |

### 3.2 Edge cases (single pair)

| Case | Result |
|---|---|
| Many recalls in flight at once (8 two-turn sessions, flush between turns) | Served; `/health` never slow; 43 of 45 pushes stored |
| Client drops a request mid-recall, then re-issues it | Re-issued request completes with the cached prefix; no engine error |
| Cache flush while transfers are pending | Refused with 400 while in flight, succeeds within seconds once idle; requests under load unaffected (24 of 24) |
| No host room for a recall landing | The request computes its prompt; nothing leaks; counted as `no_memory` |
| Decode DRAM smaller than one session | Pushes declined (`no_room`), counted, nothing breaks |
| Prefill host pool far smaller than the working set (`--hicache-ratio 0.5`) | Crash-free; all pushes land; recalls abandoned for lack of host room, by design |
| Host staging pool too small | Refused at start with the sizes in the message |
| Mixed request sizes with an immediate flush after load | 120 of 120 on both arms |
| Switch on for one role only, either direction | Requests fail by name (`peer_switch_mismatch`) |
| Different attention TP on the two roles | Refused by name (`resharding_refusal`) |

### 3.3 Process failure

| Case | Result |
|---|---|
| Decode killed while recalls are in flight, restarted alone | Prefill survives; requests in flight fail loudly (3 to 5 of 12); pushes to the dead decode are declined; 12 to 16 of 16 after restart |
| Prefill killed while the decode holds offloaded KV, restarted alone | Decode survives, releases the dead prefill's landings, is flushable; full service after restart |
| Decode killed in 1P2D and 2P2D | Same behaviour per pair; the other decode keeps serving |

### 3.4 Multi-engine routing

| Case | Result |
|---|---|
| Sticky pair, same prefill and decode (T1) | Recall works: 78.2% hit, 2.9x TTFT on the merged head |
| Other prefill, same decode (T2) | Recall works across prefills: 62.4%, 2.9x |
| Same or other prefill, other decode (T3, T4) | Cold on both arms: recall is decode-affine by design; T3 gets 11.1% from the prefill's own host tier |
| Four-leg chain over all pairs | 77.2 / 70.8 / 24.5 / 44.4% |
| Random routing | Served; gain depends on the random split |
| Route check | Every pinned point served only by its expected pair (`route_ok`) |

### 3.5 Unsupported settings

Refused at start, engine exits within seconds, port free: HiCache off, non-Raiden HiCache or transfer backend, L3
storage, radix cache off, optimistic prefill, `--sleep-on-idle`, the unified KV pool, the Rust radix tree,
speculative decoding, pipeline, context and data parallelism, the Raiden pipeline transfer on a decode,
recurrent-state models, a tpu-sync build without the host-to-host read API. (Pipeline parallelism support is designed in
`designs/2026-11-16-kv-offload-pipeline-parallel/DESIGN.md`.)

### 3.6 Soak and stress

| Run | Load | Result |
|---|---|---|
| Soak under the consensus checker | 3 repetitions of static 12 and recall 12 on one pair | Clean over 780 pushes (772 landed, 11.5M tokens) and 61 recalls |
| Agentic multi-turn, 1 hour, 1P1D and 2P2D | Real multi-turn traces, write-back with and without the switch | Found defect 6 (prefill out of memory) and defect 7 (decode pin leak); clean after the fixes (3,303 requests, 0 errors) |
| Mixed-load stress, 3 hours, 1P1D with two-host TP16 engines, Qwen3-VL-8B | Text 1 to 261k tokens, 1 to 64 images, GSM8K, session returns, client aborts; concurrency ramped 2 to 72 three times, then drain and verify | 1,841 requests, 1,832 completed, 0 hangs, 0 crashes. After each ramp: engines idle within 76 s, 24 of 24 verification requests, GSM8K 95 to 97 against a 96 baseline, no KV left after a flush. The 9 that did not complete were aborted by the engines at concurrency 48 when the KV transfer hit its 60 s deadline. |

Not achieved: the stress on 2P2D with TP16 engines (the cluster never had four two-host slices free at once; a
single-host 2P2D fallback was spot-preempted seven times and reached concurrency 14 cleanly before being stopped),
and a 6-hour run.

## 4. Defects found and fixed before merge

| Phase | Count | Examples |
|---|---|---|
| Branch validation, October (PR 1789) | 7 defects + 5 review findings | Decode exits on flush while offers are pinned; recalls abandoned under write-through because host RAM is full of device duplicates; `KeyError` in device eviction after a recall; write-back + offload stalls device eviction and the prefill dies with out of memory; decode never released the host pin of an offered prefix; device recall released active sources (P0) |
| PR 1992 review and live runs | 11 code defects (C1 to C11), 6 integration defects (L1 to L6) | Only the leaf of a pushed path was host-locked; an abort between READY and the read killed a rank; landings freed per rank let trees diverge; pushes started with no request in sight blocked flushes; `--sleep-on-idle` and optimistic prefill not refused; installer imported a renamed module so no engine could start with the switch on while unit tests stayed green; host pool control port could be stolen before bind |
| Hybrid (PR 1991, PR 2086) | 6 | Prefill out of memory from an unbacked device node above a recalled branch (fixed by adopting received pages as its backup); full and SWA host pools bound the same control port, so every push failed while client stages still passed; window fields broke older peers on the wire; **I5** recalled output differed from a recompute under write-back; **static-reuse regression** (the prefill kept only the last window of each path); **I7** native hash extension rebuilt on every pull |

Every code defect was fixed with a regression test in the upstream unit suites
(`test_decode_dram_offload_push.py`, `_recall.py`, `_validate.py`, `test_pd_decode_swa_hicache.py`).

The three PR 2086 defects found by this campaign and fixed in head `83198bc912`:

| ID | Symptom | Cause | Verified |
|---|---|---|---|
| I5 | 12 of 16 and 13 of 16 exact under write-back with the switch on; session 6 diverged at token 5 in three independent runs | With only the last window of a path kept on the prefill, a return could resume with a window that did not end at its match | 16 of 16 on all arms, fresh and used engines |
| Static regression | Write-back static reuse at 8 to 16 documents lost 13 to 23% throughput with the switch on; 0 host hits | Same rule: no window at the fork of a shared document | On arm level at 8 documents and ahead at 12 and 16 |
| I7 | 560 to 936 "stale or broken JIT extension" lines per on arm, one rebuild per rank per pull | Page hashes computed on every recall | 0 lines on every arm |

## 5. Findings that were not defects

| Finding | Explanation |
|---|---|
| I4: `write_back: backup failed ... subtree drop declined (node locked)`, 40 to 168 lines per run, and one prefill out of memory in five stress runs | Caused by `SGLANG_HICACHE_SKIP_HOST_DUPLICATE_RECLAIM=1`, which every benchmark recipe of these campaigns set. Without it: 0 refused drops and no out of memory in 3 of 3 stress runs, and the write-back recall gains rise. The user guide says to leave upstream's default. |
| I9: 9 requests with no output at concurrency 48 in the stress | Aborted by the engines with status 500 when the prefill-to-decode transfer hit its 60 s deadline on a saturated decode; delivered in-band to a streaming client. First reported as silent; that was a harness misread, corrected. |
| I12: victim pushes time out on a saturated decode | Documented behaviour: an unanswered push within 60 s is a decline |
| Client-reported cache hit near 94% with the switch off | The usage field comes from the decode's own cache in P/D and is not a prefill saving; reports use the prefill-side hit |
| Fill phases show 0% hit on both arms | Cold by construction: engines flushed and every session new |

## 6. Open items

| Item | Where | State |
|---|---|---|
| At the host-capacity edge a returning session loses part of its prefix to a push made during the return (recall 8: 86.8% on vs 93.7% off in one run; timing dependent) | [issue 2107](https://github.com/sgl-project/sglang-torchtpu/issues/2107) | Fix and A/B in progress (workstream 2, 2026-11-16) |
| No recall for sessions behind a shared hot prefix under write-back | [issue 2051](https://github.com/sgl-project/sglang-torchtpu/issues/2051) | Fix PR [2052](https://github.com/sgl-project/sglang-torchtpu/pull/2052) open, needs a rebase |
| A recall the prefill abandons after READY leaves the decode's read registered for 60 s (I8) | [issue 2201](https://github.com/sgl-project/sglang-torchtpu/issues/2201) | Filed 2026-11-16; needs a Raiden withdraw of an unstarted read |
| Decode host RAM headroom under load (I10): OOM-killed at concurrency 48 with ratio 3.5 on two-host engines; growth sits on the second host and is released on drain | Sizing guidance | Workaround ratio 2.0; cause of the asymmetry not isolated |
| `/health` unanswered for 90 s at saturation and 15 s during a 60-image request (I11) | Serving layer | Not filed |
| All write-back campaign numbers were measured with the duplicate-reclaim flag set | Recipes | Re-measure without it; being done as part of the 2107 validation |
| 2P2D stress on TP16 engines; 6-hour soak | Capacity | Not run |

## 7. Operational guidance that came out of the hardening

- Leave `SGLANG_HICACHE_SKIP_HOST_DUPLICATE_RECLAIM` unset.
- Use sticky routing per decode: a recall can only come from the decode that received the push.
- Prefer `write_through` for workloads where many requests share a long prefix and then diverge.
- Run the same build on both roles; a wire mismatch stalls requests instead of failing fast.
- Set the Raiden socket timeouts on both roles (60 s), or a vanished peer keeps pages pinned.
- Size the decode's host pool from the per-host budget, leaving room for in-flight staging under load.
- Judge cache benefit by the prefill-side hit and TTFT, not by the client-reported cached tokens.
