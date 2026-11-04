2026-11-04 11:04:32 arm E: client exit 0; summary: {"summary": {"label": "E", "duration_s": 3600, "sessions": 20, "start_local": "2026-11-04 10:04:14", "requests": 5775, "errors": 0, "worker_crashes": [], "requests_per_s
2026-11-04 11:04:42 arm E: server stopped; exceptions in server log: 0
| Arm | Requests | Errors | Req/s | Hit % | Device / host / new % | Mean sampled decode tok/s | Main p50 / p90 / p99 s | Eviction s (TP0) |
|---|---|---|---|---|---|---|---|---|
| A | 5486 | 0 | 1.524 | 67.5 | 2.8 / 64.8 / 32.5 | 386 | 30.02 / 44.66 / 53.99 | 23 |
| B | 5172 | 0 | 1.437 | 71.8 | 2.7 / 69.1 / 28.2 | 372 | 33.15 / 46.72 / 57.81 | 1886 |
| E | 5775 | 0 | 1.604 | 69.8 | 2.9 / 66.9 / 30.2 | 318 | 27.9 / 42.88 / 56.04 | 848 |

| Minutes | A | B | E |
|---|---|---|---|
| 0-10 | 68.0 | 69.5 | 70.0 |
| 10-20 | 72.8 | 75.7 | 76.4 |
| 20-30 | 65.9 | 72.6 | 67.0 |
| 30-40 | 64.6 | 76.0 | 65.1 |
| 40-50 | 66.8 | 66.3 | 72.0 |
| 50-60 | 65.7 | 69.3 | 65.8 |
