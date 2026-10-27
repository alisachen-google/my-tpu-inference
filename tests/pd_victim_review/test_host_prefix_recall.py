"""CPU-only host recall regressions against SGLANG_REVIEW_ROOT.

Use real Raiden protocol managers and Python unified FULL/SWA trees. Only the
native byte transfer and device allocation boundaries are simulated. No model,
torch_tpu, hardware compilation or benchmark is started.
"""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from array import array
from datetime import timedelta
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

import torch
from sglang.srt.mem_cache.base_prefix_cache import MatchPrefixParams
from sglang.srt.mem_cache.radix_cache import RadixKey
from sglang.srt.mem_cache.unified_cache.component_type import ComponentType
from sglang_tpu import pd_decode_window_restore
from sglang_tpu import pd_host_prefix_recall as recall
from sglang_tpu.disaggregation.raiden.serde import PrefixOffer, PrefixPull, PrefixReady
from sglang_tpu.pd_host_cache import insert_host_prefix
from sglang_tpu.raiden_transfer import RaidenKVTransfer


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


ROOT = Path(os.environ["SGLANG_REVIEW_ROOT"])
FX = _load(
    "_host_recall_pools",
    ROOT / "test/registered/unit/hardware_backend/tpu/test_pd_victim_push.py",
)
PX = _load(
    "_host_recall_protocol",
    ROOT / "test/registered/unit/disaggregation/test_raiden_prefix_pull.py",
)


