# Live validation of the restructured offload (PR 1992 head 8ec40f0eec), write-back, 2026-11-06

Pair: prefill on 10.128.15.217, decode on 10.128.15.239, TP8 each. Model Qwen3-30B-A3B-Instruct-2507-FP8, page 128,
fp8 KV, context 262144, write_back on both roles, offload switch on. Stack: torch_tpu 0.2.1.dev20261028201649,
libtpu 0.0.50, tpu-sync-torch 0.0.1.dev20261103081657 (first nightlies with the merged host-to-host read API).
Recipe `recipes/pd_1992_qwen_wb.json`, driver `harness/val_1992.sh` (chain_pair.sh with LAUNCHER=pd_main.sh),
caches flushed before every point, sticky routing by document.

| Point | Prefill hit % | TTFT p50 s | Input tok/s | Request errors | Pushes stored (cum.) | Recalls (cum.) | Recalled tokens (cum.) |
|---|---|---|---|---|---|---|---|
| recall, 12 sessions x 128k filled then recalled oldest first | 64.5 | 9.1 | 28038 | 0 | 28 | 7 | 660,224 |
| static reuse, 12 docs x 3 visits | 62.1 | 4.5 | 27194 | 0 | 68 | 16 | 1,577,600 |
| static reuse, 16 docs x 3 visits | 60.1 | 7.7 | 27283 | 0 | 155 | 31 | 3,049,856 |

End of run counters (rank 0; all 8 ranks of each role logged the same):
- prefill: `[victim-push] role=prefill started=155 stored=155`; recall totals `offers 43, pulls 31, pulled_tokens 3049856,
  skipped_local_host 12, no_memory 0, over_budget 0, failed 0`; `inserted=True` on 248 = 31 x 8 rank log lines.
- decode: `[victim-push] role=decode received=155 granted=155 landed=155 landed_tokens=5495040`; 0 refused pulls.
- No warning and no error in either server log before the harness stopped the engines; every flush succeeded (0 pair restarts).

Reference on the PR 1789 tree (same workload): static 12 docs 50.9% write-back only / 60.4% with the switch;
16 docs 39.2% / 61.0%.

Defects the live run found (unit tests build managers without their constructor and fake the native transfer):
1. `start_read(..., local_host_block_ids=...)`: the merged tpu-sync API takes host landing pages as `local_block_ids`
   with `destination="host"`; the engine refused to start (startup check) and the call would have raised.
2. The raiden channel read `manager._state_lock` in its constructor, which runs before the manager creates that lock:
   every scheduler process died at start with AttributeError.
Both are fixed in PR 1992; the same two fixes exist for PR 1981 as an unpushed local commit (worktree ~/sglang-1981, 478f2f3dc2).

Not exercised live: write-through, declined pushes and failed recalls (none occurred), ranks proposing different recall
ranges, the pair refusals, engine-start refusals.
