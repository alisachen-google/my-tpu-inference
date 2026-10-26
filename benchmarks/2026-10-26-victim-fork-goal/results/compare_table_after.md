### Recall workload (fill N sessions, recall oldest first; recall phase)

| Prefix+new | Sessions | Prefill hit before → after | TTFT p50 before → after | TTFT speedup | E2E p50 before → after | Total tok/s before → after | Throughput gain | KV offloaded to decode DRAM (after) | KV pulled from decode DRAM (after) | Pulled share of prompt | Pulls (after) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 128k+8k | 8 | 36.7% → - | 14.7 s → - | - | 21.4 s → - | 27,142 → - | - | - | - | - | - |
| 128k+8k | 10 | 0.0% → - | 20.4 s → - | - | 26.6 s → - | 20,245 → - | - | - | - | - | - |
| 128k+8k | 12 | 0.0% → - | 20.6 s → - | - | 27.0 s → - | 20,403 → - | - | - | - | - | - |
| 128k+8k | 16 | 0.0% → - | 20.5 s → - | - | 26.8 s → - | 20,856 → - | - | - | - | - | - |
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
| 128k+8k | 4 | 62.7% → - | 6.9 s → - | - | 14.3 s → - | 37,557 → - | - | - | - | - | - |
| 128k+8k | 8 | 60.5% → 58.3% | 6.7 s → 6.4 s | 1.04x | 14.6 s → 15.1 s | 37,044 → 34,719 | 0.94x | 1.86M (112 pushes) | 0.00M | 0.0% | 0 |
| 128k+8k | 12 | 35.6% → 32.8% | 9.6 s → 9.7 s | 0.99x | 17.6 s → 18.0 s | 31,181 → 29,057 | 0.93x | 1.73M (182 pushes) | 0.00M | 0.0% | 0 |
| 128k+8k | 16 | 28.2% → 28.1% | 12.0 s → 10.9 s | 1.10x | 18.6 s → 18.9 s | 29,961 → 28,854 | 0.96x | 2.17M (346 pushes) | 0.00M | 0.0% | 0 |
| 128k+8k | 20 | 23.0% → 19.8% | 12.6 s → 11.6 s | 1.08x | 19.5 s → 19.9 s | 27,272 → 26,834 | 0.98x | 3.08M (441 pushes) | 0.00M | 0.0% | 0 |
| 128k+8k | 24 | 14.7% → 16.5% | 13.1 s → 12.6 s | 1.04x | 19.8 s → 20.5 s | 25,856 → 25,956 | 1.00x | 4.17M (631 pushes) | 0.00M | 0.0% | 0 |
| 128k+8k | 28 | 14.1% → 15.1% | 17.4 s → 13.8 s | 1.26x | 24.2 s → 21.8 s | 25,700 → 25,799 | 1.00x | 6.15M (698 pushes) | 0.00M | 0.0% | 0 |
| 256k+16k | 2 | 62.7% → 62.7% | 18.8 s → 52.9 s | 0.36x | 26.9 s → 60.3 s | 30,073 → 15,103 | 0.50x | 0.00M (12 pushes) | 0.00M | 0.0% | 0 |
| 256k+16k | 4 | 49.7% → 23.8% | 38.2 s → 68.1 s | 0.56x | 46.2 s → 96.9 s | 22,594 → 15,094 | 0.67x | 0.85M (11 pushes) | 0.00M | -0.0% | 0 |
| 256k+16k | 6 | 37.9% → - | 45.3 s → - | - | 54.4 s → - | 20,311 → - | - | - | - | - | - |
| 256k+16k | 8 | 29.4% → - | 51.1 s → - | - | 59.4 s → - | 19,466 → - | - | - | - | - | - |
| 256k+16k | 10 | 31.8% → - | 50.7 s → - | - | 58.8 s → - | 19,373 → - | - | - | - | - | - |
| 256k+16k | 12 | 9.8% → - | 64.2 s → - | - | 72.5 s → - | 16,529 → - | - | - | - | - | - |
| 256k+16k | 14 | 14.1% → - | 55.3 s → - | - | 63.3 s → - | 16,580 → - | - | - | - | - | - |

_Before points: 30; after points: 8. Offloaded tokens = victim-push tokens that landed in the decode's host pool during the point (decode landed_tokens deltas); pulled tokens = prefix-pull tokens the prefill received from the decode during the point (TP0 counter deltas); pulled share = those tokens / the point's measured-phase prompt tokens (for recall points the pulls of the fill phase are included, so the share can exceed 100%)._
