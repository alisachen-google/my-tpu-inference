"""Check whether a native session deadline drains a paused TCP data peer.

This is a bounded fault probe, not a throughput benchmark. It pauses only its
own spawned CPU consumer after one block arrived, observes the producer past
its session deadline, then resumes the consumer and drains both endpoints.
Pass the benchmark-only CPU binding directory built against tpu-sync 759530c7.
"""

from __future__ import annotations

import argparse
import importlib
import json
import multiprocessing as mp
import os
import signal
import sys
import time
from typing import Any


def _module(directory: str) -> Any:
    sys.path.insert(0, directory)
    return importlib.import_module("_host_pull_serve_benchmark")


def _consumer(directory: str, pipe: Any, blocks: int, block_bytes: int) -> None:
    impl = _module(directory).HostPoolManager(1, 1, block_bytes, blocks, 1, 0, 0.2)
    pipe.send("ready")
    endpoint, req_id, uuid = pipe.recv()
    ids = list(range(blocks))
    impl.start_read(req_id, uuid, endpoint, ids, [], 1, ids, True)
    deadline = time.monotonic() + 5
    while impl.read_block_bytes(0, 0)[0] != 125:
        if time.monotonic() > deadline:
            pipe.send("first block did not arrive")
            return
        time.sleep(0.0001)
    pipe.send("pausing after first block")
    os.kill(os.getpid(), signal.SIGSTOP)
    # The parent always sends SIGCONT before trying to join/terminate us.
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        report = impl.complete_read()
        if req_id in report[1] or req_id in report[2]:
            pipe.send("consumer drained")
            return
        time.sleep(0.001)
    pipe.send("consumer did not drain")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native-module-dir", required=True)
    args = parser.parse_args()
    blocks, block_bytes = 2048, 65536
    req_id, uuid = "paused-peer-review", 420009
    producer = _module(args.native_module_dir).HostPoolManager(
        1, 1, block_bytes, blocks, 1, 0, 0.2
    )
    producer.write_block_bytes(0, 0, bytes([125]) * block_bytes)
    ctx = mp.get_context("spawn")
    parent, child = ctx.Pipe()
    process = ctx.Process(
        target=_consumer,
        args=(args.native_module_dir, child, blocks, block_bytes),
    )
    process.start()
    result: dict[str, Any] = {
        "logical_timeout_s": 0.2,
        "paused_observation_s": 1.0,
        "payload_bytes": blocks * block_bytes,
        "only_owned_cpu_child_paused": True,
        "configured_io_timeouts": {
            key: value
            for key, value in os.environ.items()
            if key.startswith("TPU_RAIDEN_") and "TIMEOUT" in key
        },
    }
    try:
        if not parent.poll(10) or parent.recv() != "ready":
            raise RuntimeError("Consumer did not start")
        producer.notify_for_read(req_id, uuid, list(range(blocks)), True)
        parent.send((producer.listener_address, req_id, uuid))
        if not parent.poll(5):
            raise RuntimeError("Consumer did not report data arrival")
        event = parent.recv()
        if event != "pausing after first block":
            raise RuntimeError(event)
        # Ensure SIGSTOP has landed before starting the observation window.
        time.sleep(0.02)
        deadline = time.monotonic() + 1.0
        terminal = None
        while time.monotonic() < deadline:
            report = producer.complete_read()
            if req_id in report[0]:
                terminal = "sent"
            elif req_id in report[2]:
                terminal = "failed"
            time.sleep(0.002)
        result["producer_terminal_while_consumer_paused"] = terminal
        os.kill(process.pid, signal.SIGCONT)
        deadline = time.monotonic() + 10
        while terminal is None and time.monotonic() < deadline:
            report = producer.complete_read()
            if req_id in report[0]:
                terminal = "sent"
            elif req_id in report[2]:
                terminal = "failed"
            time.sleep(0.002)
        result["producer_terminal_after_resume"] = terminal
        if parent.poll(10):
            result["consumer_after_resume"] = parent.recv()
    finally:
        if process.is_alive():
            os.kill(process.pid, signal.SIGCONT)
        process.join(10)
        if process.is_alive():
            process.terminate()
            process.join(5)
        result["consumer_exit_code"] = process.exitcode
    print(json.dumps(result, indent=2), flush=True)


if __name__ == "__main__":
    main()
