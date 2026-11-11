**Performance gain** (what a user of the pair sees; return rows are the requests whose prefix the previous turn produced).

| Point | TTFT p50 off -> on | Speedup | TTFT p95 off -> on | Speedup | E2E p50 off -> on | Wall s off -> on | Gain | Req/min off -> on | Gain | Warm returns off -> on | Prefill tokens computed per request, off -> on |
|---|---|---|---|---|---|---|---|---|---|---|---|
| T1_p0d0_fill (fill) | 23.7 -> 23.8 s | 1.0x | 24.0 -> 24.1 s | 1.0x | 23.8 -> 23.9 s | 73.9 -> 74.5 | -1% | 9.8 -> 9.7 | -1% | 0 / 12 -> 0 / 12 | 139,298 -> 139,298 |
| T1_p0d0_ka (fill) | 8.0 -> 7.9 s | 1.0x | 8.0 -> 8.0 s | 1.0x | 8.1 -> 8.0 s | 25.2 -> 25.3 | -0% | 57.1 -> 56.9 | -0% | 1 / 24 -> 0 / 24 | 36,898 -> 36,898 |
| T1_p0d0_ret (recall) | 26.2 -> 8.4 s | 3.1x | 26.3 -> 10.7 s | 2.5x | 26.3 -> 8.6 s | 79.9 -> 23.5 | +71% | 9.0 -> 30.6 | +240% | 0 / 12 -> 4 / 12 | 147,577 -> 31,524 |
| T2_p1d0_fill (fill) | 23.7 -> 23.8 s | 1.0x | 24.1 -> 24.1 s | 1.0x | 23.9 -> 23.9 s | 72.6 -> 73.0 | -1% | 9.9 -> 9.9 | -1% | 0 / 12 -> 0 / 12 | 139,298 -> 139,298 |
| T2_p1d0_ka (fill) | 8.0 -> 7.9 s | 1.0x | 8.1 -> 8.1 s | 1.0x | 8.1 -> 8.1 s | 25.2 -> 25.4 | -1% | 57.1 -> 56.6 | -1% | 1 / 24 -> 1 / 24 | 36,898 -> 36,898 |
| T2_p1d0_ret (recall) | 25.8 -> 10.5 s | 2.5x | 26.1 -> 14.0 s | 1.9x | 25.9 -> 10.6 s | 80.3 -> 34.9 | +57% | 9.0 -> 20.6 | +130% | 0 / 12 -> 1 / 12 | 147,577 -> 54,734 |
| T3_p0d1_fill (fill) | 23.7 -> 23.7 s | 1.0x | 24.0 -> 24.0 s | 1.0x | 23.8 -> 23.8 s | 72.6 -> 73.0 | -1% | 9.9 -> 9.9 | -1% | 0 / 12 -> 0 / 12 | 139,298 -> 139,298 |
| T3_p0d1_ka (fill) | 8.0 -> 8.0 s | 1.0x | 8.0 -> 8.1 s | 1.0x | 8.1 -> 8.1 s | 25.2 -> 25.4 | -1% | 57.1 -> 56.7 | -1% | 1 / 24 -> 1 / 24 | 36,898 -> 36,898 |
| T3_p0d1_ret (recall) | 26.1 -> 26.1 s | 1.0x | 26.2 -> 26.2 s | 1.0x | 26.3 -> 26.2 s | 79.8 -> 80.0 | -0% | 9.0 -> 9.0 | -0% | 0 / 12 -> 0 / 12 | 147,577 -> 147,577 |
| T4_p1d1_fill (fill) | 23.7 -> 23.8 s | 1.0x | 24.0 -> 24.1 s | 1.0x | 23.9 -> 23.9 s | 72.5 -> 73.0 | -1% | 9.9 -> 9.9 | -1% | 0 / 12 -> 0 / 12 | 139,298 -> 139,298 |
| T4_p1d1_ka (fill) | 8.0 -> 8.0 s | 1.0x | 8.0 -> 8.0 s | 1.0x | 8.1 -> 8.1 s | 25.2 -> 25.4 | -1% | 57.1 -> 56.7 | -1% | 1 / 24 -> 1 / 24 | 36,898 -> 36,898 |
| T4_p1d1_ret (recall) | 25.9 -> 25.9 s | 1.0x | 26.1 -> 26.3 s | 1.0x | 26.0 -> 26.1 s | 79.0 -> 79.5 | -1% | 9.1 -> 9.1 | -1% | 0 / 12 -> 0 / 12 | 147,577 -> 147,577 |
| chain_fill (fill) | 23.7 -> 23.7 s | 1.0x | 24.1 -> 24.2 s | 1.0x | 23.9 -> 23.9 s | 72.6 -> 72.9 | -0% | 9.9 -> 9.9 | -1% | 0 / 12 -> 0 / 12 | 139,298 -> 139,298 |
| chain_ka (fill) | 8.0 -> 8.0 s | 1.0x | 8.0 -> 8.2 s | 1.0x | 8.1 -> 8.2 s | 25.3 -> 25.5 | -1% | 57.0 -> 56.4 | -1% | 1 / 24 -> 1 / 24 | 36,898 -> 36,898 |
| chain_l1_p0d0 (recall) | 26.0 -> 8.5 s | 3.1x | 26.2 -> 8.9 s | 3.0x | 26.2 -> 8.7 s | 79.7 -> 21.7 | +73% | 9.0 -> 33.1 | +267% | 0 / 12 -> 4 / 12 | 147,577 -> 31,524 |
| chain_l2_p1d0 (recall) | 25.9 -> 7.6 s | 3.4x | 26.2 -> 8.1 s | 3.3x | 26.1 -> 7.7 s | 79.0 -> 20.6 | +74% | 9.1 -> 35.0 | +284% | 0 / 12 -> 4 / 12 | 147,577 -> 29,460 |
| chain_l3_p0d1 (recall) | 19.9 -> 19.8 s | 1.0x | 25.3 -> 26.6 s | 1.0x | 20.1 -> 19.9 s | 59.6 -> 60.6 | -2% | 12.1 -> 11.9 | -2% | 2 / 12 -> 0 / 12 | 105,230 -> 110,702 |
| chain_l4_p1d1 (recall) | 20.4 -> 13.7 s | 1.5x | 25.8 -> 14.5 s | 1.8x | 20.5 -> 13.9 s | 59.4 -> 50.0 | +16% | 12.1 -> 14.4 | +19% | 2 / 12 -> 0 / 12 | 105,316 -> 88,164 |
| random_fill (fill) | 12.3 -> 17.5 s | 0.7x | 18.5 -> 23.6 s | 0.8x | 12.4 -> 17.6 s | 61.1 -> 67.0 | -10% | 15.7 -> 14.3 | -9% | 0 / 16 -> 0 / 16 | 139,298 -> 139,298 |
| random_ret (recall) | 7.7 -> 7.3 s | 1.1x | 19.8 -> 13.3 s | 1.5x | 7.9 -> 7.5 s | 43.2 -> 31.5 | +27% | 22.2 -> 30.5 | +37% | 4 / 16 -> 6 / 16 | 77,945 -> 69,241 |

