// pd1992-qwen3-30b-xpyd — SGLang P/D over Raiden with the KV offload to decode DRAM (sglang-torchtpu PR 1992),
// Qwen3-30B-A3B-Instruct-2507-FP8, N prefill x M decode, one TP8/EP8 engine per 2x2x1 tpu7x host.
//
// The engines run the PR tree staged from this VM with --map-dir (no image rebuild): every pod gets the tree at
// TREE_DIR and pip-installs it editable over the image's own sglang; tpu-sync-torch is upgraded from PyPI to the
// version the PR needs (host-to-host read API), and torch_tpu to the tree's pin from a wheel shipped in the harness
// directory (the private torch-tpu registry is not reachable from the pods). The settings are the bare-metal
// recipe pd_1992_qwen_wb.json of the validation campaign (fp8 KV, 128k sessions, write-back on both roles,
// decode radix cache on, 128 GB Raiden host pool).
//
//   TREE=$HOME/sglang-1992; HARNESS=/mnt/disks/scratch/alisachen/pd1992-harness
//   cdk recipe render pd1992-qwen3-30b-xpyd NUM_PREFILL=1 NUM_DECODE=1 STAGE=smoke
//   cdk job create pd1992-qwen3-30b-xpyd -t agent-jobs,alisachen,pd1992 \
//     --map-dir "$TREE:*:/workspace/sglang-1992" --map-dir "$HARNESS:*:/workspace/harness" \
//     NUM_PREFILL=1 NUM_DECODE=1 STAGE=smoke                       # 1P1D smoke, 8 chips
//   cdk job create pd1992-qwen3-30b-xpyd ... NUM_PREFILL=2 NUM_DECODE=2 STAGE=2p2d SWITCH=true    # A5 on, 16 chips
//   cdk job create pd1992-qwen3-30b-xpyd ... NUM_PREFILL=2 NUM_DECODE=2 STAGE=2p2d SWITCH=false   # A5 off arm
//   cdk job create pd1992-qwen3-30b-xpyd ... NUM_PREFILL=1 NUM_DECODE=2 STAGE=layout             # 1P2D sticky (A3)
//   cdk job create pd1992-qwen3-30b-xpyd ... MODEL_PROFILE=gpt-oss-120b TREE_DIR=/workspace/sglang-1991 \\
//     --map-dir "$HOME/sglang-1991:*:/workspace/sglang-1991" ... STAGE=layout                        # hybrid, PR 1991 (H6)
//
// Layout: prefill-i at ${JS_NAME}-prefill-i-0, decode-j at ${JS_NAME}-decode-j-0 (port 30000, bootstrap 8998,
// Raiden KV 31000). The router pod runs one random mini-lb on 8080 plus one pinned mini-lb per (prefill, decode)
// pair on 8100 + 10*i + j, which is how the sticky cases of the 2P2D stage choose their route. The bench pod
// generates the prompt corpus, waits for every router, runs stage_<STAGE>.sh from the harness, and its completion
// ends the JobSet. Server logs are copied every 60 s to $SHARED/<role>-<i>/server.log (gcsfuse shows a file only
// once it is closed), where the bench reads them for exception counts and transfer evidence.

local cdk = import 'cdk.common';

// --- Topology ----------------------------------------------------------------------
local numPrefill = cdk.numVar('NUM_PREFILL', 2);
local numDecode = cdk.numVar('NUM_DECODE', 2);
local accelerator = cdk.var('ACCELERATOR', 'tpu7x');
// CDK rejects nodeAffinity on kubernetes.io/hostname and on cloud.google.com/gke-spot (Kueue must stay free to place
// the job on any idle slice), so a spot preemption mid-stage is handled by job_manager's retry (up to 30), which
// replays the JobSet from the stored snapshot.
local topology = cdk.var('TOPOLOGY', '2x2x1');
local chips = cdk.numVar('CHIPS', 4);
local tp = cdk.numVar('TP', 8);
local ep = cdk.numVar('EP', 8);

