**Performance gain** (what a user of the pair sees; return rows are the requests whose prefix the previous turn produced).

| Point | TTFT p50 off -> on | Speedup | TTFT p95 off -> on | Speedup | E2E p50 off -> on | Wall s off -> on | Gain | Req/min off -> on | Gain | Warm returns off -> on | Prefill tokens computed per request, off -> on |
|---|---|---|---|---|---|---|---|---|---|---|---|
| recall_8_fill (fill) | 23.4 -> 23.4 s | 1.0x | 25.9 -> 26.0 s | 1.0x | 23.5 -> 23.5 s | 49.8 -> 49.8 | +0% | 9.6 -> 9.6 | +0% | 0 / 8 -> 0 / 8 | 139,298 -> 139,298 |
| recall_8_ret (recall) | 17.2 -> 2.4 s | 7.2x | 22.1 -> 3.2 s | 7.0x | 17.4 -> 2.7 s | 37.0 -> 6.0 | +84% | 13.0 -> 80.6 | +521% | 2 / 8 -> 8 / 8 | 93,425 -> 8,313 |
| recall_12_fill (fill) | 23.6 -> 23.5 s | 1.0x | 23.6 -> 23.6 s | 1.0x | 23.8 -> 23.7 s | 72.4 -> 72.1 | +0% | 9.9 -> 10.0 | +0% | 0 / 12 -> 0 / 12 | 139,298 -> 139,298 |
| recall_12_ret (recall) | 25.7 -> 9.0 s | 2.9x | 25.8 -> 16.2 s | 1.6x | 25.9 -> 9.1 s | 78.8 -> 38.8 | +51% | 9.1 -> 18.5 | +103% | 0 / 12 -> 1 / 12 | 147,577 -> 64,446 |
| recall_16_fill (fill) | 23.6 -> 23.5 s | 1.0x | 23.6 -> 23.6 s | 1.0x | 23.8 -> 23.7 s | 96.4 -> 96.1 | +0% | 10.0 -> 10.0 | +0% | 0 / 16 -> 0 / 16 | 139,298 -> 139,298 |
| recall_16_ret (recall) | 25.7 -> 2.4 s | 10.9x | 25.8 -> 8.6 s | 3.0x | 25.9 -> 2.5 s | 104.8 -> 17.1 | +84% | 9.2 -> 56.0 | +512% | 0 / 16 -> 12 / 16 | 147,577 -> 17,017 |
| static_4 | 7.0 -> 7.1 s | 1.0x | 15.5 -> 16.5 s | 0.9x | 10.1 -> 9.3 s | 33.8 -> 34.2 | -1% | 21.3 -> 21.1 | -1% | 5 / 12 -> 5 / 12 | 51,963 -> 51,963 |
| static_8 | 6.7 -> 7.9 s | 0.8x | 18.7 -> 18.9 s | 1.0x | 9.1 -> 10.3 s | 66.6 -> 66.4 | +0% | 21.6 -> 21.7 | +0% | 10 / 24 -> 9 / 24 | 54,675 -> 54,013 |
| static_12 | 12.5 -> 5.6 s | 2.2x | 22.0 -> 21.9 s | 1.0x | 14.8 -> 8.1 s | 145.0 -> 101.4 | +30% | 14.9 -> 21.3 | +43% | 4 / 36 -> 19 / 36 | 89,470 -> 55,198 |
| static_16 | 15.8 -> 7.0 s | 2.3x | 21.8 -> 21.6 s | 1.0x | 17.9 -> 9.2 s | 211.7 -> 141.7 | +33% | 13.6 -> 20.3 | +49% | 1 / 48 -> 18 / 48 | 99,451 -> 58,148 |
| mixed_long | 24.4 -> 15.1 s | 1.6x | 31.3 -> 26.5 s | 1.2x | 26.8 -> 17.9 s | 160.9 -> 116.5 | +28% | 8.9 -> 12.4 | +38% | 0 / 24 -> 1 / 24 | 260,665 -> 173,014 |
| mixed_short | 8.9 -> 8.4 s | 1.1x | 31.7 -> 28.5 s | 1.1x | 9.1 -> 8.6 s | 216.6 -> 163.5 | +25% | 26.6 -> 35.2 | +32% | 2 / 96 -> 14 / 96 | 65,166 -> 43,254 |

**Cache (mechanism)**: prefill-side hit, client-reported cached tokens, where the prefix was found, and what the on arm recalled from decode DRAM.

