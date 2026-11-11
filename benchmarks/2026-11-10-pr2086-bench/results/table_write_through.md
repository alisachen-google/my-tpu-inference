**Performance gain** (what a user of the pair sees; return rows are the requests whose prefix the previous turn produced).

| Point | TTFT p50 off -> on | Speedup | TTFT p95 off -> on | Speedup | E2E p50 off -> on | Wall s off -> on | Gain | Req/min off -> on | Gain | Warm returns off -> on | Prefill tokens computed per request, off -> on |
|---|---|---|---|---|---|---|---|---|---|---|---|
| recall_8_fill (fill) | 23.4 -> 23.4 s | 1.0x | 25.7 -> 25.8 s | 1.0x | 23.5 -> 23.6 s | 49.6 -> 49.7 | -0% | 9.7 -> 9.7 | -0% | 0 / 8 -> 0 / 8 | 139,298 -> 139,298 |
| recall_8_ret (recall) | 17.4 -> 4.3 s | 4.1x | 21.9 -> 7.4 s | 3.0x | 17.6 -> 6.2 s | 36.9 -> 15.2 | +59% | 13.0 -> 31.6 | +143% | 1 / 8 -> 7 / 8 | 97,481 -> 25,721 |
| recall_12_fill (fill) | 23.5 -> 23.6 s | 1.0x | 23.6 -> 23.7 s | 1.0x | 23.7 -> 23.8 s | 72.1 -> 72.2 | -0% | 10.0 -> 10.0 | -0% | 0 / 12 -> 0 / 12 | 139,298 -> 139,298 |
| recall_12_ret (recall) | 25.7 -> 7.5 s | 3.4x | 25.7 -> 14.0 s | 1.8x | 25.8 -> 7.6 s | 78.6 -> 31.2 | +60% | 9.2 -> 23.1 | +152% | 0 / 12 -> 6 / 12 | 147,577 -> 50,116 |
| recall_16_fill (fill) | 23.5 -> 23.6 s | 1.0x | 23.6 -> 23.6 s | 1.0x | 23.7 -> 23.7 s | 96.2 -> 96.1 | +0% | 10.0 -> 10.0 | +0% | 0 / 16 -> 0 / 16 | 139,298 -> 139,298 |
| recall_16_ret (recall) | 25.7 -> 2.4 s | 10.7x | 25.7 -> 8.4 s | 3.1x | 25.8 -> 2.6 s | 104.5 -> 17.8 | +83% | 9.2 -> 53.9 | +487% | 0 / 16 -> 12 / 16 | 147,577 -> 17,017 |
| static_4 | 7.0 -> 7.1 s | 1.0x | 15.5 -> 16.5 s | 0.9x | 10.1 -> 9.3 s | 34.9 -> 32.4 | +7% | 20.6 -> 22.2 | +8% | 5 / 12 -> 5 / 12 | 51,963 -> 51,963 |
| static_8 | 6.6 -> 7.7 s | 0.9x | 18.7 -> 16.4 s | 1.1x | 8.9 -> 10.4 s | 66.7 -> 66.4 | +0% | 21.6 -> 21.7 | +0% | 10 / 24 -> 9 / 24 | 54,672 -> 53,016 |
| static_12 | 12.4 -> 5.9 s | 2.1x | 21.8 -> 21.8 s | 1.0x | 14.6 -> 8.4 s | 145.0 -> 100.7 | +31% | 14.9 -> 21.4 | +44% | 4 / 36 -> 19 / 36 | 89,497 -> 53,829 |
| static_16 | 15.9 -> 9.6 s | 1.7x | 21.6 -> 21.4 s | 1.0x | 17.9 -> 12.0 s | 213.5 -> 151.5 | +29% | 13.5 -> 19.0 | +41% | 1 / 48 -> 17 / 48 | 100,392 -> 63,424 |
| mixed_long | 24.7 -> 15.7 s | 1.6x | 30.9 -> 26.7 s | 1.2x | 27.2 -> 18.8 s | 160.9 -> 112.2 | +30% | 8.9 -> 12.8 | +43% | 0 / 24 -> 4 / 24 | 261,761 -> 174,494 |
| mixed_short | 8.9 -> 8.9 s | 1.0x | 30.5 -> 28.1 s | 1.1x | 9.1 -> 9.1 s | 217.3 -> 161.3 | +26% | 26.5 -> 35.7 | +35% | 2 / 96 -> 7 / 96 | 65,440 -> 43,624 |

**Cache (mechanism)**: prefill-side hit, client-reported cached tokens, where the prefix was found, and what the on arm recalled from decode DRAM.

