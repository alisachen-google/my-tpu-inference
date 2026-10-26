"""Run the relevant CPU unit suites without importing or compiling on TPU.

The OOT platform inventory imports decorators naming the TPU compiler. Register
a guard so these decorators can be imported; any compiler invocation fails.
Plugin discovery remains enabled for the tests that explicitly exercise it.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sglang-root", type=Path, required=True)
    parser.add_argument("--junit-xml", type=Path)
    args = parser.parse_args()
    root = args.sglang_root.resolve()
    sys.path[:0] = [str(root / "python"), str(root)]
    os.environ["SGLANG_REVIEW_ROOT"] = str(root)
    os.environ["TORCH_DEVICE_BACKEND_AUTOLOAD"] = "0"
    os.environ["PYTEST_DISABLE_PLUGIN_AUTOLOAD"] = "1"
    os.environ.pop("SGLANG_PLUGINS", None)

    import pytest
    from torch._dynamo.backends import registry

    compiler_calls = 0

    def forbid_tpu_compile(*_args, **_kwargs):
        nonlocal compiler_calls
        compiler_calls += 1
        raise AssertionError("CPU-only review must never invoke the TPU compiler")

    if "tpu" not in registry._BACKENDS:
        registry.register_backend(forbid_tpu_compile, name="tpu")

    suites = [
        "hardware_backend/tpu/test_pd_decode_swa_hicache.py",
        "hardware_backend/tpu/test_pd_victim_push.py",
        "hardware_backend/tpu/test_tpu_raiden_hybrid_offload_unit.py",
        "hardware_backend/tpu/test_tpu_raiden_offload_unit.py",
        "hardware_backend/tpu/test_raiden_host_transfer.py",
        "mem_cache/test_hybrid_pool_assembler.py",
        "disaggregation/test_raiden_prefix_pull.py",
        "plugins/test_tpu_oot_platform_contract.py",
    ]
    paths = [str(root / "test/registered/unit" / name) for name in suites]
    paths.append(str(Path(__file__).with_name("test_shared_swa_host_stack.py")))
    options = ["-q", "-c", str(root / "test/pytest.ini")]
    if args.junit_xml:
        args.junit_xml.parent.mkdir(parents=True, exist_ok=True)
        options += [f"--junitxml={args.junit_xml}"]
    status = pytest.main(options + paths)
    if compiler_calls or "torch_tpu" in sys.modules:
        raise AssertionError("CPU-only boundary violated")
    print("CPU boundary verified: no TPU compiler calls and no torch_tpu import.")
    return int(status)


if __name__ == "__main__":
    raise SystemExit(main())