**Cache (mechanism)**: prefill-side hit, client-reported cached tokens, where the prefix was found, and what the on arm recalled from decode DRAM.

| Point | Requests on / off (errors) | Prefill-side hit off -> on | Gain | Client-reported hit off -> on | Cached by tier device / host, off -> on | Recalled from decode DRAM (on) |
|---|---|---|---|---|---|---|
| T1_p0d0_fill (fill) | 12 / 12 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| T1_p0d0_ka (fill) | 24 / 24 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| T1_p0d0_ret (recall) | 12 / 12 (0/0) | 0.0% -> 78.6% | +78.6 pp | 94.4% -> 86.5% | 1.67M / 0.00M -> 0.14M / 1.39M | 1,392,640 tok in 10 pulls + 1,280 SWA |
| T2_p1d0_fill (fill) | 12 / 12 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| T2_p1d0_ka (fill) | 24 / 24 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| T2_p1d0_ret (recall) | 12 / 12 (0/0) | 0.0% -> 62.9% | +62.9 pp | 94.4% -> 70.8% | 1.67M / 0.00M -> 0.14M / 1.11M | 1,114,112 tok in 8 pulls + 1,024 SWA |
| T3_p0d1_fill (fill) | 12 / 12 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| T3_p0d1_ka (fill) | 24 / 24 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| T3_p0d1_ret (recall) | 12 / 12 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| T4_p1d1_fill (fill) | 12 / 12 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| T4_p1d1_ka (fill) | 24 / 24 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| T4_p1d1_ret (recall) | 12 / 12 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| chain_fill (fill) | 12 / 12 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| chain_ka (fill) | 24 / 24 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| chain_l1_p0d0 (recall) | 12 / 12 (0/0) | 0.0% -> 78.6% | +78.6 pp | 94.4% -> 86.5% | 1.67M / 0.00M -> 0.14M / 1.39M | 1,392,640 tok in 10 pulls + 1,280 SWA |
| chain_l2_p1d0 (recall) | 12 / 12 (0/0) | 0.0% -> 80.0% | +80.0 pp | 99.9% -> 88.4% | 1.77M / 0.00M -> 0.15M / 1.42M | 2,392,256 tok in 17 pulls + 2,176 SWA |
| chain_l3_p0d1 (recall) | 12 / 12 (0/0) | 28.7% -> 25.0% | -3.7 pp | 28.7% -> 25.0% | 0.00M / 0.51M -> 0.01M / 0.43M | 417,792 tok in 3 pulls + 384 SWA |
| chain_l4_p1d1 (recall) | 12 / 12 (0/0) | 28.6% -> 40.3% | +11.6 pp | 99.9% -> 40.3% | 1.26M / 0.51M -> 0.12M / 0.59M | 590,080 tok in 4 pulls + 512 SWA |
| random_fill (fill) | 16 / 16 (0/0) | 0.0% -> 0.0% | +0.0 pp | 0.0% -> 0.0% | 0 / 0 -> 0 / 0 | 0 |
| random_ret (recall) | 16 / 16 (0/0) | 47.2% -> 53.1% | +5.9 pp | 76.7% -> 53.1% | 0.96M / 0.85M -> 0.26M / 0.99M | 417,792 tok in 3 pulls + 384 SWA |

