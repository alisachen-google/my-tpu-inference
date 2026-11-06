# Static prefix reuse on 1P/1D: write-back only vs write-back + offload switch (2026-11-06)

gpt-oss-120b, prefill on host a, decode on host b, tree = PR #1789 old base with the leak fix (c213ffaf), caches wiped before every point, K documents x 3 visits. Recipes: `gpt-oss_C_static_wb_off.json` / `gpt-oss_C_static_wb_spill.json`. The spill arm was stopped after the 256k K=6 point.

| Point | Hit % write-back | Hit % + switch | TTFT p50 s | TTFT p50 s + switch | Total tok/s | Total tok/s + switch |
|---|---|---|---|---|---|---|
| p128k_n8k_k4 | 62.7 | 62.7 | 7.0 | 7.2 | 36894.0 | 35996.0 |
| p128k_n8k_k8 | 62.7 | 55.1 | 6.7 | 6.7 | 38210.0 | 34040.0 |
| p128k_n8k_k12 | 50.4 | 30.4 | 6.7 | 11.6 | 33068.0 | 29688.0 |
| p128k_n8k_k16 | 40.5 | 23.8 | 11.6 | 12.1 | 31077.0 | 27879.0 |
| p128k_n8k_k20 | 34.1 | 20.0 | 12.1 | 12.3 | 30693.0 | 26682.0 |
| p128k_n8k_k24 | 24.3 | 12.6 | 12.5 | 15.4 | 27998.0 | 25189.0 |
| p128k_n8k_k28 | 24.4 | 14.4 | 12.6 | 16.3 | 28052.0 | 25637.0 |
| p256k_n16k_k2 | 62.7 | 62.7 | 18.8 | 21.8 | 29971.0 | 25944.0 |
| p256k_n16k_k4 | 62.5 | 32.0 | 22.7 | 49.9 | 28900.0 | 18720.0 |
| p256k_n16k_k6 | 52.1 | 31.6 | 29.3 | 46.0 | 24537.0 | 19096.0 |
| p256k_n16k_k8 | 50.6 | not run | 38.4 | not run | 23746.0 | not run |
| p256k_n16k_k10 | 43.9 | not run | 35.1 | not run | 22428.0 | not run |
| p256k_n16k_k12 | 28.2 | not run | 54.1 | not run | 18919.0 | not run |
| p256k_n16k_k14 | 27.3 | not run | 48.9 | not run | 18453.0 | not run |

All points: 0 errors. In the switch arm the pushes were stored (40 by the 128k K=24 point, 4.65M tokens) and there were 0 recalls.

## Why there were no recalls

One instrumented point (128k, K=12) per write policy on the same build:

| | write-back + switch | write-through + switch |
|---|---|---|
| Prefill hit % | 31.2 | 60.9 |
| Pushes stored | 14 (whole 139k-token paths) | 191 (path pushed again as it grows) |
| Repeat visits where the decode promised an offer | 9 | 18 |
| Offers the decode could actually make | 0 | 16 |
| Recalls | 0 | 11 (1.19M tokens) |

gpt-oss is a hybrid sliding-window model, so an offered prefix needs its sliding-window KV at the offered boundary. A victim carries one window, at its end. Under write-back a branch is pushed once, whole, after device eviction, so its only window sits after the request's unique tail; a repeat visit shares only the first 131,072 tokens and the decode has no window there. Under write-through the growing path is pushed at successive lengths, so windows exist near the shared boundary (offers at 130,816 to 131,072 tokens). After a stored push the prefill marks its own copy as the next to evict, so pushing without recalling lowers the hit rate below write-back only.

## Qwen3-30B-A3B (full attention only): the switch recovers the hit rate

Same workload and pair (1 prefill + 1 decode, sticky routing by document, 128k-token prompts, K documents x 3 visits, write-back on both roles), model Qwen3-30B-A3B-Instruct-2507-FP8. Recipes: `recipes/qwen3-30b_C_static_wb_{off,spill}.json`.

| K docs | Hit % write-back only | Hit % + switch | TTFT p50 s, only | TTFT p50 s, + switch | Input tok/s, only | Input tok/s, + switch | Pushes stored | Recalls | Recalled tokens |
|---|---|---|---|---|---|---|---|---|---|
| 4 | 62.7 | 62.7 | 8.2 | 8.4 | 30065 | 27529 | 6 | 0 | 0.00M |
| 8 | 62.7 | 62.7 | 7.7 | 7.6 | 30718 | 28899 | 0 | 0 | 0.00M |
| 12 | 50.9 | 60.4 | 8.0 | 4.5 | 27508 | 26845 | 43 | 9 | 1.06M |
| 16 | 39.2 | 61.0 | 13.6 | 5.5 | 25822 | 28317 | 72 | 13 | 1.41M |
| 20 | 34.1 | 57.4 | 13.8 | 7.9 | 26023 | 27924 | 107 | 23 | 2.28M |
| 24 | 24.6 | 53.5 | 14.9 | 7.9 | 23849 | 26870 | 153 | 32 | 3.36M |
| 28 | 24.7 | 50.4 | 14.5 | 8.7 | 24321 | 26968 | 205 | 33 | 3.28M |

All points: 0 errors. Pushes, recalls and recalled tokens are per point (differences of the engine's running counters). Up to K=8 everything fits in the prefill's device and host tiers, so nothing is recalled. From K=12 the prefill's host tier overflows; write-back only loses the evicted branches, while with the switch they are recalled from decode DRAM: the hit rate stays at 50 to 61% where write-back only falls to 25 to 51%, and TTFT p50 is 4.5 to 8.7 s against 8.0 to 14.9 s. A full-attention model has no sliding-window KV to restore, so a branch pushed whole can be offered at any page boundary, which is what gpt-oss lacked above.
