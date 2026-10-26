#!/usr/bin/env python3
"""Cross-host microbenchmark of tpu-sync 759530c7 host-to-host reads (the victim-cache H2H path), torch manager.

Uses the exact API the victim path uses on host-only managers:
  source: register_read(req_id, uuid, blocks, source="host")
  dest:   start_read(req_id, uuid, "<src ip>:<control port>", blocks, local_host_block_ids=..., destination="host")
          then poll_stats_with_details() until the req_id settles.
Geometry defaults to one gpt-oss-120b rank of the HiCache host pool: 18 full-attention layers,
8 KiB per (layer, 64-token page) (1 KV head x 64 dim x K+V x fp8).

  serve: python h2h_microbench.py serve --ctrl-port P --bench-port Q [--pages N]
  fetch: python h2h_microbench.py fetch --server IP --ctrl-port P --bench-port Q --sizes 16,128,... --reps 5
Source blocks hold seeded random bytes; the dest CRC-checks the first transfer of every size.
"""
from __future__ import annotations

import argparse
import ctypes
import json
import random
import socket
import statistics
import sys
import time
import zlib

import torch
import torch_tpu  # noqa: F401
from tpu_sync.api.torch.kv_cache_manager import KVCacheManager  # noqa: E402


def block_bytes(seed, layer, block, size):
    return random.Random(seed * 1_000_003 + layer * 65_537 + block).randbytes(size)


def make(a, pages):
    """Full torch manager (the HiCache host-pool manager kind): small TPU buffers, real host pool."""
    dev = torch.device("tpu", 0)
    tensors = [[torch.zeros((8, a.slice_bytes), dtype=torch.uint8, device=dev)] for _ in range(a.layers)]
    make.keep = tensors
    return KVCacheManager(tensors, local_control_port=a.local_port or a.ctrl_port, host_blocks_to_allocate=pages,
                          parallelism=a.parallelism, timeout_s=120.0, unsafe_skip_buffer_lock=True)


def serve(a):
    mgr = make(a, a.pages)
    t0 = time.time()
    for layer in range(a.layers):
        for b in range(a.pages):
            mgr.write_block_bytes(layer, b, block_bytes(a.seed, layer, b, a.slice_bytes))
    print(f"serve: {a.pages} pages x {a.layers} layers filled in {time.time()-t0:.1f}s; control port {a.ctrl_port}", flush=True)
    srv = socket.create_server(("0.0.0.0", a.bench_port))
    conn, _ = srv.accept()
    f = conn.makefile("rw")
    for line in f:
        cmd = line.split()
        if not cmd or cmd[0] == "STOP":
            break
        if cmd[0] == "REG":  # REG req_id uuid n
            ok = mgr.register_read(cmd[1], int(cmd[2]), list(range(int(cmd[3]))), source="host")
            f.write(f"OK {int(ok)}\n"); f.flush()
        elif cmd[0] == "POLL":  # drain the sender's reports so they never pile up
            s = mgr.poll_stats_with_details()
            f.write(f"SENT {len(s.sent)} FAILED {len(s.failed)}\n"); f.flush()
    print("serve: stop", flush=True)


def fetch(a):
    sizes = [int(x) for x in a.sizes.split(",")]
    mgr = make(a, max(sizes))
    conn = socket.create_connection((a.server, a.bench_port))
    f = conn.makefile("rw")
    endpoint = f"{a.server}:{a.ctrl_port}"
    results = []
    uuid = a.uuid_base
    for n in sizes:
        times, ok_crc = [], None
        for rep in range(a.warmup + a.reps):
            uuid += 1
            rid = f"mb-{a.node_id}-{uuid}"
            f.write(f"REG {rid} {uuid} {n}\n"); f.flush()
            assert f.readline().startswith("OK")
            t0 = time.perf_counter()
            mgr.start_read(rid, uuid, endpoint, list(range(n)), local_host_block_ids=list(range(n)),
                           parallelism=a.streams, destination="host")
            state = None
            while state is None:
                s = mgr.poll_stats_with_details()
                if any(t.req_id == rid for t in s.received):
                    state = "done"
                elif any(t.req_id == rid for t in s.failed):
                    state = "failed"
                else:
                    time.sleep(a.poll_us / 1e6)
            dt = time.perf_counter() - t0
            f.write("POLL\n"); f.flush(); f.readline()
            if state != "done":
                print(f"FAILED n={n} rep={rep}", flush=True); continue
            if rep == a.warmup:  # verify bytes once per size (outside the timing)
                bad = 0
                for layer in range(a.layers):
                    for b in range(n):
                        if mgr.read_block_bytes(layer, b) != block_bytes(a.seed, layer, b, a.slice_bytes):
                            bad += 1
                ok_crc = bad == 0
                if bad:
                    print(f"DATA MISMATCH n={n}: {bad} of {n*a.layers} blocks differ", flush=True)
            if rep >= a.warmup:
                times.append(dt)
        nbytes = n * a.layers * a.slice_bytes
        r = {"pages": n, "MiB": round(nbytes / 2**20, 2), "reps": len(times), "data_ok": ok_crc,
             "lat_p50_ms": round(statistics.median(times) * 1e3, 2) if times else None,
             "lat_min_ms": round(min(times) * 1e3, 2) if times else None,
             "lat_max_ms": round(max(times) * 1e3, 2) if times else None,
             "GiBps_p50": round(nbytes / statistics.median(times) / 2**30, 3) if times else None}
        results.append(r)
        print("RESULT " + json.dumps(r), flush=True)
    f.write("STOP\n"); f.flush()
    print("SUMMARY " + json.dumps({"server": a.server, "streams": a.streams, "parallelism": a.parallelism,
                                   "layers": a.layers, "slice_bytes": a.slice_bytes, "results": results}), flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("role", choices=["serve", "fetch"])
    ap.add_argument("--server", default="127.0.0.1")
    ap.add_argument("--ctrl-port", type=int, required=True)
    ap.add_argument("--bench-port", type=int, required=True)
    ap.add_argument("--local-port", type=int, default=0, help="this manager's control port (fetch); default --ctrl-port")
    ap.add_argument("--pages", type=int, default=4352)
    ap.add_argument("--sizes", default="16,128,512,2176,4352")
    ap.add_argument("--layers", type=int, default=18)
    ap.add_argument("--slice-bytes", type=int, default=8192)
    ap.add_argument("--parallelism", type=int, default=4, help="manager transfer parallelism")
    ap.add_argument("--streams", type=int, default=1, help="start_read parallelism")
    ap.add_argument("--warmup", type=int, default=1)
    ap.add_argument("--reps", type=int, default=5)
    ap.add_argument("--poll-us", type=int, default=100)
    ap.add_argument("--seed", type=int, default=5)
    ap.add_argument("--node-id", type=int, default=1)
    ap.add_argument("--uuid-base", type=int, default=1000)
    a = ap.parse_args()
    serve(a) if a.role == "serve" else fetch(a)


if __name__ == "__main__":
    main()
