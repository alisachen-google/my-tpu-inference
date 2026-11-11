# PR 2086 author session, 2026-11-11 05:30 to 17:00 UTC

What was found, fixed, measured and merged for the hybrid (SWA + full attention) KV offload to decode DRAM, from the
author's side. Hosts: prefill `amandaliang-v7x-8` (10.128.0.246), decode `v7` (10.128.15.239), gpt-oss-120b, TP8 per
role, fp8 KV, page size 64, 128k prefix + 8k new tokens, prefill `--hicache-ratio 1.2`, caches flushed before every
point. Hit is prefill-side. The benchmarking agents' campaigns are in `README.md` and `ISSUES-2026-11-11.md` next to
this file; this report refers to their issue numbers.

## Outcome

| Item | State |
|---|---|
| PR 2086 (hybrid offload) | merged into main as `5c136df1b4` (head `83198bc912`, approved, CI green) |
| Static-reuse regression under write-back | fixed in 2086 |
| I5, recalled output differs from recompute under write-back | fixed in 2086 by the same change |
| I7, native hash extension rebuilt on every pull | fixed in 2086 (third commit) |
| I4, refused subtree drops under write-back | still occurs as a warning; one out-of-memory in five stress runs; open |
| Recall-8 capacity-edge loss | filed as upstream issue 2107; fix on branch `pd-dram-spill-capacity-edge` (`48187d32a3`), A/B half done, PR not opened |
| I3, spot preemptions | cluster behaviour, nothing to fix |

## Timeline

| UTC | Event |
|---|---|
| 05:30 | Compared PR 1789 with PR 2086 at the code level to explain 1789's better static-reuse numbers. Window retention on the decode, offer rule, pull rule, victim choice, next-victim stamp and the decode's skipped radix inserts are the same. Difference found: 1789 made the prefill keep only the last SWA window of each path behind a separate flag; 2086 forced it whenever the switch was on. Upstream main now backs up the window of every evicted node by default, so the off arm kept the window at a shared document's end and the on arm dropped it. |
| 05:40 to 06:24 | Experiment, switch on, both arms: PR head vs the same head with the prefill's retention left to upstream. Result in the first table below. |
| 06:15 | Agents' issues I3, I4, I5, I7 received. I7 fixed (hash pages only when the tree keeps hashes, as core does), unit test added. |
| 06:25 to 07:30 | First stress attempts. One prefill out-of-memory on the fixed tree with background probes running during the returns. Two harness mistakes of mine: a tree deployed while I was committing in it, and new recipes that were not copied to the hosts (the launcher reads the recipe path on the host). Also found that my local integrity tool kept its probes running during the recall phase, which makes its equality numbers invalid on TPU (greedy decoding is not batch-invariant); wrote `victim_integrity_quiet.py`, which stops the probes first. |
| 07:50 | Pushed the fix to PR 2086 at the user's request once the 8 to 16 document benchmark was in: `e312ed48e4` host tier (prefill rule removed), `525992d523` hybrid (README corrected), `83198bc912` page-hash fix. |
| 08:45 | CI green on `83198bc912`, including the TPU unit shard. |
| 08:50 to 09:35 | Equivalence pass with the quiet tool, four arms on fresh engines. Second table below. I5 closed. |
| 09:35 to 13:20 | Edge-case validation of `83198bc912`: write-back and write-through, switch on and off, ladders, five edge cases, four stress repeats. Third and fourth tables below. |
| 12:00 | Upstream issue 2107 filed for the recall-8 loss the agents measured on the new head. Assessed their four proposed fixes; implemented the first in its simplest form. |
| 13:25 | PR 2086 merged (squash) as `5c136df1b4`. Results posted on the PR conversation (two comments). |
| 13:25 to 14:40 | A/B #1 of the 2107 fix against merged main. Fifth table below. |
| 14:40 to 17:00 | A/B #2 (off, main, fix; recall 8, 9, 12 three times each). The off and main arms completed; the session ended before the fix arm ran. Sixth table below. Hosts released. |

## 1. Static-reuse regression: cause and fix

With the switch on, the previous head made a hybrid prefill keep only the last SWA window of each cached path. A
request that forks from a shared prefix (a static document) needs the window that ends at the fork; upstream's host
tier keeps it, the previous head threw it away, so the on arm's host tier served no static revisit (the agents'
counters: 0.00M host-cached tokens on every static point of that arm). The fix removes the rule from the prefill; only
the decode, which stores pushed branches, keeps one window per path.