| Point | Requests on / off (errors) | Prefill-side hit off -> on | Gain | Client-reported hit off -> on | Cached by tier device / host, off -> on | Recalled from decode DRAM (on) |
|---|---|---|---|---|---|---|
| recall_8_fill (fill) | 8 / 8 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| recall_8_ret (recall) | 8 / 8 (0/0) | 36.7% -> 94.4% | +57.7 pp | 94.4% -> 94.4% | 0.80M / 0.32M -> 0.22M / 0.89M | 394,560 tok in 7 pulls + 896 SWA |
| recall_12_fill (fill) | 12 / 12 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| recall_12_ret (recall) | 12 / 12 (0/0) | 0.0% -> 56.3% | +56.3 pp | 94.4% -> 72.1% | 1.67M / 0.00M -> 0.34M / 0.94M | 883,840 tok in 8 pulls + 1,024 SWA |
| recall_16_fill (fill) | 16 / 16 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| recall_16_ret (recall) | 16 / 16 (0/0) | 0.0% -> 88.5% | +88.5 pp | 94.4% -> 94.4% | 2.23M / 0.00M -> 0.14M / 2.09M | 2,088,960 tok in 15 pulls + 1,920 SWA |
| static_4 | 12 / 12 (0/0) | 62.7% -> 62.7% | +0.0 pp | 62.7% -> 62.7% | 1.05M / 0.00M -> 1.05M / 0.00M | 0 |
| static_8 | 24 / 24 (0/0) | 60.8% -> 61.2% | +0.5 pp | 62.7% -> 62.0% | 1.83M / 0.27M -> 1.87M / 0.20M | 65,536 tok in 2 pulls + 256 SWA |
| static_12 | 36 / 36 (0/0) | 35.8% -> 60.4% | +24.6 pp | 62.7% -> 62.7% | 2.90M / 0.25M -> 1.57M / 1.58M | 1,203,200 tok in 14 pulls + 1,792 SWA |
| static_16 | 48 / 48 (0/0) | 28.6% -> 58.3% | +29.7 pp | 62.6% -> 61.0% | 3.90M / 0.28M -> 1.64M / 2.43M | 2,253,568 tok in 19 pulls + 2,432 SWA |
| mixed_long | 24 / 24 (0/0) | 11.7% -> 41.4% | +29.7 pp | 62.7% -> 61.5% | 1.93M / 0.16M -> 1.10M / 0.96M | 1,563,520 tok in 41 pulls + 5,248 SWA |
| mixed_short | 96 / 96 (0/0) | 11.7% -> 41.4% | +29.7 pp | 13.8% -> 30.0% | 0.52M / 0.00M -> 0.17M / 0.95M | 1,563,520 tok in 41 pulls + 5,248 SWA |

**Throughput** (gain = on vs off, higher is better).

| Point | Total tok/s off | on | Gain | Output tok/s off | on | Gain | Req/min off | on | Gain |
|---|---|---|---|---|---|---|---|---|---|
| recall_8_fill (fill) | 22367 | 22362 | -0% | 2.6 | 2.6 | +0% | 9.6 | 9.6 | +0% |
| recall_8_ret (recall) | 31955 | 198305 | +521% | 3.5 | 21.5 | +514% | 13.0 | 80.6 | +521% |
| recall_12_fill (fill) | 23088 | 23175 | +0% | 2.7 | 2.7 | +0% | 9.9 | 10.0 | +0% |
| recall_12_ret (recall) | 22479 | 45612 | +103% | 2.4 | 4.9 | +104% | 9.1 | 18.5 | +103% |
| recall_16_fill (fill) | 23132 | 23192 | +0% | 2.7 | 2.7 | +0% | 10.0 | 10.0 | +0% |
| recall_16_ret (recall) | 22523 | 137881 | +512% | 2.4 | 14.9 | +521% | 9.2 | 56.0 | +512% |
| static_4 | 49576 | 48958 | -1% | 90.9 | 89.8 | -1% | 21.3 | 21.1 | -1% |
| static_8 | 50271 | 50478 | +0% | 92.2 | 92.6 | +0% | 21.6 | 21.7 | +0% |
| static_12 | 34637 | 49554 | +43% | 63.5 | 90.9 | +43% | 14.9 | 21.3 | +43% |
| static_16 | 31639 | 47289 | +49% | 58.0 | 86.7 | +49% | 13.6 | 20.3 | +49% |
| mixed_long | 20818 | 28746 | +38% | 38.2 | 52.7 | +38% | 8.9 | 12.4 | +38% |
| mixed_short | 17285 | 22898 | +32% | 7.1 | 9.4 | +32% | 26.6 | 35.2 | +32% |

**Latency** (gain = reduction on vs off, positive means the on arm is faster).

