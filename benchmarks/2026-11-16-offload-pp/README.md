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

> Workstream 1 commit ids, second rewrite (2026-11-16 about 21:40Z): PR 2202 is now 3 commits, head `c61131c7`, tree identical to `99118811`: `324a6f7a` decode-side store, decode workers and Raiden channel; `fe8b69d0` prefill stage ops, wiring, validation, byte check, draft opt-in; `c61131c7` manual live checks and README. Ids of the 9-commit history now read "new id (9-commit id)"; the ids before the first rewrite stay in their parentheses. Backups: local branches `pr2202-before-3commit` and `pr2202-before-squash` in `/mnt/disks/scratch/alisachen/sglang-pp-offload`.

> Workstream 1 commit ids: PR 2202 was rewritten into 9 commits at 2026-11-16 about 19:50Z (head `04e89a10`, same tree as the old head `62d7dcb2`). Where an old id is cited it now reads "new id (old id before the history rewrite)". Older workstream 1 ids without a mapping (for example `b2244a8a`, `cab47428`, `1effe708`) exist only on the local branch `pr2202-before-squash` in `/mnt/disks/scratch/alisachen/sglang-pp-offload`.

## Result as of 2026-11-16 17:15Z

Draft PR: https://github.com/sgl-project/sglang-torchtpu/pull/2202 (fork branch `pd-dram-offload-pp`, head `c61131c7 (04e89a10 in the 9-commit history)` after the history rewrite; `f3a5199a` at the time of this table).
Everything below ran on the shared CDK cluster, image `sglang-torchtpu:anvil-jax0112-97afaea9` plus the tree's pinned
tpu-sync `0.0.1.dev20261112081648` and `libibverbs1`, tree staged with `--map-dir`. Evidence per job is in `runs/`
(check output and the engines' `[dram-offload]` counters). All jobs are deleted except the one named at the end.

### Live matrix (offload on)

| Model and shape | Job | Pushes stored | Recalls / pages | Failed, tracebacks | Second turns from cache |
|---|---|---|---|---|---|
| Qwen3-30B, prefill pp8 tp1, decode tp8 | `j-7c625460-2ac7-4c7e-a511`, `j-0aefbbd3-81fa-4a08-ab5b` | 24 of 24 | 47 / 1,175 and 93 / 2,325 | 0 | 24 of 24 |
| Qwen3-30B, prefill pp16 over two hosts, decode tp16 over two hosts | `j-c79f10b7-e1f8-43a0-bd67` | 24 of 24 on all 16 stages | 93 / 2,325 | 0 | 24 of 24 |
| gpt-oss-120b (hybrid), prefill pp8 tp1, decode tp8 | `j-9933628c-7e68-4c7a-bdc3` | 33 of 33, with windows | 100 / 5,560 | 0 | 24 of 24 |
| Muse Spark Open, nightly PP8 + TP8 config, draft off | `j-7f22262c-0199-4230-9653` | 66 of 66, with windows | 47 / 580 | 0 | 20 of 20 |

### Integrity

| Check | Job | Result |
|---|---|---|
| Byte check on Muse Spark (each stage hashes pushed and recalled host pages) | `j-7f22262c-0199-4230-9653` | 1,116 pages verified on each of 8 stages, 0 mismatched |
| Byte check on gpt-oss-120b | `j-02219a9d-db9e-4078-be4e` | 5,800 verified, 0 mismatched |
| Recalled answer against the answer resumed from the prefill's own cache, gpt-oss | `j-9933628c-7e68-4c7a-bdc3` | 48 of 48 identical |
| Recalled answer against the cold answer, Qwen3-30B | `j-7c625460-2ac7-4c7e-a511`, `j-0aefbbd3-81fa-4a08-ab5b` | 72 of 72 identical |

On the hybrid models a cold answer is not a valid reference: resuming from any cached prefix changes some greedy
answers with the offload off as well (gpt-oss: 10 of 24; control `j-f83c694c-d85c-4d76-adb2`). Concurrent bursts change
some answers on every model, off and on (control `j-a8c3a35f-9174-44f0-99f8`).

### Performance, off against on (time for the sequential second turns)

| Case | Off | On | Jobs |
|---|---|---|---|
| Qwen3-30B, 24 prompts of 3.3k tokens | 13.2 s | 14.8 s | `j-a8c3a35f-9174-44f0-99f8`, `j-0aefbbd3-81fa-4a08-ab5b` |
| Qwen3-30B, 10 prompts of 28.5k tokens (8 recalled) | 17.8 s | 16.4 s | `j-9e468308-a2ad-4770-89e8`, `j-27d85d13-2dcc-4ada-bcd1` |
| Muse Spark Open, 20 prompts of 3.5k tokens | 37.4 s | 35.4 s | `j-465c8fec-db0b-4abd-bb9b`, `j-90f6c45b-04c6-4461-a92a` |

A recall costs two to three pipeline loops before its request leaves bootstrap. On Muse a second turn reuses only the
prompt up to where the 2,048-token sliding window starts. No long-prompt or AgentX measurement on Muse yet.

### Not done

- Speculative decoding. The nightly Muse config runs DFLASH; the offload refuses it because the draft KV of a cached
  prefix is in HiCache's draft sidecar pool, which is not moved. It needs one more pool kind per stage on the decode.
  The Muse runs here turned the draft off, a deviation from the nightly config.
- Attention DP on the prefill (upstream's `agentic.py` PP2 x TP4 shape), a stress run, an agentic trace.
- In the long-prompt run 5 of 38 recalls were given up before any read; the cause is not confirmed.
- The standalone on-device probe and a cluster unit-test job never got a node; unit tests run on this VM
  (`/mnt/disks/scratch/alisachen/tmp/ut.sh`).

### DFLASH (2026-11-16 19:15Z)

Design: DESIGN.md Revision 2026-11-16f. Implemented behind `SGLANG_PD_OFFLOAD_ALLOW_DRAFT=1` (fork commit `fe8b69d0 (1f6d7c29 in the 9-commit history) (ee32d752 before the history rewrite)`):
each stage moves its HiCache draft sidecar pools at the page ids of the pools they follow.

Live, `j-b351f388-1542-4f20-ac94` (deleted, evidence in `runs/`): Muse Spark Open, nightly PP8 config unchanged
(DFLASH on), offload on, opt-in on both roles, byte check on, 20 sessions.

| | Result |
|---|---|
| Job, check, tracebacks | Succeeded, exit 0, none |
| Start-up | 2,494 s |
| Which stage has the sidecar | the last one (PP7): 5 tensors, 2.50 MiB a page; decode rank 7 built the matching 640-page pool |
| Pushes stored, every stage | 61 of 61 |
| Recalls / full pages pulled | 26 / 376 |
| Byte check, stages 0 to 6 | 680 pages verified each (376 full + 304 window), 0 mismatched |
| Byte check, stage 7 | 1,056 verified (the same plus 376 draft sidecar pages), 0 mismatched |

The opt-in gate is still in place. The byte check passed with the sidecar pages included. The answer check reported no
failure but compared nothing on Muse (no second turn resumed at the warm reference's cached length), and no
speculative acceptance figure was collected, so "a recalled prefix drafts as well as a local one" is shown at the
byte level only. Removing the gate is a small change in `startup_validation.py`, `pd_decode_swa_hicache.py` and
`dram_offload_hooks.py`; it is left for a decision.

Decision (coordinator, 19:25Z): the gate stays. Status line: DFLASH is opt-in, byte-verified live on the Muse nightly
config in one run; the gate is left in pending answer-level and acceptance evidence. Removing it is the user's call.

### DFLASH comparison runs (2026-11-16 21:00Z to 2026-11-17 01:00Z)

All Muse Spark Open, nightly PP8 config unchanged (DFLASH on), same 20 sessions of 3,452 tokens. Jobs deleted, evidence
in `runs/`. Time and accept length are for the 20 sequential second turns of the first pass.

| Run | Job | Second turns resumed from | Time | Accept length |
|---|---|---|---|---|
| offload on, draft opt-in | `j-3fb296ed-17c7-4bdd-8762` | device tier at 1,280 tokens (no recall yet) | 32.5 s | 6.25 |
| offload off, equal settings | `j-2e39db5f-b6fd-4fd5-8ed0` | device tier at 1,280 tokens | 32.5 s | 6.15 |
| offload off, prefill host ratio 12 | `j-0adaa33e-78f4-497e-9302` | own host tier at 3,328 tokens | 20.3 s | 4.94 |
| offload off, host ratio 30, 40 fillers | `j-e883dfc5-8c6a-4b63-bc0c` | own host tier at 3,328 tokens | 20.3 s | 5.03 |

What these show:

- The draft path is deterministic: cold and warm answers are identical across independent jobs (20 of 20 each).
- On Muse a turn that lost its sliding window resumes at the prompt minus the 2,048-token window (1,280 tokens) and
  recomputes the window; with the window available it resumes at 3,328. That is the gain a timely recall can deliver:
  20.3 s against 32.5 s.
- In the offload-on run nothing was recalled in the first pass, so on and off are equal (32.5 s). The pushes (13 to 30 a
  minute, only while serving) had not stored the branches before the windows left the prefill, and the decode's pools
  held 10 windows with the draft sidecar in the budget.
- With the offload off, 11 of 20 turns resumed from the prefill's own host tier answer differently from the same turns
  resumed from the device tier at the same cached length. An answer difference after a recall can therefore not be
  held against the offload on this model. The byte check is the integrity evidence.

Still missing: an offload-on run in which the first-pass second turns are recalled (the run with 40 filler sessions
and a 16 GB stage store, below), to compare answer digests and accept length with `j-e883dfc5-8c6a-4b63-bc0c` and to
measure the recall's time against 20.3 s and 32.5 s.

### Still on the cluster (as of 2026-11-17 01:00Z)

`j-a8369017-1583-4683-9b55`: Muse, DFLASH on, offload on, draft opt-in, 16 GB stage store, 40 fillers. Queued 3 h, ran
29 min, preempted (spot), retry 12 of 30, pending again. When it reports: read `STAGE_OFFLOAD_CHECK` (`turns`,
`accept_length`, `seconds`) in the bench container, compare the `turns` digests with
`runs/j-e883dfc5-8c6a-4b63-bc0c-*/check.txt`, read the prefill's `[dram-offload] stage` counters, then delete it.
