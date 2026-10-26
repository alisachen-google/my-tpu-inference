# vllm-torchtpu review notes

Review notes for the pull requests in the [BirdsOfAFthr review queue](https://github.com/vllm-project/vllm-torchtpu/pulls/review-requested/BirdsOfAFthr)
on `vllm-project/vllm-torchtpu`. All eleven belong to zhubin086's Qwen3.8 Flash / Qwen4Exp stack
([RFC #1955](https://github.com/vllm-project/vllm-torchtpu/issues/1955)).
Snapshot taken 2026-10-21 (heads as listed in each note). Each note has a recommendation,
findings ordered by severity with ready-to-paste comment text, questions, nits, and a list of threads other
reviewers already covered so nothing is repeated.

## Benchmark: victim prefix cache, commit 6c60fd77 (added 2026-10-26)

[benchmarks/2026-10-26-victim-6c60/](benchmarks/2026-10-26-victim-6c60/README.md) holds a before/after benchmark of
the P/D victim prefix cache on gpt-oss-120b 1P1D: parent 49ddede7 against 6c60fd77 with tpu-sync 759530c7. The
workloads are static 128k/256k-prefix prompts with 8k/16k new tokens and 1k output. Also included: an H2H
microbenchmark of tpu-sync (loopback and cross-host), a concurrency audit of the D2D and H2H paths, host-memory
measurements, the crash found in the "after" config, plus raw results, harness and recipes. The "before" side is
complete; the "after" sweep is pending.

## Handoff: decode DRAM as a prefill KV tier (added 2026-10-25)

[handoff/decode-dram-kv-tier.md](handoff/decode-dram-kv-tier.md) records our understanding of
vllm-torchtpu's offload and evict sweep, tpu-sync/Raiden's managers and transfer paths, the
relevant parts of sglang-torchtpu, and the victim-cache branch solution: how it works, how it
measured, the code on the fork and in tpu-sync, and the next steps. Written so another agent can continue the work.

## RFC #1955 (added 2026-10-23)

[reviews/vllm-torchtpu/RFC-1955.md](reviews/vllm-torchtpu/RFC-1955.md) reviews the RFC itself: six findings (mixed-batch dispatch promised in the thread but gone from the stack; GDN conv history silently moved from FP32 to BF16; the dependency table no longer matches the PRs; boundary leaks; uneven validation; PD contracts to verify), a status table for the nine questions already asked on the thread, and a ready-to-paste follow-up comment. [reviews/vllm-torchtpu/PR-1971.md](reviews/vllm-torchtpu/PR-1971.md) checks the P/D PR against the RFC's contracts and proposes causes for the open cross-host mismatch.

**Restack notice.** Between 2026-10-21 and 2026-10-23 the author rewrote most heads: #1964 was replaced by #2291, #1969 was closed, #2123 (fused decode) appeared, and #1968 grew to 67 files. The per-PR notes below were written against the heads recorded in each note; the "Stack state" table at the end of the RFC note says, per PR, which findings still apply and which need a re-check.

## Stack and status (snapshot 2026-10-21)

Ordered bottom-up by dependency.

| PR | Title | Base | Size | CI (head) | Existing reviews | Recommendation | Notes |
|---|---|---|---|---|---|---|---|
| [#1963](https://github.com/vllm-project/vllm-torchtpu/pull/1963) | [Core][Kernel] Support explicit pooled GDN convolution-state dtype | `main` | 7 files, +410/-33 | Buildkite failing: integration-qwen35-pcp4tp1-tp4dcp2-disagg-correct, unit-tests-multichip-pr | BirdsOfAFthr (3 comments) | **REQUEST CHANGES** (0 blocker / 1 major / 2 minor) | [notes](reviews/vllm-torchtpu/PR-1963.md) |
| [#2005](https://github.com/vllm-project/vllm-torchtpu/pull/2005) | [Kernel] Separate GDN input preparation from execution | `zhubin/qwen4-05-gdn-state` | 13 files, +834/-47 (true delta: 3 commits on top of #1963 (c4a375fcd, ac838cec0, 74d7a94a5)) | green | no reviews yet | **APPROVE WITH NITS** (0 blocker / 1 major / 2 minor) | [notes](reviews/vllm-torchtpu/PR-2005.md) |
| [#2017](https://github.com/vllm-project/vllm-torchtpu/pull/2017) | [Kernel] Compose StreamIndex readers, schedules and top-k backends | `main` | 4 files, +602/-26 | green | anthonsu approved | **APPROVE WITH NITS** (0 blocker / 2 major / 3 minor) | [notes](reviews/vllm-torchtpu/PR-2017.md) |
| [#2018](https://github.com/vllm-project/vllm-torchtpu/pull/2018) | [Kernel][Qwen4Exp] Add standalone block-sparse QSA prefill | `main` | 20 files, +4446/-0 | green | anthonsu approved | **APPROVE WITH NITS** (0 blocker / 1 major / 5 minor) | [notes](reviews/vllm-torchtpu/PR-2018.md) |
| [#1962](https://github.com/vllm-project/vllm-torchtpu/pull/1962) | [Model][Qwen4Exp] Preserve HyperConnection precision on TPU | `zhubin/qwen4-03-hc-kernels` | 2 files, +757/-0 | 8 Buildkite jobs pending | BirdsOfAFthr (5 comments), anthonsu (2 comments) | **APPROVE WITH NITS** (0 blocker / 1 major / 3 minor) | [notes](reviews/vllm-torchtpu/PR-1962.md) |
| [#1964](https://github.com/vllm-project/vllm-torchtpu/pull/1964) | [Kernel][Qwen4Exp] Compose QSA indexing and native pooled attention | `zhubin/qwen4-qsa-base` | 13 files, +3353/-0 | Buildkite failing: integration-compilation-cache-e2e | anthonsu (3 comments) | **REQUEST CHANGES** (0 blocker / 2 major / 2 minor) | [notes](reviews/vllm-torchtpu/PR-1964.md) |
| [#1965](https://github.com/vllm-project/vllm-torchtpu/pull/1965) | [Model][Qwen4Exp] Load sparse QSA weights and bind native metadata | `zhubin/qwen4-qsa-base-889dbef8` | 5 files, +1195/-0 | GH gates: Check for Ready Label | no reviews yet | **REQUEST CHANGES** (0 blocker / 2 major / 4 minor) | [notes](reviews/vllm-torchtpu/PR-1965.md) |
| [#1966](https://github.com/vllm-project/vllm-torchtpu/pull/1966) | [Kernel][Qwen4Exp] Add PLE lookup and request-owned convolution | `zhubin/qwen4-qsa-base-889dbef8` | 3 files, +646/-0 | GH gates: Check for Ready Label | no reviews yet | **REQUEST CHANGES** (0 blocker / 2 major / 4 minor) | [notes](reviews/vllm-torchtpu/PR-1966.md) |
| [#1967](https://github.com/vllm-project/vllm-torchtpu/pull/1967) | [Model][Qwen4Exp] Add resident and shared-host PLE embeddings | `zhubin/qwen4-08-ple-kernels` | 12 files, +2165/-16 | GH gates: Check for Ready Label | no reviews yet | **REQUEST CHANGES** (0 blocker / 2 major / 4 minor) | [notes](reviews/vllm-torchtpu/PR-1967.md) |
| [#1968](https://github.com/vllm-project/vllm-torchtpu/pull/1968) | [Model][Qwen4Exp] Integrate complete QSA PLE execution and native caches | `zhubin/qwen4-model-base-input-20261016` | 36 files, +5891/-737 | Buildkite failing: integration-compilation-cache-e2e | no reviews yet | **REQUEST CHANGES** (0 blocker / 3 major / 5 minor) | [notes](reviews/vllm-torchtpu/PR-1968.md) |
| [#1969](https://github.com/vllm-project/vllm-torchtpu/pull/1969) | [Kernel][Qwen4Exp] Score logical index-key width and split mixed requests | `zhubin/qwen4-10-model-cache` | 44 files, +5689/-770 (true delta: 2 commits on top of #1968 (f8068ce3e, 1d88dcd11)) | Buildkite failing: unit-tests-cpu-pr, unit-tests-multichip-pr; GH gates: Check for Ready Label | no reviews yet | **NEEDS DISCUSSION** (0 blocker / 2 major / 3 minor) | [notes](reviews/vllm-torchtpu/PR-1969.md) |

## Suggested review order

1. **Near approval, unblock first:** #2017, #2018, #1962, #2005 (approve with nits). #1963 needs one fix (conv dtype resolver) and is the base of #2005.
2. **Kernel layer needing changes:** #1964 (pooled path untested, three anthonsu threads still open in the head). #1965 and #1966 are built on a snapshot of it and inherit its outcome.
3. **Model layer:** #1967 (shared-host table lifecycle), then #1968 (integration: hot-path token upload, 73 single-layer cache groups, pool reservation), then #1969 (needs discussion on the owner-cache `lax.cond` copy).

## Cross-cutting themes

These recur across several PRs and are worth raising once on the RFC (#1955) rather than per PR.

- **Production pooled paths lack tests.** The pooled QSA step, main-cache and compressed-key writers (#1964), the PLE resident lookup/decode (#1966), custom StreamIndex components on decode passes (#2017) and the shared-host table reader (#1967) are not executed by any test in their PRs. Most kernel tests are TPU-only (`tpu_test`); there is almost no CPU/interpret coverage.
- **PR descriptions claim more than the diff contains.** #1965 (metadata builder and geometry-rejection tests), #1966 (resident lookup coverage), #1969 (commit 1 "FP8 caller passes the logical query" only holds for the pure-decode bucket), #2005 (benchmark run on an integrated #1968 revision, not this head). Ask for bodies to be trimmed to what is in the diff.
- **Pool byte accounting has more than one source of truth.** #1963 declares the explicit conv dtype in `get_state_dtype` but the block-slot derivation and the Raiden manifest still resolve conv to BF16 through `pooled_gdn_state_dtypes`; #1968's planner reserves main-KV-sized pages for compressed keys, and vLLM's uniform-page grouping turns its 73 pooled specs into 73 single-layer KV cache groups (one block table staged and one metadata build per group per step), which the PR does not mention. These should be fixed in #1963 before #1968 bakes in the same helper.
- **Prefill/decode routing is inferred from padded shapes.** #1964 decides prefill vs decode from `len(query)` vs slot count in both directions, #1969 derives the decode count from the decode-first ordering invariant, and #2018's un-chunked general TC fallback is the path TP=2 lands on. A single explicit routing signal from the runner would remove the heuristics.
- **Hot-path cost not yet measured end to end.** #1968 uploads the full `[max_num_reqs, max_model_len]` token table every step; #1969 threads the owner cache through a `lax.cond` whose RPA arm aliases it in place (the author's own note about "emitted cache-owner copies"). Both need an HBM/latency number from a real serving run, not standalone kernel timings.
- **Open threads from anthonsu on #1964** (topk_backend threading, unconditional `select_decode_blocks` in `qsa_step`, padded slot-count misclassification) are still unaddressed in the current head even though later PRs claim #2017 resolved the first.

## Layout

- `AGENTS.md` – context for agents: what this repo is, where things are, the owner's rules.
- `README.md` – this index.
- `handoff/<topic>.md` – handoff notes for ongoing work, written for another engineer or agent.
- `reviews/vllm-torchtpu/PR-<n>.md` – one note per PR: recommendation, findings by severity with ready-to-paste comment text, questions, nits, threads already covered by other reviewers, test coverage assessment.

## How these were produced

Each PR head was checked out in a worktree and diffed against its true base (for #1969 and #2005 the base branch on GitHub is a stale copy of the parent PR, so only the top commits were reviewed). Existing review threads were read first so nothing is repeated; where an author said a comment was fixed, the head was checked for the fix. Line numbers refer to the PR head listed in each note. No TPU tests were run.