**Throughput** (gain = on vs off, higher is better).

| Point | Total tok/s off | on | Gain | Output tok/s off | on | Gain | Req/min off | on | Gain |
|---|---|---|---|---|---|---|---|---|---|
| T1_p0d0_fill (fill) | 22633 | 22440 | -1% | 2.6 | 2.6 | +0% | 9.8 | 9.7 | -1% |
| T1_p0d0_ka (fill) | 35110 | 34977 | -0% | 15.2 | 15.2 | +0% | 57.1 | 56.9 | -0% |
| T1_p0d0_ret (recall) | 22170 | 75386 | +240% | 2.4 | 8.2 | +242% | 9.0 | 30.6 | +240% |
| T2_p1d0_fill (fill) | 23043 | 22892 | -1% | 2.6 | 2.6 | +0% | 9.9 | 9.9 | -1% |
| T2_p1d0_ka (fill) | 35144 | 34811 | -1% | 15.2 | 15.1 | -1% | 57.1 | 56.6 | -1% |
| T2_p1d0_ret (recall) | 22058 | 50776 | +130% | 2.4 | 5.5 | +129% | 9.0 | 20.6 | +130% |
| T3_p0d1_fill (fill) | 23034 | 22912 | -1% | 2.6 | 2.6 | +0% | 9.9 | 9.9 | -1% |
| T3_p0d1_ka (fill) | 35160 | 34893 | -1% | 15.2 | 15.1 | -1% | 57.1 | 56.7 | -1% |
| T3_p0d1_ret (recall) | 22183 | 22126 | -0% | 2.4 | 2.4 | +0% | 9.0 | 9.0 | -0% |
| T4_p1d1_fill (fill) | 23045 | 22897 | -1% | 2.6 | 2.6 | +0% | 9.9 | 9.9 | -1% |
| T4_p1d1_ka (fill) | 35156 | 34893 | -1% | 15.2 | 15.1 | -1% | 57.1 | 56.7 | -1% |
| T4_p1d1_ret (recall) | 22411 | 22277 | -1% | 2.4 | 2.4 | +0% | 9.1 | 9.1 | -1% |
| chain_fill (fill) | 23036 | 22927 | -0% | 2.6 | 2.6 | +0% | 9.9 | 9.9 | -1% |
| chain_ka (fill) | 35079 | 34715 | -1% | 15.2 | 15.0 | -1% | 57.0 | 56.4 | -1% |
| chain_l1_p0d0 (recall) | 22220 | 81496 | +267% | 2.4 | 8.8 | +267% | 9.0 | 33.1 | +267% |
| chain_l2_p1d0 (recall) | 22419 | 85961 | +283% | 2.4 | 9.3 | +288% | 9.1 | 35.0 | +284% |
| chain_l3_p0d1 (recall) | 29738 | 29239 | -2% | 3.2 | 3.2 | +0% | 12.1 | 11.9 | -2% |
| chain_l4_p1d1 (recall) | 29833 | 35430 | +19% | 3.2 | 3.8 | +19% | 12.1 | 14.4 | +19% |
| random_fill (fill) | 36489 | 33290 | -9% | 4.2 | 3.8 | -10% | 15.7 | 14.3 | -9% |
| random_ret (recall) | 54656 | 75009 | +37% | 5.9 | 8.1 | +37% | 22.2 | 30.5 | +37% |

