# Workstream 1: KV offload to decode DRAM with a pipeline-parallel prefill

Design walkthrough, 2026-11-16. Written against `sgl-project/sglang-torchtpu` main at `82e2b973` (PR 1992 and
PR 2086 merged). Status: proposal, nothing implemented. File and function names are the real ones in that tree;
statements marked **to verify** are things I inferred from reading and have not run.

## 1. The goal in one paragraph

Today the offload (`SGLANG_ENABLE_PREFILL_KV_OFFLOAD_TO_DECODE_DRAM=1`) refuses to start when the engine uses
pipeline parallelism: `startup_validation.py` rejects `--pp-size` above 1 and, on a decode,
`SGLANG_RAIDEN_PIPELINE_TRANSFER`. We want a prefill that runs as a pipeline (the layout large models need, for
example `--pp-size 8 --tp-size 1`) to push its cold KV to the decode's host RAM and recall it later, with the same
guarantees the tensor-parallel version gives: outputs identical to a recompute, no request ever fails because of
the offload, and every rank's cache tree stays identical.

## 2. How it works today (tensor parallel only)

```
 prefill rank t                                   decode rank t
 ┌─────────────────────────┐                      ┌─────────────────────────┐
 │ radix tree (same on all │                      │ radix tree              │
 │ ranks)                  │                      │                         │
 │ HBM pool                │                      │ HBM pool                │
 │ HiCache host pool ──────┼── host-to-host ──────┼─▶ HiCache host pool     │
 │  page = all layers ×    │   Raiden read        │   page = all layers ×   │
 │  this rank's head slice │   (page for page)    │   this rank's head slice│
 └─────────────────────────┘                      └─────────────────────────┘
```

Three properties make this simple, and pipeline parallelism breaks each of them:

| Property today | Where it lives | What a pipeline changes |
|---|---|---|
| **One peer per rank.** Prefill rank `t` talks to decode rank `t`; the two host pages have the same bytes layout, so a push or a recall is a plain page copy. | `raiden/dram_offload_channel.py`, `radix_host_ops.py` | A pipeline stage holds only its own layers. A decode rank holds all layers. The page layouts differ unless the decode is the same pipeline. |
| **All ranks act in the same scheduler step.** Every tree decision (start a push, retire it, accept a recall, allocate host pages) is all-reduced over the attention-TP group so every rank does the same thing in the same step. | `rank_lockstep.py` (`RankLockstep.of` uses `scheduler.attn_tp_cpu_group`) | Stages run the same micro-batches in the same order but at different times: stage `r` sees a batch `r` hand-offs after stage 0. "The same step" no longer exists. |
| **A recall finishes before the forward.** The request waits in the bootstrap queue until its prefix is in host RAM on every rank. | `prefill_dram_prefix_puller.py`, `dram_offload_hooks.py` | Every stage needs its share of the prefix before its forward of that request, and it is all or nothing across stages: a stage cannot recompute its layers for prefix tokens the earlier stages skipped. |

## 3. What a pipeline-parallel prefill looks like

Facts from the tree that the design builds on:

- Each stage has its own scheduler loop, its own radix tree, its own HBM pool for its layers
  (`get_pp_indices` in `distributed/utils.py` gives each stage `[start_layer, end_layer)`), and its own HiCache
  host pool whose page row holds only those layers (`memory_pool_host.py`, `layer_num = len(device_buffers)`).
- Every stage runs the same micro-batches in the same order (`pp_buffered.py`, `pp_wave.py`). So the trees are
  the same **as a function of the micro-batch number**, not of wall time.
- HiCache already runs under PP and already has the agreement pattern we need: stage 0 reduces over its
  attention group, then the result is relayed stage to stage (`UnifiedRadixCache._pp_sync`, tag
  `HICACHE_PP_SYNC`). The write-back copy-ahead and the asynchronous ready-count reduce are turned off under PP.
- The regular prefill-to-decode KV transfer already handles a PP prefill: each stage registers its layers as
  named pools (`fa.lN`, `swa.lN`), the decode's rank 0 plans one transfer that pulls from every stage, and a
  tensor-parallel decode receives each page split by kv-head with strided byte spans
  (`raiden/README.md`, "Pipeline-parallel prefill"). That path moves HBM pools; the offload moves host pools.

## 4. Design

