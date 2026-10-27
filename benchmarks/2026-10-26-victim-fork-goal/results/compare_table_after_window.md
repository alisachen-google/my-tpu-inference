### Recall workload (fill N sessions, recall oldest first; recall phase)

| Prefix+new | Sessions | Prefill hit before → after | Hit gain | TTFT p50 before → after | TTFT speedup | E2E p50 before → after | Total tok/s before → after | Throughput gain | KV offloaded to decode DRAM (after) | KV pulled from decode DRAM (after) | Pulled share of prompt | Pulls (after) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 128k+8k | 8 | 36.7% → 93.0% | +56.3 pts (2.53x) | 14.7 s → 3.0 s | 4.86x | 21.4 s → 11.5 s | 27,142 → 50,373 | 1.86x | 0.97M (31 pushes) | 0.73M | 61.8% | 7 |
| 128k+8k | 10 | 0.0% → 77.1% | +77.1 pts (-) | 20.4 s → 7.2 s | 2.84x | 26.6 s → 16.2 s | 20,245 → 35,894 | 1.77x | 1.29M (59 pushes) | 0.86M | 58.2% | 7 |
| 128k+8k | 12 | 0.0% → 64.7% | +64.7 pts (-) | 20.6 s → 8.0 s | 2.58x | 27.0 s → 17.1 s | 20,403 → 34,031 | 1.67x | 37.12M (1594 pushes) | 28.29M | 1597.3% | 192 |
| 128k+8k | 16 | 0.0% → 66.9% | +66.9 pts (-) | 20.5 s → 7.9 s | 2.60x | 26.8 s → 16.5 s | 20,856 → 36,635 | 1.76x | 2.29M (156 pushes) | 1.58M | 66.9% | 12 |
| 128k+8k | 20 | 0.0% → 55.2% | +55.2 pts (-) | 20.5 s → 8.4 s | 2.43x | 27.0 s → 17.4 s | 21,078 → 31,517 | 1.50x | 7.17M (494 pushes) | 4.35M | 147.5% | 36 |
| 128k+8k | 24 | 0.0% → 39.1% | +39.1 pts (-) | 20.4 s → 11.3 s | 1.81x | 27.0 s → 19.9 s | 21,229 → 28,577 | 1.35x | 4.33M (291 pushes) | 1.38M | 39.1% | 13 |
| 128k+8k | 28 | 0.0% → 13.0% | +13.0 pts (-) | 20.4 s → 14.4 s | 1.42x | 26.9 s → 22.6 s | 21,338 → 23,954 | 1.12x | 6.68M (383 pushes) | 0.54M | 13.0% | 5 |
| 128k+8k | 32 | 0.0% → 13.6% | +13.6 pts (-) | 20.5 s → 18.2 s | 1.13x | 27.0 s → 25.7 s | 21,420 → 24,077 | 1.12x | 7.38M (511 pushes) | 0.64M | 13.6% | 6 |
| 256k+16k | 4 | 51.3% → 93.7% | +42.4 pts (1.82x) | 32.5 s → 41.9 s | 0.78x | 39.0 s → 49.5 s | 21,571 → 22,730 | 1.05x | 1.27M (18 pushes) | 0.56M | 47.2% | 3 |
| 256k+16k | 5 | 6.1% → 56.1% | +50.0 pts (9.20x) | 57.1 s → 56.7 s | 1.01x | 65.3 s → 62.8 s | 14,358 → 12,377 | 0.86x | 1.14M (44 pushes) | 0.79M | 53.3% | 3 |
| 256k+16k | 6 | 20.8% → 92.5% | +71.7 pts (4.45x) | 45.4 s → 42.2 s | 1.07x | 53.4 s → 49.9 s | 16,018 → 18,877 | 1.18x | 1.70M (46 pushes) | 1.38M | 77.7% | 5 |
| 256k+16k | 8 | 0.0% → 63.9% | +63.9 pts (-) | 71.8 s → 61.8 s | 1.16x | 78.2 s → 96.1 s | 14,268 → 13,457 | 0.94x | 2.11M (98 pushes) | 1.51M | 63.9% | 6 |
| 256k+16k | 10 | 0.0% → 63.9% | +63.9 pts (-) | 71.4 s → 50.6 s | 1.41x | 78.1 s → 82.7 s | 14,358 → 13,342 | 0.93x | 2.91M (120 pushes) | 1.88M | 63.9% | 9 |
| 256k+16k | 12 | 0.0% → 27.5% | +27.5 pts (-) | 71.7 s → 67.1 s | 1.07x | 79.7 s → 98.4 s | 14,430 → 11,866 | 0.82x | 4.65M (162 pushes) | 0.97M | 27.5% | 5 |
| 256k+16k | 14 | 0.0% → 6.9% | +6.9 pts (-) | 71.7 s → 74.9 s | 0.96x | 79.6 s → 109.7 s | 14,492 → 11,085 | 0.76x | 6.82M (249 pushes) | 0.29M | 6.9% | 3 |
| 256k+16k | 16 | 0.0% → 1.2% | +1.2 pts (-) | 71.8 s → 75.6 s | 0.95x | 79.8 s → 110.9 s | 14,539 → 10,847 | 0.75x | 8.39M (277 pushes) | 0.06M | 1.2% | 1 |

