"""Recall cancellation must retain idle/reset ownership until native drain.

Run with SGLANG_PLUGINS=none TORCH_DEVICE_BACKEND_AUTOLOAD=0 and PYTHONPATH
pointing at a candidate SGLang checkout and its python/ directory. Set
SGLANG_REVIEW_ROOT when the checkout is not /tmp/sglang-victim-full-swa.

These tests exercise the real recall manager/puller and Scheduler idle/flush
methods. Only the transport engine, cache storage, and device allocator are
CPU boundary fixtures. They do not initialize a TPU or launch a server.
"""

from __future__ import annotations

import importlib.util
import os
import sys
import time
import unittest
from pathlib import Path
from types import ModuleType, SimpleNamespace

import torch
from sglang.srt.disaggregation.prefill import PrefillBootstrapQueue
from sglang.srt.disaggregation.utils import DisaggregationMode
from sglang.srt.managers.scheduler import Scheduler
from sglang_tpu.disaggregation.raiden.prefix_pull import DecodePrefixPuller


def _load_fixtures() -> ModuleType:
    root = Path(os.environ.get("SGLANG_REVIEW_ROOT", "/tmp/sglang-victim-full-swa"))
    path = root / "test/registered/unit/disaggregation/test_raiden_prefix_pull.py"
    spec = importlib.util.spec_from_file_location("_recall_review_fixtures", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load boundary fixtures from {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class TestRecallIdleOwnership(unittest.TestCase):
    def setUp(self) -> None:
        self.fixtures = _load_fixtures()
        self.manager = self.fixtures._prefill_manager()
        self.manager._pipeline = None
        self.manager._state_engine = None
        room = self.fixtures.ROOM
        self.manager._prefill.decode_addr[room] = ("10.0.0.2", 5555)
        self.manager._prefill.prefix_offer_since[room] = time.time()
        self.manager._prefill.prefix_offers[room] = (16, [3, 4, 5, 6])
        self.tree = self.fixtures._FakeTree(have_tokens=4)
        self.allocator = self.fixtures._FakeAllocator(free_tokens=64)
        self.puller = DecodePrefixPuller(
            kv_manager=self.manager,
            scheduler=SimpleNamespace(
                tree_cache=self.tree,
                token_to_kv_pool_allocator=self.allocator,
                req_to_token_pool=SimpleNamespace(req_to_token=torch.zeros(1)),
                attn_tp_cpu_group=None,
                attn_cp_cpu_group=None,
            ),
        )
        self.req = self.fixtures._req()
        self.puller.advance([self.req])
        self.manager._prefill.prefix_ready[room] = (
            self.fixtures.PX,
            99,
            self.fixtures.DECODE_RAIDEN,
            1,
            3,
        )
        self.puller.advance([self.req])
        self.assertEqual(self.puller._plans[room].state, "pulling")
        self.assertEqual(self.manager.prefix_read_state(self.fixtures.PX), "pending")
        # Removing the last bootstrapping request must not revoke this native read.
        self.puller.release(self.req)
        self.assertEqual(len(self.puller._zombies), 1)
        self.assertEqual(self.allocator.freed, [])
        self.cleared: list[str] = []
        self.tree.reset = lambda: self.cleared.append("tree")
        self.allocator.clear = lambda: self.cleared.append("allocator")
        self.scheduler = self._empty_scheduler()

    def _empty_scheduler(self) -> SimpleNamespace:
        scheduler = SimpleNamespace(
            running_batch=SimpleNamespace(reqs=[], is_empty=lambda: True),
            chunked_req=None,
            dllm_manager=SimpleNamespace(any_staging_reqs=lambda: False),
            last_batch=None,
            enable_overlap=False,
            _pp_microbatches_drained=lambda: True,
            waiting_queue=[],
            _engine_paused=False,
            disaggregation_mode=DisaggregationMode.PREFILL,
            grammar_manager=SimpleNamespace(
                grammar_queue=[], clear=lambda: self.cleared.append("grammar")
            ),
            disagg_prefill_inflight_queue=[],
            disagg_prefill_bootstrap_queue=SimpleNamespace(
                queue=[], decode_prefix_puller=self.puller
            ),
            _deferred_chunked_sender_aborts=[],
            enable_hisparse=False,
            enable_hierarchical_cache=False,
            enable_lmcache=False,
            tree_cache=self.tree,
            token_to_kv_pool_allocator=self.allocator,
            req_to_token_pool=SimpleNamespace(
                clear=lambda: self.cleared.append("req_pool"),
                reset_aux_cache_allocator=lambda: None,
            ),
            metrics_reporter=SimpleNamespace(
                reset_metrics=lambda: None,
                is_stats_logging_rank=False,
                record_scheduler_active=lambda _: None,
                record_scheduler_idle=lambda: None,
            ),
            draft_worker=None,
        )
        scheduler.is_fully_idle = lambda **kw: Scheduler.is_fully_idle(scheduler, **kw)
        return scheduler

    def test_last_aborted_recall_is_not_fully_idle(self) -> None:
        self.assertFalse(
            Scheduler.is_fully_idle(self.scheduler),
            "Pending reverse-read destinations survive the last request and must keep idle false",
        )

    def test_flush_refuses_native_reverse_read_destinations(self) -> None:
        flushed = Scheduler.flush_cache(self.scheduler, empty_cache=False)
        self.assertFalse(
            flushed,
            f"Flush must wait for the pending native receiver; cleared={self.cleared}",
        )
        self.assertEqual(self.cleared, [])
        self.assertEqual(self.manager.prefix_read_state(self.fixtures.PX), "pending")

    def test_empty_bootstrap_tick_drains_and_reaps_completed_recall(self) -> None:
        # Native completion is a one-shot queue, harvested only by the engine poll.
        self.manager._engine.poll_stats_with_details.return_value = (
            self.fixtures._polled(received=[self.fixtures.PX])
        )
        self.puller.advance([])
        self.assertEqual(
            self.allocator.freed,
            [self.fixtures.NEW_INDICES],
            "An empty bootstrap queue still has to harvest native completion and reap its zombie",
        )
        self.assertEqual(self.puller._zombies, [])

    def test_paused_control_tick_drains_before_retrying_cache_flush(self) -> None:
        self.scheduler._engine_paused = True
        self.manager._engine.poll_stats_with_details.return_value = (
            self.fixtures._polled(received=[self.fixtures.PX])
        )
        # Paused engines skip pop_bootstrapped/advance; this is their real control tick.
        PrefillBootstrapQueue.resolve_deferred_prefix_releases(
            self.scheduler.disagg_prefill_bootstrap_queue
        )
        Scheduler._record_scheduler_state_for_paused_engine(self.scheduler)
        self.assertTrue(Scheduler.flush_cache(self.scheduler, empty_cache=False))
        self.assertEqual(self.allocator.freed, [self.fixtures.NEW_INDICES])
        self.assertEqual(self.puller._zombies, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
