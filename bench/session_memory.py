"""Opt-in native session memory/wake measurement; never invoked by tests."""
import argparse
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import tempfile

PROJECT = Path(__file__).resolve().parents[1]
PROBE = PROJECT / 'bench/session_memory.exs'


def summarize(values):
    if not values or any(type(value) not in (int, float) or not math.isfinite(value)
                         or value < 0 for value in values):
        raise ValueError('missing, negative or invalid measurement')
    ordered = sorted(values)
    return {'n': len(values), 'mean': sum(values) / len(values),
            'min': ordered[0], 'max': ordered[-1],
            **{f'p{p}': ordered[math.ceil(len(values) * p / 100) - 1] for p in (50, 99)}}


def environment(root, samples, turns, hibernate_after_ms):
    # Preserve SDK locations, not provider credentials, proxy settings or Lemon config.
    original_home = Path.home()
    env = {key: os.environ[key] for key in ('PATH', 'LANG', 'LC_ALL') if key in os.environ}
    for key, directory in (('MIX_HOME', '.mix'), ('HEX_HOME', '.hex')):
        env[key] = str(Path(os.environ.get(key, original_home / directory)).expanduser().resolve())
    for directory in ('home', 'cwd', 'tmp'):
        (root / directory).mkdir(parents=True, mode=0o700)
    # This also applies before dependencies loaded by Mix can start tzdata.
    (root / 'offline.config').write_text('[{tzdata, [{autoupdate, disabled}]}].\n')
    env.update(HOME=str(root / 'home'), TMPDIR=str(root / 'tmp'), MIX_ENV='dev',
               LEMON_DOTENV_DIR=str(root / 'cwd'), LEMON_AGENT_PROFILES_CWD=str(root / 'cwd'),
               LEMON_STORE_PATH=str(root / 'store'), LEMON_MEMORY_BENCH_ROOT=str(root),
               LEMON_MEMORY_BENCH_SAMPLES=str(samples), LEMON_MEMORY_BENCH_TURNS=str(turns),
               LEMON_MEMORY_BENCH_HIBERNATE_MS=str(hibernate_after_ms),
               ERL_FLAGS=f'+S 2:2 +SDcpu 1 +SDio 1 -config {root / "offline"}')
    return env


def stop(process):
    if process is None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=5)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        pass
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)


def measure(args):
    with tempfile.TemporaryDirectory(prefix='lemon-session-memory-') as temporary:
        root = Path(temporary)
        env = environment(root, args.samples, args.turns, args.hibernate_after_ms)
        process = None
        try:
            with (root / 'runtime.log').open('wb') as log:
                process = subprocess.Popen(
                    ['mix', 'run', '--no-start', '--no-compile', '--no-deps-check', str(PROBE)],
                    cwd=PROJECT, env=env, stdin=subprocess.DEVNULL,
                    stdout=log, stderr=log, start_new_session=True)
                # Four cohorts, one discarded warm-up each; hibernated cohorts
                # settle before memory, both scalar probes, a turn, and refresh.
                timeout = 120 + (args.samples + 1) * (args.turns * 8 + 30
                                                    + args.hibernate_after_ms / 100)
                status = process.wait(timeout=timeout)
            if status != 0:
                # The disposable VM sees only authored fixture data and private paths.
                raise RuntimeError('session memory probe failed:\n'
                                   + (root / 'runtime.log').read_text(errors='replace'))
            return json.loads((root / 'result.json').read_text())
        finally:
            stop(process)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--revision', required=True, help='exact tested full lowercase commit SHA')
    parser.add_argument('--output', required=True)
    parser.add_argument('--samples', type=int, default=20, help='fresh sessions per cohort')
    parser.add_argument('--turns', type=int, default=4, help='fixture turns retained at memory sample')
    parser.add_argument('--hibernate-after-ms', type=int, default=50,
                        help='benchmark-only idle timeout; production defaults to 5000')
    args = parser.parse_args(argv)
    if not re.fullmatch(r'[0-9a-f]{40}', args.revision):
        parser.error('revision must be a full lowercase Git SHA')
    if args.samples < 1 or args.turns < 1 or args.hibernate_after_ms < 1:
        parser.error('samples, turns and hibernate-after-ms must be positive')
    # Keep a single trial inside the real root's five-minute idle retention TTL.
    if args.hibernate_after_ms > 60_000:
        parser.error('hibernate-after-ms must be at most 60000 (root TTL safety margin)')
    raw = measure(args)
    metrics = {}
    for cohort in ('child_idle', 'child_hibernated', 'root_idle', 'root_hibernated'):
        rows = [row for row in raw['samples'] if row['cohort'] == cohort]
        if len(rows) != args.samples:
            raise ValueError('incomplete cohort')
        metrics[cohort] = {key: summarize([row['metrics'][key] for row in rows])
                           for key in rows[0]['metrics']}
    report = {'schema_version': 1, 'revision': args.revision,
              'measured_at_utc': datetime.now(timezone.utc).isoformat(),
              'environment': {'os': platform.system(), 'release': platform.release(),
                              'architecture': platform.machine(), **raw['environment']},
              'settings': {'samples_per_cohort': args.samples, 'seed_turns': args.turns,
                           'hibernate_after_ms': args.hibernate_after_ms,
                           'idle_hibernate_after': 'infinity',
                           'warmups_per_cohort': 1, **raw['settings']},
              'metrics': metrics, 'samples': raw['samples']}
    destination = Path(args.output)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(report, indent=2, allow_nan=False) + '\n')
    for cohort, measurements in metrics.items():
        print(cohort)
        for key, values in measurements.items():
            print(f'  {key}: p50={values["p50"]:.3f} p99={values["p99"]:.3f} '
                  f'mean={values["mean"]:.3f} n={values["n"]}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