### Static prefix-reuse workload (K documents x 3 visits, shuffled)

| Prefix+new | Docs | Prefill hit before → after | Hit gain | TTFT p50 before → after | TTFT speedup | E2E p50 before → after | Total tok/s before → after | Throughput gain | KV offloaded to decode DRAM (after) | KV pulled from decode DRAM (after) | Pulled share of prompt | Pulls (after) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 128k+8k | 4 | 62.7% → 62.7% | -0.0 pts (1.00x) | 6.9 s → 5.9 s | 1.18x | 14.3 s → 14.3 s | 37,557 → 36,830 | 0.98x | 10.09M (605 pushes) | 4.54M | 271.4% | 39 |
| 128k+8k | 8 | 60.5% → 62.5% | +1.9 pts (1.03x) | 6.7 s → 6.4 s | 1.04x | 14.6 s → 14.3 s | 37,044 → 37,149 | 1.00x | 10.96M (628 pushes) | 4.73M | 141.4% | 41 |
| 128k+8k | 12 | 35.6% → 60.5% | +25.0 pts (1.70x) | 9.6 s → 3.7 s | 2.61x | 17.6 s → 12.4 s | 31,181 → 36,005 | 1.15x | 1.66M (78 pushes) | 1.46M | 29.2% | 12 |
| 128k+8k | 16 | 28.2% → 59.7% | +31.5 pts (2.12x) | 12.0 s → 6.6 s | 1.81x | 18.6 s → 14.8 s | 29,961 → 35,417 | 1.18x | 4.82M (228 pushes) | 4.01M | 60.0% | 33 |
| 128k+8k | 20 | 23.0% → 54.7% | +31.8 pts (2.38x) | 12.6 s → 6.7 s | 1.89x | 19.5 s → 15.4 s | 27,272 → 34,813 | 1.28x | 2.95M (166 pushes) | 2.59M | 31.0% | 22 |
| 128k+8k | 24 | 14.7% → 47.1% | +32.4 pts (3.20x) | 13.1 s → 7.0 s | 1.87x | 19.8 s → 15.4 s | 25,856 → 33,259 | 1.29x | 3.82M (209 pushes) | 3.61M | 36.0% | 34 |
| 128k+8k | 28 | 14.1% → 38.5% | +24.4 pts (2.73x) | 17.4 s → 10.5 s | 1.66x | 24.2 s → 19.0 s | 25,700 → 30,582 | 1.19x | 5.94M (311 pushes) | 3.36M | 28.7% | 32 |
| 256k+16k | 2 | 62.7% → 62.7% | +0.0 pts (1.00x) | 18.8 s → 34.9 s | 0.54x | 26.9 s → 54.2 s | 30,073 → 15,315 | 0.51x | 0.00M (5 pushes) | 0.00M | 0.0% | 0 |
| 256k+16k | 4 | 49.7% → 52.9% | +3.2 pts (1.06x) | 38.2 s → 58.3 s | 0.66x | 46.2 s → 89.9 s | 22,594 → 12,903 | 0.57x | 1.15M (26 pushes) | 0.49M | 14.7% | 2 |
| 256k+16k | 6 | 37.9% → 59.3% | +21.4 pts (1.57x) | 45.3 s → 44.6 s | 1.01x | 54.4 s → 78.0 s | 20,311 → 15,826 | 0.78x | 1.66M (54 pushes) | 1.89M | 37.7% | 8 |
| 256k+16k | 8 | 29.4% → 58.2% | +28.8 pts (1.98x) | 51.1 s → 54.5 s | 0.94x | 59.4 s → 86.3 s | 19,466 → 13,483 | 0.69x | 2.31M (70 pushes) | 1.99M | 29.8% | 10 |
| 256k+16k | 10 | 31.8% → 53.7% | +22.0 pts (1.69x) | 50.7 s → 54.5 s | 0.93x | 58.8 s → 86.0 s | 19,373 → 13,031 | 0.67x | 3.28M (103 pushes) | 2.09M | 25.0% | 10 |
| 256k+16k | 12 | 9.8% → 45.7% | +35.9 pts (4.66x) | 64.2 s → 54.8 s | 1.17x | 72.5 s → 87.3 s | 16,529 → 12,460 | 0.75x | 4.41M (115 pushes) | 3.79M | 37.8% | 17 |
| 256k+16k | 14 | 14.1% → 36.2% | +22.1 pts (2.56x) | 55.3 s → 58.4 s | 0.95x | 63.3 s → 90.9 s | 16,580 → 11,727 | 0.71x | 5.46M (199 pushes) | 3.37M | 28.8% | 15 |

_Before points: 30; after points: 30. Offloaded tokens = victim-push tokens that landed in the decode's host pool during the point (decode landed_tokens deltas); pulled tokens = prefix-pull tokens the prefill received from the decode during the point (TP0 counter deltas); pulled share = those tokens / the point's measured-phase prompt tokens (for recall points the pulls of the fill phase are included, so the share can exceed 100%)._
