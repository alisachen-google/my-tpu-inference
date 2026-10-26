#!/usr/bin/env python3
"""In-process loopback microbenchmark of tpu-sync 759530c7 host-to-host reads on the torch manager.

Each pair is a source and a destination KVCacheManager wrapping small per-layer TPU buffers and a
host pool of real size (the HiCache layout: host block = one 64-token page of one layer). The
destination reads source host blocks into its own host blocks over tpu-sync's transport:
  src.register_read(rid, uuid, blocks, source="host")
  dst.start_read(rid, uuid, "127.0.0.1:<src control port>", blocks, local_host_block_ids=..., destination="host")
  dst.poll_stats_with_details() until rid settles
With --pairs > 1 every pair transfers at the same time (8 ranks pushing at once).
Source blocks hold seeded random bytes; the first transfer of every size is byte-checked.
"""
from __future__ import annotations

import argparse
import json
import random
import statistics
import time

import torch
import torch_tpu  # noqa: F401
from tpu_sync.api.torch.kv_cache_manager import KVCacheManager


def payload(seed, layer, block, size):
    return random.Random(seed * 1_000_003 + layer * 65_537 + block).randbytes(size)


def manager(a, port, device_index, host_pages):
    dev = torch.device("tpu", device_index)
    tensors = [[torch.zeros((a.device_pages, a.slice_bytes), dtype=torch.uint8, device=dev)] for _ in range(a.layers)]
    mgr = KVCacheManager(tensors, local_control_port=port, host_blocks_to_allocate=host_pages,
                         parallelism=a.parallelism, timeout_s=120.0, unsafe_skip_buffer_lock=True)
    return mgr, tensors


def wait(mgrs_rids, poll_s):
    pending = dict(mgrs_rids)
    state = {}
    while pending:
        for rid, mgr in list(pending.items()):
            s = mgr.poll_stats_with_details()
            for t in s.received:
                if t.req_id in pending:
                    state[t.req_id] = "done"; pending.pop(t.req_id)
            for t in s.failed:
                if t.req_id in pending:
                    state[t.req_id] = "failed"; pending.pop(t.req_id)
        if pending:
            time.sleep(poll_s)
    return state


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sizes", default="16,128,512,2176,4352")
    ap.add_argument("--layers", type=int, default=18)
    ap.add_argument("--slice-bytes", type=int, default=8192)
    ap.add_argument("--device-pages", type=int, default=8)
    ap.add_argument("--parallelism", type=int, default=4)
    ap.add_argument("--streams", type=int, default=1)
    ap.add_argument("--pairs", type=int, default=1)
    ap.add_argument("--warmup", type=int, default=1)
    ap.add_argument("--reps", type=int, default=5)
    ap.add_argument("--poll-us", type=int, default=100)
    ap.add_argument("--base-port", type=int, default=42000)
    ap.add_argument("--seed", type=int, default=5)
    ap.add_argument("--verify", type=int, default=1)
    a = ap.parse_args()
    sizes = [int(x) for x in a.sizes.split(",")]
    top = max(sizes)
    pairs = []
    for i in range(a.pairs):
        src, st = manager(a, a.base_port + 20 * i, 0, top)
        dst, dt = manager(a, a.base_port + 20 * i + 10, 1, top)
        pairs.append((src, dst, st, dt))
    t0 = time.time()
    for src, _, _, _ in pairs:
        for layer in range(a.layers):
            for b in range(top):
                src.write_block_bytes(layer, b, payload(a.seed, layer, b, a.slice_bytes))
    print(f"filled {a.pairs} source pools ({top} pages x {a.layers} layers) in {time.time()-t0:.1f}s", flush=True)
    uuid = 1000
    results = []
    for n in sizes:
        times, data_ok = [], None
        for rep in range(a.warmup + a.reps):
            rids = {}
            for i, (src, dst, _, _) in enumerate(pairs):
                uuid += 1
                rid = f"mb-{i}-{uuid}"
                src.register_read(rid, uuid, list(range(n)), source="host")
                rids[rid] = (uuid, src, dst, i)
            t_start = time.perf_counter()
            for rid, (u, src, dst, i) in rids.items():
                dst.start_read(rid, u, f"127.0.0.1:{a.base_port + 20 * i}", list(range(n)),
                               local_host_block_ids=list(range(n)), parallelism=a.streams, destination="host")
            state = wait({rid: v[2] for rid, v in rids.items()}, a.poll_us / 1e6)
            dt = time.perf_counter() - t_start
            for rid, (u, src, dst, i) in rids.items():
                src.poll_stats_with_details()
            if any(s != "done" for s in state.values()):
                print(f"FAILED n={n} rep={rep} {state}", flush=True)
                continue
            if rep == a.warmup and a.verify:
                bad = 0
                for _, dst, _, _ in pairs:
                    for layer in range(a.layers):
                        for b in range(n):
                            if dst.read_block_bytes(layer, b) != payload(a.seed, layer, b, a.slice_bytes):
                                bad += 1
                data_ok = bad == 0
                if bad:
                    print(f"DATA MISMATCH n={n}: {bad} blocks", flush=True)
            if rep >= a.warmup:
                times.append(dt)
            for _, dst, _, _ in pairs:  # reset destination bytes so the next check cannot pass on stale data
                if rep == a.warmup and a.verify:
                    for layer in range(a.layers):
                        for b in range(n):
                            dst.write_block_bytes(layer, b, bytes(a.slice_bytes))
        per_pair = n * a.layers * a.slice_bytes
        med = statistics.median(times) if times else None
        r = {"pages": n, "MiB_per_pair": round(per_pair / 2**20, 2), "pairs": a.pairs, "streams": a.streams,
             "reps": len(times), "data_ok": data_ok,
             "lat_p50_ms": round(med * 1e3, 2) if med else None,
             "lat_min_ms": round(min(times) * 1e3, 2) if times else None,
             "lat_max_ms": round(max(times) * 1e3, 2) if times else None,
             "GiBps_aggregate_p50": round(per_pair * a.pairs / med / 2**30, 3) if med else None}
        results.append(r)
        print("RESULT " + json.dumps(r), flush=True)
    print("SUMMARY " + json.dumps({"mode": "loopback-in-process", "layers": a.layers, "slice_bytes": a.slice_bytes,
                                   "parallelism": a.parallelism, "results": results}), flush=True)


if __name__ == "__main__":
    main()
