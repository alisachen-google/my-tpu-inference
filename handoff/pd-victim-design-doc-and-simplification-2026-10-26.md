# Design review website and separate simplification branch

Written 2026-10-26.

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