Switch on, write-back, same hosts:

| Point | Previous head `54a80863a6` | Fixed | Switch off (earlier run) |
|---|---|---|---|
| Static 8 docs | 53.5%, TTFT p50 6.3 s | 62.5%, 6.2 s | 62.5%, 6.1 s |
| Static 12 docs | 29.7%, 10.1 s | 56.3%, 4.6 s | 50.3%, 6.7 s |
| Static 16 docs | 24.5%, 10.1 s | 54.1%, 6.7 s | 40.2%, 9.9 s |
| Recall 12 sessions | 70.8%, 6.4 s | 70.7%, 4.2 s | |

145 of 145 requests per arm; 159 of 159 pushes stored and landed on the fixed arm, 25 recalls each with its window.

## 2. I5, output equivalence under write-back

Procedure: 16 sessions of 128k + 8k filled under 6 concurrent 8k probes; each session then returns alone; both
engines are flushed and every return is recomputed; 64 greedy tokens compared. Fresh engines per arm.

| Arm | Exact | Refused drops | Hash rebuilds |
|---|---|---|---|
| Previous head `54a80863a6`, write-back | 12 / 16 (sessions 6, 11, 12, 15) | 40 | 120 |
| Fixed, write-back | 16 / 16 | 64 | 0 |
| Fixed, write-back, copy-ahead off | 16 / 16 | 0 | 0 |
| Fixed, write-through | 16 / 16 | 0 | 0 |

The previous head reproduces the agents' sessions 6 and 11. With only the last window of a path kept, a return could
resume with a window that did not end at its match; with upstream's rule it gets the window computed there. Session 15
of the previous-head arm was recomputed in both phases and still differs at token 2, which is not explained.

## 3. Validation of the merged head `83198bc912`, switch off vs on

Write-back:

| Point | Prefill hit off -> on | TTFT p50 off -> on |
|---|---|---|
| Recall 8 sessions | 84.0% -> 94.4% | 2.4 s -> 2.1 s |
| Recall 12 | 24.9% -> 60.1% | 14.9 s -> 6.3 s |
| Recall 16 | 0.0% -> 45.4% | 18.6 s -> 9.1 s |
| Static 4 docs | 62.7% -> 62.7% | 4.7 s -> 6.7 s |
| Static 8 | 62.5% -> 62.5% | 6.1 s -> 6.2 s |
| Static 12 | 51.8% -> 55.4% | 6.4 s -> 6.3 s |
| Static 16 | 40.7% -> 52.3% | 10.2 s -> 6.7 s |

Write-through:

| Point | Prefill hit off -> on | TTFT p50 off -> on |
|---|---|---|
| Recall 8 sessions | 24.2% -> 94.4% | 10.8 s -> 2.8 s |
| Recall 12 | 0.0% -> 67.9% | 18.4 s -> 3.3 s |
| Recall 16 | 0.0% -> 78.7% | 18.5 s -> 3.9 s |
| Static 4 docs | 62.7% -> 62.7% | 6.7 s -> 6.7 s |
| Static 8 | 60.5% -> 61.9% | 6.4 s -> 6.4 s |
| Static 12 | 35.6% -> 58.9% | 8.0 s -> 3.7 s |
| Static 16 | 28.2% -> 58.8% | 10.4 s -> 3.5 s |

205 of 205 requests on each of the four arms, no scheduler exception, out-of-memory or malformed message.

