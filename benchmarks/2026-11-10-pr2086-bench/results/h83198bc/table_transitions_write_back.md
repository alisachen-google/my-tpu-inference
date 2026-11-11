**Performance gain** (what a user of the pair sees; return rows are the requests whose prefix the previous turn produced).

| Point | TTFT p50 off -> on | Speedup | TTFT p95 off -> on | Speedup | E2E p50 off -> on | Wall s off -> on | Gain | Req/min off -> on | Gain | Warm returns off -> on | Prefill tokens computed per request, off -> on |
|---|---|---|---|---|---|---|---|---|---|---|---|
| T1_p0d0_fill (fill) | 23.7 -> 23.7 s | 1.0x | 24.1 -> 24.0 s | 1.0x | 23.9 -> 23.8 s | 74.2 -> 74.3 | -0% | 9.7 -> 9.7 | +0% | 0 / 12 -> 0 / 12 | 139,298 -> 139,298 |
| T1_p0d0_ka (fill) | 7.9 -> 7.8 s | 1.0x | 8.0 -> 7.9 s | 1.0x | 8.1 -> 8.0 s | 25.4 -> 25.2 | +1% | 56.7 -> 57.1 | +1% | 1 / 24 -> 1 / 24 | 36,898 -> 36,898 |
| T1_p0d0_ret (recall) | 26.2 -> 8.9 s | 3.0x | 26.2 -> 9.5 s | 2.8x | 26.3 -> 9.0 s | 80.4 -> 22.7 | +72% | 9.0 -> 31.7 | +254% | 0 / 12 -> 4 / 12 | 147,577 -> 32,228 |
| T2_p1d0_fill (fill) | 23.7 -> 23.7 s | 1.0x | 24.0 -> 24.0 s | 1.0x | 23.9 -> 23.8 s | 73.0 -> 72.8 | +0% | 9.9 -> 9.9 | +0% | 0 / 12 -> 0 / 12 | 139,298 -> 139,298 |
| T2_p1d0_ka (fill) | 7.9 -> 7.8 s | 1.0x | 8.0 -> 8.1 s | 1.0x | 8.0 -> 8.0 s | 25.4 -> 25.2 | +1% | 56.7 -> 57.1 | +1% | 1 / 24 -> 1 / 24 | 36,898 -> 36,898 |
| T2_p1d0_ret (recall) | 25.8 -> 8.9 s | 2.9x | 26.1 -> 13.6 s | 1.9x | 26.0 -> 9.0 s | 80.7 -> 33.5 | +58% | 8.9 -> 21.5 | +141% | 0 / 12 -> 5 / 12 | 147,577 -> 55,438 |
| T3_p0d1_fill (fill) | 23.7 -> 23.7 s | 1.0x | 24.0 -> 24.0 s | 1.0x | 23.9 -> 23.8 s | 72.9 -> 72.8 | +0% | 9.9 -> 9.9 | +0% | 0 / 12 -> 0 / 12 | 139,298 -> 139,298 |
| T3_p0d1_ka (fill) | 7.9 -> 7.8 s | 1.0x | 8.0 -> 7.9 s | 1.0x | 8.1 -> 8.0 s | 25.3 -> 25.2 | +0% | 57.0 -> 57.1 | +0% | 1 / 24 -> 1 / 24 | 36,898 -> 36,898 |
| T3_p0d1_ret (recall) | 26.1 -> 23.5 s | 1.1x | 26.2 -> 25.5 s | 1.0x | 26.2 -> 23.6 s | 80.3 -> 74.3 | +7% | 9.0 -> 9.7 | +8% | 0 / 12 -> 0 / 12 | 147,577 -> 131,273 |
| T4_p1d1_fill (fill) | 23.7 -> 23.7 s | 1.0x | 24.1 -> 24.0 s | 1.0x | 23.9 -> 23.8 s | 72.9 -> 72.9 | +0% | 9.9 -> 9.9 | -0% | 0 / 12 -> 0 / 12 | 139,298 -> 139,298 |
| T4_p1d1_ka (fill) | 7.9 -> 7.8 s | 1.0x | 8.0 -> 7.9 s | 1.0x | 8.1 -> 8.0 s | 25.3 -> 25.2 | +0% | 57.0 -> 57.1 | +0% | 1 / 24 -> 1 / 24 | 36,898 -> 36,898 |
| T4_p1d1_ret (recall) | 25.9 -> 25.8 s | 1.0x | 26.1 -> 26.1 s | 1.0x | 26.0 -> 26.0 s | 79.3 -> 79.4 | -0% | 9.1 -> 9.1 | -0% | 0 / 12 -> 0 / 12 | 147,577 -> 147,577 |
| chain_fill (fill) | 23.7 -> 23.7 s | 1.0x | 24.0 -> 24.0 s | 1.0x | 23.9 -> 23.9 s | 72.8 -> 72.9 | -0% | 9.9 -> 9.9 | -0% | 0 / 12 -> 0 / 12 | 139,298 -> 139,298 |
| chain_ka (fill) | 7.9 -> 7.8 s | 1.0x | 8.0 -> 7.9 s | 1.0x | 8.1 -> 8.0 s | 25.3 -> 25.2 | +0% | 56.9 -> 57.2 | +0% | 1 / 24 -> 1 / 24 | 36,898 -> 36,898 |
| chain_l1_p0d0 (recall) | 26.1 -> 8.4 s | 3.1x | 26.3 -> 9.9 s | 2.7x | 26.2 -> 8.5 s | 79.9 -> 22.9 | +71% | 9.0 -> 31.4 | +248% | 0 / 12 -> 5 / 12 | 147,577 -> 33,614 |
| chain_l2_p1d0 (recall) | 25.8 -> 8.2 s | 3.1x | 26.2 -> 9.0 s | 2.9x | 26.0 -> 8.9 s | 79.3 -> 29.1 | +63% | 9.1 -> 24.8 | +173% | 0 / 12 -> 0 / 12 | 147,577 -> 43,140 |
| chain_l3_p0d1 (recall) | 23.4 -> 20.3 s | 1.1x | 23.8 -> 26.5 s | 0.9x | 23.5 -> 20.5 s | 66.6 -> 61.7 | +7% | 10.8 -> 11.7 | +8% | 1 / 12 -> 0 / 12 | 114,356 -> 111,385 |
| chain_l4_p1d1 (recall) | 20.2 -> 14.4 s | 1.4x | 23.6 -> 23.2 s | 1.0x | 20.3 -> 14.5 s | 61.6 -> 48.6 | +21% | 11.7 -> 14.8 | +27% | 1 / 12 -> 1 / 12 | 106,713 -> 82,094 |
| random_fill (fill) | 11.7 -> 11.7 s | 1.0x | 17.7 -> 17.6 s | 1.0x | 11.8 -> 11.9 s | 54.9 -> 49.9 | +9% | 17.5 -> 19.2 | +10% | 0 / 16 -> 0 / 16 | 139,298 -> 139,298 |
| random_ret (recall) | 7.8 -> 7.4 s | 1.1x | 13.3 -> 13.6 s | 1.0x | 8.1 -> 7.6 s | 37.8 -> 37.3 | +1% | 25.4 -> 25.7 | +1% | 5 / 16 -> 4 / 16 | 69,241 -> 77,945 |

