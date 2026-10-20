"""Compare DNS throughput and executor isolation in two uvloop checkouts.

Build both checkouts in place with matching optimized uvloop/libuv settings.
For example, on Linux:

    python examples/bench/dns.py --baseline /path/to/baseline \\
        --candidate /path/to/pr --affinity 0,1 --samples 15

Use --count 65536 for longer samples. The native_numeric_* cases specify
socktype=0 to bypass the numeric fast path without performing network DNS.
Use identical --baseline and --candidate paths to measure harness noise.
"""

import argparse
import asyncio
import concurrent.futures
import json
import os
import pathlib
import platform
import socket
import statistics
import subprocess
import sys
import threading
import time


CASES = (
    'forward_sequential', 'forward_concurrent',
    'reverse_sequential', 'reverse_concurrent',
    'numeric_fast_path', 'native_numeric_sequential',
    'native_numeric_concurrent', 'executor_saturated',
)


def run_child(args):
    repo = args.repo.resolve()
    sys.path.insert(0, str(repo))
    import uvloop
    import uvloop.loop

    loop = uvloop.new_event_loop()
    if loop._debug_cc:
        raise RuntimeError('benchmark requires a non-debug build')
    if not pathlib.Path(uvloop.loop.__file__).is_relative_to(repo):
        raise RuntimeError('uvloop was imported from the wrong checkout')
    asyncio.set_event_loop(loop)
    native_numeric = args.case.startswith('native_numeric')

    async def lookup(reverse=False, numeric=False):
        if native_numeric:
            return await loop.getaddrinfo(
                '127.0.0.1', 443, family=socket.AF_INET,
                type=0, flags=socket.AI_NUMERICHOST)
        if reverse:
            return await loop.getnameinfo(
                ('127.0.0.1', 443),
                socket.NI_NUMERICHOST | socket.NI_NUMERICSERV)
        return await loop.getaddrinfo(
            '127.0.0.1' if numeric else 'localhost', 443,
            family=socket.AF_INET, type=socket.SOCK_STREAM)

    async def run():
        if args.case == 'executor_saturated':
            # Occupy every worker with sleeping application work. DNS should
            # remain independent of this queue, as it is in native libuv.
            loop.set_default_executor(
                concurrent.futures.ThreadPoolExecutor(max_workers=4))
            release = threading.Event()
            ready = [threading.Event() for _ in range(4)]

            def application_work(event):
                event.set()
                release.wait()

            tasks = [loop.run_in_executor(None, application_work, event)
                     for event in ready]
            while not all(event.is_set() for event in ready):
                await asyncio.sleep(0.001)
            timer = loop.call_later(0.2, release.set)
            start = time.perf_counter()
            try:
                await lookup()
                elapsed = time.perf_counter() - start
            finally:
                release.set()
                timer.cancel()
                await asyncio.gather(*tasks)
            return {'dns_latency_ms': elapsed * 1000}

        reverse = args.case.startswith('reverse')
        numeric = args.case == 'numeric_fast_path'
        concurrency = 32 if args.case.endswith('concurrent') else 1
        count = args.count or (32768 if numeric else
                               (4096 if reverse else 8192))
        count = ((count + concurrency - 1) // concurrency) * concurrency
        for _ in range(100):
            await lookup(reverse, numeric)

        async def worker():
            for _ in range(count // concurrency):
                result = await lookup(reverse, numeric)
                if not result:
                    raise RuntimeError('lookup returned no result')

        start = time.perf_counter()
        await asyncio.gather(*(worker() for _ in range(concurrency)))
        elapsed = time.perf_counter() - start
        return {'lookups_per_second': count / elapsed,
                'microseconds_per_lookup': elapsed * 1e6 / count,
                'lookups': count, 'concurrency': concurrency}

    try:
        result = loop.run_until_complete(run())
        loop.run_until_complete(loop.shutdown_default_executor())
    finally:
        loop.close()
    result.update(module=uvloop.loop.__file__, version=uvloop.__version__,
                  libuv_version=uvloop.loop.libuv_get_version())
    print(json.dumps(result))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=pathlib.Path,
                        help=argparse.SUPPRESS)
    parser.add_argument('--case', choices=CASES, help=argparse.SUPPRESS)
    parser.add_argument('--baseline', type=pathlib.Path)
    parser.add_argument('--candidate', type=pathlib.Path)
    parser.add_argument('--samples', type=int, default=7)
    parser.add_argument('--count', type=int, default=0)
    parser.add_argument('--cases', nargs='+', choices=CASES, default=CASES)
    parser.add_argument('--affinity', help='CPU IDs, e.g. 0,1 (Linux only)')
    parser.add_argument('--output', type=pathlib.Path,
                        default=pathlib.Path('dns-benchmark.json'))
    args = parser.parse_args()
    if args.samples < 1 or args.count < 0:
        parser.error('--samples must be positive and --count nonnegative')
    if args.repo:
        if not args.case:
            parser.error('--repo requires --case')
        run_child(args)
        return
    if not args.baseline or not args.candidate:
        parser.error('--baseline and --candidate are required')
    if args.affinity:
        if not hasattr(os, 'sched_setaffinity'):
            parser.error('--affinity requires sched_setaffinity')
        os.sched_setaffinity(0, {int(cpu) for cpu in args.affinity.split(',')})
    result = {
        'environment': {
            'python': sys.version,
            'platform': platform.platform(),
            'cpu_count': os.cpu_count(),
            'cpu_affinity': (sorted(os.sched_getaffinity(0))
                             if hasattr(os, 'sched_getaffinity') else None),
            'uv_threadpool_size': 4,
            'python_hash_seed': 0,
            'samples': args.samples,
        },
        'cases': {},
    }
    env = dict(os.environ)
    env.pop('PYTHONASYNCIODEBUG', None)
    env.pop('LD_PRELOAD', None)
    env['UV_THREADPOOL_SIZE'] = '4'
    env['PYTHONHASHSEED'] = '0'
    for case in args.cases:
        samples = {name: [] for name in ('baseline', 'candidate')}
        for index in range(args.samples):
            order = (('baseline', 'candidate') if index % 2 == 0 else
                     ('candidate', 'baseline'))
            for name in order:
                output = subprocess.check_output(
                    [sys.executable, str(pathlib.Path(__file__).resolve()),
                     '--repo', str(getattr(args, name)), '--case', case,
                     '--count', str(args.count)],
                    text=True, env=env, timeout=60)
                samples[name].append(json.loads(output))
        key = ('dns_latency_ms' if case == 'executor_saturated' else
               'lookups_per_second')
        medians = {name: statistics.median(sample[key] for sample in runs)
                   for name, runs in samples.items()}
        result['cases'][case] = {
            'samples': samples,
            'median': medians,
            'candidate_over_baseline': (medians['candidate'] /
                                        medians['baseline']),
        }
        print(case, json.dumps(medians), flush=True)
        args.output.write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
