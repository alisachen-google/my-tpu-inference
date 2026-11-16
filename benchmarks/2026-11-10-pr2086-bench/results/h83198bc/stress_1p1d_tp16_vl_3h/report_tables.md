**Verdict 1P1D TP16 Qwen3-VL-8B, 3 h:** FAIL; reasons: ["cycle 1: server or router down at concurrency 72: health: ['http://j-cee50ceb-f5ed-44f4-80f9-prefill-0-0.j-cee50ceb-f5ed-44f4-80f9:30000 ReadTimeout after 30 s'] (3 probes in a row)", "cycle 2: server or router down at concurrency 72: health: ['http://j-cee50ceb-f5ed-44f4-80f9-prefill-0-0.j-cee50ceb-f5ed-44f4-80f9:30000 ReadTimeout after 30 s'] (3 probes in a row)"]; duration 11240 s, cycles 3, last good concurrency per cycle [48, 48, 32], ramp ended at [72, 72, 48] (["health: ['http://j-cee50ceb-f5ed-44f4-80f9-prefill-0-0.j-cee50ceb-f5ed-44f4-80f9:30000 ReadTimeout after 30 s'] (3 probes in a row)", "health: ['http://j-cee50ceb-f5ed-44f4-80f9-prefill-0-0.j-cee50ceb-f5ed-44f4-80f9:30000 ReadTimeout after 30 s'] (3 probes in a row)", 'error rate 0.109']); GSM8K baseline 0.96 on 100.

Slow health probes (an engine took more than 30 s to answer /health, recovered): 15; slowest successful answer per endpoint: {'prefill-0': 30.09, 'decode-0': 30.04}.

**Ramp** (one row per level; a level holds its concurrency for the step time; hit = client-reported cached share; GSM8K = inline questions correct).

