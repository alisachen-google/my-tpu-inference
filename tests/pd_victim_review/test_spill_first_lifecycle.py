"""Host victim exports must progress before prefix recall is introduced.

Select the SGLang checkout with SGLANG_REVIEW_ROOT and PYTHONPATH. This probe
uses its real controller constructor, bootstrap queue hooks and CPU cache.
Only the external transport completion boundary is simulated.
"""

from __future__ import annotations

import importlib.util
import os
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock

from sglang.srt.disaggregation.prefill import PrefillBootstrapQueue
from sglang.srt.mem_cache.base_prefix_cache import EvictParams
from sglang_tpu.disaggregation.raiden.serde import VictimAck
from sglang_tpu.pd_victim_push import VictimPrefixPuller


class TestSpillFirstLifecycle(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        root = Path(os.environ.get("SGLANG_REVIEW_ROOT", "/tmp/sglang-victim-full-swa"))
        path = root / "test/registered/unit/hardware_backend/tpu/test_pd_victim_push.py"
        spec = importlib.util.spec_from_file_location("_spill_first_fixtures", path)
        if spec is None or spec.loader is None:
            raise RuntimeError(f"Cannot load CPU pool fixtures: {path}")
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        cls.fixtures = module

    def test_empty_and_paused_queue_ticks_settle_host_exports_without_recall(
        self,
    ) -> None:
        cache, allocator = self.fixtures.full_cache(host_capacity=32)
        host = cache.cache_controller.host
        manager = MagicMock()
        manager.local_ip = "127.0.0.1"
        manager.decode_peer.return_value = ("127.0.0.1", 5001)
        manager.send_victim_push.return_value = True
        acks: dict[int, VictimAck] = {}
        manager.take_victim_ack.side_effect = lambda seq: acks.pop(seq, None)
        scheduler = SimpleNamespace(
            tree_cache=cache,
            token_to_kv_pool_allocator=allocator,
            req_to_token_pool=cache.req_to_token_pool,
            attn_tp_cpu_group=None,
            attn_cp_cpu_group=None,
            waiting_queue=[],
        )
        controller = VictimPrefixPuller(
            kv_manager=manager, scheduler=scheduler, swa_window=None
        )
        queue = PrefillBootstrapQueue.__new__(PrefillBootstrapQueue)
        queue.scheduler = scheduler
        queue.scheduler_stage_metrics = None
        queue.decode_prefix_puller = controller
        queue.queue = []

        tokens = list(range(8))
        self.fixtures.insert_tokens(cache, allocator, tokens)
        controller.commit(SimpleNamespace(bootstrap_room=1, origin_input_ids=tokens))
        self.assertFalse(controller.has_pending_deferred_releases())
        cache.evict(EvictParams(num_tokens=len(tokens)))
        self.assertEqual(self.fixtures.device_hit(cache, tokens), 0)
        self.assertEqual(self.fixtures.host_hit(cache, tokens), len(tokens))

        # The real empty-queue path calls advance([]), so no later request is
        # needed to start the recorded branch's host export.
        self.assertEqual(queue.pop_bootstrapped(), [])
        manager.send_victim_push.assert_called_once()
        offered = manager.send_victim_push.call_args.kwargs
        self.assertEqual(offered["tokens"], tokens)
        self.assertEqual(
            list(host.transfer.registrations.values()),
            [(offered["uuid"], offered["blocks"], "host")],
        )
        self.assertTrue(controller.has_pending_deferred_releases())

        # An accepted offer alone cannot release source pages. Paused control
        # ticks drain existing work without starting another export.
        acks[offered["seq"]] = VictimAck(seq=offered["seq"], stored=True)
        queue.resolve_deferred_prefix_releases()
        cache.evict_host(len(tokens), self.fixtures.FULL)
        self.assertEqual(self.fixtures.host_hit(cache, tokens), len(tokens))
        self.assertTrue(controller.has_pending_deferred_releases())
        manager.send_victim_done.assert_not_called()

        host.transfer.complete("sent")
        queue.resolve_deferred_prefix_releases()
        self.assertFalse(controller.has_pending_deferred_releases())
        self.assertEqual(controller.pusher._pushes, {})
        self.assertEqual(controller.pusher.stats["started"], 1)
        self.assertEqual(controller.pusher.stats["stored"], 1)
        manager.send_victim_push.assert_called_once()
        manager.send_victim_done.assert_called_once_with(
            decode=("127.0.0.1", 5001), seq=offered["seq"], ok=True
        )
        cache.evict_host(len(tokens), self.fixtures.FULL)
        self.assertEqual(self.fixtures.host_hit(cache, tokens), 0)

        for method in (
            "take_prefix_offer",
            "ask_prefix_pull",
            "start_prefix_pull",
            "prefix_read_state",
        ):
            getattr(manager, method).assert_not_called()


if __name__ == "__main__":
    unittest.main()
