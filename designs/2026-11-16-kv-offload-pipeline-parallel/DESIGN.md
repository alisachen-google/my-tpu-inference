# Workstream 1: KV offload to decode DRAM with a pipeline-parallel prefill

Design walkthrough, 2026-11-16 (multi-host pipelines added the same day, section 4.7). Written against `sgl-project/sglang-torchtpu` main at `82e2b973`, which contains
the feature as merged: [PR 1992](https://github.com/sgl-project/sglang-torchtpu/pull/1992) (offload of cold prefill
KV to decode DRAM, commit `3dabdc26`) and [PR 2086](https://github.com/sgl-project/sglang-torchtpu/pull/2086)
(hybrid sliding-window models, commit `5c136df1`). Status: design verified against the code and revised (see Revision 2026-11-16b); the first building block is implemented on branch `pd-dram-offload-pp` of the fork (`d4c6764a`), nothing is wired into the engines. File and function names are the real ones in that tree;
statements marked **to verify** are things I inferred from reading and have not run.

## Revision 2026-11-16b: what the code check changed

The "to verify" items were checked against upstream main `82e2b973` (`managers/scheduler_pp_mixin.py`,
`disaggregation/prefill.py`, `decode_dram_offload/dram_offload_hooks.py`). Three design points change; sections 4.2
to 4.4 below are superseded where they conflict with this revision.

1. **The pipeline already has the agreement mechanism; reuse it instead of "stage 0 decides".** Every stage runs its
   own loop over `pp_loop_size = pp_size + pp_async_batch_depth` micro-batch slots, synchronized by blocking receives
   from the previous stage. For bootstrap and release it already does this: in a slot each stage folds its local
   view into what the previous stage sent (good rids intersect, bad rids unite) and passes it on
   (`_pp_pd_get_bootstrapped_ids`, `_pp_pd_send_control`); the last stage's fold is the consensus, which travels the
   ring (`_pp_pd_send_consensus_to_next_stage`, tag `_PP_PD_CONSENSUS_TAG`) and is applied by every stage when its
   loop reaches the next slot (`process_bootstrapped_queue`). So the rule is: **every stage votes, the last stage's
   fold is the verdict, every stage applies it in the same later slot.** No stage decides alone and no vote flows
   backwards. The delay is one trip of the ring, fixed by the loop, for both the lockstep wave and the buffered
   hand-off. Implemented as `decode_dram_offload/stage_votes.py` (fold, per-slot ledger) with a simulated-ring test.
2. **The bootstrap queue lives on every stage, and a request already leaves it only by consensus.** Each stage has
   its own `disagg_prefill_bootstrap_queue`; `pop_bootstrapped` is called on every stage with the consensus rids, and
   the offload's hook (`_pop_bootstrapped`) wraps exactly that method. A stage whose recall is not settled keeps its
   room in Bootstrapping, so it does not vote "good" and the request waits on every stage. The "hold the request
   until the last stage committed" step of 4.4 therefore needs no new protocol. What is still new is the
   all-or-nothing outcome: whether every stage's read succeeded has to be a stage vote, applied at the pop, because
   "bad" in the existing consensus fails the request and a failed recall must only fall back to computing.
3. **The existing workers are synchronous; under a pipeline they become two-phase.** Pusher, puller, receiver and
   offerer call `RankLockstep.reduce` about fifteen times and act on the result in the same step. With stage votes
   the result arrives one ring trip later, so each call site becomes "cast now, act when the verdict settles", with
   the state in between kept per key (push sequence number, bootstrap room). This is the bulk of the work and the
   main risk: every site needs its own answer to "what if the request left, the read failed, or the engine was
   flushed while the vote was in flight". Keeping one code path for TP-only and PP means the TP-only lockstep is
   expressed as the same two phases with a zero-length ring; that has to be shown not to change TP-only behaviour.

Also confirmed: the decode's pipeline loop has the same consensus points for prealloc, retract and transfer
(`_pp_pd_get_prealloc_ids`, `decode_transfer_status`), so the decode side can use the same ledger. Not confirmed by
code reading alone: that a pipeline decode runs with `--disaggregation-decode-enable-radix-cache` and HiCache at all
(no refusal found, no test found); Phase A depends on it and it needs a live check before anything else is built on
it. Upstream main no longer runs on the 2026-11-03 serving image, so every on-cluster test of this work first needs an
image that runs main.

Revised order of work: (a) live check that a matching pipeline pair serves with decode radix cache and HiCache,
switch off; (b) wire the ledger into both pipeline loops next to the existing consensus sends; (c) recall as cast
and settle, with the outcome vote at the pop; (d) push; (e) startup validation and the layout fingerprint; (f) the
unit and live matrix of section 7.

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

### 4.7 Multi-host pipelines (requirement added 2026-11-16)

The pipeline must also be supported when its stages span several hosts (`--nnodes` above 1, for example 16 stages over
the two hosts of a 2x2x2 slice, or 2 stages of TP8 each on its own host), and when the decode is a multi-host engine.
Sections 4.2 to 4.5 were written so that nothing in them assumes one host; this section lists what multi-host adds.

What already holds across hosts, from the tree:

- **Peers are addressed per rank, not per host.** Every rank registers its own `rank_ip` and `rank_port` at bootstrap,
  and the offload channel sends to those (`dram_offload_channel.py`). A stage on another host is just another address.
- **Ports and budgets are already per node.** The Raiden control port is `base + 6 * node_worker_rank`, where the node
  worker rank counts the ranks resident on that node including pipeline replicas (`host_pool.node_worker_rank`,
  `ranks_per_node(..., pp_size)`), and `SGLANG_RAIDEN_HOST_POOL_GB` is a per-node budget split over them.
- **The stage hand-off is slice-wide.** The lockstep wave and the buffered hand-off run over ICI between the devices
  of the slice, whichever host they sit on.
- **Two-host engines with the offload work today** at TP16 on both roles (the 3-hour stress run in
  `benchmarks/2026-11-10-pr2086-bench/STRESS-2026-11-11.md`), so cross-host rank agreement and host-to-host reads
  between multi-host engines are exercised; only the pipeline dimension is new.

What multi-host adds to the design:

| Topic | Requirement |
|---|---|
| Decision relay (4.2) | The down-relay and the up-votes travel on the CPU process group, which crosses hosts over TCP. The delay `D` must cover the slowest hop, so it is derived from the pipeline depth in micro-batches, never from wall time, and a stage that reaches an effective number without the record waits for it (a blocking receive on that tag) instead of guessing. |
| Host memory is per host | Each host has its own RAM and its own HiCache host pools. A reservation vote (4.4) is therefore per stage and can differ between hosts; the all-or-nothing rule already covers it. Host pressure for the pusher (4.3) is evaluated on stage 0's host; a stage on a fuller host votes "decline" and the push is retired as declined on every stage. Add the per-host free room to the periodic `[dram-offload]` line so an uneven pipeline is visible. |
| Sizing | Size each host's pools from that host's budget: its stages' layers times the tokens kept, plus the Raiden staging share, plus in-flight load. The stress run measured up to 250 GB of load-proportional growth on the second host of a two-host engine (ISSUES I10); the pipeline version must report RSS per host in its validation. |
| Fan-in and fan-out (Phase B) | A decode rank reads its head slice from every stage, so a push opens stages x decode-ranks host reads across hosts, and a recall the reverse. Bound them with one in-flight budget per engine (today `MAX_INFLIGHT = 4` pushes) expressed in sessions, and let the decode's rank 0 plan each push as one unit, as the regular pipeline transfer does. |
| A multi-host decode | Phase A pairs stage with stage wherever they sit. In Phase B the decode's ranks may sit on several hosts; each lands its slice in its own host pool, and "stored" still requires every rank of every decode host. |
| Failure | Losing any host of an engine loses the engine, as today. What must hold: the surviving peer engine fails or declines its in-flight pushes and recalls within the Raiden deadline, releases its pins, and is flushable. Set the socket timeouts on every host. A decision record that never arrives (a dead stage) must surface as the engine's existing distributed timeout, not as a silent stall. |
| Start-up validation | Refuse layouts where a stage's ranks straddle hosts in a way the pipeline itself refuses (`pp_stage_chips.py`), and include the host count and the per-host stage list in the layout fingerprint of 4.6 so that mismatched pairs fail by name. |

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
| 8 | Multi-host: per-host free room and RSS in the counters, layout fingerprint with hosts, blocking receive for a late decision record, per-engine in-flight budget | `rank_lockstep.py`, `dram_offload_channel.py`, `startup_validation.py` | A and B |
| 9 | Write-back copy-ahead is off under PP, so evictions back up synchronously; measure, and port the copy-ahead to the decision relay only if the stall shows | `hicache_write_back_copy_ahead.py` | after B |

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

Hardware: Phase A needs two pipelines of the same layout; Phase B a pipeline prefill and a TP decode. Single-host:
`--pp-size 8 --tp-size 1` on one 2x2x1 host. Multi-host, the required case: `--pp-size 2 --tp-size 8` or
`--pp-size 16 --tp-size 1` on one 2x2x2 slice (two hosts), then a 2x2x4 slice (four hosts) for a longer pipeline;
every test of the table above runs on both a single-host and a multi-host pipeline, plus one extra fault case:
kill one host of the pipeline mid-push and mid-recall and check the peer engine settles and is flushable.

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
