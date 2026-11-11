**Cache**: prefill-side hit, where the prefix was found, and what the on arm recalled from decode DRAM.

| Point | Requests on / off (errors) | Hit off | Hit on | Gain | Cached by tier device / host, off -> on | Recalled from decode DRAM (on) |
|---|---|---|---|---|---|---|
| recall_8_fill (fill) | 8 / 8 (0/0) | 0.0% | 0.0% | +0.0 pp | 0 / 0 -> 0 / 0 | 0 |
| recall_8_ret (recall) | 8 / 8 (0/0) | 92.3% | 94.4% | +2.1 pp | 0.24M / 0.88M -> 0.42M / 0.70M | 0 |
| recall_12_fill (fill) | 12 / 12 (0/0) | 0.0% | 0.0% | +0.0 pp | 0 / 0 -> 0 / 0 | 0 |
| recall_12_ret (recall) | 12 / 12 (0/0) | 28.2% | 37.1% | +8.9 pp | 1.17M / 0.50M -> 0.10M / 0.56M | 57,024 tok in 1 pulls + 128 SWA |
| recall_16_fill (fill) | 16 / 16 (0/0) | 0.0% | 0.0% | +0.0 pp | 0 / 0 -> 0 / 0 | 0 |
| recall_16_ret (recall) | 16 / 16 (0/0) | 0.0% | 64.9% | +64.9 pp | 2.23M / 0.00M -> 0.14M / 1.53M | 1,531,904 tok in 11 pulls + 1,408 SWA |
| static_4 | 12 / 12 (0/0) | 62.7% | 62.7% | +0.0 pp | 1.05M / 0.00M -> 1.05M / 0.00M | 0 |
| static_8 | 24 / 24 (0/0) | 62.3% | 55.6% | -6.7 pp | 1.85M / 0.25M -> 1.86M / 0.00M | 0 |
| static_12 | 36 / 36 (0/0) | 50.4% | 32.2% | -18.2 pp | 1.80M / 1.34M -> 2.43M / 0.00M | 0 |
| static_16 | 48 / 48 (0/0) | 39.8% | 27.1% | -12.7 pp | 3.09M / 1.10M -> 3.73M / 0.00M | 0 |
| mixed_long | 24 / 24 (0/0) | 21.9% | 39.7% | +17.8 pp | 0.91M / 1.18M -> 1.89M / 0.00M | 1,585,152 tok in 43 pulls + 5,504 SWA |
| mixed_short | 96 / 96 (0/0) | 21.9% | 39.7% | +17.8 pp | 1.22M / 0.00M -> 0.00M / 1.59M | 1,585,152 tok in 43 pulls + 5,504 SWA |

**Throughput** (gain = on vs off, higher is better).

| Point | Total tok/s off | on | Gain | Output tok/s off | on | Gain | Req/min off | on | Gain |
|---|---|---|---|---|---|---|---|---|---|
| recall_8_fill (fill) | 22328 | 22283 | -0% | 2.6 | 2.6 | +0% | 9.6 | 9.6 | -0% |
| recall_8_ret (recall) | 132883 | 134261 | +1% | 14.4 | 14.6 | +1% | 54.0 | 54.6 | +1% |
| recall_12_fill (fill) | 22906 | 22845 | -0% | 2.6 | 2.6 | +0% | 9.9 | 9.8 | -0% |
| recall_12_ret (recall) | 29500 | 32656 | +11% | 3.2 | 3.5 | +9% | 12.0 | 13.3 | +11% |
| recall_16_fill (fill) | 22919 | 22852 | -0% | 2.6 | 2.6 | +0% | 9.9 | 9.8 | -0% |
| recall_16_ret (recall) | 22230 | 56723 | +155% | 2.4 | 6.1 | +154% | 9.0 | 23.1 | +155% |
| static_4 | 51369 | 51056 | -1% | 94.2 | 93.7 | -1% | 22.1 | 21.9 | -1% |
| static_8 | 52414 | 45568 | -13% | 96.2 | 83.6 | -13% | 22.5 | 19.6 | -13% |
| static_12 | 42076 | 32246 | -23% | 77.2 | 59.2 | -23% | 18.1 | 13.9 | -23% |
| static_16 | 35744 | 30296 | -15% | 65.6 | 55.6 | -15% | 15.4 | 13.0 | -15% |
| mixed_long | 25182 | 22846 | -9% | 46.2 | 41.9 | -9% | 10.8 | 9.8 | -9% |
| mixed_short | 19277 | 22807 | +18% | 7.9 | 9.4 | +19% | 29.6 | 35.1 | +18% |

**Latency** (gain = reduction on vs off, positive means the on arm is faster).

