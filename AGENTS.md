# Context for agents working in this repo

This is a private notes repo owned by alisachen-google. It holds working knowledge about TPU
inference stacks: code reviews of vllm-torchtpu PRs, and handoff notes for ongoing
sglang-torchtpu work. No code in this repo runs. Read this file first, then the file for your task.

## Where things are

| Path | What it is | Read it when |
|---|---|---|
| `README.md` | Index of everything here, with dates | Always, to find the latest notes |
| `handoff/decode-dram-kv-tier.md` | Current state of the "decode DRAM as an extension of the prefill KV cache" project: how vllm-torchtpu, tpu-sync/Raiden and sglang-torchtpu work; the victim-cache branch solution with measurements, code on the fork and in tpu-sync, next steps, hosts, harness, rules | Continuing any P/D disaggregation, HiCache, Raiden or KV offload work |
| `reviews/vllm-torchtpu/PR-<n>.md`, `RFC-<n>.md` | Review notes for vllm-torchtpu PRs (Qwen4Exp stack, RFC #1955), with findings by severity and ready-to-paste comments | Reviewing or following up on those PRs |

## The three systems, in one paragraph each

- **vllm-torchtpu** (`vllm-project/vllm-torchtpu`, local clone `~/vllm-torchtpu`): vLLM on TPU.
  Host KV offload is a connector over tpu-sync's native `KVCacheStore`, which owns host DRAM,
  a hash directory and an LRU. An evict sweep moves the store's cold blocks DRAM to DRAM to
  store-node processes on other hosts, chosen by a global registry.
- **tpu-sync / Raiden** (`google/tpu-sync`, installed as `tpu_sync_torch` in `~/venv/sglang`):
  the transfer library. `KVCacheManager` runs either as a P/D engine (HBM page ids, hidden host
  staging) or as a HiCache host pool (one pinned host buffer). There is no device-to-device
  network path on TPU. Host-to-host pushes exist (`push_registered_plan`, and our wrapper
  `h2h_push`).
- **sglang-torchtpu** (`sgl-project/sglang-torchtpu`; our fork `alisachen-google/sglang-torchtpu`):
  SGLang on TPU. HiCache's radix tree is the cache directory for device and host tiers;
  `sglang_tpu/disaggregation/raiden/conn.py` runs the P/D handoff over a per-rank ZMQ control
  socket, with bytes on Raiden.

Details, code pointers and line numbers are in the handoff note, not here.

## Rules from the owner (apply to any code work these notes lead to)

- Do not commit or push to upstream `sgl-project/sglang-torchtpu` for the spill/victim work;
  use the fork `alisachen-google/sglang-torchtpu`.
- Commit as `alisachen-google <280552753+alisachen-google@users.noreply.github.com>`, with no
  Co-Authored-By or session trailers. This applies to this repo too.
- Open PRs as drafts; mark them ready only after unit tests, live TPU validation and upstream
  CI pass.
- TPU code goes under `sglang_tpu/`; no new `is_tpu()` branches or `sglang_tpu` imports in
  core SGLang.
- Never reference the owner's private results repo in upstream issues, PRs, comments or code.
- The TPU hosts are shared: never kill other users' processes.
- Never use a bare `git stash` in the shared worktrees.

## How to update this repo

- Add a new review as `reviews/<project>/PR-<n>.md` and a row in the README table.
- Add or extend a handoff note under `handoff/<topic>.md`; put the date it was written at the
  top, name the commits facts were checked against, and mark anything not verified.
- Keep the README index current: one dated section per note.
- State measurements with the run name, the workload and the baseline they compare against.
