#!/usr/bin/env python3
"""Run omp mutation fixtures through isolated Lemon edit/patch and omp arms.

Plan-only unless --live is supplied. No fixture, model response or actual file
is executed; the trusted upstream verifier runs on the host after agent exit.
"""
import argparse
import hashlib
import json
import os
import random
import secrets
import subprocess
import tarfile
import time
from collections import Counter
from pathlib import Path, PurePosixPath

import arena
from bench_common import ARMS, HOME, aggregate, command, configuration, metrics, token_for, wire_usage, write_report
from edit_errors import edit_attempts
from terminal_bench import external_directory

HERE = Path(__file__).resolve().parent
UPSTREAM_REVISION = '7c49c11aa5bbaf3f418406583096168ad5b8c6dc'


def extract_fixtures(archive, destination):
    """Accept only regular fixture files/directories; no links or path traversal."""
    with tarfile.open(archive, 'r:gz') as source:
        for member in source:
            path = PurePosixPath(member.name)
            if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0] != 'fixtures':
                raise ValueError('unsafe fixture archive path')
            if not (member.isdir() or member.isfile()):
                raise ValueError('fixture archives may not contain links or devices')
            target = destination.joinpath(*path.parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with source.extractfile(member) as content:
                    target.write_bytes(content.read())
    return destination / 'fixtures'


def fixture_tasks(root, selected=None, limit=None):
    tasks = []
    for path in sorted(root.iterdir()):
        if not path.is_dir() or (selected and path.name not in selected):
            continue
        if not (path / 'prompt.md').is_file() or not (path / 'input').is_dir() or not (path / 'expected').is_dir():
            raise ValueError(f'incomplete fixture {path.name}')
        tasks.append(path)
    if selected and selected - {task.name for task in tasks}:
        raise ValueError('unknown selected fixture')
    if not tasks:
        raise ValueError('no edit fixtures selected')
    return tasks[:limit] if limit else tasks


def regular_files(root):
    files = {}
    for path in sorted(root.rglob('*')):
        if path.is_symlink() or not (path.is_dir() or path.is_file()):
            raise ValueError('nonregular benchmark artifact')
        if path.is_file():
            files[path.relative_to(root).as_posix()] = path.read_bytes()
    return files


def byte_verification(expected, actual):
    left, right = regular_files(expected), regular_files(actual)
    return {'success': left == right,
            'missing_files': len(left.keys() - right.keys()), 'extra_files': len(right.keys() - left.keys()),
            'mismatched_files': sum(left[key] != right[key] for key in left.keys() & right.keys())}


def upstream_verification(args, expected, actual):
    regular_files(actual)  # never let upstream's traversal follow an agent's symlink
    result = subprocess.run([args.bun, str(HERE / 'edit_verify.ts'), str(args.omp_source),
                             str(expected), str(actual)], capture_output=True, text=True, timeout=120, check=True)
    return json.loads(result.stdout)


def edit_command(agent, prompt, args):
    argv = command(agent, prompt, args.model, args.effort, args.deadline, '/work', stream=True)
    if agent == 'lemon':
        argv += ['--allowed-tools', f'read,{args.lemon_tool}']
    else:
        argv += ['--tools', 'read,edit']
    return argv


def run_fixture(fixture, agent, rep, args, out, container_factory=arena.Container,
                formatted_verifier=upstream_verification):
    identifier = f'{args.model}-{fixture.name}-{args.lemon_tool}-{agent}-r{rep}'
    trial = out / 'trials' / identifier
    trial.mkdir(parents=True, mode=0o700)
    proxy_trial = 'edit-' + secrets.token_hex(16)
    token = token_for(args.proxy_secret, proxy_trial, args.model)
    row = {'task': fixture.name + ':' + args.lemon_tool, 'fixture': fixture.name,
           'agent': agent, 'rep': rep, 'model': args.model, 'effort': args.effort,
           'deadline': args.deadline, 'treatment': args.lemon_tool,
           'proxy_trial': proxy_trial, 'passed': False, 'failure': 'infrastructure',
           'edit_calls': None, 'edit_retries': None, 'edit_failures': None, 'attempts': []}
    container = None
    try:
        container = container_factory(arena.IMAGES[agent], 'edit-' + secrets.token_hex(8), args.cpus, args.memory)
        container.copy_in(fixture / 'input', '/work')
        files, env = configuration(agent, args.model, args.effort, args.proxy_url, token)
        for relative, content in files.items():
            container.write(f'{HOME}/{relative}', content)
        isolated = ['env', '-i', *[f'{key}={value}' for key, value in env.items()]]
        if agent == 'lemon':
            container.exec([*isolated, 'lemon', 'daemon'], timeout=240, check=True)
        # Original prompt bytes (apart from outer whitespace) are preserved. Same
        # suffix and fixture file list reach both arms; no expected output leaks.
        filenames = sorted(regular_files(fixture / 'input'))
        prompt = (fixture / 'prompt.md').read_text().strip() + '\n\nFiles: ' + ', '.join(filenames)
        prompt += '\nUse only the supplied read and editing tools. Do not rewrite files by another mechanism.'
        started = time.monotonic()
        invocation = container.exec([*isolated, *edit_command(agent, prompt, args)], timeout=args.deadline)
        row['wall_seconds'] = time.monotonic() - started
        (trial / 'agent.stdout').write_text(invocation.stdout.replace(token, '[TRIAL_TOKEN]'))
        (trial / 'agent.stderr').write_text(invocation.stderr.replace(token, '[TRIAL_TOKEN]'))
        row.update(metrics(agent, invocation.stdout))
        attempts = edit_attempts(agent, invocation.stdout)
        row.update(attempts=attempts, edit_calls=len(attempts),
                   edit_retries=sum(attempt['retry'] for attempt in attempts)
                   if all(attempt['retry'] is not None for attempt in attempts) else None,
                   edit_failures=sum(attempt['failed'] for attempt in attempts))
        actual = trial / 'actual'
        actual.mkdir()
        arena.docker('cp', f'{container.name}:/work/.', str(actual), timeout=120)
        byte_result = byte_verification(fixture / 'expected', actual)
        formatted = formatted_verifier(args, fixture / 'expected', actual)
        # Private verifier output can contain diffs. Publish only booleans/counts.
        (trial / 'verification.json').write_text(json.dumps({'bytes': byte_result, 'upstream': formatted}, indent=2) + '\n')
        row['byte_exact'] = byte_result['success']
        row['upstream_success'] = formatted.get('success') is True
        row['passed'] = invocation.returncode == 0 and row['agent_ok'] and row['upstream_success'] and bool(attempts)
        row['failure'] = (None if row['passed'] else 'timeout' if invocation.returncode in (124, 137) else
                          'agent_error' if not row['agent_ok'] or invocation.returncode != 0 else
                          'no_edit_calls' if not attempts else 'byte_or_formatted_mismatch')
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        # Details stay private, not in the sanitized report. No attempt is retried.
        (trial / 'harness.stderr').write_text(str(error).replace(token, '[TRIAL_TOKEN]'))
    finally:
        if container is not None:
            container.remove()
    return row


def edit_report(rows, identity, out, proxy_log):
    usage = wire_usage(proxy_log)
    for row in rows:
        row.update(usage.get(row['proxy_trial'], {}))
    result = {'schema_version': 1, 'suite': 'omp-edit-fixtures', 'identity': identity,
              'trials': rows, 'models': aggregate(rows), 'edit_metrics': {}}
    for model in sorted({row['model'] for row in rows}):
        groups = {}
        for treatment in sorted({row['treatment'] for row in rows}):
            for arm in ARMS:
                selected = [row for row in rows if row['model'] == model and row['agent'] == arm
                            and row['treatment'] == treatment]
                attempts = [a for row in selected for a in row['attempts']]
                errors = Counter(a['class'] for a in attempts if a['failed'])
                sites = {a['class']: a for a in attempts if a['failed']}
                calls = sum(row['edit_calls'] or 0 for row in selected)
                retries_complete = bool(selected) and all(row['edit_retries'] is not None for row in selected)
                retries = sum(row['edit_retries'] for row in selected) if retries_complete else None
                groups[f'{treatment}:{arm}'] = {
                    'trials': len(selected), 'passed': sum(row['passed'] for row in selected),
                    'byte_exact': sum(row.get('byte_exact') is True for row in selected),
                    'edit_calls_observed': calls, 'edit_retries': retries,
                    'retries_per_edit': retries / calls if retries is not None and calls else None,
                    'failed_edit_calls_observed': sum(a['failed'] for a in attempts),
                    'error_rate_observed': sum(a['failed'] for a in attempts) / calls if calls else None,
                    'errors': {category: {'count': count, 'site': sites[category]['site'],
                                         'attribution': sites[category]['attribution'],
                                         'url': f"https://github.com/z80dev/lemon/blob/{identity['lemon_revision']}/{sites[category]['site']}"
                                         if sites[category]['site'] else None}
                               for category, count in sorted(errors.items())}}
        result['edit_metrics'][model] = groups
    write_report(out / 'report.json', result)
    lines = ['\n## Edit failure classes', '', '| Model | Treatment / arm | Class | Count | Lemon error site |',
             '|---|---|---|---|---|']
    for model, groups in result['edit_metrics'].items():
        for treatment, group in groups.items():
            lines.append(f"\n{model} / {treatment}: {group['passed']}/{group['trials']} passed; "
                         f"retries/edit={group['retries_per_edit']}; observed error rate={group['error_rate_observed']}.\n")
            for category, error in group['errors'].items():
                site = f"[{error['site']}]({error['url']}) ({error['attribution']})" if error['url'] else 'omp reference'
                lines.append(f"| {model} | {treatment} | {category} | {error['count']} | {site} |")
    with (out / 'report.md').open('a') as source:
        source.write('\n'.join(lines) + '\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--omp-source', type=Path, required=True)
    parser.add_argument('--output-dir', required=True)
    parser.add_argument('--proxy-log', required=True)
    parser.add_argument('--lemon-revision', required=True, help='revision baked into lemon-arena-lemon')
    parser.add_argument('--omp-revision', default=UPSTREAM_REVISION, help='revision corresponding to lemon-arena-omp')
    parser.add_argument('--models', default='k3.1-pro')
    parser.add_argument('--effort', choices=['minimal', 'low', 'medium', 'high', 'xhigh'], default='high')
    parser.add_argument('--deadline', type=int, default=600)
    parser.add_argument('--repetitions', type=int, default=1)
    parser.add_argument('--limit', type=int, default=2, help='maximum fixtures (explicit positive bound)')
    parser.add_argument('--tasks', help='comma-separated fixture ids')
    parser.add_argument('--lemon-tools', default='edit,patch')
    parser.add_argument('--proxy-url', default='http://host.docker.internal:18787')
    parser.add_argument('--cpus', type=float, default=2)
    parser.add_argument('--memory', default='4g')
    parser.add_argument('--bun', default='bun')
    parser.add_argument('--seed', type=int, default=545)
    parser.add_argument('--live', action='store_true')
    parser.add_argument('--report-only', action='store_true')
    args = parser.parse_args()
    out = external_directory(args.output_dir)
    if args.report_only:
        identity = json.loads((out / 'manifest.json').read_text())
        rows = arena.read_rows(out / 'results.jsonl')
        edit_report(rows, identity, out, args.proxy_log)
        return 0
    if min(args.deadline, args.repetitions, args.limit) <= 0:
        parser.error('deadline, repetitions and limit must be positive')
    models, tools = args.models.split(','), args.lemon_tools.split(',')
    if len(set(models)) != len(models) or any(model not in arena.MODELS for model in models):
        parser.error('models must be distinct arena wire ids')
    if len(set(tools)) != len(tools) or not tools or any(tool not in ('edit', 'patch') for tool in tools):
        parser.error('lemon-tools must be edit, patch, or edit,patch')
    if out.exists():
        parser.error('choose a fresh output directory; uncertain trials are never replayed')
    revision = subprocess.run(['git', '-C', str(args.omp_source), 'rev-parse', 'HEAD'],
                              capture_output=True, text=True, check=True).stdout.strip()
    if revision != UPSTREAM_REVISION:
        parser.error(f'fixtures/verifier must be pinned to researched upstream {UPSTREAM_REVISION}')
    archive = args.omp_source / 'packages/typescript-edit-benchmark/fixtures.tar.gz'
    identity = {'lemon_revision': args.lemon_revision, 'omp_revision': args.omp_revision,
                'fixture_revision': revision, 'fixture_sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
                'models': models, 'effort': args.effort, 'deadline': args.deadline,
                'repetitions': args.repetitions, 'limit': args.limit, 'lemon_tools': tools,
                'seed': args.seed, 'live_authorized': args.live,
                'images': {arm: arena.IMAGES[arm] for arm in ARMS}}
    out.mkdir(parents=True, mode=0o700)
    root = extract_fixtures(archive, out)
    fixtures = fixture_tasks(root, set(args.tasks.split(',')) if args.tasks else None, args.limit)
    identity['fixtures'] = [fixture.name for fixture in fixtures]
    (out / 'manifest.json').write_text(json.dumps(identity, indent=2) + '\n')
    if not args.live:
        print('Plan only: fixtures extracted; no containers or model calls. Select a fresh output directory for --live.')
        return 0
    args.proxy_secret = os.environ['ARENA_PROXY_SECRET']
    # Preflight the real upstream verifier before admitting any paid trial.
    if not upstream_verification(args, fixtures[0] / 'expected', fixtures[0] / 'expected').get('success'):
        raise ValueError('upstream verifier self-check failed')
    identity['image_ids'] = {arm: arena.image_id(arena.IMAGES[arm]) for arm in ARMS}
    if not all(identity['image_ids'].values()):
        raise ValueError('build the arena images before live runs')
    (out / 'manifest.json').write_text(json.dumps(identity, indent=2) + '\n')
    schedule = [(model, tool, fixture, rep) for model in models for tool in tools for fixture in fixtures
                for rep in range(1, args.repetitions + 1)]
    random.Random(args.seed).shuffle(schedule)
    rows = []
    for index, (model, tool, fixture, rep) in enumerate(schedule):
        args.model, args.lemon_tool = model, tool
        for arm in (ARMS if index % 2 == 0 else tuple(reversed(ARMS))):
            row = run_fixture(fixture, arm, rep, args, out)
            rows.append(row)
            with (out / 'results.jsonl').open('a') as destination:
                destination.write(json.dumps(row) + '\n')
                destination.flush()
                os.fsync(destination.fileno())
            edit_report(rows, identity, out, args.proxy_log)
            if row['failure'] == 'infrastructure':
                return 1
    return int(any(not row['passed'] for row in rows))


if __name__ == '__main__':
    raise SystemExit(main())
