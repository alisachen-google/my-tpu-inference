// musespark-pd-agentx-alisachen — AgentX replay of Muse Spark Open on sglang-torchtpu, prefill/decode
// disaggregated over Raiden on two tpu7x 2x2x1 hosts (8 chips): pod 0 runs the prefill engine and the mini-lb
// router, pod 1 the decode engine. Derived from muse-spark-agentx-singlehost-sglang-junyanxu (same weights,
// client and metrics) and from the stored JobSet of the dashboard point j-ec9464b2-4aaf-46fe-af8a.
//
// Server: benchmark/tpu/recipe/configs/muse_spark/agentic.py get_config(SERVER_CONCURRENCY, mode) of the staged
// tree, with per-role JSON overrides merged over server_args / runtime_env, so a tuning run changes no code:
//   PREFILL_ARGS / DECODE_ARGS      e.g. '{"prefill_decode_interval": 16}'
//   PREFILL_ENV / DECODE_ENV        e.g. '{"SGLANG_RAIDEN_PIPELINE_EARLY_PARTS": "1"}'
// The sglang tree comes from this VM with --map-dir "<tree>:sglang-server:/workspace/sglang".
//
//     cdk recipe render musespark-pd-agentx-alisachen CLIENT_CONCURRENCIES=32 SERVER_CONCURRENCY=32
//     cdk job create musespark-pd-agentx-alisachen -t agent-jobs,alisachen,ws3 \
//       --map-dir "/mnt/disks/scratch/alisachen/sglang-main:sglang-server:/workspace/sglang" \
//       CLIENT_CONCURRENCIES=32 SERVER_CONCURRENCY=32

local agentx = import 'cdk.agentx';
local cdk = import 'cdk.common';

// --- sglang-torchtpu source, staged with --map-dir -------------------------------
local codeMountPath = cdk.var('CODE_DIR', '/workspace/sglang');

// --- General & container images ---------------------------------------------
local jobName = cdk.var('JOB_NAME', 'musespark-pd-agentx-alisachen');
local serverImage = cdk.var('SERVER_IMAGE', 'us-central1-docker.pkg.dev/cloud-tpu-inference-test/junyanxu-vllm-tpu/sglang-torchtpu:muse-disagg');
local clientImage = cdk.var('CLIENT_IMAGE', 'us-central1-docker.pkg.dev/cloud-tpu-inference-test/inferencex/inferencex-agentx:inferencex_bench_sep22');
local fetchImage = cdk.var('FETCH_IMAGE', 'google/cloud-sdk:slim');
local modelName = cdk.var('MODEL_NAME', 'meta-models/Muse-Spark-Open-816B-A42B-NVFP4');
local draftModelName = cdk.var('DRAFT_MODEL_NAME', 'RadixArk/Muse-Spark-Open-DFlash2');
local gcsCkptRoot = cdk.var('GCS_CKPT_ROOT', 'gs://cloud-devkit/ckpt/hf');
local modelRoot = '/models';