// --- Software ----------------------------------------------------------------------
local image = cdk.var('IMAGE', 'us-central1-docker.pkg.dev/cloud-tpu-inference-test/junyanxu-vllm-tpu/sglang-torchtpu:20261103');
// The PR tree, staged with --map-dir "<tree>:*:<TREE_DIR>". '' runs the image's own sglang.
local treeDir = cdk.var('TREE_DIR', '/workspace/sglang-1992');
// The harness, staged with --map-dir "<harness>:*:<HARNESS_DIR>" (clients, stage scripts, wheels/).
local harnessDir = cdk.var('HARNESS_DIR', '/workspace/harness');
// tpu-sync-torch with the host-to-host read API (register_read(source=), start_read(destination=)); '' keeps the image's.
local tpuSyncVersion = cdk.var('TPU_SYNC_VERSION', '0.0.1.dev20261103081657');
// torch_tpu wheel under HARNESS_DIR/wheels to install over the image's; '' keeps the image's.
local torchTpuWheel = cdk.var('TORCH_TPU_WHEEL', 'torch_tpu-0.2.1.dev20261028201649-cp312-cp312-manylinux_2_31_x86_64.whl');

// --- Model -------------------------------------------------------------------------
// qwen3-30b: pd_1992_qwen_wb.json (PR 1992). gpt-oss-120b: gpt-oss_C_static_wb_spill.json (hybrid SWA + full
// attention, PR 1991: pass the 1991 tree as TREE_DIR). Both in MODEL_BUCKET, mounted at /models.
local profiles = {
  'qwen3-30b': {
    model: 'Qwen/Qwen3-30B-A3B-Instruct-2507-FP8',
    served: 'qwen3-30b-a3b',
    pageSize: 128,
    contextLen: 262144,
    reasoningParser: '',
    prefillEnv: {},
    decodeEnv: {},
    runPrefix: 'g1992b',
    hybrid: false,
  },
  'gpt-oss-120b': {
    model: 'gpt/gpt-oss-120b',
    served: 'gpt-oss-120b',
    pageSize: 64,
    contextLen: 327680,
    reasoningParser: 'gpt-oss',
    // The PR 1991 tree sizes the SWA host pool with SGLANG_TPU_PD_SWA_HOST_WINDOWS, the same value on both roles
    // (the older decode-only name in gpt-oss_C_static_wb_spill.json is no longer read).
    prefillEnv: { SGLANG_TPU_FUSED_MOE_SC_GATHER: '0', SGLANG_TPU_PD_SWA_HOST_WINDOWS: '128' },
    decodeEnv: { SGLANG_TPU_FUSED_MOE_SC_GATHER: '0', SGLANG_TPU_PD_SWA_HOST_WINDOWS: '128' },
    runPrefix: 'g1991h',
    hybrid: true,
  },
};
local profileName = cdk.var('MODEL_PROFILE', 'qwen3-30b');
assert std.objectHas(profiles, profileName) : 'MODEL_PROFILE must be one of %s' % std.join(', ', std.objectFields(profiles));
local profile = profiles[profileName];
local modelBucket = cdk.var('MODEL_BUCKET', 'junyanxu-benchmark-models');
local modelSubdir = cdk.var('MODEL', profile.model);
local servedName = cdk.var('SERVED_MODEL_NAME', profile.served);
local localCopy = cdk.boolVar('LOCAL_COPY', true);

