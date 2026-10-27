# Design review website and separate simplification branch

Written 2026-10-26.

## PR #1789 simple diagram (published 2026-10-27)

The user requested a simple website diagram emphasizing spillover, recall,
FULL plus SWA, and the tpu-sync update. PR #1789 was fetched through the
GitHub connector and its current source was read at
`c910830c0e5962ec07f215ed1fec814e9b5dc323`. This PR now includes host-to-host
recall and the umbrella enable switch; the publication/status statements in
earlier sections below are historical snapshots.

The existing Site's `?section=memory-map` now shows both directions together,
with selectable spill and recall views, separate FULL/SWA arrows, the shared
ending boundary, initial Prefill D2H and later admission H2D. An API panel
explains host `register_read`, named-host `start_read`, native completion and
which role serves/pulls in each direction. The complete diagram is downloadable
as `/document/pr1789-overview.svg`. It also shows the current umbrella flag
`SGLANG_ENABLE_PREFILL_KV_OFFLOAD_TO_DECODE_DRAM=1` and the unified
`SGLANG_TPU_PD_SWA_HOST_WINDOWS` setting. Historical deep dives remain pinned
to their original revisions and are explicitly distinguished from the new
overview in the page and server document context.

Source commit: `f4bd80789f4806d2e0bdef7d4ded24b8318efb85`.
Saved version: `appgprj_6adee7597a9081918122a1861b6e35c6~appgver_abc001e7476881918cbd800ca59a6d37`.
Deployment: `appgdep_6ae0ddd262288191b3ce4f8ac805fc0c`, confirmed succeeded.
Owner-private access, D1 schema and AI configuration are preserved.

TypeScript, production build, nine SQLite checks and desktop/mobile/offline
Playwright checks passed. QA verifies saved local section questions, current
PR context from the document tool, SVG download, flow controls, no viewport
overflow/page errors, and self-contained offline assets without duplicate IDs.
The exporter now regenerates the memory-map chapter as well as the five
existing authored chapters. Local artifacts are in
`~/pd_disagg/results/pr1789-diagram-review/`; no hosted QA records, live AI
calls, SGLang runtime edits or benchmarks were made. The owned preview was
stopped after QA. No new performance measurements are claimed by the diagram.

## Host-to-host prefix recall (updated 2026-10-27)

The user requested a new commit on the original `pd-victim-prefix-cache`
branch, replacing the Decode DRAM → Decode HBM → device-source transfer
detour with Decode DRAM → Prefill DRAM recall. Local feature commit
`e18ff55cb76aae57a44fb8328fe579e92eee47c4` is based directly on published
`9d9c2d89`, in `~/sglang-victim-host-recall` on `pd-victim-host-recall`.
It does not incorporate or modify the separate simplification branch.

Victim mode uses `HostPrefixSource` and `HostPrefixPuller`. The existing
OFFER/PULL/READY messages carry an explicit memory domain. Decode offers and
host-pins completed FULL/SWA host coverage; the host managers register with
`source="host"`. Prefill allocates named pages in its existing HiCache pools,
receives with `destination="host"`, then publishes both components through
the shared host-prefetch insertion helper. Normal Prefill admission performs
H2D. Device recall outside victim mode is unchanged. Native transfers retain
ownership through aborts and room cleanup; host tree pins cover the queue-to-
admission handoff. A wrapper fix preserves completion reports cached while
listener registration releases the GIL. Runtime changes stay in `sglang_tpu/`.

Twenty-two extra CPU regressions and a guarded runner are committed in this
notes repo, outside the SGLang feature commit. Final validation passed 517 CPU
tests plus 268 subtests, including real two-rank Gloo failure/completion
coordination; there were zero TPU compiler calls and no `torch_tpu` import.
Configured lint, full F/E9 on runtime files, formatting, import ordering,
whitespace and unchanged SGLang test-method counts passed. The old request-
cleanup assertion failed identically on an untouched `9d9c2d89` worktree;
only that assertion and the existing mock host-pool size field were adapted.
The owned baseline worktree was removed after verification.

Artifacts remain local in `~/pd_disagg/results/host-prefix-recall-review/`
(`unit-tests.xml`, `status.json`, `integration.patch`, `feature.patch`).
No benchmarks, native transfers, model servers or live TPU tests were run.
No production bandwidth/latency/correctness claim follows from these CPU mocks.
The native socket-drain limitation documented earlier still applies.

Publication is blocked: Git push from this tool terminal reports missing HTTPS
credentials; the connected GitHub app identifies as `alisa888cl-eng` and its
commit API does not expose author/committer overrides. Both local feature
identities are the requested `alisachen-google` noreply identity. The target
remote branch was last verified at `9d9c2d89` and is not updated yet. From an
authenticated terminal, publish the prepared fast-forward with:

