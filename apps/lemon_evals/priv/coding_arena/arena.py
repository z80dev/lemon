#!/usr/bin/env python3
"""Isolated coding-agent arena: Lemon vs omp, one fresh container per trial.

Subcommands:
  validate  Prove every task is well-formed: its hidden verifier fails on the
            starting fixture and passes on the reference solution.
  run       Run trials (task x agent x repetition) in fresh containers, resumably.
  report    Summarize a run directory into report.json and report.md.

Trial containers see only their own fixture repository. Hidden verifier files
are copied in only after the agent exits. Model traffic goes through the host
Kimi auth proxy (kimi_auth_proxy.ts) with a per-trial signed token, so no real
credential enters a container and every request is attributable to its trial.
"""
import argparse
import base64
import hashlib
import hmac
import json
import math
import os
import random
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

HERE = Path(__file__).resolve().parent
TASKS_DIR = HERE.parent / 'coding_tasks'
IMAGES = {'base': 'lemon-arena-base', 'lemon': 'lemon-arena-lemon', 'lemon-coding': 'lemon-arena-lemon',
          'omp': 'lemon-arena-omp'}
LANGUAGES = {'python', 'javascript', 'typescript', 'go', 'rust', 'bash', 'c', 'sql', 'mixed'}
CATEGORIES = {'bug_fix', 'feature', 'refactor', 'debugging', 'performance', 'concurrency',
              'read_only', 'test_writing', 'migration', 'cli', 'data', 'parsing', 'api_design'}
DIFFICULTIES = {'easy', 'medium', 'hard'}
# Matches `lemon -p`'s fixed 600s client deadline so both agents get the same budget.
DEFAULT_TIMEOUT = 600
VERIFY_TIMEOUT = 300
PROMPT_SUFFIX = ('\n\nWork only inside the current repository. Do not install packages or use the network; '
                 'the standard library and the preinstalled toolchains are sufficient.')
MAX_ANSWER_ENV = 100_000


# ── Tasks ──────────────────────────────────────────────────────────────────

def load_tasks(root=TASKS_DIR, names=None):
    tasks = []
    for directory in sorted(path for path in Path(root).iterdir() if (path / 'task.json').is_file()):
        spec = json.loads((directory / 'task.json').read_text())
        spec['dir'] = directory
        tasks.append(spec)
    if names:
        wanted = set(names)
        unknown = wanted - {task['id'] for task in tasks}
        if unknown:
            raise SystemExit(f'unknown tasks: {", ".join(sorted(unknown))}')
        tasks = [task for task in tasks if task['id'] in wanted]
    return tasks


def task_problems(task):
    problems = []
    directory = task['dir']
    if task.get('id') != directory.name:
        problems.append('id must equal directory name')
    if task.get('language') not in LANGUAGES:
        problems.append(f'language must be one of {sorted(LANGUAGES)}')
    if task.get('category') not in CATEGORIES:
        problems.append(f'category must be one of {sorted(CATEGORIES)}')
    if task.get('difficulty') not in DIFFICULTIES:
        problems.append(f'difficulty must be one of {sorted(DIFFICULTIES)}')
    if not isinstance(task.get('prompt'), str) or len(task['prompt'].strip()) < 40:
        problems.append('prompt must be a substantive string')
    if not (directory / 'repo').is_dir():
        problems.append('repo/ fixture directory missing')
    if not (directory / 'hidden' / 'verify.sh').is_file():
        problems.append('hidden/verify.sh missing')
    read_only = task.get('read_only') is True
    if read_only and not (directory / 'solution.answer').is_file():
        problems.append('read_only tasks need solution.answer')
    if not read_only and not (directory / 'solution').is_dir() and not (directory / 'solution.delete').is_file():
        problems.append('solution/ overlay missing')
    if (directory / 'repo' / '.git').exists():
        problems.append('repo/ must not contain .git')
    return problems


# ── Docker ─────────────────────────────────────────────────────────────────