// --- Engine settings (pd_1992_qwen_wb.json) -------------------------------------------
local switchOn = cdk.boolVar('SWITCH', true);
local writePolicy = cdk.var('WRITE_POLICY', 'write_back');
local contextLen = cdk.numVar('CONTEXT_LEN', profile.contextLen);
local maxTotalTokens = cdk.numVar('MAX_TOTAL_TOKENS', 786432);
local maxRunning = cdk.numVar('MAX_RUNNING_REQUESTS', 4);
local chunkedPrefill = cdk.numVar('CHUNKED_PREFILL', 8192);
local memFraction = cdk.var('MEM_FRACTION', '0.45');
local pageSize = cdk.numVar('PAGE_SIZE', profile.pageSize);
local reasoningParser = cdk.var('REASONING_PARSER', profile.reasoningParser);
local prefillHicacheRatio = cdk.var('PREFILL_HICACHE_RATIO', '1.2');
local decodeHicacheRatio = cdk.var('DECODE_HICACHE_RATIO', '3.5');
local raidenHostPoolGb = cdk.var('RAIDEN_HOST_POOL_GB', '128');
local attentionBackend = cdk.var('ATTENTION_BACKEND', 'pallas_tpu_rpa_v3');
local extraPrefillArgs = cdk.var('EXTRA_PREFILL_ARGS', '');
local extraDecodeArgs = cdk.var('EXTRA_DECODE_ARGS', '');
// Extra env per role as a JSON object of strings, e.g. PREFILL_ENV='{"SGLANG_X":"1"}'.
local extraEnv = {
  prefill: profile.prefillEnv + std.parseJson(cdk.var('PREFILL_ENV', '{}')),
  decode: profile.decodeEnv + std.parseJson(cdk.var('DECODE_ENV', '{}')),
};

// --- Stage ------------------------------------------------------------------------------
// edges: E1 integrity, E2 stress, E3 flush under load on a 1P1D pair.
// layout: the sticky-route and random cases of the NUM_PREFILL x NUM_DECODE layout (1p1d, 1p2d, 2p1d, 2p2d, as
// goal_baseline.sh / compare_layouts.py); smoke: short 1P1D round trip; a1_ladder: the 1P1D recall/static ladders.
// The script is HARNESS_DIR/stage_<STAGE>.sh (2p2d is kept as an alias of layout).
local stage = cdk.var('STAGE', 'layout');
local layout = '%dp%dd' % [numPrefill, numDecode];
local arm = if switchOn then '' else '_off';
local run = cdk.var('RUN',
  if std.member(['layout', '2p2d'], stage) then '%s_%s%s_1' % [profile.runPrefix, layout, arm]
  else '%s_%s_%s%s' % [profile.runPrefix, stage, writePolicy, arm]);
local stageEnv = std.parseJson(cdk.var('STAGE_ENV', '{}'));
local waitTimeout = cdk.numVar('WAIT_TIMEOUT', 5400);
// Keep the servers up this long after the stage for interactive poking (cdk job exec); 0 ends the job at once.
local holdSeconds = cdk.numVar('HOLD_SECONDS', 0);

assert numPrefill >= 1 && numDecode >= 1 : 'NUM_PREFILL and NUM_DECODE must be >= 1';
assert stage != '2p2d' || (numPrefill == 2 && numDecode == 2) : 'STAGE=2p2d needs NUM_PREFILL=2 NUM_DECODE=2';
assert stage != 'layout' || (numPrefill <= 2 && numDecode <= 2) : 'STAGE=layout knows 1p1d, 1p2d, 2p1d and 2p2d';
assert !std.member(['a1_ladder', 'smoke', 'edges'], stage) || (numPrefill == 1 && numDecode == 1) : 'STAGE=%s is 1P1D: NUM_PREFILL=1 NUM_DECODE=1' % stage;
assert std.member(['write_back', 'write_through'], writePolicy) : 'WRITE_POLICY must be write_back or write_through';

// --- Ports -------------------------------------------------------------------------
local serverPort = 30000;
local bootstrapPort = 8998;
local kvPort = 31000;
local lbPort = 8080;
local pinnedPort(p, d) = 8100 + 10 * p + d;

local modelMountPath = '/models';
local modelFusePath = '%s/%s' % [modelMountPath, modelSubdir];
local shared = '/cdk-outputs/pd1992';

// ---------------------------------------------------------------------------------------
// Volumes
// ---------------------------------------------------------------------------------------
local gcsVolumes = [cdk.gcsVolume('model-volume', modelBucket, readOnly=true)];
local gcsMounts = [cdk.gcsMount('model-volume', modelMountPath, readOnly=true)];

// The gcsfuse CSI driver only injects its sidecar into pods carrying this annotation.
local withGcsfuse(job) = job {
  template+: { spec+: { template+: { metadata+: { annotations+: { 'gke-gcsfuse/volumes': 'true' } } } } },
};