**Cache (mechanism)**: prefill-side hit, client-reported cached tokens, where the prefix was found, and what the on arm recalled from decode DRAM.

| Point | Requests on / off (errors) | Prefill-side hit off -> on | Gain | Client-reported hit off -> on | Cached by tier device / host, off -> on | Recalled from decode DRAM (on) |
|---|---|---|---|---|---|---|
| T1_p0d0_fill (fill) | 12 / 12 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| T1_p0d0_ka (fill) | 24 / 24 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| T1_p0d0_ret (recall) | 12 / 12 (0/0) | 0.0% -> 78.2% | +78.2 pp | 94.4% -> 93.9% | 1.67M / 0.00M -> 0.28M / 1.38M | 1,523,456 tok in 11 pulls + 1,408 SWA |
| T2_p1d0_fill (fill) | 12 / 12 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| T2_p1d0_ka (fill) | 24 / 24 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| T2_p1d0_ret (recall) | 12 / 12 (0/0) | 0.0% -> 62.4% | +62.4 pp | 94.4% -> 70.3% | 1.67M / 0.00M -> 0.14M / 1.11M | 1,105,664 tok in 8 pulls + 1,024 SWA |
| T3_p0d1_fill (fill) | 12 / 12 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| T3_p0d1_ka (fill) | 24 / 24 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| T3_p0d1_ret (recall) | 12 / 12 (0/0) | 0.0% -> 11.1% | +11.1 pp | 0.0% -> 11.1% | 0 / 0 -> 0.00M / 0.20M | 0 |
| T4_p1d1_fill (fill) | 12 / 12 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| T4_p1d1_ka (fill) | 24 / 24 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| T4_p1d1_ret (recall) | 12 / 12 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| chain_fill (fill) | 12 / 12 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| chain_ka (fill) | 24 / 24 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| chain_l1_p0d0 (recall) | 12 / 12 (0/0) | 0.0% -> 77.2% | +77.2 pp | 94.4% -> 85.1% | 1.67M / 0.00M -> 0.14M / 1.37M | 1,785,408 tok in 13 pulls + 1,664 SWA |
| chain_l2_p1d0 (recall) | 12 / 12 (0/0) | 0.0% -> 70.8% | +70.8 pp | 99.9% -> 86.5% | 1.77M / 0.00M -> 0.28M / 1.25M | 1,253,248 tok in 9 pulls + 1,152 SWA |
| chain_l3_p0d1 (recall) | 12 / 12 (0/0) | 22.5% -> 24.5% | +2.0 pp | 22.5% -> 24.5% | 0.00M / 0.40M -> 0.00M / 0.43M | 900,928 tok in 7 pulls + 896 SWA |
| chain_l4_p1d1 (recall) | 12 / 12 (0/0) | 27.7% -> 44.4% | +16.7 pp | 99.9% -> 44.4% | 1.28M / 0.49M -> 0.02M / 0.77M | 466,368 tok in 4 pulls + 512 SWA |
| random_fill (fill) | 16 / 16 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| random_ret (recall) | 16 / 16 (0/0) | 53.1% -> 47.2% | -5.9 pp | 82.6% -> 47.2% | 0.91M / 1.04M -> 0.29M / 0.83M | 139,264 tok in 1 pulls + 128 SWA |

