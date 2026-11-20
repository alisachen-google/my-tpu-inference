# Health-probe review probes

Written 2026-11-20 for [PR 2258](../../reviews/sglang-torchtpu/PR-2258.md), head
`f3ffa42b5cd11d317f67c355c2d62fe812c97dbf`.

```bash
python3 tests/health_probe_review/probe_pr2258_admission.py /path/to/head-checkout
```

The script extracts the actual scheduler selectors and the actual CUDA checksum
test lambda. Six host-only scheduling cases pass; the prefixed-client admission
consequence and the checksum helper's unexpected-keyword TypeError reproduce.
The Rust gRPC path is established by source tracing in the review, not by this
script. Batch/allocation/device boundaries are stand-ins; it launches no server,
RPC, native transfer or distributed collective and needs only standard Python.
The reproduction assertions describe this head and should change after the fixes.