### 4.1 Two pairings, delivered in two phases

| Phase | Prefill | Decode | Page mapping | New tpu-sync work |
|---|---|---|---|---|
| **A** | `--pp-size S --tp-size T` | the same pipeline layout (`--pp-size S --tp-size T`) | stage `s` rank `t` ↔ stage `s` rank `t`, identical page rows | none expected |
| **B** | `--pp-size S --tp-size 1` | tensor parallel `--tp-size T` with `SGLANG_RAIDEN_PIPELINE_TRANSFER=1` | prefill stage `s` holds layers `L_s` × all heads; decode rank `t` holds all layers × head slice `t` | host-to-host reads with a layer offset and a head stride inside a host page |

Phase A exercises everything that is new on the control side (agreement across stages, all-or-nothing recall)
with the byte path unchanged. Phase B is the layout most deployments want and adds only the byte mapping. I
recommend building them in that order; section 6 lists what each needs.

### 4.2 Agreement across stages: decide on stage 0, apply by micro-batch number

The rule that replaces "every rank acts in the same step":

> **Stage 0 makes every offload decision. A decision carries the micro-batch number at which it takes effect.
> Every stage applies it when its own loop reaches that number.**

Because all stages replay the same sequence, a tree change applied at the same micro-batch number leaves every
stage with the same tree. This is the same idea as `_pp_sync`, generalized from "counts" to "offload decisions".

```
 micro-batch number n ───────────────────────────────────────────────▶
 stage 0   decide(push P @ n+D) ──relay──▶
 stage 1                         receives, applies at its n+D
 stage 2                                       receives, applies at its n+D
 ...
 votes (host pages allocated? transfer landed?) flow back to stage 0 point to point
```

- **Decision record** (small, fixed size): kind (start push, retire push with outcome, commit recall, cancel
  recall), the branch manifest already used for rank agreement (`push_manifest`: two 63-bit digests of tokens,
  extra key, salt and geometry), and the effective micro-batch number.
- **Transport down the pipeline**: a point-to-point send on the PP group with a new tag, next to
  `HICACHE_PP_SYNC`. Within a stage that has several attention ranks, the existing `RankLockstep` all-reduce still
  runs, unchanged, among that stage's ranks.
- **Votes up the pipeline**: each stage reports facts stage 0 cannot know (did the host allocation succeed, did
  my share of the transfer settle, did it fail). Point-to-point to stage 0, also keyed by decision.
- **Delay `D`**: a decision made at micro-batch `n` takes effect at `n + D`, with `D` at least the pipeline
  depth, so that every stage has received it before it reaches the effective number. Nothing blocks: a stage
  that reaches `n + D` already holds the record.

`RankLockstep` gets a second implementation behind the same interface (`all`, `max`, `min_max`, `agree`,
`common_to_all_ranks`, `alloc_host_pages_agreed`), selected in `RankLockstep.of` when `pp_size > 1`. The pusher,
puller, receiver and offerer keep calling the same methods; what changes is that a result becomes available `D`
micro-batches later instead of in the same step.

### 4.3 Push (prefill → decode)

Today: when the host pool runs low, every rank picks the same coldest host-backed branch, host-locks its path,
offers its pages (`VICTIM_PUSH`), the decode pulls and answers (`VICTIM_ACK`), and on "stored" the prefill makes
its own copy the next eviction victim.

With a pipeline:

1. Stage 0 picks the victim exactly as today and issues `start push P @ n+D`.
2. At its `n+D`, every stage host-locks the same path and registers **its layers' host pages** for the push.
   A stage whose branch is not host-backed votes "decline" (it should not happen, since eviction order is part
   of the replayed sequence, but the vote makes it safe).
3. The decode treats the push as one unit made of `S` shares. Phase A: each decode stage pulls from its prefill
   stage. Phase B: decode rank `t` pulls its head slice from every prefill stage, the way the regular pipeline
   transfer has rank 0 plan one transfer over all source stages.
4. The decode answers once: **stored** only if every share landed on every decode rank; otherwise it frees
   what landed and answers **declined**. A decode never keeps a partial branch.
5. Stage 0 turns the answer into `retire push P (stored | declined) @ m+D`; every stage unlocks at that number
   and, on "stored", marks its copy as the next victim.