**Throughput** (gain = on vs off, higher is better).

| Point | Total tok/s off | on | Gain | Output tok/s off | on | Gain | Req/min off | on | Gain |
|---|---|---|---|---|---|---|---|---|---|
| T1_p0d0_fill (fill) | 22520 | 22513 | -0% | 2.6 | 2.6 | +0% | 9.7 | 9.7 | +0% |
| T1_p0d0_ka (fill) | 34903 | 35118 | +1% | 15.1 | 15.2 | +1% | 56.7 | 57.1 | +1% |
| T1_p0d0_ret (recall) | 22035 | 78034 | +254% | 2.4 | 8.5 | +254% | 9.0 | 31.7 | +254% |
| T2_p1d0_fill (fill) | 22908 | 22954 | +0% | 2.6 | 2.6 | +0% | 9.9 | 9.9 | +0% |
| T2_p1d0_ka (fill) | 34888 | 35113 | +1% | 15.1 | 15.2 | +1% | 56.7 | 57.1 | +1% |
| T2_p1d0_ret (recall) | 21943 | 52852 | +141% | 2.4 | 5.7 | +138% | 8.9 | 21.5 | +141% |
| T3_p0d1_fill (fill) | 22921 | 22960 | +0% | 2.6 | 2.6 | +0% | 9.9 | 9.9 | +0% |
| T3_p0d1_ka (fill) | 35039 | 35139 | +0% | 15.2 | 15.2 | +0% | 57.0 | 57.1 | +0% |
| T3_p0d1_ret (recall) | 22064 | 23830 | +8% | 2.4 | 2.6 | +8% | 9.0 | 9.7 | +8% |
| T4_p1d1_fill (fill) | 22944 | 22917 | -0% | 2.6 | 2.6 | +0% | 9.9 | 9.9 | -0% |
| T4_p1d1_ka (fill) | 35037 | 35159 | +0% | 15.2 | 15.2 | +0% | 57.0 | 57.1 | +0% |
| T4_p1d1_ret (recall) | 22343 | 22310 | -0% | 2.4 | 2.4 | +0% | 9.1 | 9.1 | -0% |
| chain_fill (fill) | 22971 | 22941 | -0% | 2.6 | 2.6 | +0% | 9.9 | 9.9 | -0% |
| chain_ka (fill) | 35034 | 35194 | +0% | 15.2 | 15.3 | +1% | 56.9 | 57.2 | +0% |
| chain_l1_p0d0 (recall) | 22165 | 77186 | +248% | 2.4 | 8.4 | +250% | 9.0 | 31.4 | +248% |
| chain_l2_p1d0 (recall) | 22326 | 60921 | +173% | 2.4 | 6.6 | +175% | 9.1 | 24.8 | +173% |
| chain_l3_p0d1 (recall) | 26613 | 28716 | +8% | 2.9 | 3.1 | +7% | 10.8 | 11.7 | +8% |
| chain_l4_p1d1 (recall) | 28761 | 36442 | +27% | 3.1 | 4.0 | +29% | 11.7 | 14.8 | +27% |
| random_fill (fill) | 40582 | 44661 | +10% | 4.7 | 5.1 | +9% | 17.5 | 19.2 | +10% |
| random_ret (recall) | 62396 | 63249 | +1% | 6.8 | 6.9 | +1% | 25.4 | 25.7 | +1% |

