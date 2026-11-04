"""CPU probe of device-prefix source ownership after forward handoff success.

The native engine is simulated as still owning the reverse source registration;
this probe establishes premature eviction/reuse, not native byte corruption.
"""

from __future__ import annotations
import argparse
import os
import runpy
import sys
from array import array
from pathlib import Path
from types import SimpleNamespace


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sglang-root", type=Path, required=True)
    args = parser.parse_args()
    root = args.sglang_root.resolve()
    sys.path[:0] = [str(root / "python"), str(root)]
    os.environ["TORCH_DEVICE_BACKEND_AUTOLOAD"] = "0"
    os.environ["SGLANG_PLUGINS"] = "none"
    from torch._dynamo.backends import registry

    def no_compile(*args, **kwargs):
        raise AssertionError("CPU probe invoked TPU compilation")

    if "tpu" not in registry._BACKENDS:
        registry.register_backend(no_compile, name="tpu")
    px = runpy.run_path(
        str(root / "test/registered/unit/disaggregation/test_raiden_prefix_pull.py"),
        run_name="protocol_fixture",
    )
    fx = runpy.run_path(
        str(root / "test/registered/unit/hardware_backend/tpu/test_pd_victim_push.py"),
        run_name="cache_fixture",
    )
    from sglang.srt.disaggregation.base.conn import KVPoll
    from sglang.srt.disaggregation.decode import DecodeTransferQueue
    from sglang.srt.mem_cache.base_prefix_cache import EvictParams, MatchPrefixParams
    from sglang.srt.mem_cache.radix_cache import RadixKey
    from sglang_tpu.disaggregation.raiden.receiver import RaidenKVReceiver

    cache, allocator = fx["full_cache"](kv_size=16)
    # Device-only recall is supported independently of victim spill/HiCache.
    cache.cache_controller = None
    cache.tree_core.enable_hicache = False
    cache.tree_core.is_write_back = cache.is_write_back = False
    tokens = list(range(8))
    fx["insert_tokens"](cache, allocator, tokens)
    key = RadixKey(array("q", tokens))
    match = cache.match_prefix(MatchPrefixParams(key=key))
    original_indices = match.device_indices.clone()
    # Full-only production offers rely on the normal request pin; they do not
    # acquire the extra offer pin used by the hybrid path.
    request_receipt = cache.inc_lock_ref(match.last_device_node).to_dec_params()
    dr = SimpleNamespace(prefix_offer_lock=None)
    queue = SimpleNamespace(tree_cache=cache)
    manager = px["_decode_manager"]()
    manager.kv_args.page_size = allocator.page_size
    px["_register"](manager, decode_prefix_len=8)
    manager.offer_resident_prefix(px["ROOM"], original_indices.tolist())
    manager._dispatch(
        px["PrefixPull"](room=px["ROOM"], first_page=0, num_pages=8).to_frames()
    )
    # Prefill has timed out of the reverse read and recomputed. Only the forward
    # receive reports success; the reverse source has no native terminal report.
    manager._completed_recv.add(str(px["ROOM"]))
    manager.request_status[px["ROOM"]] = KVPoll.WaitingForInput
    receiver = RaidenKVReceiver.__new__(RaidenKVReceiver)
    receiver.kv_mgr = manager
    receiver.bootstrap_room = px["ROOM"]
    receiver.conclude_state = None
    assert receiver.poll() == KVPoll.Success
    assert manager.room_has_active_io(px["ROOM"])
    print(
        "forward_success_with_active_reverse_source:",
        manager.room_has_active_io(px["ROOM"]),
    )
    # Queue exit has no additional source pin to release in this full-only mode.
    # After the normal request's final unpin, native work still owns the source.
    DecodeTransferQueue._release_prefix_offer_lock(queue, dr)
    cache.dec_lock_ref(match.last_device_node, request_receipt)
    cache.evict(EvictParams(num_tokens=8))
    remaining = cache.match_prefix(MatchPrefixParams(key=key))
    reallocated = allocator.alloc(16)
    reused = sorted(set(original_indices.tolist()) & set(reallocated.tolist()))
    print(
        "after_queue_exit_and_request_finish: device_hit=",
        len(remaining.device_indices),
        "source_io_active=",
        manager.room_has_active_io(px["ROOM"]),
        "reused_source_slots=",
        reused,
    )
    assert len(remaining.device_indices) == 0
    assert manager.room_has_active_io(px["ROOM"])
    assert reused == original_indices.tolist()
    assert "torch_tpu" not in sys.modules
    print(
        "Premature source eviction/reuse reproduced; native byte corruption not tested."
    )


if __name__ == "__main__":
    main()