Edge cases, both policies, switch on: concurrent recalls after a prefill-only flush and client aborts mid-recall
(completed, health never dropped); flush under load (both engines refuse with 400, 24 of 24 requests complete); decode
killed while recalls are in flight (requests in flight fail loudly, 12 of 12 after the restart); prefill killed while
pushes are in flight (the decode releases the dead prefill's landings, 12 of 12 after the restart).

## 4. I4 and the out-of-memory

Under write-back a device eviction first backs its victim up to host. With the host pool full and the victim locked,
upstream logs "backup failed under host memory pressure but subtree drop declined (node locked)" and keeps the node on
device. Stress = the equivalence procedure with the probes kept running during the returns:

| Tree | Copy-ahead | Runs | Out-of-memory | Refused drops per run |
|---|---|---|---|---|
| Fixed | on | 5 | 1 | 40 to 80 |
| Fixed | off | 2 | 0 | 0 |
| Previous head | on | 1 | 0 | 40 |

The one out-of-memory (run `i5a_wb_on`, 06:33:22): returns were being served from the prefill's own host tier, ten
refused drops in one second on roots 493, 543, 577, 581, 585, then "Prefill out of memory" with 646,528 evictable
device tokens it could not demote. Copy-ahead's host pins together with the offload's host locks are the lead: with
copy-ahead off there is not a single refused drop. Not fixed.

## 5. Recall-8 capacity-edge loss (upstream issue 2107)

The agents' run on `83198bc912`: 93.7% -> 86.8% hit on the 8-session return, two returns partially cached (106,176 and
82,368 of 139,264 tokens), 4 pushes during the return, 0 offers. Cause: a push stored during the return made the
prefill stamp its copy as the next eviction victim (`mark_next_victim`); the pusher picks the oldest path end, which in
an oldest-first return is the session that returns next; its tail was evicted before it came back and the request had
passed the decode's offer step before the pushed pages landed. Of the agents' four proposals, the first (do not demote
a pushed session) is right and is implemented by removing the stamp (33 lines in, 84 out, 158 unit tests pass). The
second would not have prevented the push (the device pool is near full during returns), the third is not supported
(session 6's 5.0 s is queueing behind the two sessions recomputing in the shared prefill batch), the fourth does not
apply (the victims had not returned yet).

A/B #1, write-back, switch on, main `5c136df1b4` vs fix `48187d32a3`:

| Point | Main | Fix |
|---|---|---|
| Recall 8, three runs | 94.4 / 93.7 / 91.6% | 94.4 / 94.4 / 88.1% |
| Recall 9 | 63.5%, TTFT 4.7 s | 85.7%, 3.3 s |
| Recall 12 | 62.8% | 57.3% |
| Recall 16 | 56.9% | 60.0% |
| Static 12 docs | 56.0% | 56.3% |
| Static 16 docs | 52.7% | 54.6% |

219 of 219 requests per arm; equivalence on the fix 16 of 16. The fix arm still had one partially cached return
(session 7, 65,472 tokens): there the six pushes happened before the return, for the six oldest sessions, and plain LRU
then evicted part of a session that had not been pushed.

A/B #2, three runs per point; the fix arm did not run:

| Point | Switch off | Main, switch on |
|---|---|---|
| Recall 8 | 84.0 / 84.7 / 84.0% | 88.1 / 86.0 / 91.6% |
| Recall 9 | 67.2 / 69.6 / 72.7% | 69.1 / 82.6 / 82.6% |
| Recall 12 | 27.7 / 27.3 / 27.3% | 58.7 / 61.5 / 33.5% |

Reading: on these hosts the switch-on arm is above the switch-off arm at 8 sessions in every run, so the loss the
agents saw is specific to runs where the pushes fire inside the return. The on arm's 12-session point has one outlier
(33.5%), which bounds how much a single-run difference at 12 means. The fix's gain at 9 sessions rests on one run.

## Open items

1. Run the fix arm of A/B #2 (recall 8, 9, 12 three times), then open the PR for issue 2107 if the fix is level at 8
   and 12 and ahead at 9. Branch `pd-dram-spill-capacity-edge` at `48187d32a3` is local only.
2. I4: decide between giving copy-ahead's pins and the offload's locks a shared host budget, or leaving headroom in
   the push threshold; reproduce the out-of-memory first (1 in 5 so far).
3. PR 2052 (shared prefix) still sits on the pre-merge base and needs a rebase onto main.
4. The user asked for a simplification and refactoring pass over the offload code; only the 2107 change has had it.
5. The TPU unit shard runs at the edge of the repo's 40-minute budget (39.9 to 41.7 minutes on three PRs); it passed
   on the merged head.
6. The session-15 recompute-vs-recompute difference on the previous head is unexplained.

## Where the raw data is

On host b under `~/pd_disagg/`: `live/goal_followup.log` (every point and counter line of the day),
`spill/results_goal/` (jsonl of runs `g2086a_on_1`, `g2086b_on_1`, `i5q*`, `e2086_*`, `i2107_*`, `i2107b_*`),
`spill/logs/goal_*.log` (POINT lines), `spill/prefill_logs/i5a_wb_on_a.log.gz` (the out-of-memory), and the scripts
`live/goal_static_fix.sh`, `goal_i5_quiet.sh`, `goal_edge_2086.sh`, `goal_i2107.sh`, `goal_i2107b.sh`.