| Point | Requests on / off (errors) | Prefill-side hit off -> on | Gain | Client-reported hit off -> on | Cached by tier device / host, off -> on | Recalled from decode DRAM (on) |
|---|---|---|---|---|---|---|
| recall_8_fill (fill) | 8 / 8 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| recall_8_ret (recall) | 8 / 8 (0/0) | 34.0% -> 82.6% | +48.6 pp | 94.4% -> 82.6% | 0.88M / 0.24M -> 0.28M / 0.70M | 0 |
| recall_12_fill (fill) | 12 / 12 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| recall_12_ret (recall) | 12 / 12 (0/0) | 0.0% -> 66.0% | +66.0 pp | 94.4% -> 66.0% | 1.67M / 0.00M -> 0.06M / 1.10M | 1,047,680 tok in 10 pulls + 1,280 SWA |
| recall_16_fill (fill) | 16 / 16 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| recall_16_ret (recall) | 16 / 16 (0/0) | 0.0% -> 88.5% | +88.5 pp | 94.4% -> 94.4% | 2.23M / 0.00M -> 0.14M / 2.09M | 2,088,960 tok in 15 pulls + 1,920 SWA |
| static_4 | 12 / 12 (0/0) | 62.7% -> 62.7% | +0.0 pp | 62.7% -> 62.7% | 1.05M / 0.00M -> 1.05M / 0.00M | 0 |
| static_8 | 24 / 24 (0/0) | 60.8% -> 61.9% | +1.2 pp | 62.7% -> 62.2% | 1.82M / 0.28M -> 1.84M / 0.24M | 32,768 tok in 2 pulls + 256 SWA |
| static_12 | 36 / 36 (0/0) | 35.8% -> 61.4% | +25.6 pp | 62.7% -> 62.7% | 2.83M / 0.32M -> 1.56M / 1.58M | 1,497,792 tok in 14 pulls + 1,792 SWA |
| static_16 | 48 / 48 (0/0) | 27.9% -> 54.5% | +26.5 pp | 62.6% -> 60.1% | 3.81M / 0.37M -> 1.90M / 2.11M | 1,796,672 tok in 15 pulls + 1,920 SWA |
| mixed_long | 24 / 24 (0/0) | 11.3% -> 40.9% | +29.6 pp | 62.6% -> 61.7% | 1.92M / 0.18M -> 1.21M / 0.86M | 1,688,384 tok in 37 pulls + 4,736 SWA |
| mixed_short | 96 / 96 (0/0) | 11.3% -> 40.9% | +29.6 pp | 12.8% -> 26.3% | 0.48M / 0.00M -> 0.12M / 0.86M | 1,688,384 tok in 37 pulls + 4,736 SWA |

**Throughput** (gain = on vs off, higher is better).

| Point | Total tok/s off | on | Gain | Output tok/s off | on | Gain | Req/min off | on | Gain |
|---|---|---|---|---|---|---|---|---|---|
| recall_8_fill (fill) | 22487 | 22435 | -0% | 2.6 | 2.6 | +0% | 9.7 | 9.7 | -0% |
| recall_8_ret (recall) | 31988 | 77624 | +143% | 3.5 | 8.4 | +140% | 13.0 | 31.6 | +143% |
| recall_12_fill (fill) | 23176 | 23144 | -0% | 2.7 | 2.7 | +0% | 10.0 | 10.0 | -0% |
| recall_12_ret (recall) | 22539 | 56798 | +152% | 2.4 | 6.2 | +158% | 9.2 | 23.1 | +152% |
| recall_16_fill (fill) | 23180 | 23187 | +0% | 2.7 | 2.7 | +0% | 10.0 | 10.0 | +0% |
| recall_16_ret (recall) | 22589 | 132607 | +487% | 2.4 | 14.4 | +500% | 9.2 | 53.9 | +487% |
| static_4 | 47984 | 51686 | +8% | 88.0 | 94.8 | +8% | 20.6 | 22.2 | +8% |
| static_8 | 50214 | 50440 | +0% | 92.1 | 92.5 | +0% | 21.6 | 21.7 | +0% |
| static_12 | 34647 | 49890 | +44% | 63.6 | 91.5 | +44% | 14.9 | 21.4 | +44% |
| static_16 | 31375 | 44214 | +41% | 57.6 | 81.1 | +41% | 13.5 | 19.0 | +41% |
| mixed_long | 20816 | 29851 | +43% | 38.2 | 54.8 | +43% | 8.9 | 12.8 | +43% |
| mixed_short | 17231 | 23218 | +35% | 7.1 | 9.5 | +34% | 26.5 | 35.7 | +35% |

**Latency** (gain = reduction on vs off, positive means the on arm is faster).