local commonEnv = cdk.jobSetNameEnv { RECIPE_NAME: cdk.recipeName };

// ---------------------------------------------------------------------------------------
// Software setup shared by every pod: tree overlay, tpu-sync, torch_tpu
// ---------------------------------------------------------------------------------------
local softwareSetup = |||
  export SETUPTOOLS_SCM_PRETEND_VERSION=0.0.0.dev0
  if [ -n "%(tree)s" ]; then
    test -d "%(tree)s/python/sglang" || { echo "FAIL: no PR tree at %(tree)s (pass --map-dir <tree>:*:%(tree)s)"; exit 1; }
    cd "%(tree)s" && cp python/pyproject_tpu.toml python/pyproject.toml
    pip install -q --no-deps --no-build-isolation -e python/ 2>&1 | tail -2 || { echo "FAIL: pip install sglang tree"; exit 1; }
    pip install -q --no-deps --no-build-isolation -e . 2>&1 | tail -2 || { echo "FAIL: pip install sglang-tpu tree"; exit 1; }
    export PYTHONPATH="%(tree)s/python:%(tree)s${PYTHONPATH:+:$PYTHONPATH}"
    echo "tree: $(cat %(tree)s/.sglang_rev 2>/dev/null || echo unknown) at %(tree)s"
    if [ "%(hybrid)s" = true ] && ! grep -q 'hybrid_swa' "%(tree)s/sglang_tpu/disaggregation/decode_dram_offload/startup_validation.py"; then
      echo "FAIL: MODEL_PROFILE=%(profileName)s is a hybrid sliding-window model; this tree refuses hybrids (pass the PR 1991 tree as TREE_DIR)"; exit 1
    fi
  fi
  if [ -n "%(torchTpuWheel)s" ]; then
    W="%(harness)s/wheels/%(torchTpuWheel)s"
    test -f "$W" || { echo "FAIL: torch_tpu wheel $W missing from the harness map-dir"; exit 1; }
    pip install -q --no-deps --force-reinstall "$W" 2>&1 | tail -2 || { echo "FAIL: torch_tpu install"; exit 1; }
  fi
  if [ -n "%(tpuSync)s" ]; then
    pip install -q --no-deps --pre "tpu-sync-torch==%(tpuSync)s" 2>&1 | tail -2 || { echo "FAIL: tpu-sync-torch install"; exit 1; }
  fi
  # tpu-sync >= dev20261029's torch extension links libibverbs.so.1, which this image lacks.
  if ! ldconfig -p | grep -q 'libibverbs.so.1'; then
    (apt-get update -qq && apt-get install -y -qq --no-install-recommends libibverbs1) > /tmp/apt.log 2>&1 || { tail -5 /tmp/apt.log; echo "FAIL: apt-get libibverbs1"; exit 1; }
    echo "installed libibverbs1"
  fi
  python3 -c "from tpu_sync.api.torch import torch_abi; torch_abi.load_extension('tpu_sync.frameworks.torch', '_tpu_raiden_torch'); print('tpu_sync torch extension loads')" \
    || { echo "FAIL: the tpu_sync torch extension does not load (missing shared library?)"; exit 1; }
  pip list 2>/dev/null | grep -iE '^(torch|torch[-_]tpu|tpu[-_]sync[-_]torch|libtpu|sglang|sglang[-_]tpu|sglang[-_]router) '
  python3 - <<'PY'
  import inspect
  from tpu_sync.api.torch import kv_cache_manager as k
  m = k.KVCacheManager
  print("tpu_sync register_read:", list(inspect.signature(m.register_read).parameters))
  print("tpu_sync start_read:", list(inspect.signature(m.start_read).parameters))
  PY
||| % { tree: treeDir, harness: harnessDir, torchTpuWheel: torchTpuWheel, tpuSync: tpuSyncVersion, hybrid: profile.hybrid, profileName: profileName };

// ---------------------------------------------------------------------------------------
// Prefill / decode server
// ---------------------------------------------------------------------------------------
local flag(name, value=null) = if value == null then '--' + name else '--%s %s' % [name, value];

