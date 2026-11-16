// musespark-pd-offload-pp-alisachen — live check of the KV offload to decode DRAM behind a pipeline-parallel
// prefill, on Muse Spark Open, from the nightly entry's config (sglang-torchtpu
// test/registered/tpu/e2e/test_tpu_muse_spark_pd_singlehost_pp8_dflash.py, config
// benchmark/tpu/recipe/configs/muse_spark/pd_singlehost_pp8_prefix_cache_kv_offload_dflash.py): PP8 tp1 prefill,
// TP8 decode over the Raiden pipeline transfer, DFLASH on both roles. Copied from musespark-pd-agentx-alisachen
// (workstream 3's baseline recipe, left untouched); the AgentX client is replaced by a check pod that runs
// test/manual/tpu/pd_stage_offload_check.py of the staged tree against the router.
//
// Settings changed from the nightly config, and why:
//   SWITCH=true                    SGLANG_ENABLE_PREFILL_KV_OFFLOAD_TO_DECODE_DRAM=1 on both roles (the feature)
//   decode HiCache + radix cache   the offload's startup check and its extension need them on the decode
//   SGLANG_PD_OFFLOAD_STAGE_STORE_GB  bounds the decode's stage-layout pools per rank
//   Raiden socket timeouts         the offload's README asks for them on both roles
//   SERVER_ARGS_OVERRIDES speculative_* = null   the offload refuses speculative decoding (draft sidecar KV is not moved)
// Both jobs carry an active deadline (DEADLINE_SECONDS) so the JobSet ends on its own.
//
//   cdk job create musespark-pd-offload-pp-alisachen -t agent-jobs,alisachen,ws1-offload-pp \
//     --map-dir "/mnt/disks/scratch/alisachen/sglang-pp-offload:*:/workspace/sglang" SWITCH=true

local agentx = import 'cdk.agentx';
local cdk = import 'cdk.common';

// --- sglang-torchtpu source, staged with --map-dir -------------------------------
local codeMountPath = cdk.var('CODE_DIR', '/workspace/sglang');

// --- General & container images ---------------------------------------------
local jobName = cdk.var('JOB_NAME', 'musespark-pd-offload-pp-alisachen');
local serverImage = cdk.var('SERVER_IMAGE', 'us-central1-docker.pkg.dev/cloud-tpu-inference-test/junyanxu-vllm-tpu/sglang-torchtpu:muse-disagg');
local clientImage = cdk.var('CLIENT_IMAGE', 'us-central1-docker.pkg.dev/cloud-tpu-inference-test/inferencex/inferencex-agentx:inferencex_bench_sep22');
local fetchImage = cdk.var('FETCH_IMAGE', 'google/cloud-sdk:slim');
local modelName = cdk.var('MODEL_NAME', 'meta-models/Muse-Spark-Open-816B-A42B-NVFP4');
local draftModelName = cdk.var('DRAFT_MODEL_NAME', 'RadixArk/Muse-Spark-Open-DFlash2');
local gcsCkptRoot = cdk.var('GCS_CKPT_ROOT', 'gs://cloud-devkit/ckpt/hf');
local modelRoot = '/models';

// --- Server config -------------------------------------------------------------
local serverConfigModule = cdk.var('SERVER_CONFIG_MODULE', 'benchmark.tpu.recipe.configs.muse_spark.pd_singlehost_pp8_prefix_cache_kv_offload_dflash');
local switchOn = cdk.boolVar('SWITCH', true);
local deadlineSeconds = cdk.numVar('DEADLINE_SECONDS', 21600);
local sessions = cdk.numVar('SESSIONS', 12);
local promptTokens = cdk.numVar('PROMPT_TOKENS', 3400);
local stageStoreGb = cdk.var('STAGE_STORE_GB', '4');
// JSON objects merged over the module's server_args / runtime_env, e.g. {"max_total_tokens":524288}.
local serverArgsOverrides = cdk.var('SERVER_ARGS_OVERRIDES', '{}');
// Per-role overrides, merged after the common ones.
local prefillArgs = cdk.var('PREFILL_ARGS', '{}');
local decodeArgs = cdk.var('DECODE_ARGS', '{"enable_hierarchical_cache": true, "hicache_io_backend": "raiden", "hicache_mem_layout": "page_first_fused", "hicache_write_policy": "write_through", "hicache_ratio": 1, "disaggregation_decode_enable_radix_cache": true}');
local prefillEnv = cdk.var('PREFILL_ENV', '{}');
local decodeEnv = cdk.var('DECODE_ENV', '{}');
// The concurrency key of agentic.py's patch table (running requests, interval, row cap) both engines use.
local serverConcurrency = cdk.numVar('SERVER_CONCURRENCY', 32);
// Optional tpu-sync wheel inside the staged tree, installed over the image's.
local tpuSyncWheel = cdk.var('TPU_SYNC_WHEEL', '');

