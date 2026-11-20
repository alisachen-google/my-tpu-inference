"""Review probes for PR 2235; actual source, simulated transport boundaries.

Usage: python probe_pr2235_metadata.py /path/to/sglang-at-49561a1503a7
Only Python is required. Export-error probes describe the reviewed defect;
their assertions intentionally need updating once that defect is fixed.
"""

import ast
import logging
import runpy
import secrets
import sys
import threading
from pathlib import Path
from types import SimpleNamespace


class Pool:
    page_num = 16


def main():
    root = Path(sys.argv[1])
    directory = root / 'sglang_tpu/disaggregation'
    metadata = runpy.run_path(str(directory / 'decode_dram_offload/host_page_metadata.py'))
    Table = metadata['HostPageMetadata']
    register = metadata['register_host_page_metadata']

    table = Table(Pool())
    table.restore([1, 3], [b'a', b'b'])
    assert table.export([3, 1]) == [b'b', b'a']
    table.restore([3], [])
    assert table.export([3]) == []
    assert table.export([1]) == [b'a']
    table.clear()
    assert table.export([1]) == []
    print('PASS: retained rows follow page order, missing rows clear reuse, reset clears rows')

    unchecked = Table(Pool(), retain=False)
    unchecked.restore([1], [b'old'])
    assert unchecked.export([1]) == []
    print('PASS: unchecked prefill does not retain received tags')

    pool = Pool()
    late_table = Table(pool)
    restored = []
    register(pool, export=lambda pages: [b'owned' for _ in pages],
             restore=lambda pages, rows: restored.append((pages, rows)))
    assert late_table.export([2]) == [b'owned']
    late_table.restore([2], [b'recalled'])
    assert restored == [([2], [b'recalled'])]
    print('PASS: codec registration after table construction is observed')

    for pages, rows in [([1, 2], [b'a']), ([-1], []), ([16], [])]:
        try:
            late_table.restore(pages, rows)
        except ValueError:
            pass
        else:
            raise AssertionError('invalid metadata accepted')
    assert len(restored) == 1
    print('PASS: count and bounds failures precede codec restoration')

    path = directory / 'raiden/dram_offload_channel.py'
    tree = ast.parse(path.read_text())
    cls = next(n for n in tree.body if isinstance(n, ast.ClassDef)
               and n.name == 'DramOffloadChannel')
    methods = [n for n in cls.body if isinstance(n, ast.FunctionDef)
               and n.name in {'_on_prefix_pull', '_register_pull_locked'}]

    def registration(**kwargs):
        return SimpleNamespace(**(dict(uuid=0, endpoint='', swa_uuid=0,
                                      swa_endpoint='', page_metadata=[],
                                      swa_page_metadata=[]) | kwargs))

    namespace = dict(PrefixRegistration=registration, PrefixReady=registration,
                     PrefixPull=SimpleNamespace(from_frames=lambda msg: msg),
                     secrets=secrets, logger=logging.getLogger('probe'))
    module = ast.Module(body=[ast.ImportFrom(module='__future__',
                         names=[ast.alias(name='annotations')], level=0), *methods],
                        type_ignores=[])
    exec(compile(ast.fix_missing_locations(module), str(path), 'exec'), namespace)

    def run(export):
        sent, registered = [], []
        channel = SimpleNamespace(
            _lock=threading.RLock(),
            _offers={7: SimpleNamespace(pages=[1, 2], swa_pages=[], prefill_addr='peer')},
            _mgr=SimpleNamespace(_aborted=set(), attn_tp_rank=0),
            export_host_metadata=export,
            _send=lambda **kwargs: sent.append(kwargs),
            prefix_req_id=lambda room: str(room),
            host_control_address=lambda: 'host',
            _register_host_read_locked=lambda *args: registered.append(args) or True,
        )
        channel._register_pull_locked = lambda *args: namespace['_register_pull_locked'](channel, *args)
        caught = None
        try:
            namespace['_on_prefix_pull'](channel, SimpleNamespace(room=7, first_page=0, num_pages=2))
        except (RuntimeError, ValueError) as error:
            caught = error
        return sent, registered, caught

    sent, registered, caught = run(lambda pages, **kwargs: [b'x'] * len(pages))
    assert caught is None and len(sent) == len(registered) == 1
    assert sent[0]['message'].page_metadata == [b'x', b'x']
    print('PASS: successful export sends READY with metadata')

    def broken_export(pages, **kwargs):
        raise RuntimeError('unsealed source')

    malformed_pool = Pool()
    malformed = Table(malformed_pool)
    register(malformed_pool, export=lambda pages: [b'only-one'], restore=lambda *args: None)
    for name, exporter in [('raising codec', broken_export),
                           ('wrong row count', lambda pages, **kwargs: malformed.export(pages))]:
        sent, registered, caught = run(exporter)
        assert caught is not None and not sent and not registered
        print(f'REPRODUCED: {name}: {type(caught).__name__} escapes, '
              f'{len(sent)} READY replies, {len(registered)} native registrations')


if __name__ == '__main__':
    main()