class TestHostPrefixRecall(unittest.TestCase):
    def pair(self, *, hybrid=True, eagle=False, count=None):
        count = count or (256 if hybrid else 8)
        if hybrid:
            dc, da = FX.hybrid_cache(is_eagle=eagle)
            pc, pa = FX.hybrid_cache(is_eagle=eagle)
            for allocator in (da, pa):
                allocator.size_full, allocator.size_swa = 4096, 1024
        else:
            dc, da = FX.full_cache(kv_size=64, host_capacity=256)
            pc, pa = FX.full_cache(kv_size=64, host_capacity=256)
        page = da.page_size
        tokens = list(range(count + int(eagle)))
        key = RadixKey(array("q", tokens), is_bigram=eagle)
        dh, ph = dc.cache_controller.host, pc.cache_controller.host
        ds = dc.host_pool_group.get_pool(FX.PoolName.SWA) if hybrid else None
        ps = pc.host_pool_group.get_pool(FX.PoolName.SWA) if hybrid else None
        insert_host_prefix(
            dc, key, dh.alloc(count), ds.alloc(min(count, 128)) if ds else None, page
        )
        dm, pm = PX._decode_manager(), PX._prefill_manager()
        for manager in (dm, pm):
            manager._prefix_host_reads = {}
            manager.kv_args = SimpleNamespace(page_size=page)
        dm.swa_raiden_endpoint = "device-swa:9001"
        dm._decode.prefix_offer_pending.add(PX.ROOM)
        dm._decode.prefill_addr[PX.ROOM] = PX.PREFILL_ADDR
        dm._decode.prefix_tokens[PX.ROOM] = count
        pm._prefill.prefix_offer_since[PX.ROOM] = time.time()
        pm._prefill.decode_addr[PX.ROOM] = ("10.0.0.2", 5555)
        dm._send_multipart_locked.side_effect = lambda addr, frames: pm._dispatch(
            frames
        )
        pm._send_multipart_locked.side_effect = lambda addr, frames: dm._dispatch(
            frames
        )
        req = SimpleNamespace(
            rid="host-recall",
            bootstrap_room=PX.ROOM,
            origin_input_ids=tokens
            + list(range(count + int(eagle), count + int(eagle) + page)),
            extra_key=None,
            cache_salt=None,
        )
        dr = SimpleNamespace(
            req=req,
            prefix_offer_sent=False,
            prefix_match=None,
            kv_receiver=SimpleNamespace(prefix_offer_pending=True),
        )

        def scheduler(cache, allocator):
            return SimpleNamespace(
                tree_cache=cache,
                token_to_kv_pool_allocator=allocator,
                req_to_token_pool=SimpleNamespace(
                    req_to_token=torch.empty((1, 1), dtype=torch.int64)
                ),
                attn_tp_cpu_group=None,
                attn_cp_cpu_group=None,
                disagg_decode_prealloc_queue=SimpleNamespace(kv_manager=dm),
            )

        queue = SimpleNamespace(tree_cache=dc, scheduler=scheduler(dc, da))
        source = recall.HostPrefixSource(queue, dm)
        puller = recall.HostPrefixPuller(
            kv_manager=pm,
            scheduler=scheduler(pc, pa),
            swa_window=128 if hybrid else None,
        )
        return SimpleNamespace(**locals())

    def start(self, pair):
        pair.source.offer(pair.dr)
        pair.puller.advance([pair.req])
        pair.puller.advance([pair.req])
        self.assertEqual(pair.puller._plans[PX.ROOM].state, "pulling")

    def finish(self, pair, *, full="received", swa="received"):
        pair.ph.transfer.complete(full)
        if pair.ps:
            pair.ps.transfer.complete(swa)
        pair.puller.advance([pair.req])

    def match(self, pair):
        return pair.pc.match_prefix(MatchPrefixParams(key=pair.key))

    def test_wire_memory_domain_is_explicit_and_device_default_is_compatible(self):
        offer = PrefixOffer(room=7, prefix_tokens=64, blocks=[4], source="host")
        self.assertEqual(PrefixOffer.from_frames(offer.to_frames()).source, "host")
        self.assertEqual(
            PrefixOffer(room=7, prefix_tokens=64, blocks=[4]).source, "device"
        )
        ready = PrefixReady(
            room=7,
            req_id="7#px",
            uuid=1,
            endpoint="host:1",
            first_page=0,
            num_pages=1,
            source="host",
        )
        self.assertEqual(PrefixReady.from_frames(ready.to_frames()).source, "host")

    def test_hybrid_recall_uses_host_pools_without_decode_hbm_or_prefill_hbm(self):
        p = self.pair()
        self.start(p)
        for pool in (p.dh, p.ds):
            self.assertTrue(pool.transfer.registrations)
            self.assertTrue(
                all(row[2] == "host" for row in pool.transfer.registrations.values())
            )
        for pool, expected in ((p.ph, 4), (p.ps, 2)):
            read = next(iter(pool.transfer.reads.values()))
            self.assertEqual(read["destination"], "host")
            self.assertIsNone(read["local_block_ids"])
            self.assertEqual(len(read["local_host_block_ids"]), expected)
        p.da.alloc.assert_not_called()
        p.pa.alloc.assert_not_called()
        p.dm._engine.register_read.assert_not_called()
        p.pm._engine.start_read.assert_not_called()
        self.finish(p)
        p.puller.commit(p.req)
        match = self.match(p)
        self.assertEqual(len(match.device_indices), 0)
        self.assertEqual(match.host_hit_length, 256)
        self.assertEqual(match.swa_host_hit_length, 128)
        self.assertEqual(p.puller.stats["pulled_tokens"], 256)

    def test_full_completion_alone_never_publishes_hybrid_prefix(self):
        p = self.pair()
        self.start(p)
        p.ph.transfer.complete("received")
        p.puller.advance([p.req])
        self.assertIsNone(p.puller._plans[PX.ROOM].agreed_done)
        self.assertFalse(p.pm.prefix_pull_resolved(PX.ROOM))
        self.assertEqual(self.match(p).host_hit_length, 0)
        self.finish(p)
        self.assertTrue(p.puller._plans[PX.ROOM].agreed_done)

    def test_abort_keeps_destinations_until_both_native_reads_drain(self):
        p = self.pair()
        self.start(p)
        p.puller.release(p.req)
        self.assertEqual((p.ph.used, p.ps.used), (256, 128))
        p.ph.transfer.complete("received")
        p.puller.resolve_deferred_releases()
        self.assertTrue(p.puller.has_pending_deferred_releases())
        self.assertEqual((p.ph.used, p.ps.used), (256, 128))
        p.ps.transfer.complete("failed")
        p.puller.resolve_deferred_releases()
        self.assertFalse(p.puller.has_pending_deferred_releases())
        self.assertEqual((p.ph.used, p.ps.used), (0, 0))
        self.assertEqual(self.match(p).host_hit_length, 0)

    def test_swa_start_failure_retains_accepted_full_destination(self):
        p = self.pair()
        p.ps.transfer.read_error = RuntimeError("SWA start rejected")
        p.source.offer(p.dr)
        p.puller.advance([p.req])
        p.puller.advance([p.req])
        self.assertNotIn(PX.ROOM, p.puller._plans)
        self.assertEqual((p.ph.used, p.ps.used), (256, 128))
        p.ph.transfer.complete("failed")
        p.puller.resolve_deferred_releases()
        self.assertEqual((p.ph.used, p.ps.used), (0, 0))

    def test_native_swa_failure_falls_back_without_publishing_full_only(self):
        p = self.pair()
        self.start(p)
        self.finish(p, swa="failed")
        p.puller.commit(p.req)
        self.assertEqual((p.ph.used, p.ps.used), (0, 0))
        self.assertEqual(self.match(p).host_hit_length, 0)

    def test_source_pin_outlives_queue_exit_and_room_cleanup(self):
        p = self.pair()
        self.start(p)
        p.source.release(PX.ROOM)
        p.dm.clear_room(PX.ROOM)
        p.source.step()
        self.assertTrue(p.source.offers)
        p.dc.evict_host(256, ComponentType.FULL)
        self.assertEqual(p.dh.used, 256)
        p.dh.transfer.complete("sent")
        p.source.step()
        self.assertTrue(p.source.offers)
        p.ds.transfer.complete("failed")
        p.source.step()
        self.assertFalse(p.source.offers)
        p.dc.evict_host(256, ComponentType.FULL)
        self.assertEqual(p.dh.used, 0)

    def test_false_registration_still_keeps_source_until_terminal(self):
        p = self.pair()
        p.dh.transfer.registration_result = False
        self.start(p)
        p.source.release(PX.ROOM)
        p.source.step()
        self.assertTrue(p.source.offers)
        self.assertTrue(p.dm.host_prefix_pending(PX.ROOM))
        p.dh.transfer.complete("sent")
        p.ds.transfer.complete("sent")
        p.source.step()
        self.assertFalse(p.source.offers)

    def test_no_host_room_declines_without_allocating_hbm(self):
        p = self.pair()
        p.ps.alloc = Mock(return_value=None)
        p.source.offer(p.dr)
        p.puller.advance([p.req])
        p.puller.advance([p.req])
        self.assertNotIn(PX.ROOM, p.puller._plans)
        self.assertEqual(p.ph.used, 0)
        p.pa.alloc.assert_not_called()
        self.assertTrue(p.pm.prefix_pull_resolved(PX.ROOM))

    def test_received_host_prefix_is_pinned_until_admission_leaves_waiting_queue(self):
        p = self.pair()
        self.start(p)
        self.finish(p)
        p.puller.commit(p.req)
        p.pc.evict_host(256, ComponentType.FULL)
        self.assertEqual(p.ph.used, 256)
        p.puller.advance([], waiting_reqs=[p.req])
        p.pc.evict_host(256, ComponentType.FULL)
        self.assertEqual(p.ph.used, 256)
        p.puller.advance([])
        p.pc.evict_host(256, ComponentType.FULL)
        self.assertEqual(p.ph.used, 0)

    def test_partial_local_host_prefix_is_reused_and_never_freed_as_duplicate(self):
        p = self.pair()
        partial = RadixKey(array("q", p.tokens[:128]))
        existing = p.ph.alloc(128)
        insert_host_prefix(p.pc, partial, existing, p.ps.alloc(128), p.page)
        self.start(p)
        plan = p.puller._plans[PX.ROOM]
        self.assertEqual((plan.first_page, plan.num_pages), (2, 2))
        self.assertEqual(
            len(next(iter(p.ph.transfer.reads.values()))["remote_block_ids"]), 2
        )
        self.finish(p)
        p.puller.commit(p.req)
        self.assertEqual(p.ph.used, 256)
        self.assertEqual(self.match(p).host_hit_length, 256)
        self.assertEqual(self.match(p).swa_host_hit_length, 128)

    def test_complete_local_host_hit_skips_network(self):
        p = self.pair()
        insert_host_prefix(p.pc, p.key, p.ph.alloc(256), p.ps.alloc(128), p.page)
        p.source.offer(p.dr)
        p.puller.advance([p.req])
        self.assertFalse(p.puller._plans)
        self.assertFalse(p.ph.transfer.reads)
        self.assertTrue(p.pm.prefix_pull_resolved(PX.ROOM))

    def test_eagle_host_recall_preserves_bigram_boundary(self):
        p = self.pair(eagle=True)
        self.start(p)
        self.finish(p)
        p.puller.commit(p.req)
        self.assertEqual(self.match(p).host_hit_length, 256)
        self.assertEqual(self.match(p).swa_host_hit_length, 128)

    def test_full_only_recall_loads_into_device_only_when_admission_requests_it(self):
        p = self.pair(hybrid=False)
        free = p.pa.available_size()
        self.start(p)
        self.finish(p)
        p.puller.commit(p.req)
        self.assertEqual(p.pa.available_size(), free)
        node = p.pc.match_prefix(MatchPrefixParams(key=p.key)).best_match_node
        loaded = []

        def load(host_indices, *, node_id, extra_pools):
            loaded.append(host_indices.clone())
            return p.pa.alloc(len(host_indices))

        p.pc.cache_controller.load = load
        p.pc.load_back_threshold = 1
        self.assertTrue(p.pc.load_back(node))
        self.assertEqual(p.pa.available_size(), free - 8)
        self.assertEqual(len(loaded[0]), 8)

    def test_ordinary_mode_still_calls_existing_offer_path(self):
        upstream = Mock()
        queue = SimpleNamespace(tree_cache=Mock())
        with (
            patch.dict(os.environ, {"SGLANG_DISAGG_PREFIX_VICTIM_PUSH": "0"}),
            patch.object(
                pd_decode_window_restore, "uses_window_host_cache", return_value=False
            ),
        ):
            pd_decode_window_restore._offer_resident_prefixes(upstream, queue, [])
        upstream.assert_called_once_with(queue, [])

    def test_source_partial_registration_failure_keeps_accepted_full_pin(self):
        p = self.pair()
        p.ds.transfer.registration_error = RuntimeError("SWA registration rejected")
        p.source.offer(p.dr)
        p.puller.advance([p.req])
        p.puller.advance([p.req])
        self.assertFalse(p.puller._plans)
        self.assertEqual((p.ph.used, p.ps.used), (0, 0))
        p.source.release(PX.ROOM)
        p.source.step()
        self.assertTrue(p.source.offers)
        p.dh.transfer.complete("failed")
        p.source.step()
        self.assertFalse(p.source.offers)

    def test_room_cleanup_does_not_lose_pending_receive_completion(self):
        p = self.pair()
        self.start(p)
        p.puller.release(p.req)
        p.pm.clear_room(PX.ROOM)
        self.assertTrue(p.pm.host_prefix_pending(PX.ROOM))
        self.assertEqual(p.pm.prefix_read_state("7#px"), "pending")
        p.ph.transfer.complete("received")
        p.ps.transfer.complete("failed")
        p.puller.resolve_deferred_releases()
        self.assertEqual((p.ph.used, p.ps.used), (0, 0))

    def test_release_closes_offer_before_a_late_pull_can_register_pages(self):
        p = self.pair()
        p.source.offer(p.dr)
        p.source.release(PX.ROOM)
        p.source.step()
        p.dm._on_prefix_pull(
            PrefixPull(
                room=7, first_page=0, num_pages=4, swa_first_page=2, swa_num_pages=2
            ).to_frames()
        )
        self.assertFalse(p.dh.transfer.registrations)
        self.assertFalse(p.ds.transfer.registrations)

    def test_host_offer_hook_bypasses_decode_window_restore(self):
        p = self.pair()

        class Queue:
            pass

        queue = Queue()
        queue.tree_cache, queue.scheduler = p.dc, p.queue.scheduler
        upstream = Mock()
        with (
            patch.dict(os.environ, {"SGLANG_DISAGG_PREFIX_VICTIM_PUSH": "1"}),
            patch.object(
                pd_decode_window_restore,
                "_advance_restores",
                side_effect=AssertionError("Decode H2D restore invoked"),
            ),
        ):
            pd_decode_window_restore._offer_resident_prefixes(upstream, queue, [p.dr])
        upstream.assert_not_called()
        source = recall._sources.pop(queue)
        source.release(7)
        source.step()

    def test_cache_reset_rejects_pinned_or_native_owned_host_pages(self):
        p = self.pair()

        class Queue:
            pass

        queue = Queue()
        recall._sources[queue] = p.source
        try:
            self.start(p)
            with self.assertRaisesRegex(RuntimeError, "host prefix offers are pinned"):
                recall.reset_host_offers(p.dc)
            with self.assertRaisesRegex(RuntimeError, "prefix reads are in flight"):
                p.puller.release_all()
            self.assertEqual((p.ph.used, p.ps.used), (256, 128))
            p.ph.transfer.complete("failed")
            p.ps.transfer.complete("failed")
            p.puller.release_all()
            p.source.release(7)
            p.dh.transfer.complete("sent")
            p.ds.transfer.complete("sent")
            recall.reset_host_offers(p.dc)
        finally:
            recall._sources.pop(queue)

    def test_early_native_report_is_not_overwritten_after_register_returns(self):
        transfer = RaidenKVTransfer.__new__(RaidenKVTransfer)
        transfer._host_transfers = {"other": None}

        def register(*args, **kwargs):
            transfer.poll_transfer("other")
            return True

        transfer._mgr = SimpleNamespace(
            register_read=register,
            poll_stats_with_details=lambda: SimpleNamespace(
                sent=[SimpleNamespace(req_id="early")], received=[], failed=[]
            ),
        )
        transfer.register_read("early", 1, [3], source="host")
        self.assertEqual(transfer.poll_transfer("early"), "sent")

    def test_two_rank_asymmetric_completion_and_failure_do_not_hang(self):
        with tempfile.TemporaryDirectory(prefix="host-recall-gloo-") as directory:
            directory = Path(directory)
            children = []
            for rank in (0, 1):
                log = (directory / f"rank-{rank}.log").open("w")
                child = subprocess.Popen(
                    [sys.executable, __file__, "--rank", str(rank), str(directory)],
                    env=dict(
                        os.environ,
                        PYTHONPATH=f"{ROOT / 'python'}:{ROOT}",
                        SGLANG_PLUGINS="none",
                    ),
                    stdout=log,
                    stderr=subprocess.STDOUT,
                )
                children.append((child, log))
            try:
                for rank, (child, log) in enumerate(children):
                    self.assertEqual(
                        child.wait(timeout=45),
                        0,
                        (directory / f"rank-{rank}.log").read_text(),
                    )
                for rank in (0, 1):
                    self.assertEqual(
                        json.loads((directory / f"rank-{rank}.json").read_text()),
                        {"rank": rank, "pending": False, "full": 0, "swa": 0},
                    )
            finally:
                for child, log in children:
                    if child.poll() is None:
                        child.kill()
                    child.wait()
                    log.close()