**Latency** (gain = reduction on vs off, positive means the on arm is faster).

| Point | TTFT p50 off | on | Gain | TTFT p95 off | on | Gain | ITL p50 off | on | Gain |
|---|---|---|---|---|---|---|---|---|---|
| T1_p0d0_fill (fill) | 23.7 s | 23.7 s | +0% | 24.1 s | 24.0 s | +0% | 0.010 s | 0.010 s | +1% |
| T1_p0d0_ka (fill) | 7.9 s | 7.8 s | +1% | 8.0 s | 7.9 s | +1% | 0.010 s | 0.012 s | -23% |
| T1_p0d0_ret (recall) | 26.2 s | 8.9 s | +66% | 26.2 s | 9.5 s | +64% | 0.010 s | 0.012 s | -27% |
| T2_p1d0_fill (fill) | 23.7 s | 23.7 s | +0% | 24.0 s | 24.0 s | -0% | 0.010 s | 0.009 s | +2% |
| T2_p1d0_ka (fill) | 7.9 s | 7.8 s | +1% | 8.0 s | 8.1 s | -1% | 0.010 s | 0.014 s | -41% |
| T2_p1d0_ret (recall) | 25.8 s | 8.9 s | +66% | 26.1 s | 13.6 s | +48% | 0.009 s | 0.011 s | -21% |
| T3_p0d1_fill (fill) | 23.7 s | 23.7 s | +0% | 24.0 s | 24.0 s | -0% | 0.009 s | 0.010 s | -3% |
| T3_p0d1_ka (fill) | 7.9 s | 7.8 s | +2% | 8.0 s | 7.9 s | +1% | 0.009 s | 0.014 s | -52% |
| T3_p0d1_ret (recall) | 26.1 s | 23.5 s | +10% | 26.2 s | 25.5 s | +2% | 0.010 s | 0.010 s | +0% |
| T4_p1d1_fill (fill) | 23.7 s | 23.7 s | +0% | 24.1 s | 24.0 s | +0% | 0.010 s | 0.010 s | +0% |
| T4_p1d1_ka (fill) | 7.9 s | 7.8 s | +2% | 8.0 s | 7.9 s | +1% | 0.010 s | 0.013 s | -26% |
| T4_p1d1_ret (recall) | 25.9 s | 25.8 s | +0% | 26.1 s | 26.1 s | +0% | 0.010 s | 0.010 s | +1% |
| chain_fill (fill) | 23.7 s | 23.7 s | +0% | 24.0 s | 24.0 s | -0% | 0.009 s | 0.010 s | -8% |
| chain_ka (fill) | 7.9 s | 7.8 s | +2% | 8.0 s | 7.9 s | +1% | 0.010 s | 0.015 s | -58% |
| chain_l1_p0d0 (recall) | 26.1 s | 8.4 s | +68% | 26.3 s | 9.9 s | +62% | 0.010 s | 0.011 s | -13% |
| chain_l2_p1d0 (recall) | 25.8 s | 8.2 s | +68% | 26.2 s | 9.0 s | +66% | 0.010 s | 0.012 s | -22% |
| chain_l3_p0d1 (recall) | 23.4 s | 20.3 s | +13% | 23.8 s | 26.5 s | -11% | 0.010 s | 0.010 s | +4% |
| chain_l4_p1d1 (recall) | 20.2 s | 14.4 s | +29% | 23.6 s | 23.2 s | +2% | 0.010 s | 0.010 s | -2% |
| random_fill (fill) | 11.7 s | 11.7 s | -0% | 17.7 s | 17.6 s | +0% | 0.009 s | 0.009 s | -1% |
| random_ret (recall) | 7.8 s | 7.4 s | +6% | 13.3 s | 13.6 s | -3% | 0.009 s | 0.011 s | -15% |