**Latency** (gain = reduction on vs off, positive means the on arm is faster).

| Point | TTFT p50 off | on | Gain | TTFT p95 off | on | Gain | ITL p50 off | on | Gain |
|---|---|---|---|---|---|---|---|---|---|
| T1_p0d0_fill (fill) | 23.7 s | 23.8 s | -0% | 24.0 s | 24.1 s | -0% | 0.009 s | 0.010 s | -3% |
| T1_p0d0_ka (fill) | 8.0 s | 7.9 s | +1% | 8.0 s | 8.0 s | +0% | 0.010 s | 0.010 s | +0% |
| T1_p0d0_ret (recall) | 26.2 s | 8.4 s | +68% | 26.3 s | 10.7 s | +59% | 0.010 s | 0.011 s | -7% |
| T2_p1d0_fill (fill) | 23.7 s | 23.8 s | -0% | 24.1 s | 24.1 s | -0% | 0.010 s | 0.009 s | +6% |
| T2_p1d0_ka (fill) | 8.0 s | 7.9 s | +0% | 8.1 s | 8.1 s | -0% | 0.010 s | 0.010 s | -1% |
| T2_p1d0_ret (recall) | 25.8 s | 10.5 s | +59% | 26.1 s | 14.0 s | +46% | 0.010 s | 0.010 s | +2% |
| T3_p0d1_fill (fill) | 23.7 s | 23.7 s | -0% | 24.0 s | 24.0 s | +0% | 0.010 s | 0.009 s | +3% |
| T3_p0d1_ka (fill) | 8.0 s | 8.0 s | -0% | 8.0 s | 8.1 s | -1% | 0.010 s | 0.010 s | +4% |
| T3_p0d1_ret (recall) | 26.1 s | 26.1 s | +0% | 26.2 s | 26.2 s | -0% | 0.010 s | 0.009 s | +4% |
| T4_p1d1_fill (fill) | 23.7 s | 23.8 s | -0% | 24.0 s | 24.1 s | -0% | 0.010 s | 0.009 s | +2% |
| T4_p1d1_ka (fill) | 8.0 s | 8.0 s | -0% | 8.0 s | 8.0 s | -0% | 0.010 s | 0.009 s | +5% |
| T4_p1d1_ret (recall) | 25.9 s | 25.9 s | -0% | 26.1 s | 26.3 s | -1% | 0.009 s | 0.009 s | -1% |
| chain_fill (fill) | 23.7 s | 23.7 s | -0% | 24.1 s | 24.2 s | -0% | 0.010 s | 0.010 s | +2% |
| chain_ka (fill) | 8.0 s | 8.0 s | -1% | 8.0 s | 8.2 s | -3% | 0.010 s | 0.009 s | +9% |
| chain_l1_p0d0 (recall) | 26.0 s | 8.5 s | +68% | 26.2 s | 8.9 s | +66% | 0.010 s | 0.011 s | -17% |
| chain_l2_p1d0 (recall) | 25.9 s | 7.6 s | +71% | 26.2 s | 8.1 s | +69% | 0.010 s | 0.012 s | -27% |
| chain_l3_p0d1 (recall) | 19.9 s | 19.8 s | +1% | 25.3 s | 26.6 s | -5% | 0.010 s | 0.010 s | +1% |
| chain_l4_p1d1 (recall) | 20.4 s | 13.7 s | +33% | 25.8 s | 14.5 s | +44% | 0.009 s | 0.014 s | -48% |
| random_fill (fill) | 12.3 s | 17.5 s | -42% | 18.5 s | 23.6 s | -28% | 0.010 s | 0.009 s | +2% |
| random_ret (recall) | 7.7 s | 7.3 s | +5% | 19.8 s | 13.3 s | +33% | 0.010 s | 0.010 s | +4% |

