| Point | Requests on / off (errors) | Prefill hit off -> on | Cached KV by tier, device / host, off -> on | Recalled KV from decode DRAM (on) | Total tok/s off -> on | Output tok/s off -> on | Req/min off -> on | TTFT p50 / p95 off -> on | ITL p50 off -> on | Push / landing counters (on, this point) |
|---|---|---|---|---|---|---|---|---|---|---|
| recall_8_fill (fill) | 8 / 8 (0/0) | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 | 22328 -> 22283 | 2.6 -> 2.6 | 9.6 -> 9.6 | 23.5 / 25.8 s -> 23.5 / 25.7 s | 0.009 -> 0.010 s | none |
| recall_8_ret (recall) | 8 / 8 (0/0) | 92.3% -> 94.4% | 0.24M / 0.88M -> 0.42M / 0.70M | 0 | 132883 -> 134261 | 14.4 -> 14.6 | 54.0 -> 54.6 | 2.5 / 3.4 s -> 2.6 / 4.6 s | 0.076 -> 0.072 s | none |
| recall_12_fill (fill) | 12 / 12 (0/0) | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 | 22906 -> 22845 | 2.6 -> 2.6 | 9.9 -> 9.8 | 23.8 / 24.1 s -> 23.8 / 24.1 s | 0.010 -> 0.009 s | none |
| recall_12_ret (recall) | 12 / 12 (0/0) | 28.2% -> 37.1% | 1.17M / 0.50M -> 0.10M / 0.56M | 57,024 tok in 1 pulls + 128 SWA | 29500 -> 32656 | 3.2 -> 3.5 | 12.0 -> 13.3 | 19.3 / 24.9 s -> 18.6 / 20.7 s | 0.009 -> 0.010 s | push 9/9 stored; land 9/9; recall 1/2 offers skipped_local 1 |
| recall_16_fill (fill) | 16 / 16 (0/0) | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 | 22919 -> 22852 | 2.6 -> 2.6 | 9.9 -> 9.8 | 23.9 / 24.1 s -> 24.0 / 24.1 s | 0.010 -> 0.009 s | push 6/9 stored; land 6/6; recall 0/4 offers |
| recall_16_ret (recall) | 16 / 16 (0/0) | 0.0% -> 64.9% | 2.23M / 0.00M -> 0.14M / 1.53M | 1,531,904 tok in 11 pulls + 1,408 SWA | 22230 -> 56723 | 2.4 -> 6.1 | 9.0 -> 23.1 | 26.1 / 26.1 s -> 8.0 / 19.7 s | 0.010 -> 0.010 s | push 12/12 stored; land 12/12; recall 11/12 offers |
| static_4 | 12 / 12 (0/0) | 62.7% -> 62.7% | 1.05M / 0.00M -> 1.05M / 0.00M | 0 | 51369 -> 51056 | 94.2 -> 93.7 | 22.1 -> 21.9 | 7.2 / 16.3 s -> 6.5 / 18.8 s | 0.009 -> 0.009 s | push 2/2 stored |
| static_8 | 24 / 24 (0/0) | 62.3% -> 55.6% | 1.85M / 0.25M -> 1.86M / 0.00M | 0 | 52414 -> 45568 | 96.2 -> 83.6 | 22.5 -> 19.6 | 6.4 / 18.9 s -> 9.5 / 18.7 s | 0.009 -> 0.009 s | none |
| static_12 | 36 / 36 (0/0) | 50.4% -> 32.2% | 1.80M / 1.34M -> 2.43M / 0.00M | 0 | 42076 -> 32246 | 77.2 -> 59.2 | 18.1 -> 13.9 | 7.2 / 22.0 s -> 15.1 / 22.1 s | 0.009 -> 0.009 s | push 16/16 stored; land 16/16 |
| static_16 | 48 / 48 (0/0) | 39.8% -> 27.1% | 3.09M / 1.10M -> 3.73M / 0.00M | 0 | 35744 -> 30296 | 65.6 -> 55.6 | 15.4 -> 13.0 | 12.1 / 21.7 s -> 15.8 / 21.9 s | 0.009 -> 0.009 s | push 35/35 stored; land 35/35 |
| mixed_long | 24 / 24 (0/0) | 21.9% -> 39.7% | 0.91M / 1.18M -> 1.89M / 0.00M | 1,585,152 tok in 43 pulls + 5,504 SWA | 25182 -> 22846 | 46.2 -> 41.9 | 10.8 -> 9.8 | 21.0 / 26.6 s -> 20.9 / 26.5 s | 0.010 -> 0.010 s | push 93/93 stored; land 93/93; recall 43/43 offers |
| mixed_short | 96 / 96 (0/0) | 21.9% -> 39.7% | 1.22M / 0.00M -> 0.00M / 1.59M | 1,585,152 tok in 43 pulls + 5,504 SWA | 19277 -> 22807 | 7.9 -> 9.4 | 29.6 -> 35.1 | 9.2 / 26.8 s -> 5.3 / 26.7 s | 0.010 -> 0.011 s | push 93/93 stored; land 93/93; recall 43/43 offers |

integrity on: 2026-11-11 00:32:18 integrity rc=0 SUMMARY {"sessions": 16, "prefix": 131072, "new": 8192, "out_tokens": 64, "concurrent_phase_s": 244.6, "probes": {"sent": 91, "exact": 75, "min_agree": 7, "errors": 0, "mismatch_positions": [7, 7, 16, 16, 16, 34, 34, 49, 49, 49, 84, 84, 84, 96, 96, 96]}, "errors": 0, "recall": {"compared": 16, "exact": 12, "min_agree": 5, "pulled_sessions": 15}}

integrity off: 2026-11-11 00:50:44 integrity rc=0 SUMMARY {"sessions": 16, "prefix": 131072, "new": 8192, "out_tokens": 64, "concurrent_phase_s": 320.1, "probes": {"sent": 96, "exact": 80, "min_agree": 7, "errors": 0, "mismatch_positions": [7, 7, 16, 16, 20, 21, 34, 34, 49, 49, 84, 84, 84, 96, 96, 96]}, "errors": 0, "recall": {"compared": 16, "exact": 16, "min_agree": 64, "pulled_sessions": 16}}

### final counters, on arm
- decode-0: ranks 8, warnings 0, errors 0, refused lines 0; landing received=204 granted=204 landed=204 landed_tokens=11889024
- prefill-0: ranks 8, warnings 0, errors 96, refused lines 0; push started=204 stored=204; recall offers=150 pulls=71 pulled_tokens=5271232 pulled_swa_tokens=9088 skipped_local_host=78 over_budget=1

### final counters, off arm
- decode-0: ranks 0, warnings 0, errors 0, refused lines 0; 
- prefill-0: ranks 0, warnings 0, errors 0, refused lines 0; 

route_ok false on: none
