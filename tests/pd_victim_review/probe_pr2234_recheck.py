"""Run the actual _make_host_room method with simulated two-rank collectives.

Usage: python probe_pr2234_recheck.py /path/to/decode_dram_victim_receiver.py
Requires only Python. Does not test Gloo, the radix tree, native I/O, or TPU.
"""

import ast
import concurrent.futures
import sys
import threading
from pathlib import Path
from types import SimpleNamespace


def load_method(path):
    tree = ast.parse(Path(path).read_text())
    cls = next(n for n in tree.body if isinstance(n, ast.ClassDef)
               and n.name == 'DecodeDramVictimReceiver')
    method = next(n for n in cls.body if isinstance(n, ast.FunctionDef)
                  and n.name == '_make_host_room')
    namespace = {'ComponentType': SimpleNamespace(FULL='FULL', SWA='SWA'),
                 'dist': SimpleNamespace(ReduceOp=SimpleNamespace(MAX='MAX'))}
    exec(compile(ast.Module(body=[method], type_ignores=[]), str(path), 'exec'), namespace)
    return namespace[method.name]


class Pool:
    def __init__(self, free):
        self.free = free

    def available_size(self):
        return self.free


def run_case(method, full_free, swa_free, swa_released, tokens, swa_tokens):
    rows = [None, None]
    barrier = threading.Barrier(2, timeout=3)
    counts = [0, 0]

    def worker(rank):
        full = Pool(full_free[rank])
        swa = Pool(swa_free[rank]) if swa_tokens else None
        evictions = []

        def reduce(values, op):
            assert op == 'MAX'
            counts[rank] += 1
            rows[rank] = values
            barrier.wait()
            assert len(rows[0][0]) == len(rows[1][0])
            answer = [[max(a, b) for a, b in zip(rows[0][0], rows[1][0])]]
            barrier.wait()
            return answer

        def evict(amount, component):
            evictions.append((amount, component))
            if component == 'FULL':
                full.free += amount
                if swa is not None:
                    swa.free += swa_released[rank]
            else:
                swa.free += amount

        receiver = SimpleNamespace(_host_pool=full, _swa_host_pool=swa,
                                   _lockstep=SimpleNamespace(reduce=reduce),
                                   _cache=SimpleNamespace(evict_host=evict))
        method(receiver, tokens, swa_tokens)
        return evictions

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        futures = [executor.submit(worker, rank) for rank in range(2)]
        results = [future.result(timeout=5) for future in futures]
    assert counts[0] == counts[1], counts
    return results, counts[0]


def main():
    method = load_method(sys.argv[1])
    # Each tuple names the initial free slots on both ranks, collateral SWA
    # releases, requested slots, expected common evictions and collective count.
    cases = [
        ('full frees entire window', [0, 0], [0, 0], [4, 4], 8, 4,
         [(8, 'FULL')], 2),
        ('peer retains larger shortage', [0, 0], [0, 0], [2, 1], 8, 4,
         [(8, 'FULL'), (3, 'SWA')], 2),
        ('locally sufficient rank still participates', [8, 0], [4, 0], [0, 4], 8, 4,
         [(8, 'FULL')], 2),
        ('full-only model', [0, 0], [0, 0], [0, 0], 8, 0,
         [(8, 'FULL')], 1),
        ('SWA-only pressure', [8, 8], [0, 1], [0, 0], 8, 4,
         [(4, 'SWA')], 1),
        ('no pressure', [8, 9], [4, 5], [0, 0], 8, 4, [], 1),
    ]
    failed = 0
    for name, *params, expected, collectives in cases:
        observed, count = run_case(method, *params)
        passed = observed == [expected, expected] and count == collectives
        failed += not passed
        print(f'{"PASS" if passed else "FAIL"}: {name}: '
              f'evictions={observed}, collectives={count}')
    print(f'{len(cases) - failed}/{len(cases)} cases passed')
    return bool(failed)


if __name__ == '__main__':
    sys.exit(main())