// --- Server config -------------------------------------------------------------
local serverConfigModule = cdk.var('SERVER_CONFIG_MODULE', 'benchmark.tpu.recipe.configs.muse_spark.agentic');
// JSON objects merged over the module's server_args / runtime_env, e.g. {"max_total_tokens":524288}.
local serverArgsOverrides = cdk.var('SERVER_ARGS_OVERRIDES', '{}');
// Per-role overrides, merged after the common ones.
local prefillArgs = cdk.var('PREFILL_ARGS', '{}');
local decodeArgs = cdk.var('DECODE_ARGS', '{}');
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
local runtimeEnvOverrides = cdk.var('RUNTIME_ENV_OVERRIDES', '{"SGLANG_TPU_HOST_PADDING": null, "SGLANG_TPU_HOST_PADDING_NO_D2H": "1", "SGLANG_OPT_UNIFIED_CACHE_CHUNK_INSERT_STRIDE": "131072"}');
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
        storageClassName: 'premium-rwo',
        accessModes: ['ReadWriteOnce'],
        resources: { requests: { storage: '1024Gi' } },
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
    export PYTHONPATH="@CODE@/sgl-model-gateway/bindings/python/src:@CODE@/python${PYTHONPATH:+:$PYTHONPATH}"
    python3 -c "import sglang_tpu,sys; sys.exit(0 if sglang_tpu.__file__.startswith('@CODE@') else 1)" \
      || { echo "sglang_tpu resolved outside the staged tree"; exit 1; }
    rm -f /tmp/libtpu* /dev/shm/libtpu* 2>/dev/null || true

    if [ "${JOB_COMPLETION_INDEX:?}" = 0 ]; then ROLE=prefill; else ROLE=decode; fi
    export ROLE
    python3 - > /tmp/muse_config.json <<'PY' || exit 1
    import json, os
    from benchmark.tpu.recipe.configs.muse_spark import agentic

    role = os.environ["ROLE"]
    cfg = agentic.get_config(int(os.environ["SERVER_CONCURRENCY"]), mode=role)
    root = os.environ["MODEL_ROOT"]
    args = cfg["server_args"]
    args.update(
        model_path=f"{root}/{os.environ['MODEL_NAME']}",
        served_model_name=os.environ["MODEL_NAME"],
        speculative_draft_model_path=f"{root}/{os.environ['DRAFT_MODEL_NAME']}-swa",
        context_length=int(os.environ["CONTEXT_LEN"]),
        port=int(os.environ["ENGINE_PORT"]),
    )
    if role == "prefill":
        args["disaggregation_bootstrap_port"] = int(os.environ["BOOTSTRAP_PORT"])
    args.update(json.loads(os.environ["SERVER_ARGS_OVERRIDES"]))
    args.update(json.loads(os.environ["PREFILL_ARGS" if role == "prefill" else "DECODE_ARGS"]))
    cfg["runtime_env"].update(json.loads(os.environ["RUNTIME_ENV_OVERRIDES"]))
    cfg["runtime_env"].update(json.loads(os.environ["PREFILL_ENV" if role == "prefill" else "DECODE_ENV"]))
    agentic._write_swa_draft(agentic.Path(root))
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
    CONTEXT_LEN: contextLen,
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
// The client
// ---------------------------------------------------------------------------

// The tokenizer comes from the GCS mirror (the HF repo is gated). MODEL is what InferenceX
// hands aiperf as --tokenizer; SERVED_MODEL_NAME is the wire name the server registered.
local prelude = agentx.fill(
  |||
    export TPU_PJRT_EVENT_TRACE_ENABLE="0"
    export INFMAX_CONTAINER_WORKSPACE="/root/cloud-devkit/InferenceX"
    export AIPERF_DIR="/root/cloud-devkit/InferenceX/utils/aiperf"
    # Images after 2026-09-19 keep aiperf defaults (AIPERF_PYTHON_VERSION, ...) here and
    # benchmark_lib.sh asserts them without sourcing it; source first so the exports below win.
    if [ -f "${INFMAX_CONTAINER_WORKSPACE}/benchmarks/runtime_settings.sh" ]; then
      source "${INFMAX_CONTAINER_WORKSPACE}/benchmarks/runtime_settings.sh"
    fi
    export AIPERF_EXPERIMENTAL_FAST="@FAST@"
    export DURATION="@DURATION@"

    mkdir -p "$HF_HOME"
    unset HF_HUB_OFFLINE TRANSFORMERS_OFFLINE

    TOKENIZER_DIR=/tmp/tokenizer/@MODEL@
    mkdir -p "$TOKENIZER_DIR"
    for f in config.json tokenizer.json tokenizer_config.json special_tokens_map.json \
             chat_template.jinja generation_config.json; do
      gcloud storage cp "@GCS@/@MODEL@/$f" "$TOKENIZER_DIR/" \
        || { echo "cannot fetch $f from @GCS@/@MODEL@"; exit 1; }
    done
    export MODEL="$TOKENIZER_DIR"
    export SERVED_MODEL_NAME="@MODEL@"
    source "${INFMAX_CONTAINER_WORKSPACE}/benchmarks/benchmark_lib.sh"
  |||,
  { FAST: if fastMode then '1' else '0', DURATION: duration, MODEL: modelName, GCS: gcsCkptRoot }
);

local datasetInit = agentx.fill(
  |||
    export WEKA_LOADER_OVERRIDE=@LOADER@
    resolve_trace_source 2>/dev/null || true
  |||,
  { LOADER: traceLoader }
);

