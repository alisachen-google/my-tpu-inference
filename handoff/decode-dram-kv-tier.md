# Decode DRAM as an extension of the prefill's KV cache: handoff notes

Written 2026-10-25 for another engineer or AI agent picking up this work. It records what we
know about three systems (vllm-torchtpu, tpu-sync/Raiden, sglang-torchtpu), the goal, and the
one solution being pursued: the victim-cache branch `pd-victim-prefix-cache` on the fork. It
covers how that branch works, how it measured, the code as it stands, and what to do next.
Facts were checked against code at the commits named in each section; anything not verified
is marked.

Design website with diagrams, kept in sync with this file: <https://claude.ai/artifact/88muTVYCfUV99d8RXiGk3C>
(private to the owner). The sections for this work are `#bg-writers` and `#bg-demoted` (the
vllm-torchtpu reference), `#c-victim` (the branch, mapped) and `#c-victim-results` (measured).

---

## 1. The goal

A 1P/1D TPU pair (one prefill engine, one decode engine, each TP8 on its own host) runs
long multi-turn sessions. Prefill HBM plus prefill host RAM hold about 12 to 14 concurrent
128k-token sessions; past that, every later turn recomputes its whole prefix (6 s at 128k,
17 s at 256k). The decode host has hundreds of GB of RAM that the prefill cannot use.

**Goal:** when the prefill's host tier is under pressure, move its cold KV into the decode
host's RAM, and when a later turn needs it, bring it back instead of recomputing. Keep
SGLang's HiCache as the only owner of cache state (the radix tree is the directory) and use
Raiden only to move bytes ("HiCache manages, Raiden only moves").

Target model and rig: `openai/gpt-oss-120b` (hybrid: 18 full-attention + 18 sliding-window
layers, so every page has a full part and a window part), FP8 KV, page size 64, TP8+EP8 per
role, device pool 786,432 tokens per engine, 4 running requests. Hybrid sliding-window
handling is a first-class constraint, not an afterthought: a prefix is only usable if its full
KV and the window ending at the same token both exist.

---

## 2. How vllm-torchtpu does it (reference design)

Checked at vllm-torchtpu `eb1e752`, tpu-sync `cc93da2`, vLLM `v0.31.0`. Clone: `~/vllm-torchtpu`.

**Shape.** vLLM's scheduler has no host tier of its own. Host offload is a KV connector,
`TPURaidenOffloadingConnector` (`src/vllm_torchtpu/offload/raiden_connector.py`), over
tpu-sync's native `KVCacheStore`, constructed in `offload/raiden_store.py:353`. The store
owns the host DRAM, the hash directory, the LRU, pins, save/load jobs and its own
`RaidenController`. The engine's per-rank `KVCacheManager`s register with that controller as
passive DMA workers. Python only ever calls `lookup`, `insert`, `save`, `load`, `read_remote`
on the store (`raiden_store.py:478, 884, 916, 1039, 1044`); it never calls `TransferBuffers`.

**Writers of the decode host's RAM, in the store-servers recipe (`RECIPE_STORE_SERVERS=1`).**
- A: every block is written through from prefill HBM to the prefill's own store as it fills
  (`prepare_store` / `submit_store_job` then `store.save()` with no destination; local D2H).
- B: the evict sweep is the only writer into the decode host. `KVCacheStore::SweepOnce`
  (`kv_cache_store.cc:1833`) runs when free blocks < 3 % (episode ends at 5 %), nudged by
  `AllocateBlockIds`, else every 30 s. Victims: `GetEvictableKeys`, unpinned LRU, at most 128
  per step. Target: `GetPlacementTargets` from the global registry, live stores of the same
  `kv_pool_group` on the nearest higher tier, sorted by reported free blocks, top 4.
  `SaveRemote` (`kv_cache_store.cc:2139`) accepts only HOST-resident blocks and sends
  `WriteRemote`; the store node dedupes, allocates landing blocks without evicting, refuses
  with RESOURCE_EXHAUSTED when full, pulls DRAM to DRAM, and the source evicts after the ack.
- The store node on the decode host (`kv_cache_host_store_node_main`, tier 1) never sweeps
  further. The decode engine itself writes nothing there.
