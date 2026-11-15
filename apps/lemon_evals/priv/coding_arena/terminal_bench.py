#!/usr/bin/env python3
"""Bounded, opt-in Terminal-Bench pairs through Harbor's installed-agent API."""
import argparse
import hashlib
import json
import os
import subprocess
import tempfile
from datetime import datetime
from urllib.parse import urlsplit
from pathlib import Path

import arena
from bench_common import ARMS, aggregate, wire_usage, write_report

HERE = Path(__file__).resolve().parent
HARBOR_REVISION = 'ec6aeab7fe0eb51df52b4e72c524daf5ea9cc5f4'


def external_directory(path):
    path = Path(path).resolve()
    root = HERE.parents[3]
    if path == root or root in path.parents:
        raise ValueError('artifacts must be outside the source checkout')
    return path


def job_config(args, model, rep, out):
    name = f'{model}-r{rep}'
    agents = []
    for arm in ARMS:
        agents.append({'import_path': f'harbor_adapter:Harbor{arm.title()}', 'model_name': model,
                       'skip_model_parsing': True, 'override_timeout_sec': args.deadline + 20,
                       'override_setup_timeout_sec': 600,
                       'extra_allowed_hosts': [urlsplit(args.proxy_url).hostname],
                       'kwargs': {'agent_bundle': str(Path(getattr(args, arm + '_bundle')).resolve()),
                                  'agent_revision': getattr(args, arm + '_revision'),
                                  'proxy_url': args.proxy_url, 'effort': args.effort,
                                  'deadline': args.deadline, 'rep': rep}})
    dataset, version = args.dataset.rsplit('@', 1)
    return {'job_name': name, 'jobs_dir': str(out / 'jobs'), 'n_attempts': 1,
            'n_concurrent_trials': 1, 'retry': {'max_retries': 0},
            'environment': {'type': 'docker', 'delete': not args.keep_containers},
            'agents': agents, 'datasets': [{'name': dataset, 'version': version,
                                           'task_names': args.tasks.split(','), 'n_tasks': args.max_tasks}]}


def harbor_row(document, metadata, rep):
    config = document['config']['agent']
    settings = config['kwargs']
    arm = metadata.get('agent') or ('lemon' if config['import_path'].endswith('HarborLemon') else 'omp')
    rewards = (document.get('verifier_result') or {}).get('rewards') or {}
    # TB 2.0 emits a binary reward; missing or fractional rewards are not passes.
    passed = rewards.get('reward') == 1 and not document.get('exception_info')
    timing = document.get('agent_execution') or {}
    wall = None
    if timing.get('started_at') and timing.get('finished_at'):
        wall = (datetime.fromisoformat(timing['finished_at']) - datetime.fromisoformat(timing['started_at'])).total_seconds()
    return {'task': document['task_name'], 'agent': arm, 'rep': rep,
            'model': config['model_name'], 'effort': settings['effort'], 'deadline': settings['deadline'],
            'passed': passed, 'failure': None if passed else
            ('harbor_error' if document.get('exception_info') else 'verifier_failed'),
            'proxy_trial': metadata.get('proxy_trial'), 'turns': metadata.get('turns'),
            'tool_errors': metadata.get('tool_errors'), 'wall_seconds': wall}


