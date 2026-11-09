"""Diagnostic only (not for merge): log why write-back's drop fallback declines a subtree,
and every 60 s the lock state of the prefill's tree and offload extension.

Installed by core_hooks when SGLANG_TPU_DEBUG_DROP_DECLINE=1.
"""
import logging
import time

from sglang.srt.mem_cache.unified_cache.unified_tree_core import UnifiedTreeCore

logger = logging.getLogger(__name__)

_last_state_log = [0.0]


def lock_state_line(cache, extension) -> str:
    core = cache.tree_core
    nodes = host_locked = dev_locked = host_only = pending = 0
    locked_window = locked_other = 0
    stack = list(core.root_node.children.values())
    while stack:
        cur = stack.pop()
        nodes += 1
        if cur.evicted and cur.backuped:
            host_only += 1
        if cur.write_through_pending_id is not None or cur.load_back_pending_id is not None:
            pending += 1
        if any(cd.host_lock_ref > 0 for cd in cur.component_data):
            host_locked += 1
            if len(cur.key) <= 128:
                locked_window += 1
            else:
                locked_other += 1
        if any(cd.lock_ref > 0 for cd in cur.component_data):
            dev_locked += 1
        stack.extend(cur.children.values())
    parts = [
        f"nodes={nodes}",
        f"host_only={host_only}",
        f"host_locked={host_locked} (window={locked_window} other={locked_other})",
        f"dev_locked={dev_locked}",
        f"pending_dma={pending}",
    ]
    try:
        full = cache.cache_controller.mem_pool_host.anchor_entry.host_pool
        parts.append(f"full_host_avail={full.available_size()}/{full.size}")
    except Exception as e:  # diagnostic
        parts.append(f"full_host_avail=?({type(e).__name__})")
    try:
        from sglang_tpu.disaggregation.decode_dram_offload.radix_host_ops import swa_host_pool

        swa = swa_host_pool(cache)
        if swa is not None:
            parts.append(f"swa_host_avail={swa.available_size()}/{swa.size}")
    except Exception as e:  # diagnostic
        parts.append(f"swa_host_avail=?({type(e).__name__})")
    try:
        parts.append(f"dev_evictable={cache.evictable_size()}")
    except Exception as e:  # diagnostic
        parts.append(f"dev_evictable=?({type(e).__name__})")
    recall = getattr(extension, "recall", None)
    if recall is not None:
        parts.append(
            f"pins={len(getattr(recall, '_pins', {}))} plans={len(getattr(recall, '_plans', {}))} "
            f"zombies={len(getattr(recall, '_zombies', []))} offered={len(getattr(recall, '_offered', {}))}"
        )
    push = getattr(extension, "push", None)
    if push is not None:
        parts.append(f"pushes={len(getattr(push, '_pushes', {}))} routes={len(getattr(push, '_routes', {}))}")
    return " ".join(parts)


def maybe_log_state(cache, extension) -> None:
    now = time.monotonic()
    if now - _last_state_log[0] < 60:
        return
    _last_state_log[0] = now
    try:
        logger.warning("[lock-state] %s", lock_state_line(cache, extension))
    except Exception as e:  # diagnostic
        logger.warning("[lock-state] failed: %s: %s", type(e).__name__, e)


def install() -> None:
    upstream = UnifiedTreeCore.drop_subtree_no_host

    def wrapper(self, node_id):
        result = upstream(self, node_id)
        if not result.is_dropped:
            node = self.node_by_id(node_id)
            rows = []
            stack = [(node, 0)]
            while stack:
                cur, depth = stack.pop()
                locks = " ".join(
                    f"{ct}:dev={cur.component_data[ct].lock_ref}/host={cur.component_data[ct].host_lock_ref}"
                    for ct in self.component_types
                )
                rows.append(
                    f"{'  ' * depth}[{cur.id}] len={len(cur.key)} evicted={cur.evicted} backuped={cur.backuped} "
                    f"wt_pending={cur.write_through_pending_id} lb_pending={cur.load_back_pending_id} {locks}"
                )
                stack.extend((c, depth + 1) for c in cur.children.values())
            logger.warning("[drop-decline] root %s:\n%s", node_id, "\n".join(rows))
        return result

    UnifiedTreeCore.drop_subtree_no_host = wrapper

    from sglang_tpu.disaggregation.decode_dram_offload.dram_offload_extension import (
        PrefillDramOffloadExtension,
    )

    upstream_step = PrefillDramOffloadExtension.before_bootstrap_step

    def step_wrapper(self, *args, **kwargs):
        result = upstream_step(self, *args, **kwargs)
        cache = getattr(getattr(self, "recall", None), "_cache", None)
        if cache is not None:
            maybe_log_state(cache, self)
        return result

    PrefillDramOffloadExtension.before_bootstrap_step = step_wrapper