def docker(*argv, timeout=120, check=True, input=None):
    result = subprocess.run(['docker', *argv], capture_output=True, text=True, timeout=timeout,
                            input=input, stdin=None if input is not None else subprocess.DEVNULL)
    if check and result.returncode != 0:
        raise RuntimeError(f'docker {argv[0]} failed: {result.stderr.strip()[-2000:]}')
    return result


class Container:
    def __init__(self, image, name, cpus, memory):
        self.name = name
        docker('run', '-d', '--rm', '--name', name, '--hostname', 'arena',
               f'--cpus={cpus}', f'--memory={memory}', '--pids-limit=4096',
               '--add-host=host.docker.internal:host-gateway',
               image, 'sleep', 'infinity', timeout=180)

    def exec(self, argv, user='agent', cwd='/work', env=None, timeout=120, check=False, input=None):
        command = ['exec', *(['-i'] if input is not None else []), '-u', user, '-w', cwd]
        for key, value in (env or {}).items():
            command += ['-e', f'{key}={value}']
        command += [self.name, *argv]
        if timeout is None:
            return docker(*command, timeout=None, check=check, input=input)
        # The in-container `timeout` kills the agent tree; the host timeout is a backstop.
        wrapped = command[:-len(argv)] + ['timeout', '-k', '15', str(int(timeout)), *argv]
        return docker(*wrapped, timeout=timeout + 60, check=check, input=input)

    def copy_in(self, source, destination):
        docker('cp', f'{source}/.', f'{self.name}:{destination}', timeout=300)
        self.exec(['chown', '-R', 'agent:agent', destination], user='root', check=True)

    def write(self, path, content, user='agent', mode='600'):
        self.exec(['sh', '-c', f'mkdir -p "$(dirname "$1")" && cat > "$1" && chmod {mode} "$1"', 'sh', path],
                  user=user, input=content, check=True)

    def remove(self):
        docker('rm', '-f', self.name, check=False, timeout=120)


def init_repo(container, task):
    container.copy_in(task['dir'] / 'repo', '/work')
    script = ('git init -q -b main && git add -A && '
              'git -c user.name="Arena Fixture" -c user.email=fixture@example.invalid commit -qm fixture')
    container.exec(['bash', '-c', script], check=True)


def run_verifier(container, task, answer=''):
    container.copy_in(task['dir'] / 'hidden', '/verify')
    container.write('/verify/answer.txt', answer)
    env = {'BENCHMARK_ANSWER': answer[:MAX_ANSWER_ENV], 'BENCHMARK_ANSWER_FILE': '/verify/answer.txt'}
    result = container.exec(['bash', '/verify/verify.sh'], env=env, timeout=VERIFY_TIMEOUT)
    return result.returncode == 0, result


def apply_solution(container, task):
    if (task['dir'] / 'solution').is_dir():
        container.copy_in(task['dir'] / 'solution', '/work')
    delete = task['dir'] / 'solution.delete'
    if delete.is_file():
        for line in delete.read_text().splitlines():
            if line.strip():
                container.exec(['rm', '-rf', '--', line.strip()], check=True)


# ── validate ───────────────────────────────────────────────────────────────

def validate_one(task, image):
    problems = task_problems(task)
    if problems:
        return {'task': task['id'], 'ok': False, 'problems': problems}
    outcome = {'task': task['id'], 'ok': True, 'problems': []}
    for phase in ('fixture', 'solution'):
        container = Container(image, f'arena-validate-{task["id"][:40]}-{phase}-{secrets.token_hex(3)}', 2, '3g')
        try:
            init_repo(container, task)
            answer = ''
            if phase == 'solution':
                if task.get('read_only'):
                    answer = (task['dir'] / 'solution.answer').read_text()
                else:
                    apply_solution(container, task)
            started = time.monotonic()
            passed, result = run_verifier(container, task, answer)
            outcome[f'{phase}_seconds'] = round(time.monotonic() - started, 1)
            expected = phase == 'solution'
            if passed != expected:
                outcome['ok'] = False
                tail = (result.stdout + result.stderr)[-1500:]
                outcome['problems'].append(f'verifier {"failed" if expected else "passed"} on {phase}: {tail}')
        finally:
            container.remove()
    return outcome


