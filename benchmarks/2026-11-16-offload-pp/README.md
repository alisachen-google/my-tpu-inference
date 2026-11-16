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

## Update 2026-11-16 (later): target changed to Phase B, blocked on the byte path

The feature must serve the Muse Spark point (pipeline prefill, tensor-parallel decode). The pinned tpu-sync's host
reads move whole blocks only, so a stage block cannot be mapped onto a decode rank's block; see the design's
Revision 2026-11-16c for the evidence, three options (B1 tpu-sync spans, B2 foreign-layout store on the decode, B3
rejected) and the Muse Spark prerequisites (speculative decoding and draft KV first). No job was submitted: the
workstream 2 validation held the cluster, and no live run can answer the byte-path question. Decision needed from
the user: B1 (ask the tpu-sync owners) or B2 (build the decode-side store, after confirming the decode never loads
pushed pages).

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

## Update 2026-11-16 (later): option B2 started, with one changed assumption

Decision from the coordinator: build option B2 (stage-layout store on the decode). Before building it the code was
checked for what a switch-on decode does with a landed branch. Result, in the design's Revision 2026-11-16d: the
decode **does** load pushed branches into its own HBM. Its request match counts them (`_match_prefix_and_lock`,
`l2_host_hit_length`), it promises them to the prefill as `decode_prefix_len`, the recall offer is triggered by that
match (`_send_kv_metadata` hook), and `_process_hicache_local_restores` loads them. Under B2 that cannot work, so
for the pipeline pairing the branches live in a separate index, the recall is triggered by a match in that index,
and the decode receives the whole prompt over the wire on a recall turn. The tensor-parallel pairing is unchanged.

Second finding: the pinned tpu-sync wheel does not ship the host-only extension (`_tpu_raiden_host`), so
`KVCacheManager.create_host_only_for_testing` cannot be used. The store's pools must be ordinary managers built over
placeholder device tensors shaped like one page of a prefill stage, using only their host blocks. Whether that works
is unproven; the probe `test/manual/tpu/probe_stage_layout_host_store.py` on the branch tests it on one host
(source device, source host, store host, source host, source device, compare). It has not run: the workstream 2 jobs
still hold the cluster.

Code on `pd-dram-offload-pp` (fork), all torch-free and passing on this VM (49 tests):

| Commit | Module | What |
|---|---|---|
| d4c6764a | `stage_votes.py` | ring votes across pipeline stages |
| 4745864d | `stage_layout_store.py` | the decode's index: shared page paths, a window per pushed length, LRU eviction, pins, equal page ids on every rank; sizing and stage-to-rank placement |
| 26461392 | `decode_stage_branches.py` | decode receiver and offerer over the index; `StagePoolSet` builds one pool per hosted stage at the first push |

Placement rule: prefill stage `s` is hosted by decode rank `s mod decode_tp`. Stage zero also sends the branch's
tokens to every decode rank. Every pool on every rank has the same page count, so one page id names a page in all
stage pools and the ranks only agree on the index.

Not done: the raiden channel messages for stage pushes and pulls, the placeholder pool builder, the hook dispatch,
the whole prefill side (per-stage push and recall under ring votes), startup validation, README, CI registration,
the draft PR and every live run.

Hazard found for the prefill side: a vote cast in one micro-batch slot settles a full loop later, and the tree keeps
changing in between. A pick made at cast time (the leaf to push, the local prefix of a recall) can be evicted before
the verdict. The workers cannot be converted by replacing each blocking reduce with a delayed one; each call site
needs a rule for what is held between cast and settle, and locks taken before agreement would make evictions differ
between stages.
