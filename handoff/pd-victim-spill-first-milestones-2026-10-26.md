# Victim prefix cache: spill-first milestones

Written 2026-10-26. Prepared against published SGLang head
`ae2a96dd8dba1c899e0cbbc49b327df007489dcf`, parent
`49ddede7e806a5db9b2b276bf0df26beb0a1f1e9`.

The owner requested the review order **spill → preserve SWA → recall**.
The earlier recall-first sequence followed implementation dependencies. To
make each new milestone runnable, its intermediate implementation separates
host export progress from reverse-prefix reads. The final code is unchanged:
both series end at Git tree `2785915a112002cc9a8574d5cd951c8330f10b92`.

| Milestone | Prepared commit | Behavior |
|---|---|---|
| 1 | `e221f179cf03896e21b20bf8289ef381eda79e7f` | Direct Prefill DRAM → Decode DRAM FULL-only victim storage; native completion ownership, rank agreement, independent empty/paused cleanup. Hybrid configurations are rejected. |
| 2 | `bbc4b298e12be849427f4f2d5254451abe376013` | Add SWA host pools and path-end backup; send, receive and publish FULL KV plus its matching ending SWA window, retaining both allocations through partial failure. |
| 3 | `9d9c2d89e0e5a1009de44d383892efb0b035e5fc` | Add prefix OFFER/PULL/READY, host-to-HBM offer restoration and Prefill recall. Extend the earlier host-export lifecycle with the recall controller. |

These hashes are prepared locally; GitHub publication must be verified after
an authenticated push. The original published series remains in local backup
ref `backup/pd-victim-prefix-cache-before-spill-first-ae2a96dd`.

Milestones 1 and 2 gate their standalone export coordinator on the victim
switch. Milestone 3 restores the final documented configuration requiring both
victim and prefix-recall switches. It also adds the recall-specific restore
hooks and their existing tests together; no earlier milestone imports them.

The new regression
[`test_spill_first_lifecycle.py`](../tests/pd_victim_review/test_spill_first_lifecycle.py)
instantiates the real controller and drives real empty/paused Prefill queue
callbacks over CPU radix-cache fixtures. It verifies source pins survive ACK
until native completion and cleanup returns idle without another request or
export. This test passed on the standalone M1/M2 controllers and the final
inherited controller. It lives only in this research repository.

Validation: M2 passed 71 existing tests and 42 subtests. The final selected CPU
suite passed 401 existing tests and 195 subtests. M1 passed its FULL-only victim,
host API, Raiden and scheduler paths after moving an existing queue fixture's
lifecycle initialization with its production hook. No new SGLang test cases,
benchmarks or performance claims were added. No new live TPU run was performed.
The reviewed native socket-timeout limitation is unchanged.

The [saved design website](https://pd-victim-cache-design-20261026.groovyteal9.chatgpt.site)
describes the same final implementation; historical reviewed commit links there
remain references to the same final code tree. Local recovery patches, the
verified bundle, and detailed validation status are in
`~/pd_disagg/results/pd-victim-spill-first/`.