The existing bounds stay per engine, not per stage: `MAX_INFLIGHT = 4` pushes, the 60 s ack timeout (a timeout is
a decline), and "push only while a request is queued or running".

### 4.4 Recall (decode → prefill), all or nothing

Today: the decode's `PULL_REQ` names the host pages it offers for a returning prompt; the prefill allocates host
pages, pulls, inserts the prefix as a host-only node, pins it, and the request leaves the bootstrap queue.

With a pipeline the request must not start on stage 0 until **every** stage holds its share. The sequence:

1. The offer arrives with the bootstrap of the request (as today). Stage 0 plans the pull (which pages, how
   many tokens, the SWA window on hybrid models) and issues `reserve recall R @ n+D`.
2. At its `n+D`, each stage allocates host pages for its layers and votes yes or no. No tree change yet.
3. All yes: stage 0 issues `commit recall R`. Each stage starts its host read, and when its read settles it
   inserts the prefix node and pins it, at the committed micro-batch number. All stages insert the same node at
   the same number.
4. Any no, any read failure, or the bootstrap timeout: stage 0 issues `cancel recall R`; every stage frees its
   pages and the request runs as a normal cold request. No stage ever holds a prefix the others lack.
5. The request is released from the bootstrap queue only after the commit has taken effect on the last stage.
   **To verify:** where the bootstrap queue lives under PP (`disaggregation/prefill.py` carries `pp_rank` and
   `pp_size`; whether only stage 0 admits or every stage does decides who holds the request).

The cost is latency on the recall path only: `D` micro-batches for the reservation plus `D` for the commit. A
recall replaces tens of seconds of prefill for a long prompt, so two pipeline depths of delay are acceptable;
cold requests and cache hits on the prefill's own tiers pay nothing.

### 4.5 Byte mapping

**Phase A (matching pipelines).** A host page row on prefill stage `s`, rank `t` has the same bytes as on decode
stage `s`, rank `t`. The channel code is unchanged; only the peer address is per stage (the Raiden control port
already encodes the worker rank across PP replicas, `SGLANG_RAIDEN_KV_PORT + 6 * node_worker_rank`).

**Phase B (pipeline prefill, tensor-parallel decode).**

```
 prefill stage s host page (tp 1):   [ layers L_s ] × [ all kv heads ]
 decode rank t host page:            [ all layers ] × [ head slice t ]

 push:   decode rank t reads, from every stage s, the bytes (layer ∈ L_s, heads of slice t)
         and writes them at layer offset L_s inside its page.
 recall: prefill stage s reads, from every decode rank t, the bytes (layers L_s, slice t)
         and writes them at head offset t inside its page.
```

The regular pipeline transfer already does this mapping for HBM pools (named per-layer pools, strided spans per
destination rank). The offload needs the same on the host-to-host path (`register_read` / `start_read` in
`dram_offload_channel.py`): a read whose source and destination are sub-ranges of a host page with a stride.
**To verify with the tpu-sync owners:** whether the host-to-host read API accepts strided spans today or needs
the equivalent of commit `120bab96` for host pools. The FP8 constraint carries over: a head slice must be whole
32-bit packs, so FP8 KV needs an even head count per decode rank.

**Hybrid sliding-window models.** The window travels as a second page set through the SWA host pool, as today,
and follows the same rules per stage: every stage moves the window pages of its own SWA layers, and the recall
takes the whole window on every stage or nothing.

### 4.6 Things that stay refused, and new refusals

- Still refused: speculative decoding, context and data parallelism on the prefill, recurrent-state models, the
  unified KV pool, the Rust tree, L3 storage, `--sleep-on-idle`.
- Phase A refuses a pair whose stage layouts differ (stage count, layer partition, attention TP per stage),
  through the handshake that `resharding_refusal` uses today: the request fails with the reason, the pair never
  runs silently without the offload.
- `SGLANG_TPU_USE_BLOCK_MAJOR_KV=1` (one bundle per attention group) is allowed in Phase A, refused in Phase B,
  matching the regular pipeline transfer.
- The early-transfer modes of the pipeline (`SGLANG_RAIDEN_PIPELINE_EARLY_PARTS`, `_STAGE_PARTS`,
  `_EARLY_CLOSE`) concern the request's own KV hand-off and are independent of the offload. First version:
  allowed, tested in the matrix below; refuse any that the tests break.

## 5. What does not change

