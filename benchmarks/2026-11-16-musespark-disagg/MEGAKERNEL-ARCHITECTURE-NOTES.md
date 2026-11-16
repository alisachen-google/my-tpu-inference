# Muse megakernel communication architecture and PR 2183: reading notes (2026-11-16)

Source: `sglang_tpu/muse_megakernel/doc/README.md` and `comm_overview.svg` at the head of
[PR 2183](https://github.com/sgl-project/sglang-torchtpu/pull/2183) (`junyanxu/muse-mk-layout@3517b4e3f7`, draft, stacked
on #2178). The same files are what the author's checkout `sglang-muse-disagg-kernel` holds; that VM was not reachable
from here, so these notes are from the PR. Numbers are the author's, not re-measured.

## What the diagram compares

How the 8 TensorCore ranks of one tpu7x host talk to each other inside one layer of Muse Spark (residual width 8192,
MoE hidden 4096, 256 experts, top 8), for nine program variants. The unit is KiB each rank sends per token row.

| # | Program | Rows | Experts | Comm KiB/row | State |
|---|---|---|---|---|---|
| 1 | Prefill TP | replicated on all ranks | expert-TP: every rank holds 1/8 of every expert | 112 | serving today |
| 2 | Prefill SP + EP | each rank owns R/8 rows | EP: 32 whole experts per rank | 34.4 | in this PR |
| 3 | Prefill SP + EP, o all-to-all | as 2, o-proj on a replicated weight | EP | 21.3 | in this PR (the headline) |
| 4 | Decode TP megakernel | replicated | expert-TP | 112 (87.5 row-tiled) | serving today |
| 5, 6 | Decode EP "gather" | replicated | EP | 70 | exists, not wired for serving |
| 7, 8 | Decode SP + EP "a2a" | sharded | EP | about 45 / 33 | exists, not wired |
| 9 | Decode SP + EP, sliced pool/unpool | sharded | EP | 46.8 | target |

Three ideas carry the whole design:

1. **Sequence parallel (SP) instead of tensor parallel (TP).** In TP every rank holds every row and a slice of every
   weight, so every matmul ends in a reduce-scatter or all-gather of full-width activations. In SP each rank owns an
   eighth of the rows and runs router, pooler and unpooler locally on replicated weights, with no collective.
2. **Expert parallel (EP) instead of expert-TP.** With expert-TP each (token, expert slot) sends 8 partial outputs to
   its owner: 56 KiB/row, half of all traffic. With whole experts per rank a row is sent once to the rank that owns
   its expert and comes back once (dispatch and combine all-to-all, 13.4 KiB/row). The all-to-all is written as Pallas
   remote DMA straight into expert-grouped order and streamed in 4 chunks so the expert matmul overlaps the transfer.
3. **A dtype policy.** fp8 e4m3 with a row scale on the wire and in every dense dot; f32 or bf16 only where a norm is
   computed. This halves the remaining traffic and runs the matmuls at the fp8 rate.

What stays expensive: attention is still split by head, so every rank needs all rows (the a_in all-gather); removing
that needs context parallelism.

## What PR 2183 does

- Reorganizes the megakernel tree (`decode/tp`, `decode/spep`, `prefill/tp`, `prefill/spep`, `common/`), splits the
  6,700-line decode kernel, removes dead knobs. Refactor A/B is flat (same busy time per layer, identical Mosaic
  module hashes).
- Adds the SP prefill program (`SGLANG_TPU_MUSE_MK_PREFILL_SP=1`, needs `moe_mode=ep`): 4,096-row chunk, 5-layer slice,
  one host: 34.4 ms per step for TP down to 13.39 ms (2.57x), 2.60 ms busy per layer.
- Two shared fixes (zero-length KV DMAs in batched RPA; a teardown crash in MoE weight loading).

Known gaps the author lists: no GSM8K yet for the SP dtype policy (row error about 0.24 against the bf16 reference),
SP prefill is not run-to-run deterministic, one decode EP numerics row unexplained, and **no EP weight load for
serving**: `from_model` raises on `moe_mode=ep`, so SP prefill is reachable only from kernel-level tests today.

## What it means for the disaggregated gap (workstream 3)

- The baseline P/D point uses a **PP8 pipeline prefill with the megakernel off** and a TP8 decode. PR 2183 is the
  other route to a fast prefill: keep TP8 on one host and make the prefill step 2.57x cheaper. It is a per-chunk
  compute gain.
- The baseline's first-token time is not compute-bound: TTFT is 4.3 s at the median even with under 1,000 new tokens.
  So this PR alone would not close the TTFT gap; it would raise prefill throughput (the queue was 2.6 requests on
  average, 10 at p90) and it frees the pipeline's hand-off depth if the prefill becomes a TP8 megakernel engine.
- For decode, the doc's own measurement says the TP megakernel is still the fastest below 64 rows per step; SP + EP
  wins from 64 rows (-9%) and at 128 (-28%). With the DFlash draft a decode step carries several rows per request, so
  32 concurrent requests is already in that range. Decode interactivity (105 tok/s per stream at 32) is where the GPU
  disaggregated points lead most (463 to 971), so the decode EP arms are the more relevant half once they are wired.
- Not usable in a served benchmark until the EP weight load lands, so the tuning that can run today is on the
  hand-off path (early transfer modes, prefix reuse on the decode) and admission settings.
