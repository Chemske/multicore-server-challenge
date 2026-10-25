"""Compare two builds with the unchanged load generator on fresh dev clones.

This is a local experiment, not the official capacity search. The generator,
application and PostgreSQL share the Mac. No failed requests are filtered out.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tests'))
from support import Server, sql


def fingerprint(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--control', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--order', default='ABBABA')
    parser.add_argument('--users', type=int, default=128)
    parser.add_argument('--think-scale', type=float, default=0.01)
    parser.add_argument('--ramp', default='10s')
    parser.add_argument('--measure', default='30s')
    args = parser.parse_args()
    if not args.order or set(args.order) - {'A', 'B'}:
        parser.error('--order must contain only A (control) and B (candidate)')
    if not 0 < args.users < 256:
        parser.error('this experiment stays below the current 256-client limit')
    args.out = args.out.resolve()
    args.out.mkdir(parents=True, exist_ok=False)
    builds = {'A': args.control.resolve(), 'B': args.candidate.resolve()}
    loadgen = Path(os.environ['CHALLENGE_WORK']) / 'tools/loadgen'
    report = {
        'started_at_utc': datetime.now(timezone.utc).isoformat(),
        'scope': 'native Mac, development seed, co-located load generator; not an official score',
        'platform': platform.platform(), 'cpu_count': os.cpu_count(),
        'seed_counts': sql('SELECT (SELECT count(*) FROM users), (SELECT count(*) FROM articles)', 'conduit_dev'),
        'settings': {key: value for key, value in vars(args).items() if key not in ('control', 'candidate', 'out')},
        'binaries': {label: {'path': str(path), 'sha256': fingerprint(path)} for label, path in builds.items()},
        'loadgen_sha256': fingerprint(loadgen),
        'harness_sha256': fingerprint(Path(__file__).resolve()),
        'runs': [],
    }
    summary = args.out / 'summary.json'
    try:
        for index, label in enumerate(args.order):
            name = f'{index + 1:02d}-{label}'
            with Server(args.out, 'local-comparison', 'compare', name.replace('-', '_').lower(), builds[label]) as server:
                output = args.out / f'{name}.json'
                command = [str(loadgen), 'run', '-target', f'http://127.0.0.1:{server.port}',
                           '-users', str(args.users), '-ramp', args.ramp, '-measure', args.measure,
                           '-tail', '3s', '-think-scale', str(args.think_scale), '-articles', '10000',
                           '-secret', server.secret, '-run-id', f'compare{os.getpid()}n{index}', '-out', str(output)]
                with (args.out / f'{name}.log').open('w') as log:
                    subprocess.run(command, stdout=log, stderr=log, check=True, timeout=300)
                merged = args.out / f'{name}-merged.json'
                with (args.out / f'{name}-merged.log').open('w') as log:
                    merge = subprocess.run([str(loadgen), 'merge', '-o', str(merged), str(output)],
                                           stdout=log, stderr=log, timeout=30)
                if merge.returncode not in (0, 3):
                    raise RuntimeError(f'loadgen merge failed: {merge.returncode}')
                data = json.loads(merged.read_text())
                result = {'run': name, 'build': label, 'overall': data['overall'],
                          'verdict': data['verdict'], 'mix': data['mix'], 'boxes': data['boxes']}
                report['runs'].append(result)
                stats = result['overall']
                print(f"{name}: {stats['rps']:.1f} req/s; p95 {stats['p95_ms']:.2f} ms; "
                      f"p99 {stats['p99_ms']:.2f} ms; errors {stats['errors']}/{stats['count']}; "
                      f"LG-limited={result['verdict']['lg_limited']}", flush=True)
            summary.write_text(json.dumps(report, indent=2) + '\n')
        report['medians'] = {}
        for label in ('A', 'B'):
            runs = [run['overall'] for run in report['runs'] if run['build'] == label]
            if runs:
                report['medians'][label] = {field: statistics.median(run[field] for run in runs)
                                            for field in ('rps', 'p95_ms', 'p99_ms', 'error_rate')}
        if all(label in report['medians'] for label in ('A', 'B')):
            report['median_rps_change_pct'] = 100 * (report['medians']['B']['rps'] / report['medians']['A']['rps'] - 1)
        report['all_runs_zero_errors_and_no_reported_generator_limit'] = all(
            run['overall']['errors'] == 0 and not run['verdict']['lg_limited'] for run in report['runs'])
        report['completed'] = True
    finally:
        summary.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