**Offload counters on the on arm, per point** (TP0 deltas from the server logs; every push and landing is a 128k-session branch with its SWA window).

| Point | Pushes stored / started | Landings landed / received | Recalls pulls / offers | Pulled tokens | SWA tokens | Failed / refused / no room |
|---|---|---|---|---|---|---|
| T1_p0d0_fill (fill) | 0 / 0 | 39 / 42 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| T1_p0d0_ka (fill) | 75 / 75 | 36 / 33 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| T1_p0d0_ret (recall) | 40 / 36 | 28 / 28 | 11 / 12 | 1,523,456 | 1,408 | 0 / 0 / 0 |
| T2_p1d0_fill (fill) | 35 / 37 | 10 / 14 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| T2_p1d0_ka (fill) | 35 / 33 | 60 / 56 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| T2_p1d0_ret (recall) | 3 / 3 | 3 / 3 | 8 / 9 | 1,105,664 | 1,024 | 0 / 0 / 0 |
| T3_p0d1_fill (fill) | 0 / 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| T3_p0d1_ka (fill) | 77 / 77 | 26 / 23 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| T3_p0d1_ret (recall) | 175 / 175 | 175 / 175 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| T4_p1d1_fill (fill) | 0 / 0 | 45 / 48 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| T4_p1d1_ka (fill) | 79 / 79 | 34 / 31 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| T4_p1d1_ret (recall) | 2 / 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| chain_fill (fill) | 0 / 0 | 20 / 24 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| chain_ka (fill) | 21 / 18 | 56 / 52 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| chain_l1_p0d0 (recall) | 25 / 25 | 25 / 25 | 13 / 15 | 1,785,408 | 1,664 | 0 / 0 / 0 |
| chain_l2_p1d0 (recall) | 2 / 2 | 12 / 12 | 9 / 11 | 1,253,248 | 1,152 | 0 / 0 / 0 |
| chain_l3_p0d1 (recall) | 33 / 35 | 31 / 31 | 7 / 11 | 900,928 | 896 | 0 / 0 / 0 |
| chain_l4_p1d1 (recall) | 17 / 16 | 31 / 29 | 4 / 4 | 466,368 | 512 | 0 / 0 / 0 |
| random_fill (fill) | 0 / 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| random_ret (recall) | 28 / 28 | 28 / 28 | 1 / 1 | 139,264 | 128 | 0 / 0 / 0 |

### final counters, on arm
- decode-0: ranks 8, warnings 0, errors 0, refused lines 0; landing received=634 granted=634 landed=634 landed_tokens=9956992
- decode-1: ranks 8, warnings 0, errors 0, refused lines 0; landing received=47 granted=47 landed=47 landed_tokens=1860032
- prefill-0: ranks 8, warnings 0, errors 112, refused lines 0; push started=656 stored=656; recall offers=23 pulls=21 pulled_tokens=2882816 pulled_swa_tokens=2688 over_budget=2
- prefill-1: ranks 8, warnings 0, errors 32, refused lines 0; push started=25 stored=25; recall offers=25 pulls=22 pulled_tokens=2964544 pulled_swa_tokens=2816 over_budget=3

### final counters, off arm
- decode-0: ranks 0, warnings 0, errors 0, refused lines 0; 
- decode-1: ranks 0, warnings 0, errors 0, refused lines 0; 
- prefill-0: ranks 0, warnings 0, errors 0, refused lines 0; 
- prefill-1: ranks 0, warnings 0, errors 0, refused lines 0; 

