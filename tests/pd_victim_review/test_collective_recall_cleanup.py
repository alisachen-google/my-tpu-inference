"""CPU reproducer for rank-divergent cleanup of abandoned prefix recalls.

Run with SGLANG_TPU_SRC pointing at the reviewed SGLang checkout. This test
uses the real DecodePrefixPuller and a real two-rank Gloo group. Only the
native completion and device allocator boundaries are replaced. It never
loads torch_tpu, allocates device tensors, or starts a model server.
"""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import timedelta
from pathlib import Path
from types import SimpleNamespace


def _worker(rank: int, rendezvous: str, output: str) -> None:
    os.environ["TORCH_DEVICE_BACKEND_AUTOLOAD"] = "0"
    os.environ["SGLANG_PLUGINS"] = "none"
    repo = Path(os.environ.get("SGLANG_TPU_SRC", "/tmp/sglang-victim-full-swa"))
    sys.path[:0] = [str(repo / "python"), str(repo)]
    import torch.distributed as dist
    from sglang_tpu.disaggregation.raiden.prefix_pull import DecodePrefixPuller

    dist.init_process_group(
        "gloo",
        rank=rank,
        world_size=2,
        init_method=f"file://{rendezvous}",
        timeout=timedelta(seconds=8),
    )
    try:
        fixture_path = (
            repo / "test/registered/unit/hardware_backend/tpu/test_pd_victim_push.py"
        )
        spec = importlib.util.spec_from_file_location(
            "_victim_review_fixtures", fixture_path
        )
        if spec is None or spec.loader is None:
            raise RuntimeError(f"Cannot load CPU pool fixtures: {fixture_path}")
        fixture = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = fixture
        spec.loader.exec_module(fixture)
        cache, allocator = fixture.full_cache(kv_size=128, host_capacity=256)
        tokens = list(range(64))
        fixture.insert_tokens(cache, allocator, tokens)
        zombie_indices = allocator.alloc(64)
        if zombie_indices is None:
            raise RuntimeError("Could not reserve abandoned recall destinations")
        puller = DecodePrefixPuller.__new__(DecodePrefixPuller)
        puller._groups = [dist.group.WORLD]
        puller._allocator = allocator
        puller._tree_cache = cache
        puller._window_pages = None
        puller._page_size = 1
        puller._min_free_tokens = 0
        puller._zombies = [(["old-recall"], zombie_indices, 0)]
        puller._plans = {}
        # The read originally acquired pages through an all-rank allocation.
        puller._external_reads_outstanding = True
        puller._mgr = SimpleNamespace(
            prefix_read_state=lambda _: "done" if rank == 0 else "pending",
            _drain_engine=lambda: None,
        )
        # Asymmetric completion is an ordinary asynchronous transport condition.
        # This is the same all-rank drain used by the paused scheduler loop.
        puller.resolve_deferred_releases()
        pending_after_reap = puller.has_pending_deferred_releases()
        available_after_reap = allocator.available_size()
        plan = SimpleNamespace(alloc_pages=lambda: 64, new_indices=None)
        puller._allocate(8, plan)
        result = {
            "rank": rank,
            "available_after_reap": available_after_reap,
            "pending_after_reap": pending_after_reap,
            "zombies": len(puller._zombies),
            "cache_resident_tokens": fixture.device_hit(cache, tokens),
            "new_allocation_tokens": 0
            if plan.new_indices is None
            else len(plan.new_indices),
        }
        Path(output).write_text(json.dumps(result) + "\n")
        dist.barrier()
    finally:
        dist.destroy_process_group()


class TestCollectiveRecallCleanup(unittest.TestCase):
    def test_asymmetric_native_completion_preserves_rank_consistent_eviction(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="victim-recall-ranks-") as directory:
            root = Path(directory)
            env = dict(
                os.environ, TORCH_DEVICE_BACKEND_AUTOLOAD="0", SGLANG_PLUGINS="none"
            )
            processes = [
                subprocess.Popen(
                    [
                        sys.executable,
                        __file__,
                        "--worker",
                        str(rank),
                        str(root / "rendezvous"),
                        str(root / f"rank-{rank}.json"),
                    ],
                    env=env,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                for rank in range(2)
            ]
            try:
                for process in processes:
                    stdout, stderr = process.communicate(timeout=45)
                    self.assertEqual(process.returncode, 0, stdout + stderr)
                results = [
                    json.loads((root / f"rank-{rank}.json").read_text())
                    for rank in range(2)
                ]
                self.assertTrue(
                    all(result["pending_after_reap"] for result in results),
                    "A paused flush must see outstanding ownership on every rank "
                    f"until all native reads settle: {results}",
                )
                self.assertEqual(
                    results[0]["cache_resident_tokens"],
                    results[1]["cache_resident_tokens"],
                    "A completed zombie on just one TP rank makes the same new recall "
                    f"evict different live cache nodes across ranks: {results}",
                )
            finally:
                for process in processes:
                    if process.poll() is None:
                        process.kill()
                    process.wait()


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--worker":
        _worker(int(sys.argv[2]), sys.argv[3], sys.argv[4])
    else:
        unittest.main(verbosity=2)
