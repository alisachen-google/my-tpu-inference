# Issue 2107 (recall-8 capacity edge): fix attempt, validation, outcome (2026-11-16)

Workstream 2. Upstream issue sgl-project/sglang-torchtpu#2107: with the KV offload to decode DRAM on and write-back,
a returning session at the host-capacity edge lost part of its prefix to a push made during the return (first seen
in the PR 2086 rebenchmark: recall 8 on arm 86.8% hit / 4.3 s against 93.7% / 2.4 s off).

## Outcome

- **No eviction-order fix PR was opened.** The candidate fix (the issue's first proposal, also the earlier author
  session's branch: do not stamp a stored push as the next eviction victim) gains nothing at 8, 9 and 12 sessions and
  **regresses the 16-session return in every run** (hit 79.9% -> 64.4%, TTFT p50 5.6 -> 9.4 s, throughput -35%).
- **The loss in the issue needs `SGLANG_HICACHE_SKIP_HOST_DUPLICATE_RECLAIM=1`**, which our recipe set. With the flag
  unset, recall 8 and recall 9 are at the cached ceiling (94.4%) in every run on main.
- Upstream, as authorized: draft PR https://github.com/sgl-project/sglang-torchtpu/pull/2206 (start-up warning when
  the flag is set with write-back and the offload on, 3 unit tests, README note) and a comment on the issue with the
  tables below (https://github.com/sgl-project/sglang-torchtpu/issues/2107#issuecomment-6916116013).
- The stamp-removed change is kept only as `stamp-removed-experimental.patch` (and the local branch
  `fix-2107-push-victim-order` in the worktree `/mnt/disks/scratch/alisachen/sglang-2107`, never pushed).

## Setup

PR 2086 head `83198bc912` (offload code byte-identical to upstream main `82e2b973`; main itself does not start on
the 20261103 image, it needs JAX 0.11.2), gpt-oss-120b, 1P1D, TP8 per role, write-back, switch on, recipe
`pd1992-qwen3-30b-xpyd` `STAGE=bench`. New recipe variable `SKIP_HOST_DUP_RECLAIM` (default true = old behaviour) and
harness knob `LADDER_REPEATS` (repeat the recall and static ladders on the same engines; labels `_r<i>`). "Stamp kept" =
main behaviour; "stamp removed" = the candidate fix. One value per run.

## 1. Flag unset: recall 8 does not reproduce (6 runs per arm)

| Point | Hit % stamp kept | Hit % stamp removed | TTFT p50 s stamp kept | TTFT p50 s stamp removed | Total tok/s stamp kept (mean) | Total tok/s stamp removed (mean) |
|---|---|---|---|---|---|---|
| recall 8 return | 94.4/94.4/94.4/94.4/94.4/94.4 (mean 94.4) | 94.4/94.4/94.4/94.4/94.4/94.4 (mean 94.4) | 4.0/2.8/2.7/2.6/2.4/2.5 (mean 2.8) | 2.5/3.3/2.6/2.4/2.3/3.3 (mean 2.7) | 173,623 | 170,295 |

Jobs: stamp kept `j-e96c13bb-b0bb-40b6-af38`, stamp removed `j-b5734399-ac26-442e-b74c`. 0 refused drops in both.

## 2. Flag set (the issue's condition): no difference beyond spread (5 runs per arm)

| Point | Hit % stamp kept | Hit % stamp removed | TTFT p50 s stamp kept | TTFT p50 s stamp removed | Total tok/s stamp kept (mean) | Total tok/s stamp removed (mean) |
|---|---|---|---|---|---|---|
| recall 8 return | 94.4/92.3/94.4/94.4/94.4 (mean 94.0) | 93.0/94.4/94.4/90.2/94.4 (mean 93.3) | 2.6/3.3/2.6/2.6/3.4 (mean 2.9) | 3.0/2.6/3.3/3.7/2.9 (mean 3.1) | 171,864 | 163,070 |
| recall 9 return | 80.8/74.6/74.6/74.6/74.0 (mean 75.7) | 76.4/77.7/79.5/69.7/83.9 (mean 77.4) | 5.2/8.2/8.2/8.1/5.3 (mean 7.0) | 6.6/6.3/4.9/7.9/5.3 (mean 6.2) | 71,551 | 76,272 |

Jobs: stamp kept `j-1584d23c-35db-47b2-ac31` (160 refused-drop lines), stamp removed `j-8a19ba03-aaad-484f-893d` (40).

## 3. Flag unset, full ladder, 3 runs per arm on fresh engines

| Point | Hit % main | Hit % stamp removed | TTFT p50 s main | TTFT p50 s stamp removed | Total tok/s main (mean) | Total tok/s stamp removed (mean) |
|---|---|---|---|---|---|---|
| recall 8 return | 94.4/94.4/94.4 (mean 94.4) | 94.4/94.4/94.4 (mean 94.4) | 2.8/4.1/3.0 (mean 3.3) | 3.6/2.8/4.0 (mean 3.5) | 157,008 | 154,947 |
| recall 9 return | 94.4/94.4/94.4 (mean 94.4) | 94.4/94.4/94.4 (mean 94.4) | 2.6/2.4/2.2 (mean 2.4) | 2.3/3.1/2.2 (mean 2.5) | 141,714 | 150,448 |
| recall 12 return | 72.6/79.0/83.7 (mean 78.4) | 72.1/83.2/80.5 (mean 78.6) | 7.3/7.8/6.0 (mean 7.0) | 7.7/5.4/7.8 (mean 7.0) | 79,541 | 76,057 |
| recall 16 return | 74.9/81.8/82.9 (mean 79.9) | 62.1/67.9/63.1 (mean 64.4) | 8.2/5.1/3.6 (mean 5.6) | 9.4/9.4/9.3 (mean 9.4) | 81,147 | 52,339 |
| static 4 | 62.7/62.7/62.7 (mean 62.7) | 62.7/62.7/62.7 (mean 62.7) | 6.5/10.7/7.1 (mean 8.1) | 7.1/7.0/7.0 (mean 7.0) | 51,537 | 51,952 |
| static 8 | 62.5/62.5/62.5 (mean 62.5) | 62.5/62.3/62.5 (mean 62.4) | 7.1/7.2/6.8 (mean 7.0) | 7.1/7.2/7.2 (mean 7.2) | 52,268 | 51,903 |
| static 12 | 59.4/60.4/57.6 (mean 59.1) | 59.4/58.8/60.1 (mean 59.4) | 6.4/6.3/6.4 (mean 6.4) | 6.5/6.4/5.8 (mean 6.2) | 47,727 | 48,225 |
| static 16 | 51.7/56.9/55.3 (mean 54.7) | 52.4/54.7/52.3 (mean 53.1) | 11.4/7.1/8.2 (mean 8.9) | 10.3/7.3/10.4 (mean 9.3) | 43,808 | 42,739 |
| mixed long | 52.8 | 52.6 | 16.8 | 15.7 | 29,757 | 28,547 |
| mixed short | 52.8 | 52.6 | 3.7 | 3.4 | 25,300 | 26,569 |

Integrity (recalled output vs recompute): 16 of 16 on both arms. Refused drops: main 96 lines, stamp removed 0.
Pushes stored / landed: 944 / 944 (main), 952 / 952 (stamp removed); recalls 154 and 158 pulls. Jobs: main
`j-405f0892-b1ea-4887-a83b`, stamp removed `j-bf9d3225-5ae0-4867-8f77`.

Why the stamp matters at 16: without it the prefill keeps pushed sessions until plain LRU reaches them and, under
real pressure, evicts sessions that were not pushed yet (nothing can recall those) while holding copies the decode
already has.

## The "5 runs" requirement

Not run as five fix runs: the fix was rejected after three runs per arm showed a consistent regression at 16
sessions, so two more fix runs would not have changed the decision. What exists per point with the flag unset:
9 runs of recall 8 and 3 of everything else on main, the same on the stamp-removed arm.

## Unit tests

Run on this VM's CPU venv (`/mnt/disks/scratch/alisachen/tmp/ut.sh`, Python 3.12, CPU torch), not on the cluster
image. Warning branch (main + `startup-warning.patch`): push 40, recall 34, validate 13 pass, 3 new
(`test_skipping_host_duplicate_reclaim_under_write_back_warns_at_start`,
`test_no_reclaim_warning_under_write_through_or_with_the_default`,
`test_refused_engine_is_refused_before_any_warning`). Stamp-removed tree: push 42, recall 34, validate 10 pass.
Three cases I first wrote for it were wrong and dropped: they assumed a prefix match refreshes a host-only
session's place in the host eviction order; it does not.

## Problems met

- Upstream main does not start on image `sglang-torchtpu:20261103` (`ImportError: jax._src.tpu_info`); jobs
  `j-c1efeeef-0fcc-4952-a2e5`, `j-8552b9ec-94a4-4542-92af` failed at engine start.
- A spot preemption replayed the JobSet of `j-af31fde6-c6c9-4fda-9bf4` mid-ladder; the bench pod restarted before
  the decode had reloaded and `wipe` gave up after 5 minutes. `flush_one` now retries for 25 minutes; rerun as
  `j-bf9d3225-5ae0-4867-8f77`.
- Unit-test jobs `j-ff95da0a-ac33-4b97-8b7d` and `j-95df0a31-0751-4de4-8c88` never got a node and were deleted
  unrun once the local venv existed.

All twelve jobs of this workstream are deleted. Raw points, stage logs and integrity summaries per job under `raw/`.

## Not verified

- The warning's effect on a live engine (only unit-tested).
- Item 5 of the issue (no offer for a return whose push completed in the same phase) was not investigated.
- Flag-set recall 12 and 16 in the upstream PR text come from the single 2026-11-11 campaign run, not from today.
