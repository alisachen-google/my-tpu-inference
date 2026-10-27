### Recall workload (fill N sessions, recall oldest first; recall phase)

| Prefix+new | Sessions | Prefill hit before → after | Hit gain | TTFT p50 before → after | TTFT speedup | E2E p50 before → after | Total tok/s before → after | Throughput gain | KV offloaded to decode DRAM (after) | KV pulled from decode DRAM (after) | Pulled share of prompt | Pulls (after) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 128k+8k | 8 | 36.7% → - | - | 14.7 s → - | - | 21.4 s → - | 27,142 → - | - | - | - | - | - |
| 128k+8k | 10 | 0.0% → - | - | 20.4 s → - | - | 26.6 s → - | 20,245 → - | - | - | - | - | - |
| 128k+8k | 12 | 0.0% → - | - | 20.6 s → - | - | 27.0 s → - | 20,403 → - | - | - | - | - | - |
| 128k+8k | 16 | 0.0% → - | - | 20.5 s → - | - | 26.8 s → - | 20,856 → - | - | - | - | - | - |
| 128k+8k | 20 | 0.0% → - | - | 20.5 s → - | - | 27.0 s → - | 21,078 → - | - | - | - | - | - |
| 128k+8k | 24 | 0.0% → - | - | 20.4 s → - | - | 27.0 s → - | 21,229 → - | - | - | - | - | - |
| 128k+8k | 28 | 0.0% → - | - | 20.4 s → - | - | 26.9 s → - | 21,338 → - | - | - | - | - | - |
| 128k+8k | 32 | 0.0% → - | - | 20.5 s → - | - | 27.0 s → - | 21,420 → - | - | - | - | - | - |
| 256k+16k | 4 | 51.3% → - | - | 32.5 s → - | - | 39.0 s → - | 21,571 → - | - | - | - | - | - |
| 256k+16k | 5 | 6.1% → - | - | 57.1 s → - | - | 65.3 s → - | 14,358 → - | - | - | - | - | - |
| 256k+16k | 6 | 20.8% → - | - | 45.4 s → - | - | 53.4 s → - | 16,018 → - | - | - | - | - | - |
| 256k+16k | 8 | 0.0% → - | - | 71.8 s → - | - | 78.2 s → - | 14,268 → - | - | - | - | - | - |
| 256k+16k | 10 | 0.0% → - | - | 71.4 s → - | - | 78.1 s → - | 14,358 → - | - | - | - | - | - |
| 256k+16k | 12 | 0.0% → - | - | 71.7 s → - | - | 79.7 s → - | 14,430 → - | - | - | - | - | - |
| 256k+16k | 14 | 0.0% → - | - | 71.7 s → - | - | 79.6 s → - | 14,492 → - | - | - | - | - | - |
| 256k+16k | 16 | 0.0% → - | - | 71.8 s → - | - | 79.8 s → - | 14,539 → - | - | - | - | - | - |

### Static prefix-reuse workload (K documents x 3 visits, shuffled)

