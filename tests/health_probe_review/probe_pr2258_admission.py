"""Exercise PR 2258's actual scheduler selectors with host-only stand-ins.

Usage: python probe_pr2258_admission.py /path/to/sglang-at-f3ffa42b5cd1
Only Python is required. No real allocations, Rust RPC, forward, or collective.
"""

import ast
import sys
from pathlib import Path
from types import SimpleNamespace as NS
from unittest.mock import Mock


class Batch:
    def __init__(self, reqs):
        self.reqs = list(reqs)

    def batch_size(self):
        return len(self.reqs)

    def is_empty(self):
        return not self.reqs

    def filter_batch(self):
        self.reqs = [r for r in self.reqs if not r.finished()]

    def merge_batch(self, other):
        self.reqs.extend(other.reqs)

    def prepare_for_prebuilt(self):
        pass


def request(rid, *, finished=False, prebuilt_done=False):
    req = NS(rid=rid, done=finished, prebuilt_done=prebuilt_done,
             health_check_admission_seq=0, kv=NS(kv_committed_len=None),
             init_next_round_input=Mock())
    req.finished = lambda: req.done
    return req


def main():
    path = Path(sys.argv[1]) / 'python/sglang/srt/disaggregation/decode.py'
    tree = ast.parse(path.read_text())
    cls = next(n for n in tree.body if isinstance(n, ast.ClassDef)
               and n.name == 'SchedulerDisaggregationDecodeMixin')
    wanted = {'_get_new_prebuilt_batch', 'get_new_prebuilt_batch',
              'get_next_disagg_decode_batch_to_run'}
    methods = [n for n in cls.body if isinstance(n, ast.FunctionDef) and n.name in wanted]
    for method in methods:
        method.decorator_list = []
    release = Mock()
    config = NS(disaggregation_decode_host_receive_threshold=0,
                disaggregation_decode_enable_radix_cache=False)
    namespace = dict(
        HEALTH_CHECK_RID_PREFIX='HEALTH_CHECK',
        get_disagg=lambda: config, release_kv_cache=release,
        set_time_batch=lambda *args: None, set_schedule_time_batch=lambda *args: None,
        ScheduleBatch=NS(init_new=lambda reqs, *args: Batch(reqs)),
        NextBatchPlan=lambda **kwargs: NS(**kwargs),
    )
    checksum_path = path.with_name('checksum.py')
    predicate = next(n for n in ast.parse(checksum_path.read_text()).body
                     if isinstance(n, ast.FunctionDef) and n.name == 'is_health_check_req')
    module = ast.Module(body=[ast.ImportFrom(module='__future__',
                         names=[ast.alias(name='annotations')], level=0), predicate, *methods],
                        type_ignores=[])
    exec(compile(ast.fix_missing_locations(module), str(path), 'exec'), namespace)
    select = namespace['_get_new_prebuilt_batch']

    def scheduler(waiting, capacity=2, seq=0):
        s = NS(waiting_queue=list(waiting), max_running_requests=capacity,
               req_to_token_pool=NS(size=capacity), enable_priority_scheduling=False,
               grammar_manager=NS(has_waiting_grammars=lambda: False),
               health_monitor=NS(completion_seq=seq), _release_aborted_request=Mock(),
               enable_hisparse=False, tree_cache=object(), token_to_kv_pool_allocator=None,
               model_config=None, enable_overlap=False, spec_algorithm=None,
               chunked_req=None, dp_attn_adapter=NS(maybe_prepare_mlp_sync_batch=lambda b: b))
        s.get_new_prebuilt_batch = lambda running, **kwargs: select(s, running, **kwargs)
        s.update_running_batch = lambda batch: (batch.filter_batch(), batch)[1]

        def process(batch):
            # Model only the boundary result: selected users can finish at
            # prebuilt; an internal two-token probe still needs a forward.
            for req in batch.reqs:
                req.done = req.prebuilt_done

        s.batch_result_processor = NS(process_batch_result_prebuilt=process)
        return s

    probe, user = request('HEALTH_CHECK_internal'), request('user')
    s = scheduler([probe, user])
    assert select(s, Batch([])).reqs == [user] and s.waiting_queue == [probe]
    print('PASS: queued probe does not join user batch')

    s = scheduler([user])
    assert select(s, Batch([probe])) is None and s.waiting_queue == [user]
    print('PASS: unfinished internal probe isolates its forward')

    probe.done = True
    s = scheduler([user], capacity=1)
    assert select(s, Batch([probe])).reqs == [user]
    print('PASS: finished probe does not consume admission capacity')

    probe.done = False
    release.reset_mock()
    s = scheduler([probe], capacity=1, seq=1)
    assert select(s, Batch([user])) is None and not s.waiting_queue
    release.assert_called_once_with(probe, s.tree_cache, is_insert=False)
    print('PASS: newer completion retires queued probe even at full batch capacity')

    for capacity in (1, 2):
        users = [request(f'user-{i}', prebuilt_done=True) for i in range(3)]
        s = scheduler([probe, *users], capacity=capacity)
        plan = namespace['get_next_disagg_decode_batch_to_run'](s, Batch([]))
        assert plan.batch_to_run.reqs == [probe]
        assert s.waiting_queue == users[capacity:]
        print(f'PASS: prebuilt-only users leave probe a forward with backlog, capacity={capacity}')

    # Rust grpc::convert::request_id uses Rid::from_client, whose uniquifier is
    # appended. The following is the resulting shape, not an executed Rust RPC.
    client = request('HEALTH_CHECK_client#0123456789abcdef')
    s = scheduler([user])
    for _ in range(3):
        assert select(s, Batch([client])) is None and s.waiting_queue == [user]
    client.done = True
    assert select(s, Batch([client])).reqs == [user]
    print('REPRODUCED scheduler consequence: prefixed client holds waiting user '
          'on every unfinished step; user admits after client finishes')

    # Use the exact patched lambda from the CUDA checksum suite at this head.
    test_path = Path(sys.argv[1]) / 'test/registered/unit/disaggregation/test_kv_checksum.py'
    test_tree = ast.parse(test_path.read_text())
    test_class = next(n for n in test_tree.body if isinstance(n, ast.ClassDef)
                      and n.name == 'TestGetNewPrebuiltBatchChecksum')
    helper = next(n for n in test_class.body if isinstance(n, ast.FunctionDef)
                  and n.name == '_run_once')
    fixture_lambda = next(n for n in ast.walk(helper) if isinstance(n, ast.Lambda)
                          and [a.arg for a in n.args.args] == ['s', 'rb'])
    fixture = eval(compile(ast.Expression(body=fixture_lambda), str(test_path), 'eval'),
                   {'batch': None})
    fake = type('ChecksumFixture', (), {'_get_new_prebuilt_batch': fixture})()
    try:
        namespace['get_new_prebuilt_batch'](fake, Batch([]))
    except TypeError as error:
        assert 'health_check_only' in str(error)
        print(f'REPRODUCED checksum-suite regression: {error}')
    else:
        raise AssertionError('expected the reviewed fixture signature failure')


if __name__ == '__main__':
    main()