**Offload counters on the on arm, per point** (TP0 deltas from the server logs; every push and landing is a 128k-session branch with its SWA window).

| Point | Pushes stored / started | Landings landed / received | Recalls pulls / offers | Pulled tokens | SWA tokens | Failed / refused / no room |
|---|---|---|---|---|---|---|
| T1_p0d0_fill (fill) | 0 / 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| T1_p0d0_ka (fill) | 12 / 12 | 12 / 12 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| T1_p0d0_ret (recall) | 15 / 15 | 16 / 16 | 10 / 11 | 1,392,640 | 1,280 | 0 / 0 / 0 |
| T2_p1d0_fill (fill) | 0 / 0 | 2 / 4 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| T2_p1d0_ka (fill) | 11 / 11 | 9 / 7 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| T2_p1d0_ret (recall) | 5 / 5 | 5 / 5 | 8 / 9 | 1,114,112 | 1,024 | 0 / 0 / 0 |
| T3_p0d1_fill (fill) | 0 / 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| T3_p0d1_ka (fill) | 12 / 12 | 12 / 12 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| T3_p0d1_ret (recall) | 30 / 30 | 28 / 28 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| T4_p1d1_fill (fill) | 2 / 4 | 4 / 4 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| T4_p1d1_ka (fill) | 9 / 7 | 7 / 7 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| T4_p1d1_ret (recall) | 0 / 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| chain_fill (fill) | 5 / 5 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| chain_ka (fill) | 7 / 7 | 12 / 12 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| chain_l1_p0d0 (recall) | 18 / 18 | 18 / 18 | 10 / 11 | 1,392,640 | 1,280 | 0 / 0 / 0 |
| chain_l2_p1d0 (recall) | 21 / 20 | 13 / 12 | 17 / 18 | 2,392,256 | 2,176 | 0 / 0 / 0 |
| chain_l3_p0d1 (recall) | 12 / 11 | 10 / 10 | 3 / 1 | 417,792 | 384 | 0 / 0 / 0 |
| chain_l4_p1d1 (recall) | 8 / 8 | 5 / 5 | 4 / 4 | 590,080 | 512 | 0 / 0 / 0 |
| random_fill (fill) | 0 / 0 | 0 / 0 | 0 / 0 | 0 | 0 | 0 / 0 / 0 |
| random_ret (recall) | 13 / 13 | 13 / 13 | 3 / 4 | 417,792 | 384 | 0 / 0 / 0 |

### final counters, on arm
- decode-0: ranks 8, warnings 0, errors 0, refused lines 0; landing received=138 granted=138 landed=138 landed_tokens=10196160
- decode-1: ranks 8, warnings 0, errors 0, refused lines 0; landing received=16 granted=16 landed=16 landed_tokens=2048768
- prefill-0: ranks 8, warnings 0, errors 24, refused lines 0; push started=133 stored=133; recall offers=25 pulls=23 pulled_tokens=3203072 pulled_swa_tokens=2944 over_budget=2
- prefill-1: ranks 8, warnings 0, errors 16, refused lines 0; push started=21 stored=21; recall offers=25 pulls=22 pulled_tokens=3121600 pulled_swa_tokens=2816 skipped_local_host=1 over_budget=2

### final counters, off arm
- decode-0: ranks 0, warnings 0, errors 0, refused lines 0; 
- decode-1: ranks 0, warnings 0, errors 0, refused lines 0; 
- prefill-0: ranks 0, warnings 0, errors 0, refused lines 0; 
- prefill-1: ranks 0, warnings 0, errors 0, refused lines 0; 

route_ok false on: none