```bash
git -C /home/alisachen_google_com/sglang-victim-host-recall \
  push fork HEAD:pd-victim-prefix-cache
```

The website still documents the historical milestone 3 revision `9d9c2d89`;
it was not changed by this implementation task.

## Milestone 3 explanation (updated 2026-10-26)

The private design website now has `?section=milestone-recall`, matching the
milestone 2 chapter's format and pinned to
`9d9c2d89e0e5a1009de44d383892efb0b035e5fc`. It explains Decode host-to-HBM
restore, M selection, OFFER/PULL/READY, precise FULL/SWA ranges, rank-agreed
allocation and completion, the planning/offer/restore/tree-pin handoffs, and
fallback/deferred native destinations. The architecture and walkthrough name
the original inherited controller and parallel metadata tables; later
simplification commits are distinguished explicitly.

The chapter adds a downloadable architecture SVG, reuses the recall sequence
SVG, and includes five interactive ownership/fallback scenarios. It is included
in the section discussion UI, server document context and self-contained offline
download. Embedded copies of reused SVGs now have unique IDs. Source commit:
`a9bbc8bb25e5d3487dd3048f9e3cdb95fcad4170`; deployment:
`appgdep_6adfcabe9f448191a62e0c8788729503`.

TypeScript, production build and nine SQLite checks pass. Local-D1 desktop/mobile
QA verifies pinned code links, loaded diagrams, scenario behavior, saved and
reloaded section questions, and authenticated document-tool context. The offline
chapter and prior spillover/calculator checks also pass. Artifacts stay local in
`~/pd_disagg/results/milestone3-doc-review/`; no hosted QA threads, live AI calls,
SGLang changes, TPU runs or benchmarks were made.

## Shared Prefill/Decode pool construction (unit-only, 2026-10-26)

Local SGLang commit `3a2bb016cabc1344d198e60ea15423f9c98ace48` on
`pd-victim-prefix-cache-simplified` consolidates the TPU host stack into
`_SwaHostStrategy` / `_build_host_stack`. Prefill retains normal fixed/ratio
capacity, packed draft mappings and allocation callbacks. Decode retains its
FULL-only default or separately budgeted SWA-window tier. Both use existing
pool builders and one controller construction path; role-specific restore
markers are applied outside the builder. Physical pools remain independent.
Shared core, transport, recall and victim lifecycles are unchanged.

The feature commit changes one runtime module and adapts existing fixtures in
two unit files. No SGLang test methods are added or removed. A broad run also
reproduced an existing room-cleanup test failure on unchanged `14a6d804`: it
expected request-room cleanup to remove independently keyed victim sessions.
Its assertion now checks that those sessions survive; runtime cleanup is unchanged.

Final validation: 371 CPU unit tests plus 259 subtests passed, including seven
additional construction/equivalence checks in this notes repository. The
runner preserves plugin discovery and supplies an import-only TPU compiler
guard; it verifies zero compiler invocations and no `torch_tpu` import. See
`tests/pd_victim_review/run_shared_swa_host_stack_units.py`. JUnit results remain
local at `~/pd_disagg/results/shared-swa-host-stack-review/unit-tests.xml`.
Configured Ruff, formatting, isort and whitespace checks pass on feature files.
An unrelated existing F841 unused local in the broad offload test is outside
the repository's configured Ruff selection and was left unchanged.

No benchmarks, model servers or native transfer runs were started. Previous
`14a6d8049d2b2d7fd0f0c06de1148ab2c187f697` is also retained as local ref
`benchmark/pd-victim-before-host-stack-consolidation`; the original published
runtime `9d9c2d89` and `pd-victim-prefix-cache` ref are unchanged. Normal push
of the simplified branch failed because the tool terminal lacks GitHub HTTPS
credentials. Author and committer are both `alisachen-google`.

## End-to-end technical design (updated 2026-10-26)

The same private website now opens on `?section=design-brief`, with linked
`native-contract`, `phase-guide` and `workload-impact` chapters. These describe
the published runtime `9d9c2d89` and native `759530c7`, independent of the later
simplification branch. The native API snapshot's SHA256 matches the prior
benchmark manifest. The guide calls out the pinned Python constructor's
positive host-control-port requirement, initial Prefill D2H, direct host spill,
FULL/SWA publication, current device-backed recall, rank agreement and cleanup.

Two downloadable SVG sequence diagrams distinguish control metadata, native
pull control and KV payloads. A self-contained HTML download embeds the diagrams,
styles and interactions; it works offline and includes print/save-PDF styling.
Editable chapter fragments and the reproducible exporter live in the Site
source. No SGLang source or tests are changed.

