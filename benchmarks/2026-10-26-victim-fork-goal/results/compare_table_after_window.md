### Recall workload (fill N sessions, recall oldest first; recall phase)

| Prefix+new | Sessions | Prefill hit before → after | TTFT p50 before → after | TTFT speedup | E2E p50 before → after | Total tok/s before → after | Throughput gain | KV offloaded to decode DRAM (after) | KV pulled from decode DRAM (after) | Pulled share of prompt | Pulls (after) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 128k+8k | 8 | 36.7% → - | 14.7 s → - | - | 21.4 s → - | 27,142 → - | - | - | - | - | - |
| 128k+8k | 10 | 0.0% → - | 20.4 s → - | - | 26.6 s → - | 20,245 → - | - | - | - | - | - |
| 128k+8k | 12 | 0.0% → 57.2% | 20.6 s → 7.6 s | 2.71x | 27.0 s → 15.4 s | 20,403 → 31,673 | 1.55x | 6.71M (384 pushes) | 2.80M | 157.9% | 25 |
| 128k+8k | 16 | 0.0% → 73.8% | 20.5 s → 4.7 s | 4.32x | 26.8 s → 13.7 s | 20,856 → 36,189 | 1.74x | 2.12M (151 pushes) | 1.74M | 73.7% | 14 |
| 128k+8k | 20 | 0.0% → - | 20.5 s → - | - | 27.0 s → - | 21,078 → - | - | - | - | - | - |
| 128k+8k | 24 | 0.0% → - | 20.4 s → - | - | 27.0 s → - | 21,229 → - | - | - | - | - | - |
| 128k+8k | 28 | 0.0% → - | 20.4 s → - | - | 26.9 s → - | 21,338 → - | - | - | - | - | - |
| 128k+8k | 32 | 0.0% → - | 20.5 s → - | - | 27.0 s → - | 21,420 → - | - | - | - | - | - |
| 256k+16k | 4 | 51.3% → - | 32.5 s → - | - | 39.0 s → - | 21,571 → - | - | - | - | - | - |
| 256k+16k | 5 | 6.1% → - | 57.1 s → - | - | 65.3 s → - | 14,358 → - | - | - | - | - | - |
| 256k+16k | 6 | 20.8% → - | 45.4 s → - | - | 53.4 s → - | 16,018 → - | - | - | - | - | - |
| 256k+16k | 8 | 0.0% → - | 71.8 s → - | - | 78.2 s → - | 14,268 → - | - | - | - | - | - |
| 256k+16k | 10 | 0.0% → - | 71.4 s → - | - | 78.1 s → - | 14,358 → - | - | - | - | - | - |
| 256k+16k | 12 | 0.0% → - | 71.7 s → - | - | 79.7 s → - | 14,430 → - | - | - | - | - | - |
| 256k+16k | 14 | 0.0% → - | 71.7 s → - | - | 79.6 s → - | 14,492 → - | - | - | - | - | - |
| 256k+16k | 16 | 0.0% → - | 71.8 s → - | - | 79.8 s → - | 14,539 → - | - | - | - | - | - |

### Static prefix-reuse workload (K documents x 3 visits, shuffled)

| Prefix+new | Docs | Prefill hit before → after | TTFT p50 before → after | TTFT speedup | E2E p50 before → after | Total tok/s before → after | Throughput gain | KV offloaded to decode DRAM (after) | KV pulled from decode DRAM (after) | Pulled share of prompt | Pulls (after) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 128k+8k | 4 | 62.7% → 62.7% | 6.9 s → 5.9 s | 1.18x | 14.3 s → 14.3 s | 37,557 → 36,830 | 0.98x | 1.25M (70 pushes) | 0.00M | 0.0% | 0 |
| 128k+8k | 8 | 60.5% → 62.5% | 6.7 s → 6.4 s | 1.04x | 14.6 s → 14.3 s | 37,044 → 37,149 | 1.00x | 10.96M (628 pushes) | 4.73M | 141.4% | 41 |
| 128k+8k | 12 | 35.6% → 60.5% | 9.6 s → 3.7 s | 2.61x | 17.6 s → 12.4 s | 31,181 → 36,005 | 1.15x | 1.66M (78 pushes) | 1.46M | 29.2% | 12 |
| 128k+8k | 16 | 28.2% → 59.7% | 12.0 s → 6.6 s | 1.81x | 18.6 s → 14.8 s | 29,961 → 35,417 | 1.18x | 4.82M (228 pushes) | 4.01M | 60.0% | 33 |
| 128k+8k | 20 | 23.0% → 54.7% | 12.6 s → 6.7 s | 1.89x | 19.5 s → 15.4 s | 27,272 → 34,813 | 1.28x | 2.95M (166 pushes) | 2.59M | 31.0% | 22 |
| 128k+8k | 24 | 14.7% → 47.1% | 13.1 s → 7.0 s | 1.87x | 19.8 s → 15.4 s | 25,856 → 33,259 | 1.29x | 3.82M (209 pushes) | 3.61M | 36.0% | 34 |
| 128k+8k | 28 | 14.1% → 38.5% | 17.4 s → 10.5 s | 1.66x | 24.2 s → 19.0 s | 25,700 → 30,582 | 1.19x | 5.94M (311 pushes) | 3.36M | 28.7% | 32 |
| 256k+16k | 2 | 62.7% → 62.7% | 18.8 s → 34.9 s | 0.54x | 26.9 s → 54.2 s | 30,073 → 15,315 | 0.51x | 0.00M (5 pushes) | 0.00M | 0.0% | 0 |
| 256k+16k | 4 | 49.7% → 52.9% | 38.2 s → 58.3 s | 0.66x | 46.2 s → 89.9 s | 22,594 → 12,903 | 0.57x | 1.15M (26 pushes) | 0.49M | 14.7% | 2 |
| 256k+16k | 6 | 37.9% → 59.3% | 45.3 s → 44.6 s | 1.01x | 54.4 s → 78.0 s | 20,311 → 15,826 | 0.78x | 1.66M (54 pushes) | 1.89M | 37.7% | 8 |
| 256k+16k | 8 | 29.4% → 58.2% | 51.1 s → 54.5 s | 0.94x | 59.4 s → 86.3 s | 19,466 → 13,483 | 0.69x | 2.31M (70 pushes) | 1.99M | 29.8% | 10 |
| 256k+16k | 10 | 31.8% → 53.7% | 50.7 s → 54.5 s | 0.93x | 58.8 s → 86.0 s | 19,373 → 13,031 | 0.67x | 3.28M (103 pushes) | 2.09M | 25.0% | 10 |
| 256k+16k | 12 | 9.8% → 45.7% | 64.2 s → 54.8 s | 1.17x | 72.5 s → 87.3 s | 16,529 → 12,460 | 0.75x | 4.41M (115 pushes) | 3.79M | 37.8% | 17 |
| 256k+16k | 14 | 14.1% → 36.2% | 55.3 s → 58.4 s | 0.95x | 63.3 s → 90.9 s | 16,580 → 11,727 | 0.71x | 5.46M (199 pushes) | 3.37M | 28.8% | 15 |

_Before points: 30; after points: 16. Offloaded tokens = victim-push tokens that landed in the decode's host pool during the point (decode landed_tokens deltas); pulled tokens = prefix-pull tokens the prefill received from the decode during the point (TP0 counter deltas); pulled share = those tokens / the point's measured-phase prompt tokens (for recall points the pulls of the fill phase are included, so the share can exceed 100%)._