def cmd_validate(args):
    tasks = load_tasks(args.tasks_dir, args.tasks.split(',') if args.tasks else None)
    failures = 0
    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        futures = {pool.submit(validate_one, task, IMAGES['base']): task for task in tasks}
        for future in as_completed(futures):
            outcome = future.result()
            status = 'OK ' if outcome['ok'] else 'BAD'
            timing = f"fixture {outcome.get('fixture_seconds', '-')}s solution {outcome.get('solution_seconds', '-')}s"
            print(f'{status} {outcome["task"]}  ({timing})', flush=True)
            for problem in outcome['problems']:
                print('     - ' + problem.replace('\n', '\n       '), flush=True)
            failures += not outcome['ok']
    print(f'{len(tasks) - failures}/{len(tasks)} tasks valid')
    return 1 if failures else 0


# ── agents ─────────────────────────────────────────────────────────────────

def trial_token(secret, trial_id):
    encode = lambda raw: base64.urlsafe_b64encode(raw).rstrip(b'=').decode()
    header = encode(json.dumps({'alg': 'HS256', 'typ': 'JWT'}).encode())
    payload = encode(json.dumps({'sub': trial_id, 'aud': 'lemon-arena'}).encode())
    signature = encode(hmac.new(secret.encode(), f'{header}.{payload}'.encode(), hashlib.sha256).digest())
    return f'{header}.{payload}.{signature}'


def proxy_base(args):
    return f'http://host.docker.internal:{args.proxy_port}'


def prepare_lemon(container, args, token, disclosure_profile=None):
    config = f'''[defaults]
provider = "kimi_coding"
model = "kimi_coding:{args.model}"
thinking_level = "{args.thinking}"

[providers.kimi_coding]
base_url = "{proxy_base(args)}/coding"
'''
    container.write('/home/agent/.lemon/config.toml', config)
    env = {'KIMI_API_KEY': token, 'LEMON_SECRETS_MASTER_KEY': secrets.token_hex(32),
           'LEMON_CONTROL_PLANE_OPERATOR_TOKEN': secrets.token_hex(32), 'HOME': '/home/agent'}
    if disclosure_profile:
        env['LEMON_TOOL_DISCLOSURE_PROFILE'] = disclosure_profile
    started = container.exec(['lemon', 'daemon'], env=env, timeout=240)
    if started.returncode != 0:
        # The launcher waits only 60s for health; a loaded host can boot the BEAM slower than that.
        waited = container.exec(['bash', '-c', 'for i in $(seq 1 90); do curl -fsS localhost:4040/healthz '
                                 '| grep -q \'"ok":true\' && exit 0; sleep 2; done; exit 1'], timeout=200)
        if waited.returncode != 0:
            raise RuntimeError('lemon daemon failed to start: ' + (started.stdout + started.stderr)[-1500:])
    return env


def lemon_argv(prompt, args, timeout):
    # `lemon -p` has no time option; its client gives up after a fixed 600s drain deadline.
    return ['lemon', '-p', prompt, '--output', 'stream-json', '--model', f'kimi_coding:{args.model}',
            '--cwd', '/work', '--approval-policy', 'allow']


OMP_ROLES = ('default', 'smol', 'slow', 'plan', 'task', 'commit', 'scout', 'mechanic', 'research', 'review')


def prepare_omp(container, args, token):
    model = f'kimi-code/{args.omp_model or args.model}:{args.thinking}'
    # kimi-code resolves no env key on its own; the models.yml apiKey names the variable.
    models_yml = f'''providers:
  kimi-code:
    baseUrl: {proxy_base(args)}/coding/v1
    apiKey: KIMI_API_KEY
'''
    container.write('/home/agent/.omp/agent/models.yml', models_yml)
    roles = ''.join(f'  {role}: {model}\n' for role in OMP_ROLES)
    container.write('/home/agent/.omp/agent/config.yml', f'modelRoles:\n{roles}')
    return {'KIMI_API_KEY': token, 'HOME': '/home/agent'}


