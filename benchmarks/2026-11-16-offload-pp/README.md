# Workstream 1: pipeline-parallel support for the KV offload to decode DRAM, progress log

Design: `designs/2026-11-16-kv-offload-pipeline-parallel/DESIGN.md` (revised 2026-11-16b after the code check).
Code: branch `pd-dram-offload-pp` of `alisachen-google/sglang-torchtpu`, worktree
`/mnt/disks/scratch/alisachen/sglang-pp-offload`, off upstream main `82e2b973`.

## State on 2026-11-16

| Item | State |
|---|---|
| Design "to verify" items | Checked in the code; three design points changed (Revision 2026-11-16b) |
| Cross-stage agreement primitive | Done: `sglang_tpu/disaggregation/decode_dram_offload/stage_votes.py` (commit `d4c6764a`) |
| Unit tests | 12 tests in `test/registered/unit/hardware_backend/tpu/test_decode_dram_offload_stage_votes.py`, pass on this VM (the module is torch-free and loaded by path); not yet registered with the repo's CI helper |
| Wiring into the pipeline loops, recall, push, validation, README | Not started |
| Live validation, perf, system errors | Not run: nothing is wired, so there is nothing to validate live |
| Draft PR | Not opened: one unused module would be dead code by the repo's own rules; open it when recall works end to end |
| CDK jobs | None submitted by this workstream |

## What the tests cover

- `TestFoldVotes`: first stage passes its votes; fold is the element-wise minimum over shared keys; rows of
  different length are an error; `agreed` needs every stage to vote the same row.
- `TestLedger`: a slot cannot be cast twice before its verdict; settle frees the slot; a verdict above this stage's
  vote, or for a key it did not vote on, is refused.
- `TestRingOfStages` (8 stages, 9 slots, 60 iterations, 20 random interleavings that respect the blocking receives):
  every stage applies the same verdict in the same iteration; the verdict is the minimum over stages and arrives one
  round later; one stage without host room withholds a recall for all; a stage that has not seen an offer drops the key.

## Why it stopped here

The remaining work is the two-phase rewrite of the four offload workers (about fifteen agreement call sites), the
hooks into both pipeline event loops, per-stage peer addressing, the startup validation, and then the on-cluster
loop. None of it can be unit-tested on this VM (no torch), upstream main needs a newer serving image than the one
the campaigns used, and whether a pipeline decode serves with the decode radix cache and HiCache is unverified. Each
of those is a prerequisite for a meaningful live run, so no cluster time was spent.

## Next steps, in order

1. Find or build an image that runs upstream main; run the existing offload unit tests there as a baseline.
2. Live check, switch off: a matching pipeline pair (`--pp-size 8 --tp-size 1` on one 2x2x1 host per role) with
   decode radix cache and HiCache; then the same on a 2x2x2 slice. This decides whether Phase A is viable.
3. Wire the ledger into `event_loop_pp_disagg_prefill` / `_decode` next to the existing consensus sends.
4. Recall (cast, settle, outcome vote at the pop), then push, then validation and README, each with its tests.
5. The live matrix of the design's section 7 on single-host and multi-host pipelines, then the draft PR.