route_ok false on: none
**Routing and recall per point** (expected pair from the brief; served = requests per engine on the on arm; recalled = tokens the on arm's prefills pulled from decode DRAM during the point).

| Point | Expected pair | route_ok off / on | Served (on) | Prefill-side hit off -> on | TTFT p50 off -> on | Speedup | Wall s off -> on | Recalled from decode DRAM (on) |
|---|---|---|---|---|---|---|---|---|
| T1_p0d0_fill (fill) | p0d0 | True / True | d0:12 p0:12 | 0.0% -> 0.0% | 23.7 -> 23.7 s | 1.0x | 74.2 -> 74.3 | 0 |
| T1_p0d0_ka (fill) | any | None / None | d0:24 p0:24 | 0.0% -> 0.0% | 7.9 -> 7.8 s | 1.0x | 25.4 -> 25.2 | 0 |
| T1_p0d0_ret (recall) | p0d0 | True / True | d0:12 p0:12 | 0.0% -> 78.2% | 26.2 -> 8.9 s | 3.0x | 80.4 -> 22.7 | 1,523,456 tok in 11 pulls + 1,408 SWA |
| T2_p1d0_fill (fill) | p0d0 | True / True | d0:12 p0:12 | 0.0% -> 0.0% | 23.7 -> 23.7 s | 1.0x | 73.0 -> 72.8 | 0 |
| T2_p1d0_ka (fill) | any | None / None | d0:24 p0:24 | 0.0% -> 0.0% | 7.9 -> 7.8 s | 1.0x | 25.4 -> 25.2 | 0 |
| T2_p1d0_ret (recall) | p1d0 | True / True | d0:12 p1:12 | 0.0% -> 62.4% | 25.8 -> 8.9 s | 2.9x | 80.7 -> 33.5 | 1,105,664 tok in 8 pulls + 1,024 SWA |
| T3_p0d1_fill (fill) | p0d0 | True / True | d0:12 p0:12 | 0.0% -> 0.0% | 23.7 -> 23.7 s | 1.0x | 72.9 -> 72.8 | 0 |
| T3_p0d1_ka (fill) | any | None / None | d0:24 p0:24 | 0.0% -> 0.0% | 7.9 -> 7.8 s | 1.0x | 25.3 -> 25.2 | 0 |
| T3_p0d1_ret (recall) | p0d1 | True / True | d1:12 p0:12 | 0.0% -> 11.1% | 26.1 -> 23.5 s | 1.1x | 80.3 -> 74.3 | 0 |
| T4_p1d1_fill (fill) | p0d0 | True / True | d0:12 p0:12 | 0.0% -> 0.0% | 23.7 -> 23.7 s | 1.0x | 72.9 -> 72.9 | 0 |
| T4_p1d1_ka (fill) | any | None / None | d0:24 p0:24 | 0.0% -> 0.0% | 7.9 -> 7.8 s | 1.0x | 25.3 -> 25.2 | 0 |
| T4_p1d1_ret (recall) | p1d1 | True / True | d1:12 p1:12 | 0.0% -> 0.0% | 25.9 -> 25.8 s | 1.0x | 79.3 -> 79.4 | 0 |
| chain_fill (fill) | p0d0 | True / True | d0:12 p0:12 | 0.0% -> 0.0% | 23.7 -> 23.7 s | 1.0x | 72.8 -> 72.9 | 0 |
| chain_ka (fill) | any | None / None | d0:24 p0:24 | 0.0% -> 0.0% | 7.9 -> 7.8 s | 1.0x | 25.3 -> 25.2 | 0 |
| chain_l1_p0d0 (recall) | p0d0 | True / True | d0:12 p0:12 | 0.0% -> 77.2% | 26.1 -> 8.4 s | 3.1x | 79.9 -> 22.9 | 1,785,408 tok in 13 pulls + 1,664 SWA |
| chain_l2_p1d0 (recall) | p1d0 | True / True | d0:12 p1:12 | 0.0% -> 70.8% | 25.8 -> 8.2 s | 3.1x | 79.3 -> 29.1 | 1,253,248 tok in 9 pulls + 1,152 SWA |
| chain_l3_p0d1 (recall) | p0d1 | True / True | d1:12 p0:12 | 22.5% -> 24.5% | 23.4 -> 20.3 s | 1.1x | 66.6 -> 61.7 | 900,928 tok in 7 pulls + 896 SWA |
| chain_l4_p1d1 (recall) | p1d1 | True / True | d1:12 p1:12 | 27.7% -> 44.4% | 20.2 -> 14.4 s | 1.4x | 61.6 -> 48.6 | 466,368 tok in 4 pulls + 512 SWA |
| random_fill (fill) | any | None / None | d0:9 d1:7 p0:8 p1:8 | 0.0% -> 0.0% | 11.7 -> 11.7 s | 1.0x | 54.9 -> 49.9 | 0 |
| random_ret (recall) | any | None / None | d0:5 d1:11 p0:9 p1:7 | 53.1% -> 47.2% | 7.8 -> 7.4 s | 1.1x | 37.8 -> 37.3 | 139,264 tok in 1 pulls + 128 SWA |
