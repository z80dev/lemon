"""Offline native-runtime latency lane. Only loopback sockets are used."""
import argparse
import json
import math
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile
import time

from coding_benchmark_paired import isolated_environment, runtime_ports, terminate_runtime_group

PROJECT = Path(__file__).resolve().parents[3]
PROBE = PROJECT / 'apps/lemon_evals/priv/latency_probe.exs'
SSE = PROJECT / 'apps/lemon_ai/test/fixtures/openai_completions/compatible_complete.sse'
METRICS = ('cold_ready', 'boot_to_ready', 'warm_ready', 'enter_to_provider',
           'provider_to_client', 'completion_to_next_start', 'session_journal_load',
           'session_environment_capture', 'session_prompt_composition', 'session_tool_registry',
           'provider_to_gateway_token', 'gateway_token_to_client')


def summarize(values):
    if not values or any(not isinstance(v, (int, float)) or isinstance(v, bool)
                         or not math.isfinite(v) or v < 0 for v in values):
        raise ValueError('missing, negative or invalid latency samples')
    ordered = sorted(values)
    return {'n': len(values), **{f'p{p}_ms': ordered[math.ceil(len(values) * p / 100) - 1] / 1000
                              for p in (50, 99)}}


def regressions(current, baseline):
    if baseline['schema_version'] != 1 or current['environment'] != baseline['environment']:
        raise ValueError('baseline schema/environment differs')
    failures = []
    for metric in METRICS:
        for percentile in ('p50_ms', 'p99_ms'):
            before, after = baseline['metrics'][metric][percentile], current['metrics'][metric][percentile]
            # Both 25% and 2 ms must be exceeded; shared-runner noise is not an SLA.
            if after > before * 1.25 and after - before > 2:
                failures.append(f'{metric}.{percentile}: {before:.3f} -> {after:.3f} ms')
    return failures


# The probe's own fixed failure messages; interpolated ones are excluded.
PROBE_FAILURES = frozenset(re.findall(r'raise[ (]"([^"#]*)"', PROBE.read_text()))


def failure_reason(log):
    """Names why a probe VM failed without echoing runtime output: the probe's
    own fixed message, else only the exception module (never paths or terms)."""
    reason = 'no exception reported'
    try:
        lines = log.read_text(errors='replace').splitlines()
    except OSError:
        return reason
    for line in lines:
        match = re.match(r'\s*\*\* \(([A-Z][\w.]*)\) ?(.*)$', line)
        if match:
            module, message = match.groups()
            reason = f'{module}: {message}' if message in PROBE_FAILURES else module
    return reason


def measure(boots, turns):
    samples = {metric: [] for metric in METRICS}
    versions = None
    for boot in range(1, boots + 1):
        with tempfile.TemporaryDirectory(prefix='lemon-latency-') as temporary:
            state = Path(temporary)
            env = isolated_environment(state,
                '[providers.zai]\napi_key = "offline-fixture-not-a-real-credential"\n',
                'coding', {}, runtime_ports())
            result = state / 'result.json'
            env.update(LEMON_LATENCY_SSE=str(SSE), LEMON_LATENCY_TURNS=str(turns),
                       LEMON_LATENCY_RESULT=str(result), ERL_FLAGS='+S 2:2 +SDcpu 1 +SDio 1')
            # Disable timezone updater before any dependency boots.
            (state / 'offline.config').write_text('[{tzdata, [{autoupdate, disabled}]}].\n')
            env['ERL_FLAGS'] += f' -config {state / "offline"}'
            argv = ['mix', 'run', '--no-start', '--no-compile', '--no-deps-check', str(PROBE)]
            env['LEMON_LATENCY_LAUNCHED_US'] = str(time.time_ns() // 1000)
            process = None
            try:
                with (state / 'runtime.log').open('wb') as log:
                    process = subprocess.Popen(argv, cwd=PROJECT, env=env, stdin=subprocess.DEVNULL,
                                               stdout=log, stderr=log, start_new_session=True)
                    status = process.wait(timeout=120 + turns * 60)
                if status != 0 or not result.exists():
                    raise RuntimeError(
                        f'offline latency runtime failed in boot {boot}/{boots} (exit {status}): '
                        f'{failure_reason(state / "runtime.log")}; run the probe locally to diagnose')
                data = json.loads(result.read_text())
                # The probe records readiness inside the VM; launcher-to-ready is
                # separately timestamped by its readiness receipt (not VM shutdown).
                samples['cold_ready'].append(data['cold_ready_us'])
                for metric in ('boot_to_ready', 'warm_ready'):
                    samples[metric].extend(data[metric])
                for row in data['trials']:
                    for metric in METRICS[3:]:
                        value = row[metric]
                        samples[metric].extend(value if isinstance(value, list) else [value])
                versions = {'elixir': data['elixir'], 'otp': data['otp']}
            finally:
                terminate_runtime_group(process)
    return samples, versions


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--boots', type=int, default=5)
    parser.add_argument('--turns', type=int, default=20)
    parser.add_argument('--output', required=True)
    parser.add_argument('--revision', required=True)
    parser.add_argument('--baseline')
    args = parser.parse_args(argv)
    if args.boots < 1 or args.turns < 1:
        parser.error('boots and turns must be positive')
    if len(args.revision) != 40 or any(c not in '0123456789abcdef' for c in args.revision):
        parser.error('revision must be a full lowercase Git SHA')
    samples, versions = measure(args.boots, args.turns)
    report = {'schema_version': 1, 'revision': args.revision,
              'environment': {'os': platform.system(), 'arch': platform.machine(),
                              'schedulers': 2, **versions},
              'settings': {'boots': args.boots, 'turns': args.turns},
              'metrics': {key: summarize(value) for key, value in samples.items()}}
    report['top_three_session_contributors'] = sorted(
        (key for key in METRICS if key.startswith('session_')),
        key=lambda key: report['metrics'][key]['p50_ms'], reverse=True)[:3]
    failures = regressions(report, json.loads(Path(args.baseline).read_text())) if args.baseline else []
    report['baseline_status'] = 'compared' if args.baseline else 'bootstrap_no_baseline'
    report['regressions'] = failures
    destination = Path(args.output)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(report, indent=2, allow_nan=False) + '\n')
    for key, values in report['metrics'].items():
        print(f"{key}: p50={values['p50_ms']:.3f} ms p99={values['p99_ms']:.3f} ms n={values['n']}")
    for failure in failures:
        print('REGRESSION: ' + failure)
    return int(bool(failures))


if __name__ == '__main__':
    raise SystemExit(main())
