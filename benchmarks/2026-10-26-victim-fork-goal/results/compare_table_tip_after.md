### Recall workload (fill N sessions, recall oldest first; recall phase)

| Prefix+new | Sessions | Prefill hit before → after | Hit gain | TTFT p50 before → after | TTFT speedup | E2E p50 before → after | Total tok/s before → after | Throughput gain | KV offloaded to decode DRAM (after) | KV pulled from decode DRAM (after) | Pulled share of prompt | Pulls (after) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 128k+8k | 8 | 36.7% → 94.4% | +57.7 pts (2.57x) | 14.7 s → 2.1 s | 7.15x | 21.4 s → 10.7 s | 27,142 → 52,141 | 1.92x | 0.99M (43 pushes) | 0.50M | 42.4% | 7 |
| 128k+8k | 10 | 0.0% → 94.4% | +94.4 pts (-) | 20.4 s → 1.7 s | 12.04x | 26.6 s → 10.8 s | 20,245 → 49,699 | 2.45x | 1.29M (71 pushes) | 0.95M | 64.5% | 9 |
| 128k+8k | 12 | 0.0% → 94.4% | +94.4 pts (-) | 20.6 s → 1.7 s | 11.86x | 27.0 s → 10.5 s | 20,403 → 51,989 | 2.55x | 1.71M (110 pushes) | 1.43M | 81.0% | 12 |
| 128k+8k | 16 | 0.0% → 85.3% | +85.3 pts (-) | 20.5 s → 2.7 s | 7.68x | 26.8 s → 11.8 s | 20,856 → 44,030 | 2.11x | 2.27M (181 pushes) | 1.95M | 82.6% | 14 |
| 128k+8k | 20 | 0.0% → 50.1% | +50.1 pts (-) | 20.5 s → 9.9 s | 2.07x | 27.0 s → 18.2 s | 21,078 → 32,986 | 1.56x | 3.49M (325 pushes) | 1.44M | 48.8% | 19 |
| 128k+8k | 24 | 0.0% → 23.5% | +23.5 pts (-) | 20.4 s → 15.0 s | 1.37x | 27.0 s → 24.0 s | 21,229 → 25,456 | 1.20x | 5.91M (470 pushes) | 0.69M | 19.6% | 17 |
| 128k+8k | 28 | 0.0% → 3.5% | +3.5 pts (-) | 20.4 s → 18.2 s | 1.12x | 26.9 s → 26.6 s | 21,338 → 21,784 | 1.02x | 7.18M (708 pushes) | 0.14M | 3.5% | 3 |
| 128k+8k | 32 | 0.0% → 4.0% | +4.0 pts (-) | 20.5 s → 17.8 s | 1.15x | 27.0 s → 26.9 s | 21,420 → 21,984 | 1.03x | 8.89M (893 pushes) | 0.05M | 1.0% | 2 |
| 256k+16k | 4 | 51.3% → 90.2% | +38.9 pts (1.76x) | 32.5 s → 20.1 s | 1.62x | 39.0 s → 28.5 s | 21,571 → 38,827 | 1.80x | 1.12M (32 pushes) | 0.26M | 22.2% | 3 |
| 256k+16k | 5 | 6.1% → 75.5% | +69.4 pts (12.38x) | 57.1 s → 22.6 s | 2.53x | 65.3 s → 28.9 s | 14,358 → 26,153 | 1.82x | 1.15M (62 pushes) | 0.69M | 46.6% | 3 |
| 256k+16k | 6 | 20.8% → 62.9% | +42.1 pts (3.02x) | 45.4 s → 22.6 s | 2.01x | 53.4 s → 32.9 s | 16,018 → 24,037 | 1.50x | 1.71M (77 pushes) | 0.99M | 56.0% | 4 |
| 256k+16k | 8 | 0.0% → 58.7% | +58.7 pts (-) | 71.8 s → 34.6 s | 2.07x | 78.2 s → 43.3 s | 14,268 → 22,840 | 1.60x | 2.20M (145 pushes) | 1.38M | 58.6% | 5 |
| 256k+16k | 10 | 0.0% → 42.7% | +42.7 pts (-) | 71.4 s → 46.7 s | 1.53x | 78.1 s → 54.6 s | 14,358 → 19,990 | 1.39x | 4.03M (203 pushes) | 1.26M | 42.7% | 7 |
| 256k+16k | 12 | 0.0% → 15.0% | +15.0 pts (-) | 71.7 s → 60.2 s | 1.19x | 79.7 s → 70.4 s | 14,430 → 15,568 | 1.08x | 5.79M (395 pushes) | 0.51M | 14.3% | 4 |
| 256k+16k | 14 | 0.0% → 5.9% | +5.9 pts (-) | 71.7 s → 65.9 s | 1.09x | 79.6 s → 76.0 s | 14,492 → 14,915 | 1.03x | 7.34M (493 pushes) | 0.24M | 5.9% | 5 |
| 256k+16k | 16 | 0.0% → 0.7% | +0.7 pts (-) | 71.8 s → 68.8 s | 1.04x | 79.8 s → 78.7 s | 14,539 → 14,557 | 1.00x | 8.48M (541 pushes) | 0.03M | 0.7% | 2 |

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

_Before points: 30; after points: 30. Offloaded tokens = victim-push tokens that landed in the decode's host pool during the point (decode landed_tokens deltas); pulled tokens = prefix-pull tokens the prefill received from the decode during the point (TP0 counter deltas); pulled share = those tokens / the point's measured-phase prompt tokens (for recall points the pulls of the fill phase are included, so the share can exceed 100%)._