| Prefix+new | Docs | Prefill hit before → after | Hit gain | TTFT p50 before → after | TTFT speedup | E2E p50 before → after | Total tok/s before → after | Throughput gain | KV offloaded to decode DRAM (after) | KV pulled from decode DRAM (after) | Pulled share of prompt | Pulls (after) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 128k+8k | 4 | 62.7% → 62.7% | +0.0 pts (1.00x) | 6.9 s → 7.0 s | 1.00x | 14.3 s → 14.6 s | 37,557 → 37,088 | 0.99x | 1.39M (75 pushes) | 0.00M | 0.0% | 0 |
| 128k+8k | 8 | 60.5% → 61.7% | +1.2 pts (1.02x) | 6.7 s → 6.6 s | 1.00x | 14.6 s → 14.4 s | 37,044 → 35,676 | 0.96x | 1.03M (35 pushes) | 0.14M | 4.2% | 3 |
| 128k+8k | 12 | 35.6% → 59.1% | +23.5 pts (1.66x) | 9.6 s → 5.1 s | 1.88x | 17.6 s → 13.8 s | 31,181 → 35,676 | 1.14x | 1.74M (125 pushes) | 1.24M | 24.6% | 10 |
| 128k+8k | 16 | 28.2% → 55.3% | +27.1 pts (1.96x) | 12.0 s → 6.5 s | 1.84x | 18.6 s → 14.2 s | 29,961 → 34,932 | 1.17x | 2.15M (155 pushes) | 2.13M | 31.8% | 19 |
| 128k+8k | 20 | 23.0% → 42.5% | +19.5 pts (1.85x) | 12.6 s → 7.3 s | 1.71x | 19.5 s → 16.5 s | 27,272 → 31,144 | 1.14x | 3.05M (225 pushes) | 2.02M | 24.2% | 18 |
| 128k+8k | 24 | 14.7% → 46.5% | +31.8 pts (3.16x) | 13.1 s → 6.9 s | 1.90x | 19.8 s → 15.7 s | 25,856 → 33,064 | 1.28x | 4.34M (302 pushes) | 2.98M | 29.7% | 29 |
| 128k+8k | 28 | 14.1% → 38.7% | +24.6 pts (2.74x) | 17.4 s → 8.9 s | 1.97x | 24.2 s → 17.0 s | 25,700 → 30,960 | 1.20x | 5.67M (378 pushes) | 2.50M | 21.4% | 26 |
| 256k+16k | 2 | 62.7% → 62.7% | +0.0 pts (1.00x) | 18.8 s → 22.0 s | 0.85x | 26.9 s → 29.9 s | 30,073 → 26,194 | 0.87x | 0.00M (13 pushes) | 0.00M | 0.0% | 0 |
| 256k+16k | 4 | 49.7% → 57.6% | +7.8 pts (1.16x) | 38.2 s → 28.6 s | 1.33x | 46.2 s → 37.2 s | 22,594 → 23,917 | 1.06x | 1.18M (36 pushes) | 0.20M | 5.9% | 5 |
| 256k+16k | 6 | 37.9% → 51.6% | +13.7 pts (1.36x) | 45.3 s → 35.9 s | 1.26x | 54.4 s → 46.3 s | 20,311 → 23,061 | 1.14x | 1.77M (84 pushes) | 1.00M | 19.9% | 7 |
| 256k+16k | 8 | 29.4% → 49.5% | +20.1 pts (1.68x) | 51.1 s → 38.5 s | 1.33x | 59.4 s → 48.4 s | 19,466 → 22,291 | 1.15x | 2.29M (107 pushes) | 1.30M | 19.5% | 9 |
| 256k+16k | 10 | 31.8% → 53.6% | +21.9 pts (1.69x) | 50.7 s → 35.1 s | 1.44x | 58.8 s → 43.4 s | 19,373 → 23,426 | 1.21x | 2.77M (131 pushes) | 1.86M | 22.2% | 10 |
| 256k+16k | 12 | 9.8% → 29.5% | +19.7 pts (3.01x) | 64.2 s → 50.2 s | 1.28x | 72.5 s → 59.5 s | 16,529 → 18,534 | 1.12x | 4.25M (225 pushes) | 1.79M | 17.9% | 11 |
| 256k+16k | 14 | 14.1% → 25.2% | +11.1 pts (1.79x) | 55.3 s → 49.7 s | 1.11x | 63.3 s → 57.9 s | 16,580 → 18,140 | 1.09x | 6.37M (363 pushes) | 1.25M | 10.7% | 10 |

_Before points: 30; after points: 14. Offloaded tokens = victim-push tokens that landed in the decode's host pool during the point (decode landed_tokens deltas); pulled tokens = prefix-pull tokens the prefill received from the decode during the point (TP0 counter deltas); pulled share = those tokens / the point's measured-phase prompt tokens (for recall points the pulls of the fill phase are included, so the share can exceed 100%)._
