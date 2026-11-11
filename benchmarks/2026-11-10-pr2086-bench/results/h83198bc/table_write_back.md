**Performance gain** (what a user of the pair sees; return rows are the requests whose prefix the previous turn produced).

| Point | TTFT p50 off -> on | Speedup | TTFT p95 off -> on | Speedup | E2E p50 off -> on | Wall s off -> on | Gain | Req/min off -> on | Gain | Warm returns off -> on | Prefill tokens computed per request, off -> on |
|---|---|---|---|---|---|---|---|---|---|---|---|
| recall_8_fill (fill) | 23.4 -> 23.5 s | 1.0x | 25.8 -> 26.0 s | 1.0x | 23.5 -> 23.6 s | 49.8 -> 50.1 | -1% | 9.6 -> 9.6 | -1% | 0 / 8 -> 0 / 8 | 139,298 -> 139,298 |
| recall_8_ret (recall) | 2.4 -> 4.3 s | 0.5x | 3.2 -> 7.3 s | 0.4x | 3.1 -> 5.3 s | 7.0 -> 13.4 | -91% | 69.0 -> 35.9 | -48% | 8 / 8 -> 7 / 8 | 9,345 -> 19,561 |
| recall_12_fill (fill) | 23.6 -> 23.7 s | 1.0x | 24.0 -> 24.0 s | 1.0x | 23.8 -> 23.8 s | 72.7 -> 72.8 | -0% | 9.9 -> 9.9 | -0% | 0 / 12 -> 0 / 12 | 139,298 -> 139,298 |
| recall_12_ret (recall) | 22.0 -> 11.9 s | 1.9x | 23.4 -> 19.8 s | 1.2x | 22.2 -> 12.0 s | 63.9 -> 41.0 | +36% | 11.3 -> 17.5 | +56% | 1 / 12 -> 2 / 12 | 109,449 -> 65,705 |
| recall_16_fill (fill) | 23.7 -> 23.6 s | 1.0x | 24.0 -> 24.0 s | 1.0x | 23.9 -> 23.8 s | 96.9 -> 96.8 | +0% | 9.9 -> 9.9 | +0% | 0 / 16 -> 0 / 16 | 139,298 -> 139,298 |
| recall_16_ret (recall) | 26.0 -> 9.5 s | 2.7x | 26.1 -> 20.1 s | 1.3x | 26.2 -> 9.6 s | 106.0 -> 52.6 | +50% | 9.1 -> 18.2 | +101% | 0 / 16 -> 4 / 16 | 147,077 -> 65,597 |
| static_4 | 10.3 -> 10.6 s | 1.0x | 16.4 -> 16.6 s | 1.0x | 13.3 -> 12.9 s | 33.0 -> 32.3 | +2% | 21.8 -> 22.3 | +2% | 5 / 12 -> 5 / 12 | 51,968 -> 51,968 |
| static_8 | 6.9 -> 7.2 s | 1.0x | 16.4 -> 16.3 s | 1.0x | 9.2 -> 9.5 s | 63.1 -> 64.2 | -2% | 22.8 -> 22.4 | -2% | 9 / 24 -> 9 / 24 | 52,248 -> 52,208 |
| static_12 | 7.5 -> 8.2 s | 0.9x | 22.0 -> 22.2 s | 1.0x | 9.9 -> 10.4 s | 118.7 -> 112.7 | +5% | 18.2 -> 19.2 | +5% | 10 / 36 -> 13 / 36 | 68,322 -> 62,222 |
| static_16 | 11.5 -> 7.1 s | 1.6x | 21.5 -> 21.3 s | 1.0x | 14.0 -> 9.8 s | 185.5 -> 154.1 | +17% | 15.5 -> 18.7 | +20% | 7 / 48 -> 14 / 48 | 84,213 -> 64,157 |
| mixed_long | 19.2 -> 17.2 s | 1.1x | 26.6 -> 26.6 s | 1.0x | 21.8 -> 20.1 s | 131.9 -> 114.6 | +13% | 10.9 -> 12.6 | +15% | 1 / 24 -> 4 / 24 | 230,667 -> 147,569 |
| mixed_short | 9.2 -> 4.5 s | 2.1x | 26.8 -> 26.5 s | 1.0x | 9.3 -> 4.6 s | 194.1 -> 147.9 | +24% | 29.7 -> 38.9 | +31% | 2 / 96 -> 33 / 96 | 57,667 -> 36,892 |

**Cache (mechanism)**: prefill-side hit, client-reported cached tokens, where the prefix was found, and what the on arm recalled from decode DRAM.