- Three local drops never reach the decode host: the allocation-time drop, no accepting
  target, a refused or failed transfer.

**Readers.** On a local miss the prefill's store asks the registry, which answers one owner
per block (round robin over all owners, caller excluded). `KVCacheStore::ReadRemote`
(`kv_cache_store.cc:1648`) then `HostOffloadBackend::LoadRemoteBlocks`
(`host_offload_backend.cc:1068`): allocate staging in the prefill's own host pool, call the
owner's `Fetch` RPC (the owner pins and pushes DRAM to DRAM), then a local H2D into HBM.
Nothing is inserted into the prefill's directory, so a repeat miss repeats the fetch.

**Registry roster.** Stores `RegisterStore` after their gRPC server is up; heartbeats every
300 s carry free blocks; TTL is 3 periods; expired entries are skipped by readers. A registry
restart empties the roster until stores re-register.

**Key takeaway.** vLLM never chooses a decode engine. The registry ranks store processes, and
the DRAM-to-DRAM move is a store-to-store operation on top of the Raiden controller.

---

## 3. tpu-sync / Raiden (the transport library)

Checked at tpu-sync `73499f1` (installed wheel `tpu_sync_torch 0.0.1.dev20261002213151`,
`~/venv/sglang/lib/python3.12/site-packages/tpu_sync/`) and `cc93da2` on GitHub.

**One Python class, two very different instances.** `tpu_sync/api/torch/kv_cache_manager.py`
`class KVCacheManager` (line 83). Its constructor picks a mode at line 136:
- `host_blocks_to_allocate=N`: one pinned host buffer of N pages. Used by **HiCache's host
  pool** (`sglang_tpu/raiden_transfer.py:156`, `local_control_port=0`). The host memory is the
  L2 cache itself. Calls used: `d2h`, `h2d` (raw PJRT DMA, all layers, pollable future).
- `max_blocks` + `num_slots`: transient host staging slots and a TCP control listener. Used by
  the **P/D engine** (`sglang_tpu/disaggregation/raiden/conn.py` `_start_engine`, line 501).
  Calls used: `register_read(req_id, uuid, block_ids)`, `start_read(req_id, uuid, endpoint,
  remote_ids, local_ids)`, `poll_stats`. Both sides name **HBM page ids**; staging is hidden.

On a hybrid model one rank runs four managers: P/D full, P/D window, HiCache full pool,
HiCache window pool. They share the device tensors but not host memory, and do not know each
other. This is the root of the "extra hop" discussion below.

**What `register_read` + `start_read` really does** (the "HBM-to-HBM" transfer of the P/D
handoff). There is no device-to-device network path on TPU; the NIC is on the host.
- Sender `TransferSendSession`: `AcquireStagingWithRetry` takes a staging slot,
  `StartPush` issues `D2hSyncDispatch` per layer into it, `SendNextLayer` sends with
  `H2hWriteDirectAsync` (`kv_cache/transfer_send_session.cc:322, 358, 459`).
- Receiver `TransferReceiveSession`: `AllocateStagingForLoad`, `ExecutePullRequest` names the
  receiver's staging blocks as destinations, `ExecuteLayerH2d` copies into HBM
  (`transfer_receive_session.cc:208, 514, 642`).
- So: HBM, PCIe, staging DRAM, network, staging DRAM, PCIe, HBM. Staging slots belong to the
  engine; HiCache cannot address them.

**DRAM-to-DRAM primitives that exist.**
- `RaidenController::TransferBuffers` (`core/controller/raiden_controller.cc:543`) fans out to
  workers; `WorkerServiceImpl::TransferBuffers` (`worker_service_impl.cc:137`) accepts only
  D2H, H2D and H2H (`IsH2H`, line 63) and rejects HBM to HBM. H2H ends in
  `KVCacheManagerBase::H2hRead` / `H2hReadExplicit` (`kv_cache_manager_base.cc:1435-1482`),
  which calls `BlockTransport::SyncPull` (`transport/block_transport.cc:1058`). This is what
  the store uses. It needs a controller process; sglang runs none.
- Bound in Python on every `KVCacheManager` (`frameworks/torch/tpu_raiden_torch_module.cc`):
  `H2hRead(peer, src_ids)` (line 558) and `H2hWrite(peer, src_ids)` (line 542), both
  same-id on the destination; and `push_registered_plan(uuid, peer, src_ids, dst_ids,
  layer_idx=-1, parallelism)` (line 344), explicit destination ids.