**Routing and recall per point** (expected pair from the brief; served = requests per engine on the on arm; recalled = tokens the on arm's prefills pulled from decode DRAM during the point).

| Point | Expected pair | route_ok off / on | Served (on) | Prefill-side hit off -> on | TTFT p50 off -> on | Speedup | Wall s off -> on | Recalled from decode DRAM (on) |
|---|---|---|---|---|---|---|---|---|
| T1_p0d0_fill (fill) | p0d0 | True / True | d0:12 p0:12 | 0.0% -> 0.0% | 23.7 -> 23.8 s | 1.0x | 73.9 -> 74.5 | 0 |
| T1_p0d0_ka (fill) | any | None / None | d0:24 p0:24 | 0.0% -> 0.0% | 8.0 -> 7.9 s | 1.0x | 25.2 -> 25.3 | 0 |
| T1_p0d0_ret (recall) | p0d0 | True / True | d0:12 p0:12 | 0.0% -> 78.6% | 26.2 -> 8.4 s | 3.1x | 79.9 -> 23.5 | 1,392,640 tok in 10 pulls + 1,280 SWA |
| T2_p1d0_fill (fill) | p0d0 | True / True | d0:12 p0:12 | 0.0% -> 0.0% | 23.7 -> 23.8 s | 1.0x | 72.6 -> 73.0 | 0 |
| T2_p1d0_ka (fill) | any | None / None | d0:24 p0:24 | 0.0% -> 0.0% | 8.0 -> 7.9 s | 1.0x | 25.2 -> 25.4 | 0 |
| T2_p1d0_ret (recall) | p1d0 | True / True | d0:12 p1:12 | 0.0% -> 62.9% | 25.8 -> 10.5 s | 2.5x | 80.3 -> 34.9 | 1,114,112 tok in 8 pulls + 1,024 SWA |
| T3_p0d1_fill (fill) | p0d0 | True / True | d0:12 p0:12 | 0.0% -> 0.0% | 23.7 -> 23.7 s | 1.0x | 72.6 -> 73.0 | 0 |
| T3_p0d1_ka (fill) | any | None / None | d0:24 p0:24 | 0.0% -> 0.0% | 8.0 -> 8.0 s | 1.0x | 25.2 -> 25.4 | 0 |
| T3_p0d1_ret (recall) | p0d1 | True / True | d1:12 p0:12 | 0.0% -> 0.0% | 26.1 -> 26.1 s | 1.0x | 79.8 -> 80.0 | 0 |
| T4_p1d1_fill (fill) | p0d0 | True / True | d0:12 p0:12 | 0.0% -> 0.0% | 23.7 -> 23.8 s | 1.0x | 72.5 -> 73.0 | 0 |
| T4_p1d1_ka (fill) | any | None / None | d0:24 p0:24 | 0.0% -> 0.0% | 8.0 -> 8.0 s | 1.0x | 25.2 -> 25.4 | 0 |
| T4_p1d1_ret (recall) | p1d1 | True / True | d1:12 p1:12 | 0.0% -> 0.0% | 25.9 -> 25.9 s | 1.0x | 79.0 -> 79.5 | 0 |
| chain_fill (fill) | p0d0 | True / True | d0:12 p0:12 | 0.0% -> 0.0% | 23.7 -> 23.7 s | 1.0x | 72.6 -> 72.9 | 0 |
| chain_ka (fill) | any | None / None | d0:24 p0:24 | 0.0% -> 0.0% | 8.0 -> 8.0 s | 1.0x | 25.3 -> 25.5 | 0 |
| chain_l1_p0d0 (recall) | p0d0 | True / True | d0:12 p0:12 | 0.0% -> 78.6% | 26.0 -> 8.5 s | 3.1x | 79.7 -> 21.7 | 1,392,640 tok in 10 pulls + 1,280 SWA |
| chain_l2_p1d0 (recall) | p1d0 | True / True | d0:12 p1:12 | 0.0% -> 80.0% | 25.9 -> 7.6 s | 3.4x | 79.0 -> 20.6 | 2,392,256 tok in 17 pulls + 2,176 SWA |
| chain_l3_p0d1 (recall) | p0d1 | True / True | d1:12 p0:12 | 28.7% -> 25.0% | 19.9 -> 19.8 s | 1.0x | 59.6 -> 60.6 | 417,792 tok in 3 pulls + 384 SWA |
| chain_l4_p1d1 (recall) | p1d1 | True / True | d1:12 p1:12 | 28.6% -> 40.3% | 20.4 -> 13.7 s | 1.5x | 59.4 -> 50.0 | 590,080 tok in 4 pulls + 512 SWA |
| random_fill (fill) | any | None / None | d0:9 d1:7 p0:5 p1:11 | 0.0% -> 0.0% | 12.3 -> 17.5 s | 0.7x | 61.1 -> 67.0 | 0 |
| random_ret (recall) | any | None / None | d0:7 d1:9 p0:9 p1:7 | 47.2% -> 53.1% | 7.7 -> 7.3 s | 1.1x | 43.2 -> 31.5 | 417,792 tok in 3 pulls + 384 SWA |