| Point | TTFT p50 off | on | Gain | TTFT p95 off | on | Gain | ITL p50 off | on | Gain |
|---|---|---|---|---|---|---|---|---|---|
| recall_8_fill (fill) | 23.4 s | 23.4 s | -0% | 25.7 s | 25.8 s | -1% | 0.012 s | 0.009 s | +22% |
| recall_8_ret (recall) | 17.4 s | 4.3 s | +76% | 21.9 s | 7.4 s | +66% | 0.010 s | 0.074 s | -645% |
| recall_12_fill (fill) | 23.5 s | 23.6 s | -0% | 23.6 s | 23.7 s | -0% | 0.012 s | 0.009 s | +23% |
| recall_12_ret (recall) | 25.7 s | 7.5 s | +71% | 25.7 s | 14.0 s | +45% | 0.010 s | 0.010 s | -7% |
| recall_16_fill (fill) | 23.5 s | 23.6 s | -0% | 23.6 s | 23.6 s | -0% | 0.012 s | 0.010 s | +23% |
| recall_16_ret (recall) | 25.7 s | 2.4 s | +91% | 25.7 s | 8.4 s | +67% | 0.010 s | 0.011 s | -18% |
| static_4 | 7.0 s | 7.1 s | -1% | 15.5 s | 16.5 s | -6% | 0.012 s | 0.009 s | +27% |
| static_8 | 6.6 s | 7.7 s | -16% | 18.7 s | 16.4 s | +12% | 0.009 s | 0.009 s | -2% |
| static_12 | 12.4 s | 5.9 s | +52% | 21.8 s | 21.8 s | -0% | 0.009 s | 0.009 s | -4% |
| static_16 | 15.9 s | 9.6 s | +40% | 21.6 s | 21.4 s | +1% | 0.009 s | 0.010 s | -10% |
| mixed_long | 24.7 s | 15.7 s | +37% | 30.9 s | 26.7 s | +14% | 0.011 s | 0.011 s | -2% |
| mixed_short | 8.9 s | 8.9 s | +0% | 30.5 s | 28.1 s | +8% | 0.011 s | 0.011 s | -9% |

**Offload counters on the on arm, per point** (TP0 deltas from the server logs; every push and landing is a 128k-session branch with its SWA window).

| Point | Pushes stored / started | Landings landed / received | Recalls pulls / offers | Pulled tokens | SWA tokens | Failed / refused / no room |
|---|---|---|---|---|---|---|
| recall_8_fill (fill) | 7 / 7 | 7 / 7 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall_8_ret (recall) | 0 / 0 | 10 / 10 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall_12_fill (fill) | 68 / 69 | 69 / 69 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall_12_ret (recall) | 18 / 18 | 19 / 19 | 10 / 10 | 1,047,680 | 1,280 | 0 / 0 / 0 |
| recall_16_fill (fill) | 138 / 138 | 133 / 135 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| recall_16_ret (recall) | 13 / 13 | 13 / 13 | 15 / 16 | 2,088,960 | 1,920 | 0 / 0 / 0 |
| static_4 | 0 / 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| static_8 | 33 / 33 | 31 / 31 | 2 / 3 | 32,768 | 256 | 0 / 0 / 0 |
| static_12 | 105 / 105 | 107 / 107 | 14 / 17 | 1,497,792 | 1,792 | 0 / 0 / 0 |
| static_16 | 137 / 137 | 127 / 130 | 15 / 17 | 1,796,672 | 1,920 | 0 / 0 / 0 |
| mixed_long | 321 / 321 | 298 / 299 | 37 / 39 | 1,688,384 | 4,736 | 0 / 0 / 0 |
| mixed_short | 321 / 321 | 298 / 299 | 37 / 39 | 1,688,384 | 4,736 | 0 / 0 / 0 |

integrity on: 2026-11-11 01:20:13 integrity rc=0 SUMMARY {"sessions": 16, "prefix": 131072, "new": 8192, "out_tokens": 64, "concurrent_phase_s": 232.9, "probes": {"sent": 89, "exact": 73, "min_agree": 7, "errors": 0, "mismatch_positions": [7, 7, 16, 16, 16, 34, 34, 49, 49, 49, 84, 84, 84, 96, 96, 96]}, "errors": 0, "recall": {"compared": 16, "exact": 16, "min_agree": 64, "pulled_sessions": 16}}

integrity off: 2026-11-11 01:52:09 integrity rc=0 SUMMARY {"sessions": 16, "prefix": 131072, "new": 8192, "out_tokens": 64, "concurrent_phase_s": 316.4, "probes": {"sent": 94, "exact": 78, "min_agree": 7, "errors": 0, "mismatch_positions": [7, 7, 16, 16, 20, 34, 34, 49, 49, 49, 84, 84, 84, 96, 96, 96]}, "errors": 0, "recall": {"compared": 16, "exact": 16, "min_agree": 64, "pulled_sessions": 16}}

### final counters, on arm
- decode-0: ranks 8, warnings 0, errors 0, refused lines 0; landing received=1042 granted=1042 landed=1042 landed_tokens=16885056
- prefill-0: ranks 8, warnings 0, errors 0, refused lines 0; push started=1042 stored=1042; recall offers=205 pulls=118 pulled_tokens=10741504 pulled_swa_tokens=15104 skipped_local_host=86 over_budget=1

### final counters, off arm
- decode-0: ranks 0, warnings 0, errors 0, refused lines 0; 
- prefill-0: ranks 0, warnings 0, errors 0, refused lines 0; 

route_ok false on: none
