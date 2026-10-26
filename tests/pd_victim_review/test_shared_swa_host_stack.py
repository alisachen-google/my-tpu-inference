"""CPU checks for the shared Prefill/Decode host stack in an external checkout.

The real assembler, pool groups, layer mappings and strategy registry execute.
Only host-buffer construction and the native controller boundary are replaced.
No TPU, network transfer or benchmark is started.
"""

from __future__ import annotations

import contextlib
import importlib.util
import os
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from sglang.srt.mem_cache.hicache_storage import PoolName
from sglang.srt.mem_cache.hybrid_cache import hybrid_pool_assembler as assembler
from sglang.srt.mem_cache.swa_memory_pool import SWAKVPool
from sglang.srt.mem_cache.unified_cache.component_type import ComponentType
from sglang.srt.runtime_context import publish, reset_context
from sglang.srt.server_args import ServerArgs
from sglang_tpu import pd_decode_swa_hicache as tpu
from sglang_tpu.envs import envs as tpu_envs


def load_fixture(name: str, filename: str):
    root = Path(os.environ["SGLANG_REVIEW_ROOT"])
    source = root / "test/registered/unit/hardware_backend/tpu" / filename
    spec = importlib.util.spec_from_file_location(name, source)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load fixture: {source}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class TestSharedSwaHostStack(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fixtures = load_fixture(
            "_shared_swa_fixtures", "test_pd_decode_swa_hicache.py"
        )
        cls.victim = load_fixture("_shared_swa_pools", "test_pd_victim_push.py")

    def setUp(self) -> None:
        reset_context()
        self.addCleanup(reset_context)
        publish(ServerArgs(model_path="dummy"), role="scheduler")
        self.cache, self.params = self.fixtures.real_swa_cache()
        self.params.token_to_kv_pool_allocator.swa_attn_allocator = MagicMock()
        self.params.token_to_kv_pool_allocator.bind_swa_for_loaded_rows = MagicMock()
        self.params.token_to_kv_pool_allocator.free_swa = MagicMock()
        self.kv = MagicMock(spec=SWAKVPool)
        self.kv.start_layer = 8
        self.kv.layers_mapping = {
            8: (0, True),
            9: (0, False),
            10: (1, True),
            11: (1, False),
        }
        self.kv.full_kv_pool = MagicMock(size=4096, layer_num=2)
        self.kv.swa_kv_pool = MagicMock(size=4096, layer_num=2)
        self.kv.full_kv_pool.host_capacity_bytes = None
        self.kv.swa_kv_pool.host_capacity_bytes = None
        self.kv.full_kv_pool.get_kv_size_bytes.return_value = (3072000, 3072000)
        self.kv.swa_kv_pool.get_kv_size_bytes.return_value = (1024000, 1024000)
        self.options = dict(
            cache=self.cache,
            kvcache=self.kv,
            params=self.params,
            server_args=None,
            load_cache_event=None,
        )

    @contextlib.contextmanager
    def boundary(self, *, role="prefill", size=8, windows=0, unified=False):
        memory = self.fixtures.memory(hicache_size=size, enable_unified_memory=unified)
        created = []

        def host_pool(**kwargs):
            pool = self.victim._FakeHostPool(capacity=4096, page_size=64)
            pool.host_size = kwargs.get("host_size")
            pool.layout = "fused_raiden"
            pool.device = self.params.token_to_kv_pool_allocator.device
            pool.size = pool.logical_size = pool.capacity
            pool.can_use_write_back_jit = False
            created.append(pool)
            return pool

        with (
            patch.object(
                tpu, "get_disagg", return_value=self.fixtures.disagg(mode=role)
            ),
            patch.object(tpu, "get_memory", return_value=memory),
            patch.object(assembler, "get_memory", return_value=memory),
            patch.object(
                assembler, "build_kv_host_pool", autospec=True, side_effect=host_pool
            ),
            patch.object(
                tpu.HybridCacheController,
                "create_for_backend",
                side_effect=lambda *a, **kw: MagicMock(),
            ) as controller,
            tpu_envs.SGLANG_TPU_PD_DECODE_SWA_HOST_WINDOWS.override(windows),
        ):
            yield created, controller

    def signature(self, result):
        return {
            entry.name: (
                entry.host_pool.host_size,
                tuple(entry.layer_mapper(layer) for layer in range(7)),
                entry.packed_draft_device_pools,
                entry.is_primary_index_anchor,
            )
            for entry in result.host_pool_group.entries
        }

    def test_prefill_keeps_upstream_budget_layout_and_controller_contract(self) -> None:
        for size in (0, 8):
            for unified in (False, True):
                with (
                    self.subTest(size=size, unified=unified),
                    self.boundary(size=size, unified=unified) as (_, controller),
                ):
                    reference = assembler._SwaStrategy().build(**self.options)
                    expected = controller.call_args
                    result = tpu._SWA_HOST_STRATEGY.build(**self.options)
                    actual = controller.call_args
                    self.assertEqual(self.signature(result), self.signature(reference))
                    self.assertEqual(expected.kwargs, actual.kwargs)
                    self.assertEqual(expected.args[0], actual.args[0])
                    self.assertEqual(expected.args[2:], actual.args[2:])
                    self.assertIs(actual.args[1], result.host_pool_group)
                    self.assertFalse(tpu.uses_full_only_host_cache(self.cache))
                    self.assertFalse(tpu.uses_window_host_cache(self.cache))
                    swa = result.host_pool_group.entry_map[PoolName.SWA]
                    allocator = self.params.token_to_kv_pool_allocator
                    if unified:
                        self.assertEqual(
                            swa.device_indices_from_anchor_fn,
                            allocator.bind_swa_for_loaded_rows,
                        )
                        self.assertEqual(swa.device_free_fn, allocator.free_swa)
                    else:
                        self.assertEqual(
                            swa.device_alloc_fn, allocator.swa_attn_allocator.alloc
                        )
                        self.assertEqual(
                            swa.device_free_fn, allocator.swa_attn_allocator.free
                        )

    def test_decode_window_setting_does_not_change_prefill_capacity(self) -> None:
        with self.boundary(windows=128):
            result = tpu._SWA_HOST_STRATEGY.build(**self.options)
        self.assertEqual(result.host_pool_group.get_pool(PoolName.KV).host_size, 6)
        self.assertEqual(result.host_pool_group.get_pool(PoolName.SWA).host_size, 2)
        self.assertFalse(tpu.uses_full_only_host_cache(self.cache))

    def test_prefill_preserves_packed_draft_swa_mapping(self) -> None:
        draft_swa = MagicMock(layer_num=1)
        self.params.mtp_draft_device_pools = (SimpleNamespace(swa_kv_pool=draft_swa),)
        with self.boundary():
            reference = assembler._SwaStrategy().build(**self.options)
            result = tpu._SWA_HOST_STRATEGY.build(**self.options)
        self.assertEqual(self.signature(result), self.signature(reference))
        self.assertEqual(
            result.host_pool_group.entry_map[PoolName.SWA].packed_draft_device_pools,
            (draft_swa,),
        )

    def test_decode_keeps_independent_window_budget_and_full_layer_span(self) -> None:
        for windows in (0, -1, 8):
            with (
                self.subTest(windows=windows),
                self.boundary(role="decode", windows=windows),
                tpu._full_only_host_cache_build(None),
            ):
                result = tpu._SWA_HOST_STRATEGY.build(**self.options)
                self.assertTrue(tpu.uses_full_only_host_cache(self.cache))
                full = result.host_pool_group.entry_map[PoolName.KV]
                self.assertEqual(full.layer_mapper(3), 1)
                if windows > 0:
                    self.assertIsNone(full.host_pool.host_size)
                    swa = result.host_pool_group.get_pool(PoolName.SWA)
                    # 500 bytes/token; 8 windows x 3 pages x 64 tokens.
                    self.assertAlmostEqual(swa.host_size * 1e9 / 500, 8 * 3 * 64)
                    self.assertTrue(tpu.uses_window_host_cache(self.cache))
                else:
                    self.assertEqual(full.host_pool.host_size, 8)
                    self.assertEqual(
                        set(result.component_host_pools), {ComponentType.FULL}
                    )

    def test_roles_keep_independent_host_allocations(self) -> None:
        with self.boundary():
            prefill = tpu._SWA_HOST_STRATEGY.build(**self.options)
        with (
            self.boundary(role="decode", windows=8),
            tpu._full_only_host_cache_build(None),
        ):
            decode = tpu._SWA_HOST_STRATEGY.build(**self.options)
        for name in (PoolName.KV, PoolName.SWA):
            source = prefill.host_pool_group.get_pool(name)
            target = decode.host_pool_group.get_pool(name)
            self.assertIsNot(source, target)
            self.assertIsNot(prefill.cache_controller, decode.cache_controller)
            available = target.available_size()
            indices = source.alloc(64)
            self.assertEqual(target.available_size(), available)
            source.free(indices)

    def test_failed_construction_does_not_register_decode_restore_policy(self) -> None:
        for windows in (0, 8):
            with (
                self.subTest(windows=windows),
                self.boundary(role="decode", windows=windows) as (_, controller),
                tpu._full_only_host_cache_build(None),
            ):
                controller.side_effect = RuntimeError(
                    "injected controller construction failure"
                )
                with self.assertRaisesRegex(RuntimeError, "injected"):
                    tpu._SWA_HOST_STRATEGY.build(**self.options)
                self.assertFalse(tpu.uses_full_only_host_cache(self.cache))
                self.assertFalse(tpu.uses_window_host_cache(self.cache))

    def test_registry_selects_only_the_matching_pd_roles_and_backend(self) -> None:
        components = {ComponentType.FULL, ComponentType.SWA}
        with self.fixtures.installed_patches():
            for role, backend, matches in (
                ("prefill", "raiden", True),
                ("prefill", "kernel", False),
                ("decode", "raiden", False),
                ("null", "raiden", False),
            ):
                with (
                    self.subTest(role=role, backend=backend),
                    patch.object(
                        tpu, "get_disagg", return_value=self.fixtures.disagg(mode=role)
                    ),
                    patch.object(
                        tpu,
                        "get_memory",
                        return_value=self.fixtures.memory(hicache_io_backend=backend),
                    ),
                ):
                    selected = assembler._select_strategy(self.kv, components)
                    self.assertEqual(selected is tpu._SWA_HOST_STRATEGY, matches)
            with tpu._full_only_host_cache_build(None):
                self.assertIs(
                    assembler._select_strategy(self.kv, components),
                    tpu._SWA_HOST_STRATEGY,
                )
            self.assertFalse(
                tpu._SWA_HOST_STRATEGY.matches(
                    self.kv, components | {ComponentType.MAMBA}
                )
            )


if __name__ == "__main__":
    unittest.main()