- Native `TorchKVCacheManager::PushRegisteredPlan` (`frameworks/torch/kv_cache_manager.cc`,
  verified on GitHub at `cc93da2`): checks peer non-empty and equal non-empty id lists, then
  `transport->AsyncPush({peer}, src, dst, parallelism, kLayerMajor, uuid, layer_idx).Await()`.
  **It does not look up a registered plan** despite its name; the uuid only labels the push.
  It reads host blocks directly, no device memory. The receiver's `HandleIncomingPush`
  (`block_transport.cc:495`) lands explicit-destination pushes (`op == 6`) straight into the
  named host blocks; its begin/end hooks are no-ops on a HiCache-mode manager.
- Not bound in Python: `H2hReadExplicit(peer, src_ids, local_ids)`, the destination-driven
  pull with free choice of landing pages. Binding it is about 20 lines in the torch module and
  is a good upstream proposal.
- Every manager starts a block-transport server on an ephemeral port; `transfer_address`
  reports it. That is the `peer` string for any H2H call.

**API we added: `KVCacheManager.h2h_push`.** `h2h_push(peer, src_block_ids, dst_block_ids,
uuid, layer_idx=-1, parallelism=1)`, a named, documented, keyword-only wrapper over
`push_registered_plan`, rejecting empty or mismatched id lists.
- **tpu-sync commit `4dacbe3b`** on local branch `h2h-push` in `~/tpu-sync` (a clone of
  `google/tpu-sync` at `0d6e6e09`; not pushed, the owner has read-only access). One commit with
  the API in `tpu_sync/api/torch/kv_cache_manager.py` and three tests in
  `tpu_sync/api/torch/kv_cache_manager_host_test.py` (`H2hPushTest`): forwarding and argument
  validation against a fake impl (both pass), and a loopback push between two host-only
  managers that checks every layer lands in the named blocks and other blocks stay untouched.
  The loopback test needs the CPU-only native module `_tpu_raiden_host`, which the installed
  wheel does not ship, so it has **not been run**; run it in a tpu-sync bazel build
  (`//tpu_sync/api/torch:kv_cache_manager_host_test`).
- **On the hosts**, the same API is applied to the installed wheel through the patch the sglang
  branch carries, `sglang_tpu/disaggregation/raiden/tpu_sync_h2h_push.patch`. Applied on the
  decode host (b) only; **apply it on the prefill host (a) before a live run**.

---

## 4. sglang-torchtpu, the parts that matter

