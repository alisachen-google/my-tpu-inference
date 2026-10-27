### Recall workload (fill N sessions, recall oldest first; recall phase)

| Prefix+new | Sessions | Prefill hit before → after | Hit gain | TTFT p50 before → after | TTFT speedup | E2E p50 before → after | Total tok/s before → after | Throughput gain | KV offloaded to decode DRAM (after) | KV pulled from decode DRAM (after) | Pulled share of prompt | Pulls (after) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 128k+8k | 8 | 36.7% → 88.1% | +51.4 pts (2.40x) | 14.7 s → 4.3 s | 3.43x | 21.4 s → 12.8 s | 27,142 → 46,257 | 1.70x | 0.99M (39 pushes) | 0.61M | 51.4% | 6 |
| 128k+8k | 10 | 0.0% → 81.4% | +81.4 pts (-) | 20.4 s → 4.9 s | 4.15x | 26.6 s → 13.2 s | 20,245 → 38,698 | 1.91x | 1.28M (60 pushes) | 1.08M | 73.1% | 9 |
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
| 128k+8k | 4 | 62.7% → 62.7% | +0.0 pts (1.00x) | 6.9 s → 7.0 s | 1.00x | 14.3 s → 15.0 s | 37,557 → 36,690 | 0.98x | 1.25M (66 pushes) | 0.00M | 0.0% | 0 |
| 128k+8k | 8 | 60.5% → 60.5% | -0.0 pts (1.00x) | 6.7 s → 6.7 s | 1.00x | 14.6 s → 14.3 s | 37,044 → 36,094 | 0.97x | 0.87M (33 pushes) | 0.17M | 5.1% | 2 |
| 128k+8k | 12 | 35.6% → 58.9% | +23.3 pts (1.66x) | 9.6 s → 5.8 s | 1.66x | 17.6 s → 13.8 s | 31,181 → 35,384 | 1.13x | 1.59M (87 pushes) | 1.30M | 26.0% | 12 |
| 128k+8k | 16 | 28.2% → 60.5% | +32.3 pts (2.15x) | 12.0 s → 6.6 s | 1.82x | 18.6 s → 13.8 s | 29,961 → 36,720 | 1.23x | 2.27M (132 pushes) | 2.27M | 34.0% | 19 |
| 128k+8k | 20 | 23.0% → 54.0% | +31.1 pts (2.35x) | 12.6 s → 6.7 s | 1.86x | 19.5 s → 14.8 s | 27,272 → 35,370 | 1.30x | 2.92M (161 pushes) | 3.03M | 36.2% | 27 |
| 128k+8k | 24 | 14.7% → 55.0% | +40.3 pts (3.74x) | 13.1 s → 6.7 s | 1.97x | 19.8 s → 14.7 s | 25,856 → 35,823 | 1.39x | 3.59M (192 pushes) | 3.76M | 37.5% | 31 |
| 128k+8k | 28 | 14.1% → 40.9% | +26.8 pts (2.90x) | 17.4 s → 7.9 s | 2.21x | 24.2 s → 15.8 s | 25,700 → 32,343 | 1.26x | 5.00M (285 pushes) | 2.99M | 25.6% | 30 |
| 256k+16k | 2 | 62.7% → 62.7% | +0.0 pts (1.00x) | 18.8 s → 21.9 s | 0.86x | 26.9 s → 29.9 s | 30,073 → 26,229 | 0.87x | 0.00M (2 pushes) | 0.00M | 0.0% | 0 |
| 256k+16k | 4 | 49.7% → 57.8% | +8.1 pts (1.16x) | 38.2 s → 32.3 s | 1.18x | 46.2 s → 41.9 s | 22,594 → 24,106 | 1.07x | 1.11M (23 pushes) | 0.97M | 28.9% | 5 |
| 256k+16k | 6 | 37.9% → 56.0% | +18.1 pts (1.48x) | 45.3 s → 35.9 s | 1.26x | 54.4 s → 44.3 s | 20,311 → 24,459 | 1.20x | 1.49M (36 pushes) | 1.48M | 29.6% | 6 |
| 256k+16k | 8 | 29.4% → 58.9% | +29.5 pts (2.00x) | 51.1 s → 31.4 s | 1.63x | 59.4 s → 40.7 s | 19,466 → 25,827 | 1.33x | 2.17M (73 pushes) | 1.80M | 26.9% | 8 |
| 256k+16k | 10 | 31.8% → 57.3% | +25.6 pts (1.80x) | 50.7 s → 32.7 s | 1.55x | 58.8 s → 41.2 s | 19,373 → 24,563 | 1.27x | 3.05M (109 pushes) | 2.36M | 28.2% | 10 |
| 256k+16k | 12 | 9.8% → 48.2% | +38.4 pts (4.92x) | 64.2 s → 36.6 s | 1.76x | 72.5 s → 45.4 s | 16,529 → 22,140 | 1.34x | 4.36M (147 pushes) | 3.69M | 36.7% | 16 |
| 256k+16k | 14 | 14.1% → 35.6% | +21.5 pts (2.52x) | 55.3 s → 46.2 s | 1.20x | 63.3 s → 55.1 s | 16,580 → 19,823 | 1.20x | 5.99M (232 pushes) | 3.18M | 27.2% | 16 |

_Before points: 30; after points: 16. Offloaded tokens = victim-push tokens that landed in the decode's host pool during the point (decode landed_tokens deltas); pulled tokens = prefix-pull tokens the prefill received from the decode during the point (TP0 counter deltas); pulled share = those tokens / the point's measured-phase prompt tokens (for recall points the pulls of the fill phase are included, so the share can exceed 100%)._