// SGLANG_TPU_HOST_PADDING skips every speculative batch, so DFlash prefill pads on the device
// and compiles constant_pad_nd per chunk length; NO_D2H stages them on the experimental worker.
// The chunk-insert stride keeps per-chunk SWA tails out of the radix tree; without it a few
// long prompts fill the SWA pool and older prefixes are evicted whole.
local runtimeEnvOverrides = cdk.var('RUNTIME_ENV_OVERRIDES', '{}');
// agentic.py drafts speculative_num_draft_tokens=8 per verify: 7 proposals plus the anchor.
local specDraftTokens = cdk.numVar('SPEC_DRAFT_TOKENS', 7);
// InferenceX replays Muse on the full (uncapped) trace with the model's 1M context; the 256k
// variant has ~5x shorter prompts and is not comparable to its GPU curves.
local contextLen = cdk.numVar('CONTEXT_LEN', 1048576);
local traceLoader = cdk.var('TRACE_LOADER', 'semianalysis_cc_traces_weka_062126');

// --- TPU shape ---------------------------------------------------------------
local chips = cdk.numVar('TPU_CHIPS', 4);
local accelerator = cdk.var('TPU_ACCELERATOR_TYPE', 'tpu7x');
local topology = cdk.var('TPU_TOPOLOGY', '2x2x1');
local tensorParallelSize = 8;
local podIndexEnv = {};
local singleHostTpuEnv = {};
local nodeTopology = topology;
local routerPort = 8000;
local enginePort = 30000;
local bootstrapPort = 8998;

// --- Benchmark client & replay --------------------------------------------------
local fastMode = cdk.boolVar('FAST', false);
local customDuration = cdk.rawVar('DURATION', '') != '';
local duration =
  if customDuration then cdk.numVar('DURATION')
  else if fastMode then 1200
  else 3600;
local concurrencies = agentx.parseConcurrencies(cdk.var('CLIENT_CONCURRENCIES', '1'));
local benchName = cdk.var('BENCH_NAME', 'musespark-pd-agentx-alisachen');
// DEBUG_IDLE=true stages weights and /tmp/muse_config.json, then idles without a bench so
// servers can be relaunched in place (cdk_ssh); SGLANG_CACHE_DIR on the weight disk keeps
// compiled executables across relaunches.
local debugIdle = cdk.boolVar('DEBUG_IDLE', false);

local serverJobName = 'sglang-server';
local benchJobName = 'bench';

// ---------------------------------------------------------------------------
// The server
// ---------------------------------------------------------------------------

// 533 GB of NVFP4 weights plus the draft; the node boot disk cannot hold them.
local modelVolume = {
  name: 'model-storage',
  ephemeral: {
    volumeClaimTemplate: {
      spec: {
        // premium-rwo counts against the region's SSD_TOTAL_GB quota, which was exhausted on 2026-11-16.
        storageClassName: cdk.var('MODEL_STORAGE_CLASS', 'premium-rwo'),
        accessModes: ['ReadWriteOnce'],
        resources: { requests: { storage: cdk.var('MODEL_STORAGE_SIZE', '1024Gi') } },
      },
    },
  },
};