| Cycle | Level | Concurrency | Requests | Errors | Hangs | TTFT p50 s | TTFT p95 s | E2E p95 s | Hit | GSM8K | Max prompt tokens | Max images | Aborts | Engines running / queued at level end | Peak RSS GB per pod | Outcome |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 1 | 2 | 33 | 0 | 0 | 8.9 | 27.3 | 36.7 | 21.7% | 0.75 (4) | 133,882 | 59 | 0 | prefill-0 0/0, decode-0 0/0 | decode-0-h0 468, decode-0-h1 477, prefill-0-h0 433, prefill-0-h1 445 | pass |
| 1 | 2 | 3 | 36 | 0 | 0 | 10.8 | 42.8 | 59.8 | 7.2% | 1.00 (4) | 261,120 | 63 | 2 | prefill-0 0/0, decode-0 0/0 | decode-0-h0 469, decode-0-h1 511, prefill-0-h0 434, prefill-0-h1 468 | pass |
| 1 | 3 | 4 | 58 | 0 | 0 | 11.9 | 46.7 | 54.2 | 14.9% | 1.00 (5) | 261,120 | 58 | 3 | prefill-0 0/0, decode-0 0/0 | decode-0-h0 473, decode-0-h1 512, prefill-0-h0 439, prefill-0-h1 476 | pass |
| 1 | 4 | 6 | 40 | 0 | 0 | 31.9 | 62.5 | 83.1 | 5.9% | 1.00 (2) | 261,120 | 63 | 0 | prefill-0 0/0, decode-0 0/0 | decode-0-h0 475, decode-0-h1 484, prefill-0-h0 438, prefill-0-h1 446 | pass |
| 1 | 5 | 9 | 61 | 0 | 0 | 44.6 | 69.2 | 90.4 | 3.5% | 1.00 (4) | 261,120 | 64 | 1 | prefill-0 0/0, decode-0 0/0 | decode-0-h0 479, decode-0-h1 541, prefill-0-h0 442, prefill-0-h1 489 | pass |
| 1 | 6 | 14 | 63 | 0 | 0 | 58.5 | 112.9 | 127.5 | 8.0% | 1.00 (2) | 261,120 | 64 | 0 | prefill-0 0/0, decode-0 0/0 | decode-0-h0 488, decode-0-h1 549, prefill-0-h0 451, prefill-0-h1 484 | pass |
| 1 | 7 | 21 | 65 | 0 | 0 | 62.9 | 123.3 | 179.3 | 4.6% | 1.00 (4) | 261,120 | 63 | 2 | prefill-0 0/0, decode-0 0/0 | decode-0-h0 488, decode-0-h1 589, prefill-0-h0 450, prefill-0-h1 527 | pass |
| 1 | 8 | 32 | 80 | 0 | 0 | 120.9 | 160.2 | 207.4 | 2.1% | 1.00 (6) | 261,120 | 64 | 1 | prefill-0 0/0, decode-0 0/0 | decode-0-h0 505, decode-0-h1 606, prefill-0-h0 459, prefill-0-h1 536 | pass |
| 1 | 9 | 48 | 87 | 2 | 0 | 217.7 | 287.2 | 374.3 | 0.0% | 0.91 (11) | 261,120 | 64 | 3 | prefill-0 1/0, decode-0 0/0 | decode-0-h0 510, decode-0-h1 729, prefill-0-h0 473, prefill-0-h1 627 | pass |
| 1 | 10 | 72 | 43 | 0 | 0 | 336.5 | 373.8 | 395.6 | 0.3% | 1.00 (8) | 261,120 | 59 | 3 | prefill-0 1/2, decode-0 6/0 | decode-0-h0 502, decode-0-h1 640, prefill-0-h0 472, prefill-0-h1 607 | FAIL: health: ['http://j-cee50ceb-f5ed-44f4-80f9-prefill-0-0.j-cee50ceb-f5ed-44f4-80f9:30000 ReadTimeout after 30 s'] (3 |
| 2 | 1 | 2 | 32 | 0 | 0 | 7.3 | 39.4 | 42.7 | 0.0% | 0.00 (1) | 261,120 | 49 | 0 | prefill-0 0/0, decode-0 0/0 | decode-0-h0 514, decode-0-h1 521, prefill-0-h0 486, prefill-0-h1 482 | pass |
| 2 | 2 | 3 | 51 | 0 | 0 | 8.4 | 32.2 | 42.6 | 0.4% | 1.00 (5) | 261,120 | 56 | 4 | prefill-0 0/0, decode-0 0/0 | decode-0-h0 513, decode-0-h1 538, prefill-0-h0 486, prefill-0-h1 501 | pass |
| 2 | 3 | 4 | 38 | 0 | 0 | 24.8 | 55.4 | 58.0 | 0.0% | 1.00 (2) | 261,120 | 62 | 2 | prefill-0 0/0, decode-0 0/0 | decode-0-h0 513, decode-0-h1 533, prefill-0-h0 486, prefill-0-h1 482 | pass |
| 2 | 4 | 6 | 55 | 0 | 0 | 17.7 | 61.3 | 68.4 | 0.3% | 1.00 (3) | 261,120 | 64 | 1 | prefill-0 0/0, decode-0 0/0 | decode-0-h0 513, decode-0-h1 564, prefill-0-h0 486, prefill-0-h1 532 | pass |
| 2 | 5 | 9 | 69 | 0 | 0 | 31.5 | 51.9 | 65.1 | 4.1% | 1.00 (4) | 261,120 | 58 | 0 | prefill-0 0/0, decode-0 0/0 |  | pass |
| 2 | 6 | 14 | 68 | 0 | 0 | 61.0 | 104.2 | 117.9 | 2.4% | 0.86 (7) | 261,120 | 61 | 2 | prefill-0 0/0, decode-0 0/0 |  | pass |
| 2 | 7 | 21 | 72 | 0 | 0 | 78.4 | 136.9 | 154.9 | 2.5% | 0.57 (7) | 261,120 | 61 | 6 | prefill-0 0/0, decode-0 0/0 |  | pass |
| 2 | 8 | 32 | 90 | 0 | 0 | 121.9 | 155.2 | 198.3 | 7.0% | 1.00 (5) | 261,120 | 61 | 3 | prefill-0 0/0, decode-0 0/0 |  | pass |
| 2 | 9 | 48 | 88 | 1 | 0 | 183.6 | 285.7 | 327.3 | 0.0% | 1.00 (9) | 261,120 | 64 | 3 | prefill-0 0/0, decode-0 0/0 |  | pass |
| 2 | 10 | 72 | 72 | 0 | 0 | 284.0 | 328.6 | 339.9 | 0.0% | 1.00 (6) | 261,120 | 60 | 3 | prefill-0 0/0, decode-0 0/0 |  | FAIL: health: ['http://j-cee50ceb-f5ed-44f4-80f9-prefill-0-0.j-cee50ceb-f5ed-44f4-80f9:30000 ReadTimeout after 30 s'] (3 |
| 3 | 1 | 2 | 46 | 0 | 0 | 6.4 | 28.4 | 30.5 | 3.6% | 1.00 (3) | 261,120 | 64 | 2 | prefill-0 0/0, decode-0 0/0 |  | pass |
| 3 | 2 | 3 | 34 | 0 | 0 | 17.1 | 53.2 | 54.8 | 2.0% | 0.00 (1) | 261,120 | 62 | 2 | prefill-0 0/0, decode-0 0/0 |  | pass |
| 3 | 3 | 4 | 56 | 0 | 0 | 14.3 | 42.0 | 54.7 | 9.5% | 1.00 (4) | 261,120 | 52 | 4 | prefill-0 0/0, decode-0 0/0 |  | pass |
| 3 | 4 | 6 | 50 | 0 | 0 | 24.3 | 55.1 | 69.0 | 6.9% | 1.00 (10) | 261,120 | 59 | 2 | prefill-0 0/0, decode-0 0/0 |  | pass |
| 3 | 5 | 9 | 56 | 0 | 0 | 37.5 | 99.2 | 110.1 | 6.7% | 1.00 (3) | 261,120 | 64 | 4 | prefill-0 0/0, decode-0 0/0 |  | pass |
| 3 | 6 | 14 | 71 | 0 | 0 | 55.7 | 77.8 | 102.8 | 2.7% | 1.00 (7) | 261,120 | 56 | 1 | prefill-0 0/0, decode-0 0/0 |  | pass |
| 3 | 7 | 21 | 71 | 0 | 0 | 83.5 | 120.5 | 146.0 | 0.0% | 1.00 (4) | 261,120 | 64 | 3 | prefill-0 0/0, decode-0 0/0 |  | pass |
| 3 | 8 | 32 | 71 | 0 | 0 | 113.8 | 179.3 | 259.9 | 1.1% | 1.00 (2) | 261,120 | 60 | 1 | prefill-0 0/0, decode-0 0/0 |  | pass |
| 3 | 9 | 48 | 55 | 6 | 0 | 245.0 | 459.1 | 472.1 | 9.0% | 1.00 (10) | 261,120 | 64 | 2 | prefill-0 1/6, decode-0 2/0 |  | FAIL: error rate 0.109 |

**Drain and verification per cycle** (after the ramp stops: in-flight requests finish, every engine idle, a verification batch, the GSM8K gate against the idle baseline, then a flush and the leak check).

| Cycle | Ramp ended at | Why | Drain s | Idle after drain | Verification batch ok / sent | Batch TTFT p50 s | GSM8K acc (baseline) | Predictions changed | Token usage after flush | Bootstrap failures | Verdict |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 72 | health: ['http://j-cee50ceb-f5ed-44f4-80f9-prefill-0-0.j-cee50ceb-f5ed-44f4-80f9:30000 Rea | 76.0 | True  | 24 / 24 | 26.2 | 0.95 (0.96) | 3 of 100 | {'prefill-0': 0, 'decode-0': 0} | {'prefill-0': 0, 'decode-0': 0} | PASS |
| 2 | 72 | health: ['http://j-cee50ceb-f5ed-44f4-80f9-prefill-0-0.j-cee50ceb-f5ed-44f4-80f9:30000 Rea | 0.0 | True  | 24 / 24 | 31.5 | 0.96 (0.96) | 2 of 100 | {'prefill-0': 0, 'decode-0': 0} | {'prefill-0': 0, 'decode-0': 0} | PASS |
| 3 | 48 | error rate 0.109 | 60.0 | True  | 24 / 24 | 43.2 | 0.97 (0.96) | 2 of 100 | {'prefill-0': 0, 'decode-0': 0} | {'prefill-0': 0, 'decode-0': 0} | PASS |

**Requests:** 1841 sent, 1832 ok, 9 failed, 0 hangs; kinds {'gsm8k': 151, 'image': 660, 'text': 502, 'return': 528}; buckets {'gsm8k': 151, 'short': 473, 'medium': 278, 'long': 238, 'return': 528, 'xlong': 173}; 819 requests with images (max 64), max prompt 261,120 tokens, max output 2045 tokens, 528 session returns, 62 client aborts.

| Bucket | Requests | TTFT p50 s | TTFT p95 s |
|---|---|---|---|
| short | 473 | 49.5 | 284.0 |
| medium | 278 | 58.1 | 316.7 |
| long | 236 | 57.3 | 325.0 |
| xlong | 170 | 69.5 | 391.0 |
| return | 524 | 65.2 | 320.7 |
| gsm8k | 151 | 49.5 | 270.4 |

Failed requests by level and reason: L9 return: 1 x short output 0 of 612; L9 image: 1 x short output 0 of 124; L9 return: 1 x short output 0 of 447; L9 return: 1 x short output 0 of 221; L9 text: 1 x short output 0 of 253; L9 image: 1 x short output 0 of 75; L9 image: 1 x short output 0 of 1404; L9 return: 1 x short output 0 of 656