Performance coverage explains reuse/capacity versus transport savings, workload
fit, contention costs and a transparent break-even calculator. Native-only
table rows come from the local `ram2ram-759530c7/native-results.json`; integrated
case counts come from its separate validation manifest. Neither establishes
final-revision model TTFT, TPOT, throughput or hit-rate gains. Full benchmark
programs, samples and raw artifacts remain local, absent the feature commits.

Website source: `fcda1a643ed4a39f21abeeda9e656f4f5c1032d1`.
Deployment: `appgdep_6adfaadd5a70819198a80a69beebdd72`.
Validation: TypeScript and production build passed, nine SQLite checks passed,
and the new desktop/mobile/local-D1 plus offline-browser probe passed. It checks
all four discussion sections, diagram loading, calculator zero-reuse/regression
cases and offline asset independence. QA stays in
`~/pd_disagg/results/spillover-design-review/`; no hosted QA records were created.

## Milestone 2 explanation (updated 2026-10-26)

The website now has a dedicated `?section=milestone-swa` chapter pinned to
`bbc4b298e12be849427f4f2d5254451abe376013`. It explains matching FULL/SWA
endpoints, transfer-tail rounding versus host-budget allowance, the cache
builder and path-end backup policy, the two-pool transfer lifecycle, ownership
records, partial failures, ordinary FULL-only restore behavior, and the exact
boundary before milestone 3 recall. Source links point at that historical
revision. Interactive completion cases are illustrations, not measurements.

Website source: `9507357de77ee1605f1f63305f7416406ec88520`.
Deployment: `appgdep_6adfa6c31d348191bcf6036e8838f209`.
Validation: TypeScript and production build passed; nine SQLite checks passed;
the new local-D1 desktop/mobile probe verifies pinned code links, all four
completion scenarios, section-specific saved questions and chapter inclusion
in the authenticated document tool. Screenshots and QA output remain local in
`~/pd_disagg/results/milestone-swa-doc-review/`. No SGLang source or tests were
changed, and no live TPU or hosted AI request was performed.

The following records the prior deployment and separate code cleanup.

The private design document is published at
https://pd-victim-cache-design-20261026.groovyteal9.chatgpt.site .
It preserves the memory/architecture diagrams and now provides section-linked
comments/questions, selected-text quotes, saved replies, resolve/reopen and
thread links. D1 binding `DB` holds `doc_threads` and `doc_messages`; deployment
migrations contain schema only, and the hosted database was verified empty.
Local QA rows are never published. The source version is
`b3719eae681787fb6bafd6befd717e23db3af8cc`; deployment
`appgdep_6adf1f8f801c8191af0357d80c047e55` succeeded.

The private Site MCP plugin exposes read-document/read-thread and requested
Codex replies; the platform reports it already installed. Tool discovery may
need a fresh conversation. Automatic in-site answers are implemented through
a server-only OpenAI adapter, but remain disabled until a supported credential
and model are configured. The OpenAI Developers plugin was offered; connection
was not confirmed. No live AI request was made and no fake answer was seeded.
Nine real SQLite tests and desktop/mobile local-D1 browser checks passed.

The user's new code experiment is the local branch
`pd-victim-prefix-cache-simplified` in `~/sglang-victim-simplified`, based on
`fd38f16cfd9e` (short README) and the published runtime `9d9c2d89e0e5`.
Prepared cleanup revision: `14a6d8049d2b2d7fd0f0c06de1148ab2c187f697` (not yet pushed; terminal auth is
unavailable). The original branch remains intact.

This behavior-preserving first pass:

- retains complete FULL/SWA offer and READY descriptors instead of separate
  parallel dictionaries;
- uses one ACK registry for pending admission instead of a separate live set;
- derives export completion from admission and native terminal outcomes;
- composes recall/export, with explicit cleanup, request advancement and export
  phases, preserving cleanup before tree decisions and one export-settle per tick;
- gives the exporter explicit cache/manager/group dependencies.

The diff is 96 insertions and 90 deletions across six files. It reduces coupled
state and inheritance, not total code volume materially. Existing test cases
are unchanged; only exporter fixture construction is adapted. Validation:
401 existing CPU tests +195 subtests, plus ten separate CPU/Gloo probes. The
private probes now use actual wire handlers/controller construction instead of
writing implementation-specific tuples or constructing partial controller objects.
No new live TPU validation or benchmark/performance claim was made.

Direct Decode DRAM → Prefill HBM recall remains a proposal requiring native
mixed-domain validation, matched FULL/SWA host sources and careful source/dest
ownership. It can avoid restoring the source into Decode HBM but still needs
Prefill receive staging/H2D. The implemented recall path remains unchanged.