**Request routing.** In PD mode the gateway (`sgl-model-gateway/src/routers/http/pd_router.rs`
`select_pd_pair`) picks one prefill and one decode per request, stamps `bootstrap_host/port`
and a fresh `bootstrap_room`, and sends the same request to both. The room binds that pair for
the request. Only that decode ever sees the request. MiniLB gained session affinity by
`x-routing-key` on 2026-10-23 (sglang-torchtpu #1691, `--mini-lb-policy session_affinity`),
which is what any decode-held cache needs with more than one decode.

**HiCache (the cache).** `UnifiedRadixCache` (`python/sglang/srt/mem_cache/unified_radix_cache.py`)
over the Python `UnifiedTreeCore` (`unified_cache/unified_tree_core.py`). Each node holds per
component a `value` (device page indices) and a `host_value` (host page indices).
`backuped` = has host copy, `evicted` = no device copy (lines 165-176). A node is device-only,
device-and-host, or host-only; dead nodes are removed; there is never a second node per tier.
`match_prefix` (`unified_tree_core.py:886`) walks tokens from the root, collects device values
while present (`device_indices`), keeps walking through host-only nodes (`host_hit_length`),
stops at a node with neither. The scheduler treats `len(prefix_indices) + host_hit_length` as
matched and runs `load_back` (`unified_radix_cache.py:1721`) before the request, which issues
an H2D on the host-pool manager. Running requests enter the tree only at `checkpoint` (line
1056). `insert_host` (`unified_tree_core.py:2348`) inserts a host-only path;
`inc_host_lock_ref` (867) pins a node on the host tier; `evict_host` (1357) frees host pages.
Host pool on TPU: `sglang_tpu/kv_pool_host.py` `TpuRaidenHostKVCache` (`alloc` 163,
`_to_page_ids` 193, `.transfer` = `RaidenKVTransfer`). Anchor pool for full KV:
`cache.cache_controller.mem_pool_host.anchor_entry.host_pool`.

**Raiden manager (`sglang_tpu/disaggregation/raiden/conn.py` `RaidenKVManager`).** Owns the
P/D handoff: builds the P/D engines (`_build_engine` 429), runs the per-room protocol over a
per-rank ZMQ socket (`PULL_REQ`, `BLOCKS`, `CHUNK`, aborts, reshard), holds leases on
registered pages until Raiden reports the read settled, polls `poll_stats`
(`_poll_engine_status` 825). It knows nothing about tokens or cache policy. **ZMQ carries only
metadata** (ids, page numbers, msgspec-encoded, types in `serde.py`); bytes go over Raiden's
block transport. `push_registered_plan` appears in this module family only in the
asymmetric-TP reshard path, which still stages HBM through `d2h` and lands in decode HBM.

**No global directory.** Nothing in HiCache or the branch knows which decode's RAM holds which
KV. KV events (`BlockStored`/`BlockRemoved`), L3 storage backends, and the gateway's
cache-aware tree are the nearest things. The branch relies on the room binding plus session
affinity instead.

---

## 5. The branch solution and how it measured

**Idea.** The prefill stays the primary prefix cache. When its host pool runs low, it exports a
cold cached session (a "victim") to the decode that served that session, and after the decode
stores it, the prefill makes its own copy the next thing it evicts. The decode keeps pushed
victims in its radix tree and stops caching the requests it serves. On a later turn the decode
offers the prefix it holds (in its `PULL_REQ`), and the prefill pulls only the pages it lacks
from both of its own tiers before computing the suffix. Ownership is recorded per cached leaf
at checkpoint, so the export goes to the decode the router will send the session's next turn
to; with several decodes this requires session affinity at the router.

Measurements on the pair, gpt-oss-120b. Workload "ladder": N concurrent sessions, 131k-token
unique prefix, 4 turns of 4k new tokens + 256 output tokens. Baseline is the same recipe with
the two feature switches off (prefill-only caching, HiCache prefill ratio 1.2, decode ratio 3.5).

| Version | Transport for the export | 16-session ladder | Status |
|---|---|---|---|
| Device path (earlier history, `0b8149c3c1` in the backup branch) | P/D engine: a host-only victim is loaded back into prefill HBM, read into decode HBM through both staging slots, reaches decode RAM only via the decode's write-through | 375 s, 43.7 tok/s; baseline 386 s, 42.5 tok/s | Measured 2026-10-24 (runs `victim_3`, `victim_base_3`) |
| RAM-to-RAM, `c0e561665c` (current) | HiCache host pool to HiCache host pool with `h2h_push`; landed as a host-only node | not run yet | 11 victim tests; 320 tests across the touched suites pass on CPU |

**Device path, measured.**
- Ladder 12/16/20 sessions: 254/375/475 s against the baseline's 289/386/484 s, within noise.
- Pushes at 20 sessions: 2,057 started, 29 stored, 2,028 declined "no room". The decode's
  admission keeps 25 % of its device pool free, and four running 131k requests on a 786k pool
  never leave that much. Reverse pulls committed in the whole run: 6.
- Session sweep (4k prefixes, 4 turns in 2 rounds, concurrency 4): 64 and 128 sessions about
  19,000 tok/s on both; token hit rate 83 % vs 97 %, because the branch disables the decode's own
  cache of served requests.
- 256 sessions: at 01:50:48 three rooms logged "ranks planned different pulls, giving up" on
  every prefill rank and the prefill stopped completing requests; at 01:58:24 six prefill ranks
  aborted in tpu-sync (`absl raw_hash_map::at`, a missing native map key) and the pair died.
  Undiagnosed. The baseline completed 256 and 512.
- Single-turn recall after a prefill flush recomputed (6.35 s at 128k); by design this test
  cannot hit, since an idle single request is never pushed.
- Conclusion: landing victims in decode HBM does not work at this pool size, which motivated
  the RAM-to-RAM rewrite.

---

## 6. Current code (what the next agent starts from)

**Fork branch `alisachen-google/sglang-torchtpu:pd-victim-prefix-cache` at `c0e561665c`**,
worktree `~/sglang-victim` on the decode host. Two commits on top of upstream main `49ddede7`: `bee4c18a52` carries the tpu-sync (Raiden)
`h2h_push` change with its unit tests as a format-patch, and `c0e561665c` is everything else
(victim cache, the live-run hardening fixes, and the RAM-to-RAM push). The earlier five-commit
history is kept locally as branch `backup/pd-victim-prefix-cache-5commits`.

Opt-in: `SGLANG_DISAGG_PREFILL_PULL_DECODE_PREFIX=1` and `SGLANG_DISAGG_PREFIX_VICTIM_PUSH=1`
on both roles; HiCache with `--hicache-io-backend raiden` on both; decode
`--disaggregation-decode-enable-radix-cache`; PP=1; matching attention TP/CP; Python unified
tree. Hybrid: `SGLANG_TPU_PD_DECODE_SWA_HOST_WINDOWS` on decode,
`SGLANG_TPU_ENABLE_PD_PREFILL_SWA_PATH_END_BACKUP` on prefill.

**Victim push, current flow** (`sglang_tpu/pd_victim_push.py`):
1. Prefill `PrefillPusher.step` (284), every bootstrap step, every rank: settle in-flight
   pushes, then if host free tokens < 65,536 and < 4 in flight (MIN-reduced), `_maybe_start`
   (409): `_pick` (465) the oldest routed childless leaf with a host value; agree on its
   fingerprint; `_host_pages` (154) collects host page ids root to leaf (None if any node lacks
   a host value or has a write-through pending); agree on length and page count; host-lock the
   leaf; `send_victim_push` (`sender.py:553`) sends `VictimPush(prefill, seq, ack_endpoint,
   tokens, blocks)`.
2. Decode `DecodeReceiver.step` (554), every 16th decode iteration: gather pushes every rank
   holds; `_grant` (603) validates, allocates host pages (evicting host LRU if short), MIN-
   reduces success, replies `VictimAck(seq, stored, landing, address)` with landing page ids
   and the decode host pool's `host_transfer_address`, or a refusal.
3. Prefill `_settle` (310): on an ack with landing pages, `_start_push` (345) runs
   `RaidenKVTransfer.push_host_pages` (`raiden_transfer.py:205`, which calls tpu-sync
   `h2h_push`) on a thread; when every rank's push finished, MIN-reduce `ok`, send
   `VictimDone(prefill, seq, ok)`, release the host lock, and on success reset the path's LRU
   position so the local copy is evicted first.
4. Decode `_finish_agreed` (643): gather done notices every rank holds; on ok `_insert` (678)
   via `insert_host` from the root with the landing indices and page hashes, freeing pages the
   tree already held; on failure free the landing; landings with no done after 180 s expire.

**Reverse prefix pull (unchanged, still device path).** Decode promises an offer in
`PULL_REQ` (`receiver.py:278`), names device pages in `PREFIX_OFFER` after any HiCache restore
(`decode.py:2906`); prefill `DecodePrefixPuller._plan` (`prefix_pull.py:365`) asks only for
pages missing from both its tiers; decode registers (`receiver.py:391, 464`); prefill reads
into fresh HBM pages and inserts at commit (`prefix_pull.py:489, 561, 272`). A pushed
host-only node on the decode is restored to decode HBM before the offer.


---

## 7. Open problems and next steps, in order

1. **Apply the tpu-sync patch on the prefill host** and sync the worktree
   (`~/pd_disagg/spill/sync_victim_to_a.sh`).
2. **Validate `h2h_push` on hardware** between two HiCache host pools before anything else: a
   one-page push from prefill rank 0's host pool to decode rank 0's, then compare bytes with
   `read_block_bytes`. No live test has ever pushed between two HiCache pools. Also run the
   loopback unit test in a tpu-sync build.
3. **Rerun the victim chain** (`~/pd_disagg/spill/chain_victim.sh`, recipes
   `~/pd_disagg/recipes/gpt-oss_C_victim{,_base}.json`): ladder 12/16/20, sweep 64 to 512,
   stress. Add `--mini-lb-policy session_affinity` if the harness uses MiniLB. Success
   criterion: the 16-session ladder well below the 386 s baseline, with most pushes stored
   rather than declined, and the 256 and 512 sweep points completing.
4. **Diagnose the 256-session defects**: the rank-divergent pull plan (the plan depends on each
   rank's own tree; a mismatch "gives up" but evidently leaves ranks out of step) and the native
   missing-key abort eight minutes later. Logs: `~/pd_disagg/results/runs/victim_3/
   {prefill,decode}/server.log` (the prefill log is on host a, readable with sudo). Related
   upstream: sglang-torchtpu #854 (agree the matched prefix across attention-TP ranks).
5. **Sliding window**: the RAM-to-RAM push sends only FULL. On gpt-oss a pushed session is only
   pullable if the decode still has the window. Next: push the path-end window from the prefill's
   SWA host pool into the decode's SWA host pool with a second `h2h_push`, and insert the SWA
   component's host value with it.
6. **Recall RAM to RAM**: the reverse pull still goes through decode HBM (restore, then device
   read). Replace it with a fetch that lands in the prefill's host pool via `h2h_push` from the
   decode side, then let HiCache's own `load_back` finish.
7. **Decide** whether the decode should keep caching what it serves (turning it off cost
   97 % to 83 % hit rate in the sweep) and whether the prefill should free its copy at once
   after a stored push or only move it to the front of its LRU (current behaviour).
8. **Upstream tpu-sync**: propose commit `4dacbe3b` (or a native `H2hPush`, or binding
   `H2hReadExplicit` for a destination-driven pull).

---

## 8. Environment and rules for whoever continues

**Hosts.** Decode host b `10.128.0.90` (this machine, user `alisachen_google_com`). Prefill
host a `10.128.15.217`, reached as `sa_101411256518727260534@10.128.15.217` with
`~/.ssh/google_compute_engine`, then `sudo -n -iu alisachen_google_com`. Venv
`~/venv/sglang` on both. Root disks are near full; the launcher prunes inductor caches.
Shared TPU hosts: never kill other users' processes; check with `~/pd_disagg/scripts/tpu_free.sh`.

**Harness.** `~/pd_disagg/spill/`: `pd_victim.sh start|stop`, `chain_victim.sh` (W1 recall,
ladder, sweep, stress, then the baseline), `phase_victim_full.sh`, `victim_sessions.py`,
`victim_report.py` (has a JSON-control-character bug on long SUMMARY lines), results in
`~/pd_disagg/spill/results/`, phase logs in `~/pd_disagg/spill/logs/`, engine logs in
`~/pd_disagg/results/runs/<run>/`.

**Unit tests.** `PYTHONPATH=<worktree>/python:<worktree> ~/venv/sglang/bin/python -m pytest
test/registered/unit/disaggregation/test_raiden_prefix_pull.py
test/registered/unit/hardware_backend/tpu/test_pd_victim_push.py
test/registered/unit/hardware_backend/tpu/test_pd_decode_swa_hicache.py` (plus the five other
disaggregation suites the branch touches). PYTHONPATH must point at the worktree, or the
`sglang` package resolves to `~/sglang-torchtpu` main. Pre-commit:
`~/venv/sglang/bin/pre-commit run --files <changed files>`.

**Rules the owner set.**
- Never commit or push to upstream `sgl-project/sglang-torchtpu` for this work; the fork
  `alisachen-google/sglang-torchtpu` is fine.
- Commit as `alisachen-google <280552753+alisachen-google@users.noreply.github.com>` with no
  Co-Authored-By or session trailers.
- Open PRs as drafts; mark ready only after unit tests, live validation and upstream CI pass.
- TPU code stays in `sglang_tpu/`; no new `is_tpu()` or `sglang_tpu` imports in core.
- Never reference the private results repo in upstream issues, PRs, comments or code.
- Never use bare `git stash` in the shared worktrees.

**Code style rules in the repo** (`.claude/rules/`): `msgspec.Struct` not dataclasses, no
defensive `getattr`, short comments with anchored magic numbers, keyword arguments, small
functions. The victim code still uses a few `getattr` on `req` attributes inherited from the
original; fix opportunistically.
