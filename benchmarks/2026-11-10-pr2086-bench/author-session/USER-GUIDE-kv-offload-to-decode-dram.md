# Using the KV offload to decode DRAM ("spill-over")

## What it does

In a prefill/decode (P/D) pair on TPU, the prefill keeps cached prompt prefixes in HBM and, with HiCache, in its own
host RAM. When that host RAM runs low, cold cached sessions are normally dropped and recomputed when they come back.
With this feature on, the prefill instead pushes them into the host RAM of the decode that served them. When such a
session returns and misses on the prefill, the prefill recalls its KV from the decode's RAM and skips the recompute.

Use it when your working set of long prompts is larger than the prefill's HBM plus host RAM: many long sessions that
come back later, or more shared documents than the prefill can hold. It does nothing, good or bad, while everything
still fits on the prefill.

## Requirements

- sglang-torchtpu main at `5c136df1b4` or later, on both roles.
- A tpu-sync build with the host-to-host read API (google/tpu-sync@32568d35 or later).
- P/D disaggregation over raiden: `--disaggregation-transfer-backend raiden`.
- HiCache on both roles: `--enable-hierarchical-cache --hicache-io-backend raiden`.
- Radix caching on the decode: `--disaggregation-decode-enable-radix-cache`.
- The same attention-TP size on prefill and decode.
- For a hybrid sliding-window model (GPT-OSS): `--page-size` above 1.

## Turn it on

Set one environment variable on **both** roles and restart them:

```bash
export SGLANG_ENABLE_PREFILL_KV_OFFLOAD_TO_DECODE_DRAM=1
```

Recommended on both roles as well, so a peer host that disappears mid-transfer cannot keep pages pinned:

```bash
export TPU_RAIDEN_PREFILL_{HANDSHAKE_ACK_READ,FINAL_ACK_READ,PAYLOAD_READ,HANDSHAKE_WRITE,PAYLOAD_WRITE}_TIMEOUT_S=60
export TPU_RAIDEN_DECODE_{HANDSHAKE_READ,PAYLOAD_READ,ACK_WRITE,PAYLOAD_WRITE}_TIMEOUT_S=60
```

Minimal example (add your model and sizing flags):

```bash
# prefill
SGLANG_ENABLE_PREFILL_KV_OFFLOAD_TO_DECODE_DRAM=1 python -m sglang.launch_server ... \
  --disaggregation-mode prefill --disaggregation-transfer-backend raiden \
  --enable-hierarchical-cache --hicache-io-backend raiden --hicache-ratio 1.2 \
  --hicache-write-policy write_through

# decode
SGLANG_ENABLE_PREFILL_KV_OFFLOAD_TO_DECODE_DRAM=1 python -m sglang.launch_server ... \
  --disaggregation-mode decode --disaggregation-transfer-backend raiden \
  --disaggregation-decode-enable-radix-cache \
  --enable-hierarchical-cache --hicache-io-backend raiden --hicache-ratio 3.5 \
  --hicache-write-policy write_through
```

## Choosing settings

- **Write policy.** Both `write_through` and `write_back` are supported and produce the same outputs as a recompute.
  `write_through` gives the larger gains and is the one to pick for workloads where many requests share a long prefix
  and then diverge (documents, system prompts). `write_back` keeps more of the working set on the prefill before
  anything is offloaded.
- **Do not set `SGLANG_HICACHE_SKIP_HOST_DUPLICATE_RECLAIM`.** Leave upstream's default. With it set to 1 under
  `write_back`, host copies of sessions that were loaded back to the device are never freed, the host pool fills, and
  the prefill logs refused drops and can run out of memory under load. Without it the same load ran clean and the
  recall ladder improved (12 sessions 60% to 87% hit, 16 sessions 45% to 77%).
- **Decode host RAM is the offload capacity.** Size the decode's HiCache host pool (`--hicache-ratio` or
  `--hicache-size`) for the sessions you want kept. A decode whose host RAM is full declines pushes; nothing breaks,
  those sessions are simply not kept.
- **Routing.** A session is recalled from the decode that served it, so keep a session on the same decode (sticky
  routing). It may move between prefills: any prefill can recall from that decode.
- The decode keeps pushed sessions only; with the switch on it does not cache its own requests.

## What to expect

Measured on gpt-oss-120b, one prefill and one decode, 128k-token prefix plus 8k new tokens, switch off to on:

| Workload | write_through | write_back |
|---|---|---|
| 16 sessions return after being evicted | hit 0% to 79%, TTFT 18.5 s to 3.9 s | hit 0% to 45%, TTFT 18.6 s to 9.1 s |
| 12 sessions return | hit 0% to 68%, TTFT 18.4 s to 3.3 s | hit 25% to 60%, TTFT 14.9 s to 6.3 s |
| 16 shared documents, 3 visits each | hit 28% to 59%, TTFT 10.4 s to 3.5 s | hit 41% to 52%, TTFT 10.2 s to 6.7 s |
| Working set fits on the prefill (4 documents) | unchanged | unchanged |

First-time (cold) requests are not slowed by pushes in flight.

## Check that it is working

Each engine logs counters every 30 seconds while the feature is active:

- Prefill: `[dram-offload] push started=N stored=N` and `[dram-offload] recall offers=N pulls=N pulled_tokens=N`.
- Decode: `[dram-offload] landing received=N granted=N landed=N landed_tokens=N`.

Healthy: `stored` follows `started`, `landed` follows `received`, and `pulls` grows when evicted sessions return.
`declined` pushes mean the decode's host RAM is full. No push at all means the prefill's host RAM is not under
pressure yet, which is normal for a small working set. The prefill's usual `Prefill batch ... #cached-token` line
shows the recalled prefix as a host hit.

## What is not supported

An engine started with the switch on and an unsupported setting stops at start and names the setting; it never runs
silently without the offload. Refused: pipeline parallelism (`--pp-size` above 1) and the raiden pipeline transfer,
data or context parallelism, speculative decoding, GDN/Mamba models, hybrid models with compressed window state, the
unified KV pool (`--enable-unified-memory`), an L3 storage backend (`--hicache-storage-backend`), optimistic prefill,
`--sleep-on-idle`, the Rust radix tree, a transfer or HiCache I/O backend other than raiden, and HiCache or the radix
cache off.

A pair fails its requests, with the reason in the error, when the switch is on for one role only or when the two roles
differ in attention-TP size. Set the switch on both roles or on neither, and roll both roles together when upgrading.

## Operational notes

- **Cache flush.** `POST /flush_cache` is refused (HTTP 400) while transfers are in flight; retry after a few seconds.
  An idle engine settles its transfers within 60 seconds.
- **Restarts.** If the decode restarts, its offloaded sessions are gone and those prompts are recomputed; requests in
  flight at that moment fail and should be retried. If the prefill restarts, the decode releases that prefill's
  pending transfers on its own.
- **Known limits.** On a hybrid model under `write_back`, a request that shares only the beginning of an offloaded
  session is served from the prefill's own host RAM while it is still there, not from decode RAM; `write_through`
  recalls it from decode RAM too. Under `write_back` with a host pool that is full, the prefill may log
  `write_back: backup failed under host memory pressure but subtree drop declined (node locked)`; it is a warning.
  If you see it often, check that `SGLANG_HICACHE_SKIP_HOST_DUPLICATE_RECLAIM` is not set, then give the prefill more
  host RAM or use `write_through`. When the working set sits exactly at
  the prefill's capacity, a returning session can lose part of its prefix to a push made at that moment (tracked in
  issue 2107).

## Turn it off

Unset the variable on both roles and restart them. With the switch off the engines behave exactly as before the
feature existed.