def omp_argv(prompt, args, timeout):
    model = f'kimi-code/{args.omp_model or args.model}'
    return ['omp', '-p', prompt, '--mode', 'json', '--model', model, '--thinking', args.thinking,
            '--cwd', '/work', '--no-session', '--no-title', '--auto-approve', '--max-time', str(timeout)]


def json_lines(output):
    events = []
    for line in output.splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue  # launcher/runtime log noise
        if isinstance(event, dict):
            events.append(event)
    return events


def parse_omp(output):
    events = json_lines(output)
    assistants = [event['message'] for event in events
                  if event.get('type') == 'message_end' and event.get('message', {}).get('role') == 'assistant']
    last = assistants[-1] if assistants else {}
    usage = [message.get('usage') or {} for message in assistants]
    total = lambda key: sum(value.get(key) or 0 for value in usage) if usage else None
    answer = ''.join(part.get('text', '') for part in last.get('content', []) if part.get('type') == 'text')
    finished = [event for event in events if event.get('type') == 'tool_execution_end']
    tools = {}
    for event in finished:
        tools[event.get('toolName')] = tools.get(event.get('toolName'), 0) + 1
    return {'ok': bool(assistants) and any(event.get('type') == 'agent_end' for event in events)
                  and last.get('stopReason') not in ('error', 'aborted'),
            'answer': answer, 'model': last.get('model'), 'error': last.get('errorMessage'),
            'usage': {'totalTokens': total('totalTokens'), 'inputTokens': total('input'),
                      'outputTokens': total('output'), 'cacheReadTokens': total('cacheRead')},
            'metrics': {'turns': sum(event.get('type') == 'turn_end' for event in events),
                        'tool_calls': len(finished), 'tools': tools,
                        'tool_errors': sum(event.get('isError') is True for event in finished)}}


def parse_lemon(output):
    events = json_lines(output)
    result = next((event for event in reversed(events) if event.get('type') == 'result'), {})
    finished = [event['payload']['action'] for event in events
                if event.get('event') == 'agent' and isinstance(event.get('payload'), dict)
                and event['payload'].get('type') == 'tool_use' and event['payload'].get('phase') == 'completed'
                and isinstance(event['payload'].get('action'), dict)
                and (event['payload']['action'].get('detail') or {}).get('tool_call_id')]
    tools = {}
    for action in finished:
        name = action['detail'].get('name')
        tools[name] = tools.get(name, 0) + 1
    result['metrics'] = {'tool_calls': len(finished), 'tools': tools,
                         'tool_errors': sum(event['payload'].get('ok') is False for event in events
                                            if event.get('event') == 'agent' and isinstance(event.get('payload'), dict)
                                            and event['payload'].get('type') == 'tool_use'
                                            and event['payload'].get('phase') == 'completed'
                                            and ((event['payload'].get('action') or {}).get('detail') or {}).get('tool_call_id')),
                         'turns': (result.get('usage') or {}).get('turns')}
    return result


# `lemon-coding` is Lemon with the opt-in `coding` tool-disclosure profile (see docs/config.md).
AGENTS = {'lemon': (prepare_lemon, lemon_argv, parse_lemon),
          'lemon-coding': (lambda container, args, token: prepare_lemon(container, args, token, 'coding'),
                           lemon_argv, parse_lemon),
          'omp': (prepare_omp, omp_argv, parse_omp)}


# ── run ────────────────────────────────────────────────────────────────────

def redact(text, *values):
    for value in values:
        if value:
            text = text.replace(value, '<redacted>')
    return text


def git_diff_stats(container):
    result = container.exec(['bash', '-c', 'git add -A -N . 2>/dev/null; git diff --shortstat HEAD'], timeout=60)
    numbers = {key: int(value) for value, key in re.findall(r'(\d+) (file|insertion|deletion)', result.stdout)}
    return {'files_changed': numbers.get('file', 0), 'insertions': numbers.get('insertion', 0),
            'deletions': numbers.get('deletion', 0)}


