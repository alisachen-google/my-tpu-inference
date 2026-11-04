"""CPU boundary probes for PR 1789 at c910830c0e59.

Print observed behavior as JSON. True defect flags describe that reviewed head;
they are observations, not the desired behavior after a fix. Native transfers
and device copies are simulated; real manager, radix and load-back code runs.
No model server, hardware compilation or native transfer is started.
"""

from __future__ import annotations

import argparse
import json
import os
import runpy
import sys
from array import array
from pathlib import Path
from unittest.mock import Mock


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sglang-root", type=Path, required=True)
    args = parser.parse_args()
    root = args.sglang_root.resolve()
    sys.path[:0] = [str(root / "python"), str(root)]
    os.environ["TORCH_DEVICE_BACKEND_AUTOLOAD"] = "0"
    os.environ["SGLANG_PLUGINS"] = "none"

    import torch
    from torch._dynamo.backends import registry

    compiler_calls = 0

    def no_compile(*_args, **_kwargs):
        nonlocal compiler_calls
        compiler_calls += 1
        raise AssertionError("CPU review probe invoked TPU compilation")

    if "tpu" not in registry._BACKENDS:
        registry.register_backend(no_compile, name="tpu")

    unit = root / "test/registered/unit"
    fx = runpy.run_path(
        str(unit / "hardware_backend/tpu/test_pd_victim_push.py"),
        run_name="review_cache_fixture",
    )
    px = runpy.run_path(
        str(unit / "disaggregation/test_raiden_prefix_pull.py"),
        run_name="review_protocol_fixture",
    )
    from sglang.srt.mem_cache.hicache_storage import PoolName, SidecarPoolSpec
    from sglang.srt.mem_cache.pool_host.group import HostPoolGroup, PoolEntry
    from sglang.srt.mem_cache.radix_cache import RadixKey
    from sglang_tpu import pd_spill_flags
    from sglang_tpu.envs import envs
    from sglang_tpu.pd_host_cache import insert_host_prefix
    from sglang_tpu.pd_host_prefix_recall import reclaim_full_host_duplicates

    results = {}
    with (
        envs.SGLANG_ENABLE_PREFILL_KV_OFFLOAD_TO_DECODE_DRAM.override(True),
        envs.SGLANG_DISAGG_PREFIX_VICTIM_PUSH.override(False),
        envs.SGLANG_DISAGG_PREFILL_PULL_DECODE_PREFIX.override(False),
    ):
        results["explicit_false_ignored"] = {
            "victim": pd_spill_flags.victim_push_enabled(),
            "pull": pd_spill_flags.decode_prefix_pull_enabled(),
        }

    case = fx["TestRecallLandingReclaimsHostDuplicates"]()
    cache, host, tokens = case._write_through_cache()
    allocator = cache.token_to_kv_pool_allocator
    host.capacity += 8
    fx["insert_tokens"](cache, allocator, tokens + [8] * 8)
    parent = fx["root_node"](cache, 100)
    child = next(iter(parent.children.values()))
    cache.tree_core.commit_backup(child.id, host.alloc(len(child.key)), {})
    cache.tree_core._update_duplicate_tracking(child)
    parent.last_access_time, child.last_access_time = 1, 2
    freed = reclaim_full_host_duplicates(cache, 16)
    landing = host.alloc(16)
    if landing is not None:
        host.free(landing)
    freed_again = reclaim_full_host_duplicates(cache, 16 - freed)
    results["chain_reclaim"] = {
        "required": 16,
        "freed_first_pass": freed,
        "first_landing_refused": landing is None,
        "freed_second_pass": freed_again,
    }

    def manager():
        mgr = px["_decode_manager"]()
        px["_register"](mgr, decode_prefix_len=8)
        mgr.offer_resident_prefix(px["ROOM"], [3, 4])
        mgr._dispatch(
            px["PrefixPull"](room=px["ROOM"], first_page=0, num_pages=2).to_frames()
        )
        return mgr

    # Allocation refusal can make Prefill compute normally, allowing forward
    # handoff to retire the room before its unused source registration expires.
    mgr = manager()
    mgr.clear_room(px["ROOM"])
    mgr._engine.poll_stats_with_details.return_value = px["_polled"](failed=[px["PX"]])
    mgr._drain_engine()
    mgr._engine.poll_stats_with_details.return_value = px["_polled"](sent=["999#px"])
    mgr._drain_engine()
    results["retired_device_failure"] = sorted(mgr._native_failed)

    for outcome in ("sent", "failed"):
        mgr = manager()
        transfer = Mock()
        transfer.poll_transfer.return_value = outcome
        mgr._prefix_host_reads = {px["PX"]: transfer}
        mgr.clear_room(px["ROOM"])
        mgr._drain_engine()
        retained = mgr._completed_send if outcome == "sent" else mgr._native_failed
        transfer.forget_transfer.assert_called_once_with(px["PX"])
        assert not mgr._prefix_host_reads
        results[f"retired_host_{outcome}"] = sorted(retained)

    # Sidecar indices share the anchor's allocation domain, not its bytes.
    # Target-only host insertion must not imply that DRAFT bytes were received.
    cache, allocator = fx["full_cache"](kv_size=64, host_capacity=64)
    full = cache.cache_controller.host
    draft = fx["_FakeHostPool"](64)
    for pool in (full, draft):
        pool.layout, pool.device = "fake", "cpu"
        pool.logical_size, pool.can_use_write_back_jit = 64, False
    full.values = torch.full((64,), -1.0)
    draft.values = torch.full((64,), -777.0)
    group = HostPoolGroup(
        [
            PoolEntry(PoolName.KV, full, None, lambda i: i, True),
            PoolEntry(PoolName.DRAFT, draft, None, lambda i: i),
        ]
    )
    cache.cache_controller.mem_pool_host = group
    cache.sidecar_pool_specs = [SidecarPoolSpec(PoolName.DRAFT, PoolName.KV)]
    cache.load_back_threshold = 1
    indices = full.alloc(8)
    full.values[indices] = 123.0
    inserted = insert_host_prefix(
        cache, RadixKey(array("q", range(8))), indices, None, 1
    )
    observed = []

    def load(host_indices, priority=None, node_id=-1, extra_pools=None):
        transfers = group.resolve_host_transfers(
            extra_pools, primary_host_indices=host_indices
        )
        observed.extend(
            {
                "pool": str(x.name),
                "indices": x.host_indices.tolist(),
                "values": group.get_pool(x.name).values[x.host_indices].tolist(),
            }
            for x in transfers
        )
        return allocator.alloc(len(host_indices))

    cache.cache_controller.load = load
    loaded = cache.load_back(inserted.inserted_host_node)
    results["unwritten_sidecar_load"] = {"admitted": loaded, "reads": observed}
    assert not compiler_calls and "torch_tpu" not in sys.modules
    results["cpu_boundary"] = "no TPU compiler calls or torch_tpu import"
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