| Point | Requests on / off (errors) | Prefill-side hit off -> on | Gain | Client-reported hit off -> on | Cached by tier device / host, off -> on | Recalled from decode DRAM (on) |
|---|---|---|---|---|---|---|
| recall_8_fill (fill) | 8 / 8 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| recall_8_ret (recall) | 8 / 8 (0/0) | 93.7% -> 86.8% | -6.9 pp | 94.4% -> 86.8% | 0.26M / 0.85M -> 0.16M / 0.86M | 0 |
| recall_12_fill (fill) | 12 / 12 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| recall_12_ret (recall) | 12 / 12 (0/0) | 25.8% -> 55.5% | +29.6 pp | 94.4% -> 55.5% | 1.21M / 0.46M -> 0.00M / 0.98M | 295,488 tok in 5 pulls + 640 SWA |
| recall_16_fill (fill) | 16 / 16 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| recall_16_ret (recall) | 16 / 16 (0/0) | 0.3% -> 55.5% | +55.2 pp | 94.4% -> 61.5% | 2.22M / 0.01M -> 0.14M / 1.31M | 1,188,544 tok in 11 pulls + 1,408 SWA |
| static_4 | 12 / 12 (0/0) | 62.7% -> 62.7% | +0.0 pp | 62.7% -> 62.7% | 1.05M / 0.00M -> 1.05M / 0.00M | 0 |
| static_8 | 24 / 24 (0/0) | 62.5% -> 62.5% | +0.0 pp | 62.7% -> 62.5% | 1.85M / 0.25M -> 1.74M / 0.35M | 0 |
| static_12 | 36 / 36 (0/0) | 50.9% -> 55.3% | +4.4 pp | 62.6% -> 58.8% | 1.93M / 1.20M -> 1.79M / 1.16M | 417,216 tok in 7 pulls + 896 SWA |
| static_16 | 48 / 48 (0/0) | 39.5% -> 53.9% | +14.4 pp | 62.7% -> 62.1% | 3.11M / 1.08M -> 2.38M / 1.77M | 771,136 tok in 12 pulls + 1,536 SWA |
| mixed_long | 24 / 24 (0/0) | 21.9% -> 50.0% | +28.1 pp | 62.7% -> 62.5% | 1.20M / 0.90M -> 1.15M / 0.94M | 1,802,880 tok in 47 pulls + 6,016 SWA |
| mixed_short | 96 / 96 (0/0) | 21.9% -> 50.0% | +28.1 pp | 34.5% -> 40.9% | 1.29M / 0.00M -> 0.00M / 1.53M | 1,802,880 tok in 47 pulls + 6,016 SWA |

**Throughput** (gain = on vs off, higher is better).

| Point | Total tok/s off | on | Gain | Output tok/s off | on | Gain | Req/min off | on | Gain |
|---|---|---|---|---|---|---|---|---|---|
| recall_8_fill (fill) | 22360 | 22250 | -0% | 2.6 | 2.6 | +0% | 9.6 | 9.6 | -1% |
| recall_8_ret (recall) | 169638 | 88363 | -48% | 18.4 | 9.6 | -48% | 69.0 | 35.9 | -48% |
| recall_12_fill (fill) | 22986 | 22956 | -0% | 2.6 | 2.6 | +0% | 9.9 | 9.9 | -0% |
| recall_12_ret (recall) | 27696 | 43148 | +56% | 3.0 | 4.7 | +57% | 11.3 | 17.5 | +56% |
| recall_16_fill (fill) | 22999 | 23039 | +0% | 2.6 | 2.6 | +0% | 9.9 | 9.9 | +0% |
| recall_16_ret (recall) | 22286 | 44879 | +101% | 2.4 | 4.9 | +104% | 9.1 | 18.2 | +101% |
| static_4 | 50767 | 51908 | +2% | 93.1 | 95.2 | +2% | 21.8 | 22.3 | +2% |
| static_8 | 53063 | 52153 | -2% | 97.3 | 95.7 | -2% | 22.8 | 22.4 | -2% |
| static_12 | 42310 | 44583 | +5% | 77.6 | 81.8 | +5% | 18.2 | 19.2 | +5% |
| static_16 | 36114 | 43477 | +20% | 66.2 | 79.8 | +21% | 15.5 | 18.7 | +20% |
| mixed_long | 25398 | 29232 | +15% | 46.6 | 53.6 | +15% | 10.9 | 12.6 | +15% |
| mixed_short | 19287 | 25312 | +31% | 7.9 | 10.4 | +32% | 29.7 | 38.9 | +31% |

**Latency** (gain = reduction on vs off, positive means the on arm is faster).