def run_trial(trial, task, args, out):
    agent = trial['agent']
    prepare, argv_for, parse = AGENTS[agent]
    trial_dir = out / 'trials' / trial['id']
    trial_dir.mkdir(parents=True, exist_ok=True)
    token = trial_token(args.proxy_secret, trial['id'])
    row = {**{key: trial[key] for key in ('id', 'task', 'agent', 'rep')},
           'language': task['language'], 'category': task['category'], 'difficulty': task['difficulty'],
           'model': args.model, 'thinking': args.thinking, 'passed': False, 'failure': None}
    container = None
    started = time.monotonic()
    try:
        container = Container(IMAGES[agent], f'arena-{trial["id"]}', args.cpus, args.memory)
        init_repo(container, task)
        env = prepare(container, args, token)
        timeout = min(task.get('timeout_s', args.timeout), args.timeout)
        prompt = task['prompt'].strip() + PROMPT_SUFFIX
        agent_started = time.monotonic()
        invocation = container.exec(argv_for(prompt, args, timeout), env=env, timeout=timeout + 30)
        row['wall_seconds'] = round(time.monotonic() - agent_started, 1)
        row['exit_code'] = invocation.returncode
        (trial_dir / 'agent.stdout').write_text(redact(invocation.stdout, token))
        (trial_dir / 'agent.stderr').write_text(redact(invocation.stderr, token))
        timed_out = invocation.returncode in (124, 137) or row['wall_seconds'] >= timeout - 2
        result = parse(invocation.stdout) if invocation.stdout.strip() else {}
        usage = result.get('usage') if isinstance(result.get('usage'), dict) else {}
        metrics = result.get('metrics') if isinstance(result.get('metrics'), dict) else {}
        row.update({'agent_ok': result.get('ok') is True, 'turns': metrics.get('turns', usage.get('turns')),
                    'tool_calls': metrics.get('tool_calls'), 'tools': metrics.get('tools'),
                    'tool_errors': metrics.get('tool_errors', usage.get('tool_errors')),
                    'tokens': usage.get('totalTokens'), 'input_tokens': usage.get('inputTokens'),
                    'output_tokens': usage.get('outputTokens'), 'cached_tokens': usage.get('cacheReadTokens'),
                    'reported_model': result.get('model')})
        row.update(git_diff_stats(container))
        diff = container.exec(['git', 'diff', 'HEAD'], timeout=60)
        (trial_dir / 'changes.diff').write_text(diff.stdout[:2_000_000])
        answer = result.get('answer') or ''
        passed, verification = run_verifier(container, task, answer)
        (trial_dir / 'verify.log').write_text(verification.stdout[-200_000:] + '\n--- stderr ---\n' + verification.stderr[-200_000:])
        row['verifier_passed'] = passed
        row['passed'] = passed
        if not passed:
            row['failure'] = ('timeout' if timed_out else
                              'agent_error' if not result.get('ok') and not row['files_changed'] and not answer else
                              'verifier_failed')
    except Exception as error:  # noqa: BLE001 - infrastructure failures are recorded, not fatal
        row['failure'] = 'infrastructure'
        row['infrastructure_error'] = redact(str(error), token)[-2000:]
    finally:
        if container:
            container.remove()
    row['trial_seconds'] = round(time.monotonic() - started, 1)
    row['finished_at'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    return row


def plan_trials(tasks, agents, repetitions, seed):
    trials = [{'id': f'{task["id"]}--{agent}--r{rep}', 'task': task['id'], 'agent': agent, 'rep': rep}
              for rep in range(1, repetitions + 1) for task in tasks for agent in agents]
    # Interleave agents and tasks so provider load and time-of-day effects spread evenly.
    random.Random(seed).shuffle(trials)
    trials.sort(key=lambda trial: trial['rep'])
    return trials


def cmd_run(args):
    out = Path(args.output_dir)
    out.mkdir(parents=True, exist_ok=True)
    tasks = load_tasks(args.tasks_dir, args.tasks.split(',') if args.tasks else None)
    by_id = {task['id']: task for task in tasks}
    agents = args.agents.split(',')
    results_path = out / 'results.jsonl'
    done = set()
    if results_path.exists():
        for line in results_path.read_text().splitlines():
            row = json.loads(line)
            if row.get('failure') != 'infrastructure' or not args.retry_infrastructure:
                done.add(row['id'])
    manifest = {'model': args.model, 'omp_model': args.omp_model or args.model, 'thinking': args.thinking,
                'agents': agents, 'repetitions': args.repetitions, 'timeout': args.timeout,
                'tasks': sorted(by_id), 'images': {agent: image_id(IMAGES[agent]) for agent in agents}}
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    pending = [trial for trial in plan_trials(tasks, agents, args.repetitions, args.seed) if trial['id'] not in done]
    print(f'{len(pending)} trials pending ({len(done)} already recorded)', flush=True)
    lock = threading.Lock()
    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        futures = [pool.submit(run_trial, trial, by_id[trial['task']], args, out) for trial in pending]
        for index, future in enumerate(as_completed(futures), 1):
            row = future.result()
            with lock, results_path.open('a') as handle:
                handle.write(json.dumps(row) + '\n')
            verdict = 'PASS' if row['passed'] else f'FAIL({row["failure"]})'
            print(f'[{index}/{len(pending)}] {row["id"]}: {verdict} {row.get("wall_seconds", "-")}s', flush=True)
    return cmd_report(args)


def image_id(name):
    result = docker('image', 'inspect', '--format', '{{.Id}}', name, check=False)
    return result.stdout.strip() or None


# ── report ─────────────────────────────────────────────────────────────────

def wilson(passed, total, z=1.96):
    if total == 0:
        return (None, None)
    p = passed / total
    denominator = 1 + z * z / total
    centre = (p + z * z / (2 * total)) / denominator
    half = z * math.sqrt(p * (1 - p) / total + z * z / (4 * total * total)) / denominator
    return (round(centre - half, 3), round(centre + half, 3))


def binomial_two_sided(k, n):
    if n == 0:
        return 1.0
    tail = sum(math.comb(n, i) for i in range(0, min(k, n - k) + 1)) / 2 ** n
    return min(1.0, 2 * tail)


def median(values):
    values = sorted(value for value in values if isinstance(value, (int, float)))
    if not values:
        return None
    middle = len(values) // 2
    return values[middle] if len(values) % 2 else round((values[middle - 1] + values[middle]) / 2, 1)


def proxy_stats(path):
    stats = {}
    if not path or not Path(path).exists():
        return stats
    for line in Path(path).read_text().splitlines():
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        trial = stats.setdefault(entry.get('trial'), {'requests': 0, 'errors': 0, 'rate_limited': 0, 'models': set(),
                                                       'input': 0, 'cache_read': 0, 'output': 0})
        if not entry.get('path', '').endswith(('/messages', '/chat/completions')):
            continue
        if entry.get('kind') == 'usage':
            trial['input'] += entry.get('input_tokens', 0)
            trial['cache_read'] += entry.get('cache_read_tokens', 0)
            trial['output'] += entry.get('output_tokens', 0)
            continue
        trial['requests'] += 1
        if entry.get('model'):
            trial['models'].add(entry['model'])
        status = entry.get('status', 0)
        trial['rate_limited'] += status == 429
        trial['errors'] += status >= 500
    return stats


def cmd_report(args):
    out = Path(args.output_dir)
    rows = [json.loads(line) for line in (out / 'results.jsonl').read_text().splitlines() if line.strip()]
    latest = {}
    for row in rows:
        latest[row['id']] = row
    rows = list(latest.values())
    proxy = proxy_stats(args.proxy_log or (out / 'proxy.jsonl'))
    for row in rows:
        stats = proxy.get(row['id'])
        if stats:
            row['model_requests'] = stats['requests']
            row['rate_limited'] = stats['rate_limited']
            row['upstream_errors'] = stats['errors']
            row['wire_models'] = sorted(stats['models'])
            # Anthropic-style input_tokens exclude cache reads; total is everything the provider processed.
            row['wire_input_tokens'] = stats['input'] + stats['cache_read']
            row['wire_cached_tokens'] = stats['cache_read']
            row['wire_output_tokens'] = stats['output']
    agents = sorted({row['agent'] for row in rows})
    scored = [row for row in rows if row['failure'] != 'infrastructure']

    def summary(subset):
        result = {}
        for agent in agents:
            mine = [row for row in subset if row['agent'] == agent]
            passed = sum(row['passed'] for row in mine)
            result[agent] = {'passed': passed, 'total': len(mine),
                             'rate': round(passed / len(mine), 3) if mine else None,
                             'ci95': wilson(passed, len(mine))}
        return result

    overall = summary(scored)
    efficiency = {}
    for agent in agents:
        mine = [row for row in scored if row['agent'] == agent]
        efficiency[agent] = {key: median(row.get(key) for row in mine)
                             for key in ('wall_seconds', 'turns', 'model_requests', 'wire_input_tokens',
                                         'wire_cached_tokens', 'wire_output_tokens', 'files_changed')}
        efficiency[agent]['failures'] = {}
        for row in mine:
            if row['failure']:
                efficiency[agent]['failures'][row['failure']] = efficiency[agent]['failures'].get(row['failure'], 0) + 1
        efficiency[agent]['wire_models'] = sorted({model for row in mine for model in row.get('wire_models', [])})
        mix = {}
        for row in mine:
            for name, count in (row.get('tools') or {}).items():
                mix[name] = mix.get(name, 0) + count
        efficiency[agent]['tool_mix'] = dict(sorted(mix.items(), key=lambda item: -item[1]))
    breakdowns = {dimension: {value: summary([row for row in scored if row[dimension] == value])
                              for value in sorted({row[dimension] for row in scored})}
                  for dimension in ('category', 'language', 'difficulty')}

    pairs = {}
    for row in scored:
        pairs.setdefault((row['task'], row['rep']), {})[row['agent']] = row['passed']
    # Exact McNemar test over (task, repetition) pairs for every agent pair.
    paired = []
    for index, a in enumerate(agents):
        for b in agents[index + 1:]:
            complete = [pair for pair in pairs.values() if a in pair and b in pair]
            only_a = sum(pair[a] and not pair[b] for pair in complete)
            only_b = sum(pair[b] and not pair[a] for pair in complete)
            paired.append({'a': a, 'b': b, 'pairs': len(complete), 'only_a': only_a, 'only_b': only_b,
                           'both': sum(pair[a] and pair[b] for pair in complete),
                           'neither': sum(not pair[a] and not pair[b] for pair in complete),
                           'mcnemar_exact_p': round(binomial_two_sided(only_a, only_a + only_b), 4)})
    per_task = {}
    for row in scored:
        entry = per_task.setdefault(row['task'], {agent: [0, 0] for agent in agents})
        entry[row['agent']][0] += row['passed']
        entry[row['agent']][1] += 1
    report = {'manifest': json.loads((out / 'manifest.json').read_text()) if (out / 'manifest.json').exists() else {},
              'trials': len(rows), 'infrastructure_failures': len(rows) - len(scored),
              'overall': overall, 'paired': paired, 'efficiency': efficiency, 'breakdowns': breakdowns,
              'per_task': per_task}
    (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    (out / 'report.md').write_text(render_markdown(report, agents))
    print(render_markdown(report, agents))
    return 0


def render_markdown(report, agents):
    lines = ['# Coding arena report', '']
    manifest = report['manifest']
    if manifest:
        lines.append(f"Model `{manifest.get('model')}` (thinking {manifest.get('thinking')}), "
                     f"{manifest.get('repetitions')} repetitions, {len(manifest.get('tasks', []))} tasks, "
                     f"timeout {manifest.get('timeout')}s. Infrastructure failures excluded: {report['infrastructure_failures']}.")
        lines.append('')
    lines += ['| Agent | Passed | Rate | 95% CI | Median wall s | Median requests | Median input tok | Median cached tok | Median output tok |',
              '| --- | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: |']
    for agent in agents:
        o, e = report['overall'][agent], report['efficiency'][agent]
        lines.append(f"| {agent} | {o['passed']}/{o['total']} | {o['rate']} | {o['ci95'][0]}–{o['ci95'][1]} | "
                     f"{e['wall_seconds']} | {e['model_requests']} | {e['wire_input_tokens']} | "
                     f"{e['wire_cached_tokens']} | {e['wire_output_tokens']} |")
    if report['paired']:
        lines += ['', '## Paired (same task and repetition)', '',
                  '| A | B | Pairs | Only A | Only B | Both | Neither | McNemar exact p |',
                  '| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |']
        for p in report['paired']:
            lines.append(f"| {p['a']} | {p['b']} | {p['pairs']} | {p['only_a']} | {p['only_b']} | "
                         f"{p['both']} | {p['neither']} | {p['mcnemar_exact_p']} |")
    lines += ['', '## Failure modes', '']
    for agent in agents:
        lines.append(f"- {agent}: {report['efficiency'][agent]['failures'] or 'none'}; wire models {report['efficiency'][agent]['wire_models']}")
    lines += ['', '## Tool calls (all trials)', '']
    for agent in agents:
        lines.append(f"- {agent}: {report['efficiency'][agent]['tool_mix']}")
    for dimension, groups in report['breakdowns'].items():
        lines += ['', f'## By {dimension}', '', '| ' + dimension + ' | ' + ' | '.join(agents) + ' |',
                  '| --- |' + ' ---: |' * len(agents)]
        for value, summary in groups.items():
            lines.append(f'| {value} | ' + ' | '.join(f"{summary[a]['passed']}/{summary[a]['total']}" for a in agents) + ' |')
    lines += ['', '## Per task', '', '| Task | ' + ' | '.join(agents) + ' |', '| --- |' + ' ---: |' * len(agents)]
    for task, counts in sorted(report['per_task'].items()):
        lines.append(f'| {task} | ' + ' | '.join(f'{counts[a][0]}/{counts[a][1]}' for a in agents) + ' |')
    return '\n'.join(lines) + '\n'


# ── CLI ────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--tasks-dir', default=str(TASKS_DIR))
    sub = parser.add_subparsers(dest='command', required=True)
    validate = sub.add_parser('validate')
    validate.add_argument('--tasks')
    validate.add_argument('--concurrency', type=int, default=4)
    run = sub.add_parser('run')
    run.add_argument('--output-dir', required=True)
    run.add_argument('--tasks')
    run.add_argument('--agents', default='lemon,omp')
    run.add_argument('--model', default='k3.1-pro', help='Kimi Code wire model id')
    run.add_argument('--omp-model', help='omp catalog id when it differs from the wire id')
    run.add_argument('--thinking', default='high')
    run.add_argument('--repetitions', type=int, default=3)
    run.add_argument('--timeout', type=int, default=DEFAULT_TIMEOUT)
    run.add_argument('--concurrency', type=int, default=6)
    run.add_argument('--cpus', default='2')
    run.add_argument('--memory', default='3g')
    run.add_argument('--seed', type=int, default=20261111)
    run.add_argument('--proxy-port', type=int, default=18787)
    run.add_argument('--proxy-log')
    run.add_argument('--retry-infrastructure', action='store_true')
    report = sub.add_parser('report')
    report.add_argument('--output-dir', required=True)
    report.add_argument('--proxy-log')
    args = parser.parse_args()
    if args.command == 'validate':
        return cmd_validate(args)
    if args.command == 'run':
        args.proxy_secret = os.environ.get('ARENA_PROXY_SECRET') or sys.exit('ARENA_PROXY_SECRET must match the running proxy')
        return cmd_run(args)
    return cmd_report(args)


if __name__ == '__main__':
    sys.exit(main())
