# Design-document persistence checks

These tests live outside the SGLang feature. They select a separate Sites
checkout; they do not launch TPU workloads or mutate hosted review records.

- `test_discussion_store.mjs` runs nine real SQLite cases for idempotent posts,
  authorship, resolve/reopen permissions and assistant-job retry ownership.
  Set `DESIGN_DOC_SITE_ROOT`; use Node with TypeScript stripping and SQLite.
- `check_design_doc.cjs` uses Playwright against an already-running owned local
  preview with its local D1 migrations applied. Set `DESIGN_DOC_TEST_ORIGIN`
  (loopback only), `PLAYWRIGHT_MODULE`, and optionally `DESIGN_DOC_QA_OUTPUT`.
  It signs into the portable preview identity and creates local-only QA threads.
  It checks persistence across reloads, replies, resolve/reopen, cross-origin
  rejection and the authenticated MCP read surface on desktop/mobile.
- `check_swa_milestone.cjs` checks the bbc4b298 chapter's pinned source links,
  completion scenarios, responsive layout, section-specific saved questions,
  and its inclusion in the authenticated document tool. It uses the same
  local preview environment variables and never writes hosted records.
- `check_recall_milestone.cjs` checks the 9d9c2d89 chapter's code links,
  diagrams, five ownership/fallback scenarios, saved section questions and
  document-tool context. It also checks the interactive offline export and
  unique diagram IDs. Set `DESIGN_DOC_SITE_ROOT` as well as the preview variables.
- `check_spillover_design.cjs` checks the four end-to-end chapters, calculator
  break-even behavior, loaded sequence diagrams, new discussion sections and
  the self-contained download under an offline browser context. Also set
  `DESIGN_DOC_SITE_ROOT` to the selected Sites checkout.

Automatic OpenAI replies have not been live-tested: the hosted Site has no AI
credentials configured. Unavailable-provider behavior preserves questions and
never inserts a fabricated assistant reply. The deployed production DB began
empty; local QA records are separate from it.