local serverFlags(mode) =
  [
    flag('model-path', '"$MODEL_DIR"'),
    flag('served-model-name', servedName),
    flag('device', 'tpu'),
    flag('dtype', 'bfloat16'),
    flag('host', '0.0.0.0'),
    flag('port', serverPort),
    flag('grammar-backend', 'none'),
    flag('tp-size', tp),
    flag('ep-size', ep),
    flag('attention-backend', attentionBackend),
    flag('page-size', pageSize),
    flag('kv-cache-dtype', 'fp8_e4m3'),
    flag('context-length', contextLen),
    flag('max-total-tokens', maxTotalTokens),
    flag('max-running-requests', maxRunning),
    flag('chunked-prefill-size', chunkedPrefill),
    flag('max-prefill-tokens', chunkedPrefill),
    flag('tpu-compile-tokens', '512 1024 2048 4096 8192'),
    flag('tpu-compile-bs', '1 2 4'),
    flag('enable-torch-compile'),
    flag('torch-compile-max-bs', 4),
    flag('mem-fraction-static', memFraction),
    flag('sampling-backend', 'pytorch'),
    flag('skip-server-warmup'),
    flag('enable-metrics'),
    flag('enable-cache-report'),
    flag('watchdog-timeout', 3600),
    flag('dist-timeout', 3600),
    flag('disaggregation-mode', mode),
    flag('disaggregation-transfer-backend', 'raiden'),
    flag('enable-hierarchical-cache'),
    flag('hicache-io-backend', 'raiden'),
    flag('hicache-mem-layout', 'page_first_fused'),
    flag('hicache-write-policy', writePolicy),
    flag('hicache-ratio', if mode == 'prefill' then prefillHicacheRatio else decodeHicacheRatio),
  ]
  + (if reasoningParser == '' then [] else [flag('reasoning-parser', reasoningParser)])
  + (if mode == 'prefill' then [flag('disaggregation-bootstrap-port', bootstrapPort)] else [])
  + (if mode == 'decode' then [flag('disaggregation-decode-enable-radix-cache')] else [])
  + (local extra = if mode == 'prefill' then extraPrefillArgs else extraDecodeArgs;
     if extra == '' then [] else [extra]);