def report(out, proxy_log):
    manifest = json.loads((out / 'manifest.json').read_text())
    usage = wire_usage(proxy_log)
    rows = []
    for job in manifest['jobs']:
        for path in sorted((out / 'jobs' / job['name']).rglob('result.json')):
            document = json.loads(path.read_text())
            if 'task_name' not in document:  # job aggregate, not a trial
                continue
            metadata_path = path.parent / 'agent' / 'arena.json'
            metadata = json.loads(metadata_path.read_text()) if metadata_path.exists() else (
                (document.get('agent_result') or {}).get('metadata') or {})
            row = harbor_row(document, metadata, job['rep'])
            row.update(usage.get(row['proxy_trial'], {}))
            rows.append(row)
    if not rows:
        raise ValueError('no Harbor trial results found; no outcome report can be manufactured')
    result = {'schema_version': 1, 'suite': 'terminal-bench',
              'identity': manifest['identity'], 'trials': rows, 'models': aggregate(rows)}
    write_report(out / 'report.json', result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['run', 'report'])
    parser.add_argument('--output-dir', required=True)
    parser.add_argument('--proxy-log', required=True)
    parser.add_argument('--live', action='store_true', help='authorize paid calls; otherwise write plan only')
    parser.add_argument('--harbor', default='harbor')
    parser.add_argument('--dataset', default='terminal-bench@2.0')
    parser.add_argument('--tasks', default='*')
    parser.add_argument('--max-tasks', type=int, default=2)
    parser.add_argument('--models', default='k3.1-pro')
    parser.add_argument('--effort', choices=['minimal', 'low', 'medium', 'high', 'xhigh'], default='high')
    parser.add_argument('--deadline', type=int, default=600)
    parser.add_argument('--repetitions', type=int, default=1)
    parser.add_argument('--proxy-url', default='http://host.docker.internal:18787')
    parser.add_argument('--lemon-bundle')
    parser.add_argument('--omp-bundle')
    parser.add_argument('--lemon-revision')
    parser.add_argument('--omp-revision')
    parser.add_argument('--keep-containers', action='store_true', help='private credential audit; manually remove afterwards')
    args = parser.parse_args()
    out = external_directory(args.output_dir)
    if args.action == 'report':
        report(out, args.proxy_log)
        return 0
    if min(args.deadline, args.repetitions, args.max_tasks) <= 0:
        parser.error('deadline, repetitions and max-tasks must be positive')
    models = args.models.split(',')
    if not models or any(model not in arena.MODELS for model in models) or len(models) != len(set(models)):
        parser.error('models must be distinct arena wire model ids')
    if (out / 'manifest.json').exists():
        parser.error('choose a fresh output directory; uncertain trials are never replayed')
    bundles = {}
    for arm in ARMS:
        bundle, revision = getattr(args, arm + '_bundle'), getattr(args, arm + '_revision')
        if not bundle or not revision:
            parser.error(f'--{arm}-bundle and --{arm}-revision are required')
        with Path(bundle).open('rb') as source:
            bundles[arm] = {'revision': revision, 'bundle_sha256': hashlib.file_digest(source, 'sha256').hexdigest()}
    out.mkdir(parents=True, mode=0o700, exist_ok=True)
    jobs = []
    for model in models:
        for rep in range(1, args.repetitions + 1):
            config = job_config(args, model, rep, out)
            config_path = out / (config['job_name'] + '.json')
            config_path.write_text(json.dumps(config, indent=2) + '\n')
            jobs.append({'name': config['job_name'], 'rep': rep, 'config': config_path.name})
    manifest = {'identity': {'lemon': bundles['lemon'], 'omp': bundles['omp'],
                            'harbor_api_revision': HARBOR_REVISION, 'dataset': args.dataset,
                            'models': models, 'effort': args.effort, 'deadline': args.deadline,
                            'repetitions': args.repetitions, 'max_tasks': args.max_tasks,
                            'task_selection': args.tasks, 'live_authorized': args.live}, 'jobs': jobs}
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    if not args.live:
        print('Plan only; no containers or model calls. Use a fresh output directory with --live after approval.')
        return 0
    secret = os.environ['ARENA_PROXY_SECRET']
    # Harbor cannot discover the operator's provider auth or configuration.
    with tempfile.TemporaryDirectory(prefix='lemon-harbor-home-') as home:
        env = {'PATH': os.environ['PATH'], 'HOME': home, 'ARENA_PROXY_SECRET': secret,
               'PYTHONPATH': str(HERE)}
        if os.environ.get('DOCKER_HOST'):
            env['DOCKER_HOST'] = os.environ['DOCKER_HOST']
        for job in jobs:
            invocation = subprocess.run([args.harbor, 'run', '--config', str(out / job['config'])], env=env, check=False)
            if invocation.returncode:
                # Keep all attempted evidence; never automatically retry uncertainty.
                report(out, args.proxy_log)
                return invocation.returncode
    report(out, args.proxy_log)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