// The server image has no gcloud.
local fetchScript = agentx.fill(
  |||
    set -euxo pipefail
    for repo in "@MODEL@" "@DRAFT@"; do
      mkdir -p "@ROOT@/${repo}"
      gcloud storage rsync -r "@GCS@/${repo}" "@ROOT@/${repo}"
      test -f "@ROOT@/${repo}/config.json"
    done
    du -sh "@ROOT@"/*/*
  |||,
  { MODEL: modelName, DRAFT: draftModelName, ROOT: modelRoot, GCS: gcsCkptRoot }
);

local fetchContainer = {
  name: 'fetch-weights',
  image: fetchImage,
  command: ['/bin/bash', '-c', fetchScript],
  env: [{ name: k } + podIndexEnv[k] for k in std.objectFields(podIndexEnv)],
  resources: { requests: { cpu: '16', memory: '32Gi' } },
  volumeMounts: [agentx.mount('model-storage', modelRoot)],
};

local serverScript = agentx.fill(
  |||
    set -x
    test -d "@CODE@/sglang_tpu" || { echo "no sglang tree at @CODE@ (pass --map-dir <tree>:sglang-server:@CODE@)"; exit 1; }
    cat "@CODE@/.sglang_rev" 2>/dev/null || git -C "@CODE@" log -1 --oneline || true
    cd "@CODE@"
    pip install --no-deps --no-build-isolation -e "@CODE@" || exit 1
    SGLANG_BUILD_RUST_EXTS=none pip install --no-deps --no-build-isolation -e "@CODE@/python" || exit 1
    python3 -c "import zstandard" 2>/dev/null || pip install -q zstandard || exit 1
    if [ -n "${TPU_SYNC_WHEEL:-}" ]; then pip install --no-deps "@CODE@/$TPU_SYNC_WHEEL" || exit 1; fi
    if [ -n "${TPU_SYNC_VERSION:-}" ]; then pip install -q --no-deps --pre "tpu-sync-torch==$TPU_SYNC_VERSION" || exit 1; fi
    pip list 2>/dev/null | grep -iE '^(torch|torch[-_]tpu|tpu[-_]sync[-_]torch|libtpu|jax) '
    export PYTHONPATH="@CODE@/sgl-model-gateway/bindings/python/src:@CODE@/python${PYTHONPATH:+:$PYTHONPATH}"
    python3 -c "import sglang_tpu,sys; sys.exit(0 if sglang_tpu.__file__.startswith('@CODE@') else 1)" \
      || { echo "sglang_tpu resolved outside the staged tree"; exit 1; }
    rm -f /tmp/libtpu* /dev/shm/libtpu* 2>/dev/null || true

    if [ "${JOB_COMPLETION_INDEX:?}" = 0 ]; then ROLE=prefill; else ROLE=decode; fi
    export ROLE
    export MUSE_SPARK_MODEL="$MODEL_ROOT/$MODEL_NAME" MUSE_SPARK_DRAFT_MODEL="$MODEL_ROOT/$DRAFT_MODEL_NAME"
    python3 - > /tmp/muse_config.json <<'PY' || exit 1
    import importlib, json, os

    module = importlib.import_module(os.environ["SERVER_CONFIG_MODULE"])
    role = os.environ["ROLE"]
    cfg = json.loads(json.dumps(module.PREFILL_CONFIG if role == "prefill" else module.DECODE_CONFIG))
    args = cfg["server_args"]
    args["port"] = int(os.environ["ENGINE_PORT"])
    if role == "prefill":
        args["disaggregation_bootstrap_port"] = int(os.environ["BOOTSTRAP_PORT"])
    args.update(json.loads(os.environ["SERVER_ARGS_OVERRIDES"]))
    args.update(json.loads(os.environ["PREFILL_ARGS" if role == "prefill" else "DECODE_ARGS"]))
    # A null override removes the argument (e.g. {"speculative_algorithm": null} serves without the draft).
    for key in [k for k, v in args.items() if v is None]:
        del args[key]
    env = cfg["runtime_env"]
    # One engine on this host; the router is started below.
    for key in ("LB_PORT", "HEALTH_TIMEOUT", "FORCE_SINGLE_HOST"):
        env.pop(key, None)
    env["SGLANG_LAUNCHER_RANK"] = "0"
    if os.environ["OFFLOAD_SWITCH"] == "1":
        env["SGLANG_ENABLE_PREFILL_KV_OFFLOAD_TO_DECODE_DRAM"] = "1"
        if role == "decode":
            env["SGLANG_PD_OFFLOAD_STAGE_STORE_GB"] = os.environ["STAGE_STORE_GB"]
    for side, names in (
        ("PREFILL", "HANDSHAKE_ACK_READ FINAL_ACK_READ PAYLOAD_READ HANDSHAKE_WRITE PAYLOAD_WRITE"),
        ("DECODE", "HANDSHAKE_READ PAYLOAD_READ ACK_WRITE PAYLOAD_WRITE"),
    ):
        for name in names.split():
            env[f"TPU_RAIDEN_{side}_{name}_TIMEOUT_S"] = "60"
    env.update(json.loads(os.environ["RUNTIME_ENV_OVERRIDES"]))
    env.update(json.loads(os.environ["PREFILL_ENV" if role == "prefill" else "DECODE_ENV"]))
    cfg["group"] = {"hosts": 1}
    print(json.dumps(cfg, indent=1))
    PY
    cat /tmp/muse_config.json
    if [ "${DEBUG_IDLE:-0}" = "1" ]; then
      echo "DEBUG_IDLE: config staged at /tmp/muse_config.json; idling"
      exec sleep infinity
    fi
    if [ "$ROLE" = prefill ]; then
      python3 -m sglang_router.launch_router --pd-disaggregation --mini-lb \
        --prefill "http://${JS_NAME}-@JOB@-0-0.${JS_NAME}:@EPORT@" @BPORT@ \
        --decode "http://${JS_NAME}-@JOB@-0-1.${JS_NAME}:@EPORT@" \
        --host 0.0.0.0 --port @RPORT@ &
    fi
    echo "trace-start-event: name=sglang-$ROLE ts=$(date +'%s.%N') pid=sglang tid=sglang"
    python3 -m benchmark.tpu.launch_server --config @/tmp/muse_config.json
    SERVER_EXIT_CODE=$?
    echo "trace-end-event: name=sglang-$ROLE ts=$(date +'%s.%N') pid=sglang tid=sglang"
    exit ${SERVER_EXIT_CODE}
  |||,
  { CODE: codeMountPath, JOB: serverJobName, EPORT: enginePort, BPORT: bootstrapPort, RPORT: routerPort }
);

local serverEnv =
  {
    MODEL_NAME: modelName,
    DRAFT_MODEL_NAME: draftModelName,
    MODEL_ROOT: modelRoot,
    ENGINE_PORT: enginePort,
    BOOTSTRAP_PORT: bootstrapPort,
    SERVER_CONCURRENCY: serverConcurrency,
    PREFILL_ARGS: prefillArgs,
    DECODE_ARGS: decodeArgs,
    PREFILL_ENV: prefillEnv,
    DECODE_ENV: decodeEnv,
    TPU_SYNC_WHEEL: tpuSyncWheel,
    // The tree's pin; the pipeline transfer to a tensor-parallel decode needs >= 0.0.1.dev20261110081704.
    TPU_SYNC_VERSION: cdk.var('TPU_SYNC_VERSION', '0.0.1.dev20261112081648'),
    OFFLOAD_SWITCH: if switchOn then '1' else '0',
    STAGE_STORE_GB: stageStoreGb,
    SERVER_CONFIG_MODULE: serverConfigModule,
    SERVER_ARGS_OVERRIDES: serverArgsOverrides,
    RUNTIME_ENV_OVERRIDES: runtimeEnvOverrides,
  }
  + agentx.megascaleOff
  + cdk.jobSetNameEnv
  + singleHostTpuEnv
  + podIndexEnv
  + {
    // Gated repo: everything is local, never ask the Hub.
    HF_HUB_OFFLINE: '1',
    TRANSFORMERS_OFFLINE: '1',
    SGLANG_WARMUP_TIMEOUT: '3600',
    SGLANG_CACHE_DIR: modelRoot + '/sglang-cache',
    DEBUG_IDLE: if debugIdle then '1' else '0',
    GET_HOST_METRICS: '0',
    PJRT_DEVICE: 'TPU',
    TPU_VMODULE: 'tpu_pjrt_client=1,pjrt_stream_executor_client=1,tpu_pjrt_compiler_utils=1',
    TPU_STDERR_LOG_LEVEL: '0',
  };

local serverJob = cdk.job(
  name=serverJobName,
  replicas=1,
  parallelism=2,
  completions=2,
  ttlSeconds=900,
  podSpec=cdk.tpuNodeSelector(accelerator, nodeTopology)
          + { nodeSelector+: { 'cloud.google.com/gke-accelerator-count': std.toString(chips) } }
          + { initContainers: [fetchContainer] },
  volumes=[
    modelVolume,
    agentx.memoryVolume('dshm'),
  ],
  containers=[
    cdk.container(
      name=serverJobName,
      image=serverImage,
      script=serverScript,
      env=serverEnv,
      resources=cdk.tpuResources(chips, cpu='200', memory='900Gi', ephemeralStorage='100Gi'),
      volumeMounts=[
        agentx.mount('model-storage', modelRoot),
        agentx.mount('dshm', '/dev/shm'),
      ],
    ),
  ],
);

// ---------------------------------------------------------------------------
// The check
// ---------------------------------------------------------------------------
local checkScript = agentx.fill(
  |||
    cd "@CODE@" || exit 1
    ROUTER="http://${JS_NAME}-@JOB@-0-0.${JS_NAME}:@RPORT@"
    PREFILL="http://${JS_NAME}-@JOB@-0-0.${JS_NAME}:@EPORT@"
    DECODE="http://${JS_NAME}-@JOB@-0-1.${JS_NAME}:@EPORT@"
    echo "waiting for $PREFILL, $DECODE and $ROUTER"
    START=$(date +%s)
    until curl -sf -m 10 "$PREFILL/health" >/dev/null && curl -sf -m 10 "$DECODE/health" >/dev/null \
        && curl -sf -m 10 "$ROUTER/health" >/dev/null; do
      if [ $(( $(date +%s) - START )) -gt @WAIT@ ]; then echo "CHECK-FAIL: engines not healthy in @WAIT@ s"; exit 1; fi
      sleep 30
    done
    echo "CHECK-START after $(( $(date +%s) - START )) s"
    for role in "$PREFILL" "$DECODE"; do curl -s -m 30 "$role/server_info" | head -c 3000; echo; done
    python3 test/manual/tpu/pd_stage_offload_check.py --router "$ROUTER" --prefill "$PREFILL" --decode "$DECODE" \
      --sessions @SESSIONS@ --prompt-tokens @TOKENS@ @EXPECT@
    RC=$?
    echo "CHECK-RC $RC"
    # Let the engines print one more periodic [dram-offload] line before the JobSet ends.
    sleep 45
    exit $RC
  |||,
  {
    CODE: codeMountPath,
    JOB: serverJobName,
    EPORT: enginePort,
    RPORT: routerPort,
    WAIT: deadlineSeconds - 1800,
    SESSIONS: sessions,
    TOKENS: promptTokens,
    EXPECT: if switchOn then '--expect-offload' else '',
  }
);

local checkJob = cdk.job(
  name=benchJobName,
  containers=[
    cdk.container(
      name=benchJobName,
      image=serverImage,
      script=checkScript,
      env=cdk.jobSetNameEnv,
      resources={ requests: { cpu: '4', memory: '16Gi' } },
    ),
  ],
);

local withDeadline(job) = job { template+: { spec+: { activeDeadlineSeconds: deadlineSeconds } } };

cdk.jobSet(
  jobName,
  successPolicy=cdk.succeedWhen([if debugIdle then serverJobName else benchJobName]),
  failurePolicy=cdk.neverRestart,
  jobs=[withDeadline(serverJob)] + (if debugIdle then [] else [withDeadline(checkJob)]),
)