// pd_1992_qwen_wb.json runtime_envs, plus the Raiden socket timeouts the PR's README asks for on both roles.
local engineEnv = {
  SGLANG_PLATFORM: 'tpu',
  PJRT_DEVICE: 'TPU',
  HF_HUB_OFFLINE: '1',
  TRANSFORMERS_OFFLINE: '1',
  TORCH_LOGS: '+recompiles',
  TPU_ENABLE_DIAGNOSTIC_COORDINATOR: '0',
  TPU_DISABLE_DIAGNOSTIC_COORDINATOR: '1',
  TPU_DIAGNOSTIC_HARVESTER_INTERVAL_SEC: '86400',
  TPU_ENABLE_TELEMETRY_HARVESTING: '0',
  TPU_ENABLE_TELEMETRY: '0',
  ENABLE_TPU_TELEMETRY: '0',
  TPU_TELEMETRY_INTERVAL_SECONDS: '86400',
  TPU_TELEMETRY_INTERVAL_SEC: '86400',
  SGLANG_TPU_PRELOAD_TELEMETRY_STUB: '1',
  SGLANG_ENABLE_HEALTH_ENDPOINT_GENERATION: '0',
  SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN: '1',
  SGLANG_TPU_OVERLAP_PROFILE: '1',
  TORCH_TPU_INTERNAL_MATERIALIZE_COLLECTIVE_TENSORS: 'false',
  LIBTPU_INIT_ARGS: '--xla_tpu_enable_async_collective_fusion=true --xla_tpu_overlap_compute_collective_tc=true --xla_tpu_enable_async_collective_fusion_multiple_steps=true --xla_tpu_enable_latency_hiding_scheduler=true --xla_latency_hiding_scheduler_rerun=10 --xla_tpu_all_gather_collective_matmul_mode=post_spmd_conservative --xla_tpu_reduce_scatter_collective_matmul_mode=post_spmd_conservative --xla_tpu_enable_sparse_core_collective_offload_all_reduce=false --xla_tpu_offload_gather_to_sparsecore=false --xla_tpu_enable_sparse_core_collective_offload_reduce_scatter=false',
  TPU_RAIDEN_CONTROL_PLANE_BACKEND: 'grpc',
  SGLANG_RAIDEN_KV_PORT: std.toString(kvPort),
  SGLANG_RAIDEN_HOST_POOL_GB: raidenHostPoolGb,
  SGLANG_DISAGGREGATION_BOOTSTRAP_TIMEOUT: '7200',
  SGLANG_DISAGGREGATION_WAITING_TIMEOUT: '7200',
  SGLANG_RAIDEN_CHUNK_TRANSFER_TIMEOUT_S: '60',
  SGLANG_HICACHE_SKIP_HOST_DUPLICATE_RECLAIM: '1',
  TPU_RAIDEN_PREFILL_HANDSHAKE_ACK_READ_TIMEOUT_S: '60',
  TPU_RAIDEN_PREFILL_FINAL_ACK_READ_TIMEOUT_S: '60',
  TPU_RAIDEN_PREFILL_PAYLOAD_READ_TIMEOUT_S: '60',
  TPU_RAIDEN_PREFILL_HANDSHAKE_WRITE_TIMEOUT_S: '60',
  TPU_RAIDEN_PREFILL_PAYLOAD_WRITE_TIMEOUT_S: '60',
  TPU_RAIDEN_DECODE_HANDSHAKE_READ_TIMEOUT_S: '60',
  TPU_RAIDEN_DECODE_PAYLOAD_READ_TIMEOUT_S: '60',
  TPU_RAIDEN_DECODE_ACK_WRITE_TIMEOUT_S: '60',
  TPU_RAIDEN_DECODE_PAYLOAD_WRITE_TIMEOUT_S: '60',
} + (if switchOn then { SGLANG_ENABLE_PREFILL_KV_OFFLOAD_TO_DECODE_DRAM: '1' } else {});

local modelSetup =
  if localCopy then |||
    # Copy to local memory: gcsfuse reads block the TPU session heartbeat (see the xpyd recipe).
    MODEL_DIR=/dev/shm/model
    mkdir -p "$MODEL_DIR"
    echo "copying model to $MODEL_DIR $(date)"
    SKIP='( -path ./original -o -path ./metal -o -path ./.cache ) -prune -o'
    (cd %(fuse)s && find . $SKIP -type d -print0 | (cd "$MODEL_DIR" && xargs -0 mkdir -p) \
      && find . $SKIP -type f -print0 | xargs -0 -P 16 -I{} cp {} "$MODEL_DIR/{}") \
      || { echo "model copy failed"; exit 1; }
    echo "copy done $(date)"; du -sh "$MODEL_DIR"
  ||| % { fuse: modelFusePath }
  else 'MODEL_DIR=%s\n' % modelFusePath;