// Per-level deltas of sglang's counters, exported under the names agentx_metrics.py reads.
// sglang counts a request at finish: drafts = verify calls, accepted = generated - verify
// calls (so 1 + accepted/drafts is sglang's accept length); prefix hits are device-cached
// prompt tokens over all prompt tokens.
local sglangScrape = |||
  sglang_metric() {
    local v
    v=$(curl -sf "${VLLM_URL}/metrics" 2>/dev/null | awk -v n="sglang:$1" -v f="${2:-}" \
      '{k=$1; sub(/\{.*/, "", k); if (k==n && (f=="" || index($0, f))) s+=$NF} END {printf "%.0f", s+0}') || v=""
    case "$v" in
      ''|*[!0-9]*) echo 0 ;;
      *) echo "$v" ;;
    esac
  }
  if ! declare -F _orig_run_agentic_replay >/dev/null; then
    eval "_orig_run_agentic_replay() $(declare -f run_agentic_replay_and_write_outputs | tail -n +2)"
    run_agentic_replay_and_write_outputs() {
      local v0 g0 p0 c0 rc
      v0=$(sglang_metric spec_verify_calls_total)
      g0=$(sglang_metric generation_tokens_total)
      p0=$(sglang_metric prompt_tokens_total)
      c0=$(sglang_metric cached_tokens_total 'cache_source="device"')
      _orig_run_agentic_replay "$@"
      rc=$?
      local dv=$(( $(sglang_metric spec_verify_calls_total) - v0 ))
      local dg=$(( $(sglang_metric generation_tokens_total) - g0 ))
      export SPEC_DECODE_DRAFTS_DELTA=$dv
      export SPEC_DECODE_DRAFT_TOKENS_DELTA=$(( dv * @SPEC_STEPS@ ))
      export SPEC_DECODE_ACCEPTED_TOKENS_DELTA=$(( dg - dv ))
      export PREFIX_CACHE_QUERIES_DELTA=$(( $(sglang_metric prompt_tokens_total) - p0 ))
      export PREFIX_CACHE_HITS_DELTA=$(( $(sglang_metric cached_tokens_total 'cache_source="device"') - c0 ))
      echo "SGLANG c${conc}: verify=${dv} gen=${dg} prompt=${PREFIX_CACHE_QUERIES_DELTA} cached=${PREFIX_CACHE_HITS_DELTA}"
      return $rc
    }
  fi
|||;

local durationRewrites = if !customDuration then [] else [
  agentx.fill(
    |||
      REPLAY_CMD=$(echo "$REPLAY_CMD" | sed -E 's/--benchmark-duration [0-9]+/--benchmark-duration @DURATION@/')
      if [ "@DURATION@" -lt 900 ] && [[ "$REPLAY_CMD" != *"--unsafe-override"* ]]; then
        REPLAY_CMD="$REPLAY_CMD --unsafe-override"
      fi
    |||,
    { DURATION: duration }
  ),
];

local benchJob = agentx.benchJob(
  name=benchJobName,
  host=cdk.host(serverJobName),
  port=routerPort,
  image=clientImage,
  concurrencies=concurrencies,
  resultFilePrefix='muse_spark_tpu_v7x_sglang_pd_ix_conc_',
  benchName=benchName,
  tpuChips=2 * chips,
  prelude=prelude,
  datasetInit=datasetInit,
  exports={
    KV_OFFLOADING: 'none',
    PRECISION: 'fp4',
    FRAMEWORK: 'sglang',
    IS_MULTINODE: 'false',
    TP: tensorParallelSize,
    EP_SIZE: 1,
    // Asserted by validate_required_agentic_server_metrics in images after 2026-09-19. A TPU
    // host has no GPU power monitor, so power stays best-effort; no PP or prefill CP here.
    REQUIRE_POWER: '0',
    PP_SIZE: '1',
    PCP_SIZE: '1',
  },
  replayRewrites=[agentx.fill(sglangScrape, { SPEC_STEPS: specDraftTokens })] + durationRewrites,
  // 533 GB rsync plus the cold compile of target, draft and megakernel.
  waitTimeoutSeconds=10800,
  env={
    HF_HOME: '/tmp/hf_cache',
    CLIENT_CONCURRENCIES: std.join(' ', [std.toString(c) for c in concurrencies]),
    AIPERF_EXPERIMENTAL_FAST: if fastMode then '1' else '0',
    DURATION: duration,
  },
  resources={
    local disk = { 'ephemeral-storage': '64Gi' },
    // The client and its tmpfs /tmp reached ~27Gi on the full trace; with no request,
    // kubelet evicted it from a packed CPU node.
    requests: disk { memory: '64Gi' },
    limits: disk,
  },
  volumes=[
    agentx.memoryVolume('dshm'),
    agentx.memoryVolume('sidecar-tmp'),
  ],
  volumeMounts=[
    agentx.mount('sidecar-tmp', '/tmp'),
    agentx.mount('dshm', '/dev/shm'),
  ],
);

cdk.jobSet(
  jobName,
  successPolicy=cdk.succeedWhen([if debugIdle then serverJobName else benchJobName]),
  failurePolicy=cdk.neverRestart,
  jobs=[serverJob] + (if debugIdle then [] else [benchJob]),
)
