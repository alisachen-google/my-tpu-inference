# Workstream 3: Muse Spark P/D on TPU7x vs GPU (AgentX), baseline extraction 2026-11-16

Source: dash `d-19d6aedd-af5d-481d-9929` ("[Muse Spark] AgentX Disagg", 14 sheets, 45 jobs). `extract.py` pulls every
job's result and submit command through `cdk job desc`; raw data in `dash_data.json`. Cost uses the dash's own prices
per chip-hour: TPU7x 1.21, GB300 2.31, VR200 3.61. Nothing has been run yet in this workstream.

## Data points

| Config | Job | Concurrency | Tok/s per chip | M tokens per $ | p90 interactivity tok/s | Mean TTFT s | p90 TTFT s | p90 E2E s |
|---|---|---|---|---|---|---|---|---|
| GB300, TRT, aggregated TP4, 4 GPUs | `j-84aea0c8-daed-482f-a9ec` | 1 | 5,979 | 9.3 | 429 | 1.1 | 1.5 | 13.5 |
| GB300, TRT, aggregated TP4, 4 GPUs | `j-68002519-20a9-4c05-8838` | 4 | 8,752 | 13.6 | 332 | 0.7 | 1.3 | 10.8 |
| GB300, TRT, aggregated TP4, 4 GPUs | `j-e8a8950c-bafa-40ff-b2c4` | 8 | 14,896 | 23.2 | 270 | 0.8 | 1.5 | 9.8 |
| GB300, TRT, aggregated TP4, 4 GPUs | `j-0478ffcc-7819-488d-9887` | 20 | 34,282 | 53.4 | 185 | 1.4 | 2.3 | 14.5 |
| GB300, TRT, aggregated TP4, 4 GPUs | `j-8a55c8c6-69f0-4b98-b206` | 32 | 49,448 | 77.1 | 126 | 3.1 | 9.0 | 22.2 |
| GB300, TRT, aggregated TP4, 4 GPUs | `j-e6514750-19e3-4c95-8291` | 48 | 64,194 | 100.0 | 91 | 2.3 | 4.9 | 25.3 |
| VR200, Dynamo+TRT, aggregated TP4, 4 GPUs | `j-70cdd590-d42b-4e8b-bc1c` | 24 | 44,364 | 44.2 | 391 | 3.1 | 8.1 | 12.3 |
| VR200, Dynamo+TRT, aggregated TP4, 4 GPUs | `j-a3c27ac7-e8ca-425a-9c3e` | 48 | 85,017 | 84.8 | 193 | 0.8 | 1.3 | 12.8 |
| VR200, Dynamo+TRT, aggregated TP4, 4 GPUs | `j-f7a07815-5bd3-4ec1-9ca2` | 96 | 137,647 | 137.3 | 107 | 1.3 | 3.0 | 20.2 |
| VR200, aggregated TP8, 8 GPUs | `j-70b474a2-9f32-4f22-9ec8` | 1 | 4,177 | 4.2 | 990 | 0.2 | 0.3 | 4.8 |
| VR200 disagg, 4 decode x TP4, 20 GPUs | `j-897fccad-b3d1-4330-bde0` | 100 | 34,645 | 34.5 | 463 | 3.1 | 7.7 | 11.1 |
| VR200 disagg, 5 decode x TP4, 24 GPUs | `j-7a091968-7961-47f5-8f83` | 100 | 28,561 | 28.5 | 541 | 3.9 | 9.3 | 12.2 |
| VR200 disagg, 7 decode x TP4, 32 GPUs | `j-82d77041-02e7-497a-8b09` | 84 | 19,684 | 19.6 | 752 | 3.5 | 8.5 | 10.9 |
| VR200 disagg, 4 decode x TP8, 36 GPUs | `j-0c1f8009-20af-456a-b80d` | 56 | 12,967 | 12.9 | 971 | 2.1 | 5.3 | 7.1 |
| **TPU7x SGLang P/D, PP8 prefill + TP8 decode, 8 chips** | `j-ec9464b2-4aaf-46fe-af8a` | 32 | 18,326 | 54.5 | 64 | 7.1 | 12.8 | 35.8 |
| TPU7x SGLang aggregated TP8, 4 chips (latest sweep) | `j-24fcba7c-f94c-4b32-bc17` | 1 | 6,449 | 19.2 | 487 | 1.3 | 1.9 | 11.3 |
| TPU7x SGLang aggregated TP8, 4 chips (latest sweep) | `j-500bf362-a814-44c3-a12d` | 7 | 12,118 | 36.1 | 340 | 1.7 | 4.0 | 10.7 |
| TPU7x SGLang aggregated TP8, 4 chips (latest sweep) | `j-7519d90e-ac9e-4e75-bc38` | 9 | 15,775 | 46.9 | 286 | 2.7 | 6.7 | 13.6 |
| TPU7x SGLang aggregated TP8, 4 chips (latest sweep) | `j-72a31b3f-5555-4c21-bb77` | 10 | 17,139 | 51.0 | 229 | 1.8 | 3.4 | 12.7 |
| TPU7x SGLang aggregated TP8, 4 chips (latest sweep) | `j-e7259334-164f-4f3d-b372` | 16 | 23,314 | 69.4 | 166 | 3.8 | 8.6 | 21.8 |
| TPU7x SGLang aggregated TP8, 4 chips (latest sweep) | `j-6bbec2a7-2efb-4b81-9291` | 22 | 29,213 | 86.9 | 109 | 5.7 | 15.3 | 33.7 |
## The TPU disaggregated point (`j-ec9464b2-4aaf-46fe-af8a`, 2026-11-08)