local serverJob(mode, replicas) = withGcsfuse(cdk.job(
  name=mode,
  replicas=replicas,
  podSpec=cdk.tpuNodeSelector(accelerator, topology),
  volumes=[{ name: 'dshm', emptyDir: { medium: 'Memory' } }] + gcsVolumes,
  containers=[cdk.container(
    'sglang-' + mode,
    image,
    |||
      set -uo pipefail
      echo "role=%(mode)s JOBSET_JOB_INDEX=$JOBSET_JOB_INDEX HOSTNAME=$HOSTNAME $(date -u)"
      unset TPU_VISIBLE_CHIPS || true
      for v in $(compgen -e | grep '^MEGASCALE'); do unset "$v"; done
      LOG_DIR=%(shared)s/%(mode)s-${JOBSET_JOB_INDEX}
      mkdir -p "$LOG_DIR"
      %(software)s
      %(modelSetup)s
      cd /tmp
      echo "=== Environment ==="; printenv | sort | grep -v -i token; echo "==================="
      # The log goes to stdout (cdk job log) and to a local file that is copied to the shared GCS dir every
      # 60 s for the bench pod (gcsfuse makes a file visible only when it is closed).
      ( while true; do sleep 60; cp /tmp/server.log "$LOG_DIR/server.log.tmp" 2>/dev/null && mv -f "$LOG_DIR/server.log.tmp" "$LOG_DIR/server.log"; done ) &
      # A host whose previous tenant's TPU session has not cleared yet fails libtpu init with START_SESSION
      # failed (the teardown race, bare-metal issue I1); that is worth one retry before giving the host up.
      for attempt in 1 2 3; do
        echo "Starting SGLang %(mode)s server ${JOBSET_JOB_INDEX} (attempt $attempt) $(date -u)"
        python3 -m sglang.launch_server \
          %(flags)s \
          2>&1 | tee -a /tmp/server.log
        rc=$?
        if [ $attempt -lt 3 ] && grep -q -E 'START_SESSION failed|device node already opened|Failed to bind gRPC control server' /tmp/server.log; then
          echo "TPU init failed on $HOSTNAME (attempt $attempt): retrying in 120 s $(date -u)"; mv /tmp/server.log "/tmp/server.attempt$attempt.log"; cp "/tmp/server.attempt$attempt.log" "$LOG_DIR/" 2>/dev/null || true
          sleep 120; continue
        fi
        break
      done
      cp /tmp/server.log "$LOG_DIR/server.log" 2>/dev/null || true
      echo "server exited rc=$rc $(date -u)"
      exit $rc
    ||| % {
      mode: mode,
      shared: shared,
      software: std.rstripChars(softwareSetup, '\n'),
      modelSetup: std.rstripChars(modelSetup, '\n'),
      flags: std.join(' \\\n  ', serverFlags(mode)),
    },
    env=commonEnv + cdk.megascaleOff + engineEnv + {
      JOBSET_JOB_INDEX: { valueFrom: { fieldRef: { fieldPath: "metadata.labels['jobset.sigs.k8s.io/job-index']" } } },
    } + extraEnv[mode],
    resources=cdk.tpuResources(chips, cpu='32', memory='900Gi'),
    volumeMounts=[{ name: 'dshm', mountPath: '/dev/shm' }] + gcsMounts,
  )],
));

// ---------------------------------------------------------------------------------------
// Routers: one random mini-lb plus one pinned mini-lb per (prefill, decode) pair
// ---------------------------------------------------------------------------------------
local prefillUrl(i) = 'http://%s:%d' % [cdk.host('prefill', i), serverPort];
local decodeUrl(j) = 'http://%s:%d' % [cdk.host('decode', j), serverPort];
local routerHost = cdk.host('router');
local lbUrl = 'http://%s:%d' % [routerHost, lbPort];
local pinnedUrl(p, d) = 'http://%s:%d' % [routerHost, pinnedPort(p, d)];

local routerCmd(port, prefills, decodes) =
  'python3 -m sglang_router.launch_router --pd-disaggregation --mini-lb %s %s --host 0.0.0.0 --port %d > /tmp/lb_%d.log 2>&1 &' % [
    std.join(' ', ['--prefill %s %d' % [prefillUrl(i), bootstrapPort] for i in prefills]),
    std.join(' ', ['--decode %s' % decodeUrl(j) for j in decodes]),
    port,
    port,
  ];

local routerJob = cdk.job(
  name='router',
  containers=[cdk.container(
    'sglang-router',
    image,
    |||
      set -uo pipefail
      %(software)s
      %(waits)s
      echo "Starting mini-lb routers: random on %(lbPort)d, pinned on 8100+10p+d"
      %(random)s
      %(pinned)s
      sleep 5; for p in /tmp/lb_*.log; do echo "== $p"; tail -3 $p; done
      wait
    ||| % {
      software: std.rstripChars(softwareSetup, '\n'),
      waits: std.rstripChars(std.join('', [
        cdk.waitForHttp(prefillUrl(i) + '/health', waitTimeout)
        for i in std.range(0, numPrefill - 1)
      ] + [
        cdk.waitForHttp(decodeUrl(j) + '/health', waitTimeout)
        for j in std.range(0, numDecode - 1)
      ]), '\n'),
      lbPort: lbPort,
      random: routerCmd(lbPort, std.range(0, numPrefill - 1), std.range(0, numDecode - 1)),
      pinned: std.join('\n', [
        routerCmd(pinnedPort(p, d), [p], [d])
        for p in std.range(0, numPrefill - 1)
        for d in std.range(0, numDecode - 1)
      ]),
    },
    env=commonEnv,
    resources={ requests: { cpu: '4', memory: '16Gi' }, limits: { cpu: '8', memory: '32Gi' } },
  )],
);

