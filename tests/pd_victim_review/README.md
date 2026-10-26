# Host spillover review probes

Written 2026-10-26 against SGLang `6c60fd77b79f` and native tpu-sync
`759530c7fb0a`. Corrected local SGLang revision:
`f2d8c3e58ea6a47a89ead8f9f4a4a81a1eab629d`. These probes live here at the owner's request; they are not part
of the SGLang feature commit. They do not launch or access TPU model servers.

## Shared Prefill/Decode host-stack construction

`test_shared_swa_host_stack.py` checks Prefill equivalence with the upstream
hybrid builder, fixed/ratio sizing, Decode window budgeting, packed draft
mapping, unified allocation callbacks, independent allocations, failed-build
policy state and registry selection. It exercises real pool groups and mappings
over mocked host-buffer/native-controller boundaries.

Run the related unit suites plus these seven extra checks with:

```bash
python tests/pd_victim_review/run_shared_swa_host_stack_units.py \
  --sglang-root /path/to/sglang-victim-simplified \
  --junit-xml /path/to/local-results/unit-tests.xml
```

The runner disables TPU autoload, preserves the plugin-discovery tests, and
registers an import-only compiler guard that fails if invoked. The validated
run passed 371 tests and 259 subtests with zero TPU compiler calls and no
`torch_tpu` import. No benchmark or model workload is run.

## Spill-first milestone lifecycle

`test_spill_first_lifecycle.py` constructs the actual victim controller over a
real CPU FULL cache, then drives its empty bootstrap and paused cleanup hooks.
It checks that a host export starts without recall, keeps its source pinned
through acknowledgement, and releases ownership only after native completion.
Select each intermediate checkout with `SGLANG_REVIEW_ROOT` and `PYTHONPATH` to
check the spill-first milestones as well as the final inherited controller.

## Idle completion cleanup

`test_host_spill_cleanup.py` executes the real `DecodeReceiver.step` with an
external control-message inbox and no accepted native reads. A refused victim
has no landing, but Prefill still sends a failure DONE after its native source
registration expires. The original `step` skipped `_finish_agreed` when no
landings existed, so those DONE messages accumulated without bound.

The regression supplies 100 such notices and checks that one scheduled polling
round drains them. A second case checks that a DONE remains available while its
corresponding offer is waiting for admission.

```bash
export SGLANG_REVIEW_ROOT=/path/to/sglang-torchtpu
SGLANG_PLUGINS=none TORCH_DEVICE_BACKEND_AUTOLOAD=0 \
  PYTHONPATH="$SGLANG_REVIEW_ROOT/python:$SGLANG_REVIEW_ROOT" \
  python tests/pd_victim_review/test_host_spill_cleanup.py
```

Observed before the fix: the orphan-notice test failed with all 100 entries
retained. After making `_finish_agreed` run on every agreement round, both
cleanup tests and the existing 26 SGLang victim lifecycle tests passed.

## Host exports participate in idle and paused cleanup

The same private test file also has two cases using real `PrefillPusher`, radix
cache and allocator logic over the external transport boundary fixture. A
pending host export originally remained invisible to the inherited reverse-read
idle query. A flush could enter tree reset, block in the host-export drain, and
raise after its drain budget rather than returning a busy result.

`VictimPrefixPuller` now includes its globally tracked host exports in the pure
pending-ownership query. Its synchronized deferred-release resolver retires
existing exports during empty and paused control ticks without starting new
victims. The test verifies the source stays non-idle until native completion,
then releases its host pin without waiting for another request. Both new cases
pass, for four passing host-spill review tests in this file.

## Rank-consistent reverse-recall allocation

`test_collective_recall_cleanup.py` uses a real two-rank Gloo group and real
CPU radix-cache/allocator fixtures. An abandoned reverse read completes on rank
0 while rank 1 still owns its destination pages. The next allocation originally
computed its eviction shortfall locally: rank 0 retained a 64-token cached
prefix while rank 1 evicted it. That reproduced a divergent cache tree before
any future distributed cache operation; a later operation assuming identical
trees could hang or make inconsistent decisions.

The fix agrees on reserve fit, takes the maximum FULL and SWA shortfall before
cache eviction, and agrees on allocation success with rollback for partial
failure. Physical cleanup may finish at different times on each rank, while
tree-changing decisions use the same values. The real two-rank regression now
passes. It does not establish TPU lowering or hardware correctness.

