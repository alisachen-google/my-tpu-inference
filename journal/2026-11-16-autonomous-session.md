# Autonomous session journal, 2026-11-16 10:05Z onward

The user is away for about 10 hours. This file is the single place to read what was done: every action, bug, result
and decision, newest entries at the bottom of each section. Times are UTC. Job ids are CDK ids.

## Standing constraints

- The VM's user credentials (ADC) expire every few hours and only the user can renew them. When they expire, all
  cluster work stops (no submit, no collect, no delete) and work continues on code, analysis and documents only.
  Jobs still on the cluster at that point are listed here so they can be collected and deleted after the renewal.
- The cluster gives top priority to one workload per user; a second one is preempted. Order of cluster use:
  workstream 2 validation first (already running), then workstream 1 unit-test and live jobs, then workstream 3.
- Upstream PRs stay drafts unless validation supports them; nothing upstream mentions this repository.

## Workstreams

| # | Goal | Where the detail is |
|---|---|---|
| 1 | KV offload to decode DRAM with a pipeline-parallel prefill (target pairing: pipeline prefill to tensor-parallel decode, multi-host) | `designs/2026-11-16-kv-offload-pipeline-parallel/DESIGN.md`, `benchmarks/2026-11-16-offload-pp/` |
| 2 | Fix for upstream issue 2107 (recall 8 capacity edge) with unit tests, live A/B, 5-run regression check, PR | `benchmarks/2026-11-16-issue2107-fix/` (created by that workstream) |
| 3 | Muse Spark disaggregated perf toward GPU | `benchmarks/2026-11-16-musespark-disagg/` |
| 4 | Apply 1 to the tuned point of 3 | blocked on 1 and 3; prerequisites in the workstream 3 README |