- The switch, the two HiCache write policies, the decode keeping pushed branches only, back-pressure by decline.
- The decode-affine rule: a recall comes from the decode that received the push, so sticky routing matters.
- No HBM page and no staging slot on either role: bytes move host pool to host pool.
- The counters (`[dram-offload] push | landing | recall`), now also required to be equal across stages.

## 6. Work items

| # | Item | Files | Phase |
|---|---|---|---|
| 1 | Stage-relayed decisions behind the `RankLockstep` interface: decision record, down-relay, up-votes, effective micro-batch number, delay `D` | `decode_dram_offload/rank_lockstep.py`, `pp_scheduler.py` (micro-batch numbering) | A |
| 2 | Push: per-stage lock and registration, single ack per push, retire by decision | `prefill_dram_victim_pusher.py`, `decode_dram_victim_receiver.py` | A |
| 3 | Recall: reserve, commit, cancel; hold the request in bootstrap until the last stage committed | `prefill_dram_prefix_puller.py`, `decode_dram_prefix_offerer.py`, `dram_offload_hooks.py` | A |
| 4 | Peer addressing per stage; layout fingerprint in the handshake and its refusal message | `raiden/dram_offload_channel.py` | A |
| 5 | Lift the two refusals conditionally; add the new ones of 4.6 | `startup_validation.py`, `sglang_tpu/README.md` | A |
| 6 | Host-to-host strided reads between a stage page and a rank page (push and recall directions) | `raiden/dram_offload_channel.py`, `radix_host_ops.py`, tpu-sync | B |
| 7 | Decode-side planning of one push over all source stages and one recall offer over all decode ranks | `decode_dram_victim_receiver.py`, `decode_dram_prefix_offerer.py` | B |
| 8 | Write-back copy-ahead is off under PP, so evictions back up synchronously; measure, and port the copy-ahead to the decision relay only if the stall shows | `hicache_write_back_copy_ahead.py` | after B |

## 7. Validation plan

Unit level, no TPU: a simulated pipeline of `S` stage loops driven with shuffled relative delays, asserting that
the trees and counters are identical on every stage after every micro-batch, including with injected allocation
failures, transfer failures and timeouts at each step of push and recall.

On hardware, reusing the harness of the PR 2086 report (`benchmarks/2026-11-10-pr2086-bench/harness`):

| Test | What it proves | Pass condition |
|---|---|---|
| Integrity (`victim_integrity.py`, 16 sessions, recall one at a time, compare with a recompute after a flush) | A recalled prefix is the same KV on every stage | 16 of 16 identical, both write policies, fresh engines |
| Recall ladder 8, 12, 16 sessions and static ladder 4 to 16 documents, switch off vs on | The gain survives the pipeline | Same shape as the tensor-parallel results; no point worse than off beyond run-to-run spread |
| Counters | Every stage agrees | push, landing and recall counters equal on all stages and ranks; 0 `Scheduler hit an exception` |
| Fault cases: decode declines (full DRAM), a stage's allocation fails, a transfer times out, the decode vanishes | All or nothing | No failed request, no stage holding a partial prefix, engines idle afterwards |
| Stress stage (`stage_stress.sh`) at a fixed concurrency below saturation, 3 hours | No drift, no leak | Drain, verification batch, GSM8K gate and leak check pass each cycle |

Hardware: Phase A needs two pipelines of the same layout; Phase B a pipeline prefill and a TP decode. On the CDK
cluster a `--pp-size 2 --tp-size 8` prefill is one 2x2x2 slice (two hosts), which is the smallest useful case.

## 8. Open questions

1. **Which pairing do you need first?** The design assumes a pipeline prefill with a tensor-parallel decode is
   the target and matching pipelines are the stepping stone. If the deployment is pipeline on both roles, Phase A
   is the whole job.
2. Host-to-host strided reads in tpu-sync (section 4.5): available, or new work there?
3. Where the bootstrap queue lives under PP (section 4.4, step 5).
4. The value of `D`: the pipeline depth is the minimum; the lockstep wave owes `2 * (stages - 2)` zero launches
   after a send, the buffered hand-off has no such tail. One constant for both, or per hand-off mode.
5. Should the first version support hybrid sliding-window models, or full-attention models only with SWA as a
   follow-up? The control path is the same; it doubles the byte-path test matrix.