## Reverse recall idle and reset ownership

`test_recall_idle_reset.py` has four passing cases using the real Scheduler
idle/flush methods and real recall manager/puller with external CPU boundary
fixtures. An aborted last request may leave native reads writing its reserved
destination pages after the visible request queues become empty. Previously,
empty bootstrap ticks stopped harvesting those completions and idle/reset
accounting ignored the destinations.

The fix keeps a rank-consistent, sticky external-read ownership flag. The idle
query only reads that flag; synchronized normal and paused queue ticks poll
native completion, reap local reservations, and agree before clearing ownership
on all ranks. `release_all` refuses to release pending native write targets.
The cases cover the last abort, flush refusal, empty bootstrap progress, and
paused control progress followed by a successful flush.

The separate memory-release RPC retains its existing fully-idle precondition.
Pausing generation alone does not drain external writers: callers must wait
for native ownership to clear before releasing model/KV memory. This is an
existing operator contract, separate from the flush guard fixed in this review.

## Native session deadline versus blocking socket I/O

`probe_native_socket_deadline.py` uses a benchmark-only CPU binding around the
unmodified native core. It creates a producer and its own spawned consumer,
starts a 128 MiB host transfer, and pauses only that child after the first block
arrives. It resumes and drains the child in `finally`.

```bash
python tests/pd_victim_review/probe_native_socket_deadline.py \
  --native-module-dir /path/to/tpu-sync/bazel-bin/tpu_sync/frameworks/torch
```

Observed with the default native socket settings:

- Logical session timeout: 0.2 seconds.
- Producer still had no terminal report after the consumer remained paused for
  1 second. The source pin therefore remained necessary.
- After resuming the child, the transfer drained and reported failure at about
  1.63 seconds. The child exited normally.

The reason is that `TransferSendSession::FinishLocked` enters draining state
but cannot report completion until its active operation count reaches zero.
The socket adapter's ACK/read/write timeouts default to `-1`, so a logical
session deadline does not itself interrupt a blocked data operation.

The same probe with the following existing native I/O timeout variables set to
0.1 seconds reported producer failure while the consumer was still paused:

```text
TPU_RAIDEN_PREFILL_HANDSHAKE_ACK_READ_TIMEOUT_S
TPU_RAIDEN_PREFILL_FINAL_ACK_READ_TIMEOUT_S
TPU_RAIDEN_PREFILL_PAYLOAD_READ_TIMEOUT_S
TPU_RAIDEN_PREFILL_HANDSHAKE_WRITE_TIMEOUT_S
TPU_RAIDEN_PREFILL_PAYLOAD_WRITE_TIMEOUT_S
TPU_RAIDEN_DECODE_HANDSHAKE_READ_TIMEOUT_S
TPU_RAIDEN_DECODE_PAYLOAD_READ_TIMEOUT_S
TPU_RAIDEN_DECODE_ACK_WRITE_TIMEOUT_S
TPU_RAIDEN_DECODE_PAYLOAD_WRITE_TIMEOUT_S
```

The 0.1-second value is a fault-probe setting, not a serving recommendation.
Finite socket I/O deadlines mitigate a completely stalled peer; a native
session deadline still does not authorize reusing memory before its terminal
report. A per-I/O timeout is also not a strict wall-clock bound on an entire
multi-operation transfer that continues to make slow progress.

No SGLang use-after-free was observed: its retention of active source and
destination allocations is the safe behavior. The remaining issue is progress
and capacity when native I/O never drains, not premature buffer release.

## Design-site browser checks

`check_design_site.cjs` serves a selected static Site checkout on an ephemeral
loopback port and uses Playwright Chromium to check desktop/mobile layout,
diagram modes, the SWA mismatch example, ownership steps and code tabs. It
closes its browser and server afterward. Supply your own Node/Playwright setup:

```bash
node tests/pd_victim_review/check_design_site.cjs \
  --site-root /path/to/design-site/dist \
  --playwright-module /path/to/node_modules/playwright \
  --output /path/to/site-check-results
```

The published owner-private design explanation is
<https://pd-victim-cache-design-20261026.groovyteal9.chatgpt.site>. Its exact saved
source commit is recorded in the dated handoff note. No benchmark source is
added to the SGLang feature by these browser checks.