// ---------------------------------------------------------------------------------------
// Bench driver — completion of this job ends the JobSet
// ---------------------------------------------------------------------------------------
local benchJob = withGcsfuse(cdk.job(
  name='bench',
  volumes=gcsVolumes,
  containers=[cdk.container(
    'bench',
    image,
    |||
      set -uo pipefail
      export HARNESS=%(harness)s PY=python3 TOK=%(model)s PROMPTS=/tmp/prompts
      export OUT=%(shared)s/bench SHARED=%(shared)s RUN=%(run)s
      export LB=%(lb)s PREFILL_URLS="%(prefillUrls)s" DECODE_URLS="%(decodeUrls)s" LAYOUT=%(layout)s
      export MODEL_PROFILE=%(profileName)s HYBRID=%(hybrid)s PAGE_SIZE=%(pageSize)d
      lb_pin() { echo "http://%(routerHost)s:$((8100 + 10 * $1 + $2))"; }
      export -f lb_pin
      export PYTHONPATH="$HARNESS${PYTHONPATH:+:$PYTHONPATH}"
      export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
      %(stageEnv)s
      mkdir -p "$OUT"
      test -f "$HARNESS/stage_%(stage)s.sh" || { echo "FAIL: no $HARNESS/stage_%(stage)s.sh (pass --map-dir <harness>:*:$HARNESS)"; exit 1; }
      ls -la "$TOK" | head -3
      python3 "$HARNESS/make_prompts.py" --tokenizer "$TOK" --out "$PROMPTS" || { echo "FAIL: prompt corpus"; exit 1; }
      %(waits)s
      echo "stage %(stage)s run $RUN start $(date -u)"
      bash "$HARNESS/stage_%(stage)s.sh"; rc=$?
      echo "stage %(stage)s rc=$rc $(date -u)"
      if [ %(hold)d -gt 0 ]; then echo "holding the servers for %(hold)d s"; sleep %(hold)d; fi
      exit $rc
    ||| % {
      harness: harnessDir,
      model: modelFusePath,
      shared: shared,
      run: run,
      lb: lbUrl,
      routerHost: routerHost,
      prefillUrls: std.join(' ', [prefillUrl(i) for i in std.range(0, numPrefill - 1)]),
      decodeUrls: std.join(' ', [decodeUrl(j) for j in std.range(0, numDecode - 1)]),
      stage: stage,
      layout: layout,
      profileName: profileName,
      hybrid: profile.hybrid,
      pageSize: pageSize,
      stageEnv: std.join('\n', ['export %s=%s' % [k, std.escapeStringBash(stageEnv[k])] for k in std.objectFields(stageEnv)]),
      hold: holdSeconds,
      waits: std.rstripChars(std.join('', [cdk.waitForHttp(lbUrl + '/health', waitTimeout)] + [
        cdk.waitForHttp(pinnedUrl(p, d) + '/health', 600)
        for p in std.range(0, numPrefill - 1)
        for d in std.range(0, numDecode - 1)
      ]), '\n'),
    },
    env=commonEnv,
    resources={ requests: { cpu: '8', memory: '32Gi' }, limits: { cpu: '16', memory: '64Gi' } },
    volumeMounts=gcsMounts,
  )],
));

cdk.jobSet(
  'pd1992-qwen3-30b-xpyd',
  network={ enableDNSHostnames: true },
  successPolicy=cdk.succeedWhen(['bench']),
  failurePolicy=cdk.neverRestart,
  jobs=[
    serverJob('prefill', numPrefill),
    serverJob('decode', numDecode),
    routerJob,
    benchJob,
  ],
)
