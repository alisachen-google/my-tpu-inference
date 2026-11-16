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

## Bugs and defects found (running list)

| Time | Where | Bug | State |
|---|---|---|---|
| 10:07 | 2 | Upstream main (82e2b973) does not start on image sglang-torchtpu:20261103 (ImportError jax._src.tpu_info; main needs JAX 0.11.2 since #2082). Jobs j-c1efeeef-0fcc-4952-a2e5, j-8552b9ec-94a4-4542-92af failed at engine start and were deleted. Offload code is byte-identical between main and PR head 83198bc, so live validation runs on 83198bc + patch. | worked around |

## Jobs left on the cluster (update at every change)

| Job | Purpose | State |
|---|---|---|
| j-1584d23c-35db-47b2-ac31 | ws2 flag-set recall 8/9 x5, stamp kept | submitted 09:2x-09:5xZ |
| j-8a19ba03-aaad-484f-893d | ws2 flag-set recall 8/9 x5, stamp removed | submitted 09:2x-09:5xZ |
| j-405f0892-b1ea-4887-a83b | ws2 final ladder x3, baseline 83198bc | submitted 09:2x-09:5xZ |
| j-af31fde6-c6c9-4fda-9bf4 | ws2 final ladder x3, fix | submitted 09:2x-09:5xZ |
| j-ff95da0a-ac33-4b97-8b7d | ws2 unit tests | submitted 09:2x-09:5xZ |

## Decisions taken without the user (to review)

| Time | Decision | Why |
|---|---|---|
| 10:06 | Workstream 1 uses option B2 (decode stores pushed branches in the prefill stage's layout) | Needs no tpu-sync change; reversible; alternative B1 documented |
| 10:07 | Workstream 1: for the pipeline pairing the decode no longer restores a recalled prefix from its own DRAM; it receives the whole prompt from the prefill | A stage-layout page cannot be loaded into a tensor-parallel rank's HBM. Tensor-parallel pairing unchanged. Cost: more bytes over the wire on recall turns only |
| 10:07 | Workstream 1: prefill stage s is hosted by decode rank s mod decode_tp; all stage pools get the same page count; budget split 12.5 percent for sliding windows | One page id then names a page in every pool, so decode ranks agree on the index only. The split is an arbitrary default, named in the code |
| 10:09 | 2 | Data so far does not support the eviction-order fix for issue 2107 (no gain at recall 8 or 9 with the flag set; no loss to fix with the flag unset). Per the coordinator's rule the fix PR will NOT be opened; the branch stays local. Preparing instead a draft PR with a start-up warning and README note for SGLANG_HICACHE_SKIP_HOST_DUPLICATE_RECLAIM with the offload on, and a comment on issue 2107 with the public-safe numbers. The two final ladder jobs keep running to record the flag-unset ladder on both arms. |