def _rank_worker(rank: int, directory: Path) -> None:
    import torch.distributed as dist

    dist.init_process_group(
        "gloo",
        rank=rank,
        world_size=2,
        init_method=f"file://{directory / 'rendezvous'}",
        timeout=timedelta(seconds=12),
    )
    try:
        p = TestHostPrefixRecall().pair()
        p.puller._groups = p.source.groups = [dist.group.WORLD]
        if rank == 1:
            p.ps.transfer.read_error = RuntimeError("rank-one SWA start failure")
        p.source.offer(p.dr)
        p.puller.advance([p.req])
        p.puller.advance([p.req])
        p.puller.advance([p.req])
        if rank == 0:
            p.ph.transfer.complete("received")
            p.ps.transfer.complete("received")
        p.puller.resolve_deferred_releases()
        assert p.puller.has_pending_deferred_releases()
        if rank == 1:
            p.ph.transfer.complete("failed")
        p.puller.resolve_deferred_releases()
        (directory / f"rank-{rank}.json").write_text(
            json.dumps(
                {
                    "rank": rank,
                    "pending": p.puller.has_pending_deferred_releases(),
                    "full": p.ph.used,
                    "swa": p.ps.used,
                }
            )
        )
        dist.barrier()
    finally:
        dist.destroy_process_group()


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--rank":
        _rank_worker(int(sys.argv[2]), Path(sys.argv[3]))
    else:
        unittest.main()