| Point | TTFT p50 off | on | Gain | TTFT p95 off | on | Gain | ITL p50 off | on | Gain |
|---|---|---|---|---|---|---|---|---|---|
| recall_8_fill (fill) | 23.5 s | 23.5 s | +0% | 25.8 s | 25.7 s | +0% | 0.009 s | 0.010 s | -5% |
| recall_8_ret (recall) | 2.5 s | 2.6 s | -4% | 3.4 s | 4.6 s | -37% | 0.076 s | 0.072 s | +6% |
| recall_12_fill (fill) | 23.8 s | 23.8 s | -0% | 24.1 s | 24.1 s | -0% | 0.010 s | 0.009 s | +5% |
| recall_12_ret (recall) | 19.3 s | 18.6 s | +4% | 24.9 s | 20.7 s | +17% | 0.009 s | 0.010 s | -5% |
| recall_16_fill (fill) | 23.9 s | 24.0 s | -0% | 24.1 s | 24.1 s | -0% | 0.010 s | 0.009 s | +3% |
| recall_16_ret (recall) | 26.1 s | 8.0 s | +69% | 26.1 s | 19.7 s | +25% | 0.010 s | 0.010 s | -3% |
| static_4 | 7.2 s | 6.5 s | +10% | 16.3 s | 18.8 s | -15% | 0.009 s | 0.009 s | +2% |
| static_8 | 6.4 s | 9.5 s | -49% | 18.9 s | 18.7 s | +1% | 0.009 s | 0.009 s | +1% |
| static_12 | 7.2 s | 15.1 s | -109% | 22.0 s | 22.1 s | -1% | 0.009 s | 0.009 s | +3% |
| static_16 | 12.1 s | 15.8 s | -31% | 21.7 s | 21.9 s | -1% | 0.009 s | 0.009 s | +3% |
| mixed_long | 21.0 s | 20.9 s | +0% | 26.6 s | 26.5 s | +1% | 0.010 s | 0.010 s | -3% |
| mixed_short | 9.2 s | 5.3 s | +43% | 26.8 s | 26.7 s | +0% | 0.010 s | 0.011 s | -15% |

**Offload counters on the on arm, per point** (TP0 deltas from the server logs; every push and landing is a 128k-session branch with its SWA window).

| Point | Pushes stored / started | Landings landed / received | Recalls pulls / offers | Pulled tokens | SWA tokens | Failed / refused / no room |
|---|---|---|---|---|---|---|
| recall_8_fill (fill) | 0 / 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall_8_ret (recall) | 0 / 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall_12_fill (fill) | 0 / 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall_12_ret (recall) | 9 / 9 | 9 / 9 | 1 / 2 | 57,024 | 128 | 0 / 0 / 0 |
| recall_16_fill (fill) | 6 / 9 | 6 / 6 | 0 / 4 | 0 | 0 | 0 / 0 / 0 |
| recall_16_ret (recall) | 12 / 12 | 12 / 12 | 11 / 12 | 1,531,904 | 1,408 | 0 / 0 / 0 |
| static_4 | 2 / 2 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| static_8 | 0 / 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| static_12 | 16 / 16 | 16 / 16 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| static_16 | 35 / 35 | 35 / 35 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| mixed_long | 93 / 93 | 93 / 93 | 43 / 43 | 1,585,152 | 5,504 | 0 / 0 / 0 |
| mixed_short | 93 / 93 | 93 / 93 | 43 / 43 | 1,585,152 | 5,504 | 0 / 0 / 0 |

integrity on: 2026-11-11 00:32:18 integrity rc=0 SUMMARY {"sessions": 16, "prefix": 131072, "new": 8192, "out_tokens": 64, "concurrent_phase_s": 244.6, "probes": {"sent": 91, "exact": 75, "min_agree": 7, "errors": 0, "mismatch_positions": [7, 7, 16, 16, 16, 34, 34, 49, 49, 49, 84, 84, 84, 96, 96, 96]}, "errors": 0, "recall": {"compared": 16, "exact": 12, "min_agree": 5, "pulled_sessions": 15}}

integrity off: 2026-11-11 00:50:44 integrity rc=0 SUMMARY {"sessions": 16, "prefix": 131072, "new": 8192, "out_tokens": 64, "concurrent_phase_s": 320.1, "probes": {"sent": 96, "exact": 80, "min_agree": 7, "errors": 0, "mismatch_positions": [7, 7, 16, 16, 20, 21, 34, 34, 49, 49, 84, 84, 84, 96, 96, 96]}, "errors": 0, "recall": {"compared": 16, "exact": 16, "min_agree": 64, "pulled_sessions": 16}}

### final counters, on arm
- decode-0: ranks 8, warnings 0, errors 0, refused lines 0; landing received=204 granted=204 landed=204 landed_tokens=11889024
- prefill-0: ranks 8, warnings 0, errors 96, refused lines 0; push started=204 stored=204; recall offers=150 pulls=71 pulled_tokens=5271232 pulled_swa_tokens=9088 skipped_local_host=78 over_budget=1

### final counters, off arm
- decode-0: ranks 0, warnings 0, errors 0, refused lines 0; 
- prefill-0: ranks 0, warnings 0, errors 0, refused lines 0; 

route_ok false on: none
