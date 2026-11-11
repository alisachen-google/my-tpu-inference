# Running the P/D stages on Cloud DevKit (cdk)

The bare-metal harness (`../goal/`) drives engines over ssh on named TPU hosts. On the shared CDK GKE TPU cluster
(`cloud-devkit-gke`, project `cloud-tpu-inference-test`) the same stages run as one JobSet from the recipe
`recipes/cdk/pd1992-qwen3-30b-xpyd.jsonnet` (registered in the `cloud-devkit-recipes` repo as
`pd1992-qwen3-30b-xpyd`): N prefill + M decode pods, one TP8/EP8 engine per 2x2x1 tpu7x host (4 chips, 8 cores), a
router pod with one random mini-lb (8080) and one pinned mini-lb per (prefill, decode) pair (8100 + 10 p + d), and a
bench pod that generates the prompt corpus, runs `stage_<STAGE>.sh` and ends the JobSet.

- The PR tree and this directory are staged into every pod with `--map-dir` (no image rebuild). The image is
  `junyanxu-vllm-tpu/sglang-torchtpu:20261103`; at start each pod pip-installs the tree editable, the PR's
  `tpu-sync-torch` (0.0.1.dev20261103081657, PyPI) and the tree's `torch_tpu` pin (wheel under `wheels/`, fetched from the
  private torch-tpu registry on the launch VM; the pods cannot reach that registry).
- Weights: `gs://junyanxu-benchmark-models/Qwen/Qwen3-30B-A3B-Instruct-2507-FP8`, copied to `/dev/shm/model` per pod.
- Engine settings are `../../recipes/pd_1992_qwen_wb.json`; `SWITCH=false` is the off arm; `WRITE_POLICY=write_through`
  the write-through arm.
- Prompt corpus: `make_prompts.py` builds `<N>.jsonl` files (seeded pseudo-English) with the shapes the clients expect;
  the bare-metal corpus (`~/pd_disagg/prompts/gpt-oss`) is not needed.
- Server logs: `/cdk-outputs/pd1992/<role>-<i>/server.log`, refreshed every 60 s; the bench reads them for exception
  counts and `evidence`. Results: `/cdk-outputs/pd1992/bench/` (`cdk job sync-outputs <id>`), run names follow
  `compare_layouts.py` (`g1992b_2p2d_1`, `g1992b_2p2d_off_1`).

```bash
TREE=/mnt/disks/scratch/alisachen/sglang-1992; HARNESS=/mnt/disks/scratch/alisachen/pd1992-harness
cdkx job create pd1992-qwen3-30b-xpyd -t agent-jobs,alisachen,pd1992 \
  --map-dir "$TREE:*:/workspace/sglang-1992" --map-dir "$HARNESS:*:/workspace/harness" \
  --pending-timeout-seconds 3600 NUM_PREFILL=1 NUM_DECODE=1 STAGE=smoke          # 1P1D smoke
cdkx job create ... NUM_PREFILL=2 NUM_DECODE=2 STAGE=2p2d SWITCH=true                 # A5 switch on
cdkx job create ... NUM_PREFILL=2 NUM_DECODE=2 STAGE=2p2d SWITCH=false                # A5 switch off
```
