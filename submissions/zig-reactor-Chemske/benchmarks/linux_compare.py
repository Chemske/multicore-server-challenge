"""Compare real Linux binaries on fresh full-seed clones; preserve all failures."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import statistics
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tests'))
from support import Server, upstream


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def threads(pid):
    result = {}
    for item in Path(f'/proc/{pid}/task').glob('*/stat'):
        try:
            fields = item.read_text().rsplit(')', 1)[1].split()
            result[item.parent.name] = int(fields[11]) + int(fields[12])
        except (OSError, ValueError):
            pass
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--variant', action='append', required=True, help='A=/absolute/executable')
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--order', default='ABCCBA')
    p.add_argument('--users', type=int, default=20000)
    p.add_argument('--think-scale', type=float, default=1)
    p.add_argument('--ramp', default='15s')
    p.add_argument('--measure', default='30s')
    p.add_argument('--tail', default='3s')
    p.add_argument('--conformance', action='store_true')
    args = p.parse_args()
    builds = {label: Path(binary).resolve() for label, binary in (v.split('=', 1) for v in args.variant)}
    if set(args.order) - builds.keys() or not args.order:
        p.error('every order label must have a variant')
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    work = Path(os.environ['CHALLENGE_WORK'])
    loadgen = work / 'tools/loadgen'
    report = {'started_at_utc': datetime.now(timezone.utc).isoformat(),
              'scope': 'Linux comparison; generator, application and database share runner. Not official capacity.',
              'platform': platform.platform(), 'cpu_count': os.cpu_count(),
              'source_revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
              'settings': {k: v for k, v in vars(args).items() if k not in ('variant', 'out')},
              'binaries': {k: digest(v) for k, v in builds.items()}, 'loadgen_sha256': digest(loadgen),
              'conformance': {}, 'runs': [], 'completed': False}
    summary = out / 'summary.json'
    try:
        if args.conformance:
            for label, binary in builds.items():
                with Server(out, 'linux-comparison', 'linuxcheck', label.lower(), binary, template='conduit_seed') as server:
                    run, transcript, _, description = upstream(server, f'conformance-{label}', work / 'tools/conformance')
                    assert run.returncode == 0 and len(transcript) == 197, run.stdout
                    report['conformance'][label] = description
                    print(label + ': ' + description, flush=True)
                summary.write_text(json.dumps(report, indent=2) + '\n')
        for index, label in enumerate(args.order):
            name = f'{index + 1:02d}-{label}'
            with Server(out, 'linux-comparison', 'linuxbench', f'n{index}', builds[label], template='conduit_seed') as server:
                output = out / f'{name}.json'
                command = [str(loadgen), 'run', '-target', f'http://127.0.0.1:{server.port}',
                           '-users', str(args.users), '-think-scale', str(args.think_scale),
                           '-ramp', args.ramp, '-measure', args.measure, '-tail', args.tail,
                           '-articles', '500000', '-secret', server.secret,
                           '-run-id', f'linux{os.getpid()}n{index}', '-out', str(output)]
                samples = []
                with (out / f'{name}.log').open('w') as log:
                    process = subprocess.Popen(command, stdout=log, stderr=log)
                    try:
                        deadline = time.monotonic() + 1200
                        while process.poll() is None:
                            samples.append({'unix_s': time.time(), 'ticks': threads(server.process.pid)})
                            if time.monotonic() > deadline:
                                raise TimeoutError('load run exceeded 1200 seconds')
                            time.sleep(1)
                        assert process.returncode == 0, f'load generator exited {process.returncode}'
                    finally:
                        if process.poll() is None:
                            process.terminate()
                            try:
                                process.wait(timeout=5)
                            except subprocess.TimeoutExpired:
                                process.kill()
                                process.wait()
                (out / f'{name}-threads.json').write_text(json.dumps({'clock_ticks_per_second': os.sysconf('SC_CLK_TCK'), 'samples': samples}) + '\n')
                merged = out / f'{name}-merged.json'
                with (out / f'{name}-merge.log').open('w') as log:
                    rc = subprocess.run([str(loadgen), 'merge', '-o', str(merged), str(output)], stdout=log, stderr=log).returncode
                assert rc in (0, 3), rc
                data = json.loads(merged.read_text())
                start = data['start_at_ms'] / 1000 + data['ramp_s']
                end = start + data['measure_s']
                selected = [sample for sample in samples if start <= sample['unix_s'] <= end]
                cpu = {}
                if len(selected) > 1:
                    duration = selected[-1]['unix_s'] - selected[0]['unix_s']
                    for tid, last in selected[-1]['ticks'].items():
                        first = selected[0]['ticks'].get(tid, last)
                        cpu[tid] = 100 * (last - first) / os.sysconf('SC_CLK_TCK') / duration
                stats = []
                for line in (out / f'{server.database}.log').read_text().splitlines():
                    if 'reactor_stats ' in line:
                        stats.append({key: int(value) for key, value in re.findall(r'(\w+)=([0-9]+)', line)})
                result = {'run': name, 'build': label, 'overall': data['overall'], 'verdict': data['verdict'],
                          'mix': data['mix'], 'per_thread_cpu_pct_of_one_core': cpu, 'reactor_stats': stats}
                report['runs'].append(result)
                overall = data['overall']
                print(f"{name}: {overall['rps']:.1f} req/s; p95 {overall['p95_ms']:.2f} ms; p99 {overall['p99_ms']:.2f} ms; errors {overall['errors']}/{overall['count']}; LG-limited={data['verdict']['lg_limited']}", flush=True)
            summary.write_text(json.dumps(report, indent=2) + '\n')
        report['medians'] = {label: {key: statistics.median(r['overall'][key] for r in report['runs'] if r['build'] == label)
                                   for key in ('rps', 'p95_ms', 'p99_ms', 'error_rate')}
                             for label in set(args.order)}
        report['completed'] = True
    finally:
        summary.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
