"""Regression probes for the SGLang victim protocol, kept outside its feature PR.

Run with SGLang and its python/ directory on PYTHONPATH, for example:
  SGLANG_PLUGINS=none TORCH_DEVICE_BACKEND_AUTOLOAD=0 \
    PYTHONPATH=/path/to/sglang/python:/path/to/sglang \
    python tests/pd_victim_review/test_host_spill_cleanup.py

The manager below replaces only the external control-message inbox. The tests
execute the real DecodeReceiver polling and cleanup methods without a TPU.
"""

from __future__ import annotations

import importlib.util
import os
import sys
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from typing import Any
from unittest.mock import MagicMock

from sglang.srt.mem_cache.base_prefix_cache import EvictParams
from sglang.test.test_utils import CustomTestCase
from sglang_tpu import pd_victim_push as victim
from sglang_tpu.disaggregation.raiden.serde import VictimAck, VictimDone


class _Inbox:
    def __init__(self) -> None:
        self.pushes: dict[tuple[str, int], Any] = {}
        self.dones: dict[tuple[str, int], VictimDone] = {}

    def victim_pushes(self) -> dict[tuple[str, int], Any]:
        return dict(self.pushes)

    def victim_dones(self) -> dict[tuple[str, int], VictimDone]:
        return dict(self.dones)

    def take_victim_done(self, key: tuple[str, int]) -> VictimDone | None:
        return self.dones.pop(key, None)


def _idle_receiver(inbox: _Inbox) -> victim.DecodeReceiver:
    receiver = victim.DecodeReceiver.__new__(victim.DecodeReceiver)
    receiver._mgr = inbox
    receiver._groups = []
    receiver._landings = {}
    receiver._first_seen = {}
    receiver._iterations = victim._CADENCE - 1
    receiver._rounds = 0
    receiver._last_log = [time.monotonic()]
    receiver.stats = {"received": 0, "dropped": 0}
    return receiver


class TestHostSpillCleanup(CustomTestCase):
    def test_refused_victims_do_not_accumulate_done_messages_while_idle(self) -> None:
        inbox = _Inbox()
        receiver = _idle_receiver(inbox)
        # Refused offers have no landing. Prefill still reports DONE after its
        # unpulled native registrations expire, with a fresh seq each time.
        for seq in range(100):
            inbox.dones[("prefill", seq)] = VictimDone(
                prefill="prefill", seq=seq, ok=False
            )
        receiver.step()
        self.assertEqual(inbox.dones, {})
        self.assertFalse(receiver.holds_pages())

    def test_done_waits_for_an_offer_not_yet_admitted_on_all_ranks(self) -> None:
        inbox = _Inbox()
        receiver = _idle_receiver(inbox)
        key = ("prefill", 3)
        inbox.pushes[key] = object()
        done = VictimDone(prefill=key[0], seq=key[1], ok=True)
        inbox.dones[key] = done
        receiver._finish_agreed()
        self.assertEqual(inbox.dones, {key: done})


class TestHostSpillIdleOwnership(CustomTestCase):
    @classmethod
    def setUpClass(cls) -> None:
        root = Path(os.environ.get("SGLANG_REVIEW_ROOT", "/tmp/sglang-victim-full-swa"))
        path = root / "test/registered/unit/hardware_backend/tpu/test_pd_victim_push.py"
        spec = importlib.util.spec_from_file_location("_host_review_fixtures", path)
        if spec is None or spec.loader is None:
            raise RuntimeError(f"Cannot load CPU pool fixtures: {path}")
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        cls.fixtures = module

    def setUp(self) -> None:
        self.cache, self.allocator = self.fixtures.full_cache(host_capacity=32)
        self.host = self.cache.cache_controller.host
        self.manager = MagicMock()
        self.manager.local_ip = "127.0.0.1"
        self.manager.decode_peer.return_value = ("127.0.0.1", 5001)
        self.acks: dict[int, VictimAck] = {}
        self.manager.take_victim_ack.side_effect = lambda seq: self.acks.pop(seq, None)
        self.pusher = victim.PrefillPusher(
            SimpleNamespace(
                _mgr=self.manager,
                _tree_cache=self.cache,
                _page_size=1,
                _groups=[],
            )
        )
        self.tokens = list(range(8))
        self.fixtures.insert_tokens(self.cache, self.allocator, self.tokens)
        self.pusher.record(
            SimpleNamespace(bootstrap_room=1, origin_input_ids=self.tokens)
        )
        self.cache.evict(EvictParams(num_tokens=8))
        self.puller = victim.VictimPrefixPuller.__new__(victim.VictimPrefixPuller)
        self.puller._external_reads_outstanding = False
        self.puller.pusher = self.pusher

    def test_host_exports_keep_idle_false_without_reverse_read_zombies(self) -> None:
        self.assertFalse(self.puller.has_pending_deferred_releases())
        self.pusher.step()
        self.assertEqual(len(self.pusher._pushes), 1)
        self.assertTrue(self.puller.has_pending_deferred_releases())

    def test_control_tick_retires_exports_without_starting_new_victims(self) -> None:
        self.pusher.step()
        offer = self.manager.send_victim_push.call_args.kwargs
        self.acks[offer["seq"]] = VictimAck(seq=offer["seq"], stored=True)
        self.host.transfer.complete("sent")
        self.puller.resolve_deferred_releases()
        self.assertFalse(self.puller.has_pending_deferred_releases())
        self.assertEqual(self.pusher._pushes, {})
        self.assertEqual(self.pusher.stats["started"], 1)
        self.assertEqual(self.pusher.stats["stored"], 1)
        self.cache.evict_host(8, self.fixtures.FULL)
        self.assertEqual(self.fixtures.host_hit(self.cache, self.tokens), 0)


if __name__ == "__main__":
    unittest.main()