## Log
| 10:25 | 3 | Wrote my own Muse Spark P/D recipe `musespark-pd-agentx-alisachen` (derived from the owner's single-host recipe and the stored JobSet of `j-ec9464b2-4aaf-46fe-af8a`): two 2x2x1 hosts, prefill + router on pod 0, decode on pod 1, tree via `--map-dir`, per-role JSON overrides (`PREFILL_ARGS`, `DECODE_ARGS`, `PREFILL_ENV`, `DECODE_ENV`) so tuning needs no code change. Renders. Copy in `benchmarks/2026-11-16-musespark-disagg/recipes/`. Not run yet. |
| 10:27 | 3 | Finding: upstream main's `agentic.py` differs from the dashboard point: prefill is PP2 x TP4 with DP attention (the dash job ran PP8 x TP1 from a private checkout), decode uses the megakernel, and the concurrency-32 patch sets `max_running_requests` 6 (dash job: 32). A rerun on main is therefore a different configuration, not a reproduction. |
| 10:30 | 3 | Submitted two 30-minute image checks (does upstream main import and do the offload validation tests run): `j-a6eabbfd-d6ba-4121-b2b0` (image `muse-disagg`), `j-d4dd1ecb-65c5-42e6-8f43` (image `anvil-jax0112-97afaea9`). Needed by workstreams 1 and 3 before any run on main. |

| Time | Workstream | Action / finding |
|---|---|---|
| 10:06 | all | Session start. ADC valid. Cluster: workstream 2 has 5 jobs (2 collected-pending, 1 running, 1 retrying, 1 unit-test pending). Scratch disk 7.9 GB free, /home 221 MB free. |
| 10:07 | 2 | Fix for issue 2107 written on branch fix-2107-push-victim-order off upstream main (worktree sglang-2107): the stamp that made a stored push the next eviction victim is removed (pusher + radix_host_ops.mark_next_victim), 7 unit tests added/reworked in test_decode_dram_offload_push.py. Not yet pushed anywhere. |
| 10:07 | 2 | Exploratory A/B, flag SGLANG_HICACHE_SKIP_HOST_DUPLICATE_RECLAIM UNSET, recall 8 x6 per arm (j-e96c13bb-b0bb-40b6-af38 stamp kept, j-b5734399-ac26-442e-b74c stamp removed): 94.4% hit in 6/6 runs on BOTH arms, 0 refused drops; the recall-8 loss does not reproduce without the flag. Both jobs collected and deleted. |
| 10:07 | 2 | Submitted: flag-SET reproduction pair recall 8,9 x5 (j-1584d23c-35db-47b2-ac31 stamp kept, j-8a19ba03-aaad-484f-893d stamp removed); final ladder runs flag unset, recall 8/9/12/16 + static 4-16 x3 + mixed + integrity (baseline j-405f0892-b1ea-4887-a83b, fix j-af31fde6-c6c9-4fda-9bf4); unit tests j-ff95da0a-ac33-4b97-8b7d. |
| 10:07 | 1 | Checked what a switch-on decode does with a landed branch (upstream main 82e2b973): it inserts it into its own radix cache, counts it in decode_prefix_len, triggers the recall offer from that match, and loads it into its own HBM (_process_hicache_local_restores). Option B2 therefore keeps pipeline branches in a separate index with its own recall trigger; the decode receives the whole prompt over the wire on a recall turn. Design Revision 2026-11-16d. |
| 10:07 | 1 | Pinned tpu-sync wheel ships no host-only extension (_tpu_raiden_host missing), so create_host_only_for_testing cannot be used. Stage pools are ordinary managers over one-page placeholder tensors; unproven until the probe test/manual/tpu/probe_stage_layout_host_store.py runs on a TPU. |
| 10:07 | 1 | Fork branch pd-dram-offload-pp: 4745864d stage_layout_store.py (index, sizing, placement), 26461392 decode_stage_branches.py (decode receiver, offerer, StagePoolSet), f75834f3 channel and serde stage fields plus stage_pool_builder.py. 49 torch-free tests pass on this VM (stage_votes 12, stage_layout_store 21, stage_branches 16). test_decode_dram_offload_stage_channel.py needs torch and has not run. |
| 10:07 | 1 | Hazard for the prefill side: a vote cast in one micro-batch slot settles a loop later while the tree keeps changing. Rule adopted: vote only on local facts that cannot revert (a read settled, a registration accepted, a message arrived); re-check tree facts deterministically at settle time; take no lock before agreement. |
| 10:09 | 2 | Flag-SET reproduction (5 repeats per arm, same engines): recall 8 hit stamp kept 94.4/92.3/94.4/94.4/94.4 vs stamp removed 93.0/94.4/94.4/90.2/94.4; recall 9 kept 80.8/74.6/74.6/74.6/74.0 (mean 75.7) vs removed 76.4/77.7/79.5/69.7/83.9 (mean 77.4). Refused drops 160 vs 40. No difference beyond run-to-run spread; removing the stamp does not remove the occasional partial return (90.2 with the fix). Jobs j-1584d23c-35db-47b2-ac31 and j-8a19ba03-aaad-484f-893d collected and deleted. |
| 10:10 | 2 | Wrote the fallback upstream change on branch offload-warn-skip-host-dup-reclaim (off main): start-up warning when SGLANG_HICACHE_SKIP_HOST_DUPLICATE_RECLAIM=1 with write_back and the offload switch on, 3 unit tests, README note. Unit job j-ff95da0a-ac33-4b97-8b7d (pending 1 h, never placed) deleted and replaced by j-95df0a31-0751-4de4-8c88, which runs the offload unit tests of both the fix tree and the warning tree. |
| 10:17 | 1 | Engine wired on fork branch pd-dram-offload-pp (00188807). Prefill stages vote through the pipeline's own ready/failed bootstrap lists (marked entries, no new ring message): stage_agreement.py, stage_prefill_workers.py (torch-free decisions), stage_prefill_ops.py (thin torch glue). Decode offer rides the pipeline request's consumer JSON. Startup now accepts a pipeline prefill at tp 1 and a decode with the pipeline transfer; a pipeline decode stays refused. 62 torch-free tests pass on this VM; nothing torch-bound has run anywhere yet. |
| 10:20 | 1 | Submitted j-0fef6998-a7d1-4974-9077 (tree f5e3a98c, image anvil-jax0112-97afaea9, 4 chips): all test_decode_dram_offload_*.py plus test_raiden_host_transfer, then the stage-layout host store probe. Queued behind workstreams 2 and 3 on the coordinator's instruction. |
| 10:27 | 1 | Built a CPU test environment on this VM: uv venv /mnt/disks/scratch/alisachen/venv-ws1 (Python 3.12, torch 2.15 cpu, libstdc++ from /mnt/disks/scratch/tb/lib), runner /mnt/disks/scratch/alisachen/tmp/ut.sh (TREE=<worktree> to point it at another tree). The torch-bound offload unit tests now run here without the cluster: on tree f5e3a98c test_decode_dram_offload_push 40, recall 34, validate 10, stage_channel 6, test_raiden_host_transfer 9, plus the torch-free files, all pass. Other workstreams can use it. |
| 10:30 | 1 | User instruction relayed by the coordinator: live validation runs on Muse Spark Open (meta-models/Muse-Spark-Open-816B-A42B-NVFP4), the nightly model, not a stand-in. Plan: unit + probe job first, optionally a small-model smoke of the pipeline path, then one Muse run carrying as many checks as possible, with an active deadline. |
| 10:30 | 2 | Unit tests run on the VM's CPU venv (ut.sh), not on the cluster image. Warning tree (PR head + warning patch): push 40, recall 34, validate 13 pass (3 new). Fix tree (stamp removed): recall 34, validate 10 pass; push 42 pass after dropping 3 of my new cases that wrongly assumed a prefix match refreshes the host LRU order (finding: match_prefix alone does not move a host-only session in the host eviction order). Pending unit job j-95df0a31-0751-4de4-8c88 deleted unrun. |
| 10:35 | 1 | 1effe708: end-to-end unit test of a 2-stage pipeline prefill against a tensor-parallel decode through the real hooks (push, recall, failed recall, declined push) passes locally; upstream test_raiden_pipeline.py 69 pass. Startup now accepts speculative decoding in the pipeline pairing only (whole host blocks, draft tensors included, return to the stage they came from; the decode never reads a pushed page). Found the nightly Muse entry: test/registered/tpu/e2e/test_tpu_muse_spark_pd_singlehost_pp8_dflash.py with config pd_singlehost_pp8_prefix_cache_kv_offload_dflash.py (PP8 tp1 prefill, TP8 decode, DFLASH, write_through), the same shape this design supports. |
| 10:43 | 1 | Draft PR opened: https://github.com/sgl-project/sglang-torchtpu/pull/2202 (branch pd-dram-offload-pp at 0d9563ac, draft, no reviewers requested by me). Body states what ran (CPU only: 71 new tests in 5 files, plus validate 11, push 40, recall 34, host transfer 9, upstream pipeline 69) and what did not (any TPU run, the probe, a live pair, CI). |
| 10:43 | 1 | Recipe musespark-pd-offload-pp-alisachen created (copy of workstream 3's recipe, theirs untouched): nightly config module pd_singlehost_pp8_prefix_cache_kv_offload_dflash, offload switch, decode HiCache and radix cache, check pod running test/manual/tpu/pd_stage_offload_check.py, active deadline 6 h on both jobs. Renders. Waiting for the unit + probe job before submitting. |
| 10:45 | 3 | Both image checks failed without running: admitted at 10:11, the pods never started (no node placed them), and my 30-minute active deadline, which counts from admission, ended them at 10:41 with no log. Deleted both. Resubmitted the `muse-disagg` check with a 3 h deadline (the other image is covered by workstream 1's unit job `j-0fef6998-a7d1-4974-9077`). |
| 10:47 | 1 | Submitted j-413cdada-1b3e-4f6d-884b (tree 6a34fc03, image anvil-jax0112-97afaea9, 8 chips): Qwen3-30B 1P1D, prefill --pp-size 8 --tp-size 1 --ep-size 1, decode tp8 with the pipeline transfer, offload on, small pools (16,384 tokens, prefill host ratio 2), harness stage offloadcheck running test/manual/tpu/pd_stage_offload_check.py. A cheap proof of the wiring under a real pipeline loop before the Muse run. Whether Qwen3-30B serves at pp8 tp1 is itself unknown. |
| 11:01 | 1 | j-413cdada-1b3e-4f6d-884b: Qwen3-30B serves at pp8 tp1 on the anvil-jax0112 image with upstream main, both engines started with the offload on (decode: stage-layout extension attached; prefill: 8 stages, 257 host pages each), start-up about 2 min after pod start. First request hit the bug above. Job deleted. Resubmitted as j-767cc815-240c-4663-a0cc with the fix. |
| 11:02 | 1 | j-0fef6998-a7d1-4974-9077 never ran: first placement unschedulable for 13 min, the retry sat SchedulingGated on node gke-tpu-d716ab26-bwhb for 7 min. Deleted it and resubmitted as j-9d176863-957f-4c12-90d6 with the current tree and the full test list. |

## Bugs and defects found (running list)

| Time | Where | Bug | State |
|---|---|---|---|
| 10:07 | 2 | Upstream main (82e2b973) does not start on image sglang-torchtpu:20261103 (ImportError jax._src.tpu_info; main needs JAX 0.11.2 since #2082). Jobs j-c1efeeef-0fcc-4952-a2e5, j-8552b9ec-94a4-4542-92af failed at engine start and were deleted. Offload code is byte-identical between main and PR head 83198bc, so live validation runs on 83198bc + patch. | worked around |
| 10:11 | 2 | Harness: after a spot preemption replayed the JobSet of j-af31fde6-c6c9-4fda-9bf4 mid-ladder, the bench pod restarted before the decode had reloaded; wipe() gave up after 5 min of flush retries and the stage exited 1, failing the job (bench has no restart). flush_one now retries for 25 min. Job deleted, resubmitted as j-bf9d3225-5ae0-4867-8f77. | fixed in harness |
| 10:17 | tpu-sync pinned wheel 0.0.1.dev20261112081648 | KVCacheManager.create_host_only_for_testing imports _tpu_raiden_host, which the wheel does not ship | worked around with placeholder-tensor pools; unverified on device |
| 10:17 | sglang_tpu/raiden_transfer.py host_control_port_candidates | The deterministic host-pool control port is derived from the TP rank only, so the 8 stages of a single-host pipeline prefill (all TP rank 0) ask for the same port; later stages fall back to two get_free_port tries | open; not fixed in this branch; watch for 'host pool control port is taken' in the first live run |
| 10:35 | ws1 branch, pool_transfer.py pipeline request hooks | Read mgr.dram_offload_channel directly; two upstream tests in test_raiden_pipeline.py use managers without that attribute and failed | fixed in 1effe708 (getattr); found by the local CPU run |
| 10:45 | harness (mine) | An active deadline shorter than the placement wait kills a job that never ran: the deadline counts from Kueue admission, not from pod start | Use deadlines of hours for anything on a busy pool |
| 11:01 | ws1 branch, dram_offload_hooks._pipeline_prefill_extension | Captured scheduler.disagg_prefill_bootstrap_queue at attach time, when it is still None (the extension is attached while the queue is built); the prefill crashed on its first vote with AttributeError and the engine exited (rc 137). Found live in j-413cdada-1b3e-4f6d-884b within 10 s of the first request | fixed (queue read when asked; the pair test now attaches before the queue exists) |

## Jobs left on the cluster (update at every change)
| `j-a6eabbfd-d6ba-4121-b2b0`, `j-d4dd1ecb-65c5-42e6-8f43` | image checks | failed unplaced, deleted 10:45 |

| Job | Purpose | State |
|---|---|---|
| j-1584d23c-35db-47b2-ac31 | ws2 flag-set recall 8/9 x5, stamp kept | submitted 09:2x-09:5xZ |
| j-8a19ba03-aaad-484f-893d | ws2 flag-set recall 8/9 x5, stamp removed | submitted 09:2x-09:5xZ |
| j-405f0892-b1ea-4887-a83b | ws2 final ladder x3, baseline 83198bc | submitted 09:2x-09:5xZ |
| j-af31fde6-c6c9-4fda-9bf4 | ws2 final ladder x3, fix | submitted 09:2x-09:5xZ |
| j-ff95da0a-ac33-4b97-8b7d | ws2 unit tests | submitted 09:2x-09:5xZ |
| j-95df0a31-0751-4de4-8c88 | ws2 unit tests (fix tree + warning tree) | submitted 10:2xZ; replaces j-ff95da0a-ac33-4b97-8b7d (deleted) |
| j-bf9d3225-5ae0-4867-8f77 | ws2 final ladder x3, fix (resubmit) | submitted 10:15Z |
| j-0fef6998-a7d1-4974-9077 | ws1 unit tests on the image candidate for main + B2 byte-path probe | submitted 10:2xZ |
| j-95df0a31-0751-4de4-8c88 | ws2 unit tests | DELETED 10:3xZ (tests ran locally instead) |
| j-413cdada-1b3e-4f6d-884b | ws1 small-model check: Qwen3-30B pp8 prefill to tp8 decode, offload on, scripted push/recall check | submitted 10:47Z |
| j-413cdada-1b3e-4f6d-884b | ws1 small-model check, first attempt | failed on a ws1 bug, deleted 11:0xZ |
| j-767cc815-240c-4663-a0cc | ws1 small-model check, second attempt (queue fix) | submitted 11:0xZ |
| j-0fef6998-a7d1-4974-9077 | ws1 unit + probe, first submission | never started, deleted 11:0xZ |
| j-9d176863-957f-4c12-90d6 | ws1 unit tests + B2 byte-path probe (resubmission) | submitted 11:0xZ |

## Decisions taken without the user (to review)
| 10:30 | A full Muse Spark P/D run (two 1 TB weight disks, about 3 h start-up, 8 chips) is submitted only if the cluster is free of workstream 1 and 2 jobs and an image is known to run the tree; it gets an active deadline so it ends by itself if credentials expire | Cost and contention; jobs that finish release their chips without me |

| Time | Decision | Why |
|---|---|---|
| 10:06 | Workstream 1 uses option B2 (decode stores pushed branches in the prefill stage's layout) | Needs no tpu-sync change; reversible; alternative B1 documented |
| 10:07 | Workstream 1: for the pipeline pairing the decode no longer restores a recalled prefix from its own DRAM; it receives the whole prompt from the prefill | A stage-layout page cannot be loaded into a tensor-parallel rank's HBM. Tensor-parallel pairing unchanged. Cost: more bytes over the wire on recall turns only |
| 10:07 | Workstream 1: prefill stage s is hosted by decode rank s mod decode_tp; all stage pools get the same page count; budget split 12.5 percent for sliding windows | One page id then names a page in every pool, so decode ranks agree on the index only. The split is an arbitrary default, named in the code |
| 10:09 | 2 | Data so far does not support the eviction-order fix for issue 2107 (no gain at recall 8 or 9 with the flag set; no loss to fix with the flag unset). Per the coordinator's rule the fix PR will NOT be opened; the branch stays local. Preparing instead a draft PR with a start-up warning and README note for SGLANG_HICACHE_SKIP_HOST_DUPLICATE_RECLAIM with the offload on, and a comment on issue 2107 with the public-safe numbers. The two final ladder jobs keep running to record the flag-unset ladder on both arms. |
| 10:17 | Workstream 1: behind a pipeline prefill the decode caches its own requests again (upstream behaviour) instead of caching pushed sessions only | Pushed branches live outside the decode radix cache in this pairing, so nothing conflicts; matches the Muse Spark point's decode radix cache setting |
| 10:17 | Workstream 1 first version is simpler than the tensor-parallel workers: a recall reads the whole offered prefix, a stored branch is not stamped as next eviction victim, a one-sided switch is not failed by name | Keeps the torch-bound glue thin while no torch test can run here; each is listed as a follow-up in stage_prefill_ops.py |
| 10:43 | Workstream 1: speculative decoding (DFLASH) accepted by the offload in the pipeline pairing only | Whole host blocks, draft tensors included, return to the stage they came from and the decode never reads a pushed page; lets the Muse run keep the nightly's DFLASH. Not validated on device yet |
| 10:43 | Workstream 1: live check judges integrity by a passkey placed further back than the sliding window; other text differences from a cold reference are counted, not failed | A cached prefix changes how the prompt is chunked, which can change later tokens without any KV corruption |