| Point | TTFT p50 off | on | Gain | TTFT p95 off | on | Gain | ITL p50 off | on | Gain |
|---|---|---|---|---|---|---|---|---|---|
| recall_8_fill (fill) | 23.4 s | 23.4 s | -0% | 25.9 s | 26.0 s | -0% | 0.012 s | 0.010 s | +15% |
| recall_8_ret (recall) | 17.2 s | 2.4 s | +86% | 22.1 s | 3.2 s | +86% | 0.010 s | 0.016 s | -67% |
| recall_12_fill (fill) | 23.6 s | 23.5 s | +0% | 23.6 s | 23.6 s | -0% | 0.012 s | 0.010 s | +16% |
| recall_12_ret (recall) | 25.7 s | 9.0 s | +65% | 25.8 s | 16.2 s | +37% | 0.010 s | 0.011 s | -14% |
| recall_16_fill (fill) | 23.6 s | 23.5 s | +0% | 23.6 s | 23.6 s | +0% | 0.012 s | 0.011 s | +9% |
| recall_16_ret (recall) | 25.7 s | 2.4 s | +91% | 25.8 s | 8.6 s | +67% | 0.009 s | 0.011 s | -18% |
| static_4 | 7.0 s | 7.1 s | -1% | 15.5 s | 16.5 s | -6% | 0.012 s | 0.009 s | +25% |
| static_8 | 6.7 s | 7.9 s | -18% | 18.7 s | 18.9 s | -1% | 0.009 s | 0.009 s | +0% |
| static_12 | 12.5 s | 5.6 s | +56% | 22.0 s | 21.9 s | +0% | 0.009 s | 0.009 s | -6% |
| static_16 | 15.8 s | 7.0 s | +56% | 21.8 s | 21.6 s | +1% | 0.009 s | 0.009 s | -6% |
| mixed_long | 24.4 s | 15.1 s | +38% | 31.3 s | 26.5 s | +15% | 0.010 s | 0.011 s | -7% |
| mixed_short | 8.9 s | 8.4 s | +6% | 31.7 s | 28.5 s | +10% | 0.010 s | 0.012 s | -17% |

**Offload counters on the on arm, per point** (TP0 deltas from the server logs; every push and landing is a 128k-session branch with its SWA window).

| Point | Pushes stored / started | Landings landed / received | Recalls pulls / offers | Pulled tokens | SWA tokens | Failed / refused / no room |
|---|---|---|---|---|---|---|
| recall_8_fill (fill) | 8 / 8 | 8 / 8 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall_8_ret (recall) | 8 / 8 | 8 / 8 | 7 / 8 | 394,560 | 896 | 0 / 0 / 0 |
| recall_12_fill (fill) | 70 / 70 | 70 / 70 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall_12_ret (recall) | 26 / 26 | 26 / 26 | 8 / 10 | 883,840 | 1,024 | 0 / 0 / 0 |
| recall_16_fill (fill) | 137 / 137 | 137 / 137 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall_16_ret (recall) | 17 / 17 | 17 / 17 | 15 / 16 | 2,088,960 | 1,920 | 0 / 0 / 0 |
| static_4 | 0 / 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| static_8 | 36 / 36 | 36 / 36 | 2 / 5 | 65,536 | 256 | 0 / 0 / 0 |
| static_12 | 111 / 111 | 111 / 111 | 14 / 17 | 1,203,200 | 1,792 | 0 / 0 / 0 |
| static_16 | 146 / 146 | 146 / 146 | 19 / 21 | 2,253,568 | 2,432 | 0 / 0 / 0 |
| mixed_long | 342 / 342 | 342 / 342 | 41 / 45 | 1,563,520 | 5,248 | 0 / 0 / 0 |
| mixed_short | 342 / 342 | 342 / 342 | 41 / 45 | 1,563,520 | 5,248 | 0 / 0 / 0 |

integrity on: 2026-11-11 09:18:51 integrity rc=0 SUMMARY {"sessions": 16, "prefix": 131072, "new": 8192, "out_tokens": 64, "concurrent_phase_s": 234.0, "probes": {"sent": 92, "exact": 76, "min_agree": 7, "errors": 0, "mismatch_positions": [7, 7, 16, 16, 20, 34, 34, 49, 49, 49, 84, 84, 84, 96, 96, 96]}, "errors": 0, "recall": {"compared": 16, "exact": 16, "min_agree": 64, "pulled_sessions": 16}}

integrity off: 2026-11-11 09:30:27 integrity rc=0 SUMMARY {"sessions": 16, "prefix": 131072, "new": 8192, "out_tokens": 64, "concurrent_phase_s": 316.9, "probes": {"sent": 99, "exact": 83, "min_agree": 7, "errors": 0, "mismatch_positions": [7, 7, 16, 16, 20, 34, 34, 49, 49, 49, 84, 84, 84, 96, 96, 96]}, "errors": 0, "recall": {"compared": 16, "exact": 16, "min_agree": 64, "pulled_sessions": 16}}

### final counters, on arm
- decode-0: ranks 8, warnings 0, errors 16, refused lines 0; landing received=1090 granted=1090 landed=1090 landed_tokens=16945280
- prefill-0: ranks 8, warnings 0, errors 0, refused lines 0; push started=1090 stored=1090; recall offers=222 pulls=127 pulled_tokens=10705984 pulled_swa_tokens=16256 skipped_local_host=92 no_memory=1 over_budget=2

### final counters, off arm
- decode-0: ranks 0, warnings 0, errors 0, refused lines 0; 
- prefill-0: ranks 0, warnings 0, errors 0, refused lines 0; 

route_ok false on: none