| Point | TTFT p50 off | on | Gain | TTFT p95 off | on | Gain | ITL p50 off | on | Gain |
|---|---|---|---|---|---|---|---|---|---|
| recall_8_fill (fill) | 23.4 s | 23.5 s | -0% | 25.8 s | 26.0 s | -1% | 0.009 s | 0.009 s | +2% |
| recall_8_ret (recall) | 2.4 s | 4.3 s | -83% | 3.2 s | 7.3 s | -125% | 0.019 s | 0.075 s | -283% |
| recall_12_fill (fill) | 23.6 s | 23.7 s | -0% | 24.0 s | 24.0 s | -0% | 0.009 s | 0.009 s | +4% |
| recall_12_ret (recall) | 22.0 s | 11.9 s | +46% | 23.4 s | 19.8 s | +15% | 0.009 s | 0.010 s | -6% |
| recall_16_fill (fill) | 23.7 s | 23.6 s | +0% | 24.0 s | 24.0 s | +0% | 0.010 s | 0.009 s | +4% |
| recall_16_ret (recall) | 26.0 s | 9.5 s | +64% | 26.1 s | 20.1 s | +23% | 0.010 s | 0.010 s | +2% |
| static_4 | 10.3 s | 10.6 s | -3% | 16.4 s | 16.6 s | -1% | 0.009 s | 0.009 s | +1% |
| static_8 | 6.9 s | 7.2 s | -5% | 16.4 s | 16.3 s | +1% | 0.009 s | 0.009 s | +2% |
| static_12 | 7.5 s | 8.2 s | -8% | 22.0 s | 22.2 s | -1% | 0.009 s | 0.009 s | +2% |
| static_16 | 11.5 s | 7.1 s | +38% | 21.5 s | 21.3 s | +1% | 0.009 s | 0.009 s | -3% |
| mixed_long | 19.2 s | 17.2 s | +10% | 26.6 s | 26.6 s | -0% | 0.010 s | 0.010 s | -6% |
| mixed_short | 9.2 s | 4.5 s | +52% | 26.8 s | 26.5 s | +1% | 0.010 s | 0.012 s | -19% |

**Offload counters on the on arm, per point** (TP0 deltas from the server logs; every push and landing is a 128k-session branch with its SWA window).

| Point | Pushes stored / started | Landings landed / received | Recalls pulls / offers | Pulled tokens | SWA tokens | Failed / refused / no room |
|---|---|---|---|---|---|---|
| recall_8_fill (fill) | 0 / 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall_8_ret (recall) | 4 / 4 | 4 / 4 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall_12_fill (fill) | 0 / 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall_12_ret (recall) | 40 / 40 | 40 / 40 | 5 / 5 | 295,488 | 640 | 0 / 0 / 0 |
| recall_16_fill (fill) | 45 / 45 | 45 / 45 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall_16_ret (recall) | 32 / 32 | 32 / 32 | 11 / 12 | 1,188,544 | 1,408 | 0 / 0 / 0 |
| static_4 | 0 / 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| static_8 | 0 / 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| static_12 | 49 / 49 | 49 / 49 | 7 / 10 | 417,216 | 896 | 0 / 0 / 0 |
| static_16 | 107 / 107 | 107 / 107 | 12 / 17 | 771,136 | 1,536 | 0 / 0 / 0 |
| mixed_long | 191 / 191 | 191 / 191 | 47 / 48 | 1,802,880 | 6,016 | 0 / 0 / 0 |
| mixed_short | 191 / 191 | 191 / 191 | 47 / 48 | 1,802,880 | 6,016 | 0 / 0 / 0 |

integrity on: 2026-11-11 09:29:32 integrity rc=0 SUMMARY {"sessions": 16, "prefix": 131072, "new": 8192, "out_tokens": 64, "concurrent_phase_s": 244.0, "probes": {"sent": 89, "exact": 73, "min_agree": 7, "errors": 0, "mismatch_positions": [7, 7, 16, 16, 16, 34, 34, 49, 49, 49, 84, 84, 84, 96, 96, 96]}, "errors": 0, "recall": {"compared": 16, "exact": 16, "min_agree": 64, "pulled_sessions": 13}}

integrity off: 2026-11-11 09:20:00 integrity rc=0 SUMMARY {"sessions": 16, "prefix": 131072, "new": 8192, "out_tokens": 64, "concurrent_phase_s": 318.6, "probes": {"sent": 96, "exact": 80, "min_agree": 7, "errors": 0, "mismatch_positions": [7, 7, 16, 16, 16, 21, 34, 34, 49, 49, 84, 84, 84, 96, 96, 96]}, "errors": 0, "recall": {"compared": 16, "exact": 16, "min_agree": 64, "pulled_sessions": 16}}

### final counters, on arm
- decode-0: ranks 8, warnings 0, errors 0, refused lines 0; landing received=574 granted=574 landed=574 landed_tokens=11390464
- prefill-0: ranks 8, warnings 0, errors 168, refused lines 0; push started=574 stored=574; recall offers=184 pulls=103 pulled_tokens=6490496 pulled_swa_tokens=13184 skipped_local_host=80 over_budget=1

### final counters, off arm
- decode-0: ranks 0, warnings 0, errors 0, refused lines 0; 
- prefill-0: ranks 0, warnings 0, errors 0, refused lines 0; 

route_ok false on: none