- Layout: one JobSet, two tpu7x 2x2x1 hosts (8 chips). Host 0: prefill, `--pp-size 8 --tp-size 1`, plus the mini-lb
  router. Host 1: decode, `--tp-size 8`. Code from an NFS checkout (`sglang-torchtpu-disagg-dbg`), launcher
  `benchmark/tpu/recipe/muse_spark_agentx_launcher.sh <prefill|decode> 32`, settings in
  `benchmark/tpu/recipe/configs/muse_spark/agentic.py`. Full resolved arguments of both roles: `server_args.json`.
- Model `Muse-Spark-Open-816B-A42B-NVFP4` (`modelopt_fp4`), KV `fp8_e4m3`, page 256, DFlash draft (8 draft tokens,
  1 step), `pallas_tpu_rpa_batched`, megakernel off on the P/D roles.
- Both roles: `max_running_requests 32`, chunked prefill 4,096, HiCache `write_through` over Raiden, ratio 3.0,
  `prefill_decode_interval 40`. Prefill: `mem_fraction_static 0.88`, `pp_async_batch_depth 1`, overlap schedule off.
  Decode: `mem_fraction_static 0.95`, decode radix cache on, 64 extra slots, `scheduler_recv_interval 8`,
  `SGLANG_RAIDEN_PIPELINE_TRANSFER=1`.
- Client: aiperf `inferencex-agentx-mvp`, concurrency 32, 3,600 s, 3,468 successful requests, mean input 152k
  tokens with 97.2% served from cache (mean 4.3k new tokens per request), mean output 993 tokens.

## Where the time goes (client export of that job, 3,468 requests)

| Measure | Value |
|---|---|
| Share of end-to-end time spent before the first token | 41% |
| TTFT p50 / p90 | 5.2 s / 12.8 s |
| TTFT p50 when fewer than 1,000 tokens are new | 4.3 s |
| TTFT p50 when 1,000 to 4,096 tokens are new | 5.1 s |
| TTFT p50 when more than 64,000 tokens are new | 10.9 s |
| Inter-token latency p50 / p90 | 8.7 ms / 15.4 ms (about 105 tok/s per stream) |
| Prefill queue length, mean / p90 | 2.6 / 10 requests |
| Prefill batch size | 1.1 requests, 2,405 new tokens on average (4,096 cap) |

Reading: TTFT barely depends on how many tokens are new (4.3 s with almost nothing to compute), so the first-token
time is dominated by fixed per-request cost on the prefill-to-decode path (queueing behind other requests' chunks,
the pipeline's depth, and moving or restoring a 150k-token prefix for the decode), not by prefill compute. Decode
speed per stream at 32 concurrent (105 tok/s) is close to the aggregated TPU server at 22 concurrent (109 tok/s p90).
The decode's logs for this job are truncated in GCS, so the split of the 4 s between queue, pipeline and transfer is
not measured yet.

## Gap to close

- Per chip, the TPU P/D point (18.3k tok/s, 54.5 M tokens per $) is below the aggregated TPU server on 4 chips
  (29.2k, 86.9 at concurrency 22) and below GB300 at the same concurrency (49.4k, 77.1) and VR200 aggregated (85.0k,
  84.8 at 48). The GPU disaggregated points trade cost for interactivity (463 to 971 tok/s p90 at 12.9 to 34.5 M
  tokens per $); the TPU P/D point has neither yet (64 tok/s p90).
- Only one TPU P/D point exists (concurrency 32). The GPU curves have 4 to 6.

## Tuning plan (not started)

1. Measure first: rerun the point with complete engine logs and per-request stage timing to split TTFT into prefill
   queue, pipeline compute, KV transfer and decode admission.
2. A concurrency sweep (8, 16, 24, 32, 48) to draw the curve the dash compares on.
3. Candidates suggested by the data and the tree: the pipeline hand-off modes that overlap the KV transfer with
   the prefill (`SGLANG_RAIDEN_PIPELINE_EARLY_PARTS`, `_STAGE_PARTS`, `_EARLY_CLOSE`, all off in this run), early
   send of the cached prefix, decode-side prefix reuse so a 97%-cached prompt does not move again, prefill batch
   admission (`prefill_decode_interval`, `pp_async_batch_depth`), and the megakernel on the decode role.
