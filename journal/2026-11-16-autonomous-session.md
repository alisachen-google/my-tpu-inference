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

## Bugs and defects found (running list)

| Time | Where | Bug | State |
|---|---|---|---|

## Jobs left on the cluster (update at every change)

| Job | Purpose | State |
|---|---|---|

## Decisions taken without the user (to review)

| Time | Decision | Why |
|---|---|---|
| 10:06 | Workstream 1 uses option B2 (decode stores pushed branches in the prefill stage's layout) | Needs no tpu-sync change; reversible; alternative B1 documented |
