#!/usr/bin/env python3
"""Isolated coding-agent arena: Lemon vs omp, one fresh container per trial.

Subcommands:
  validate  Prove every task is well-formed: its hidden verifier fails on the
            starting fixture and passes on the reference solution.
  run       Run trials (task x agent x repetition) in fresh containers, resumably.
  report    Summarize a run directory into report.json and report.md.

Trial containers see only their own fixture repository. Hidden verifier files
are copied in only after the agent exits. Model traffic goes through the host
auth proxy (kimi_auth_proxy.ts: Kimi Code and Z.AI) with a per-trial signed
token, so no real credential enters a container and every request is
attributable to its trial. Every (task, repetition) group runs all arms on one
model (see Scheduler), so comparisons never mix models.
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
import urllib.error
import urllib.request
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
    # Checked exec/cp calls are idempotent setup steps; under load Docker Desktop occasionally
    # fails them with no diagnostics, so retry those. Agent invocations run unchecked, never retried.
    attempts = 3 if check and argv[0] in ('exec', 'cp') else 1
    for attempt in range(attempts):
        result = subprocess.run(['docker', *argv], capture_output=True, text=True, timeout=timeout,
                                input=input, stdin=None if input is not None else subprocess.DEVNULL)
        if result.returncode == 0 or not check:
            return result
        if attempt + 1 < attempts:
            time.sleep(2 * (attempt + 1))
    raise RuntimeError(f'docker {argv[0]} failed (exit {result.returncode}): {result.stderr.strip()[-2000:]}')


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
            try:
                outcome = future.result()
            except Exception as error:  # noqa: BLE001 - one task's infrastructure failure must not hide the rest
                outcome = {'task': futures[future]['id'], 'ok': False, 'problems': [f'infrastructure: {error}']}
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


# Wire model id → how each harness and the host proxy reach it. Both harnesses always use the same
# wire model inside one comparison; the protocol each harness picks for it is a harness property.
MODELS = {
    'k3.1-pro': {'provider': 'kimi', 'lemon_provider': 'kimi_coding', 'lemon_env': 'KIMI_API_KEY',
                 'lemon_base': '/coding', 'omp_provider': 'kimi-code', 'omp_env': 'KIMI_API_KEY',
                 'omp_base': '/coding/v1', 'probe_interval': 300},
    # Lemon's catalog serves glm-5.3 over Z.AI's coding-plan chat-completions endpoint; omp's over
    # Z.AI's Anthropic-compatible endpoint. Same model, quota and credential.
    'glm-5.3': {'provider': 'zai', 'lemon_provider': 'zai', 'lemon_env': 'ZAI_API_KEY',
                'lemon_base': '/zai/api/coding/paas/v4', 'omp_provider': 'zai', 'omp_env': 'ZAI_API_KEY',
                'omp_base': '/zai/api/anthropic',
                # Z.AI answers 1302 "Rate limit reached for requests" (a concurrency throttle) briefly.
                'probe_interval': 60},
}


def proxy_request(args, path, body=None, timeout=60):
    """One host-side request through the proxy with a throwaway attempt token; returns (status, json)."""
    token = trial_token(args.proxy_secret, f'scheduler-probe#{secrets.token_hex(4)}')
    request = urllib.request.Request(f'http://127.0.0.1:{args.proxy_port}{path}',
                                     data=json.dumps(body).encode() if body is not None else None,
                                     headers={'content-type': 'application/json', 'authorization': f'Bearer {token}',
                                              'x-api-key': token, 'anthropic-version': '2023-06-01'})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, json.loads(response.read() or b'null')
    except urllib.error.HTTPError as error:
        return error.code, None
    except (OSError, ValueError):  # connection errors, timeouts, non-JSON bodies all mean "unknown"
        return 0, None


def model_responds(args, model):
    """A tiny real request: True when the provider currently accepts this model (quota left)."""
    if MODELS[model]['provider'] == 'kimi':
        status, _ = proxy_request(args, '/coding/v1/messages', {
            'model': model, 'max_tokens': 8, 'messages': [{'role': 'user', 'content': 'Reply with OK.'}]})
    else:
        status, _ = proxy_request(args, '/zai/api/coding/paas/v4/chat/completions', {
            'model': model, 'max_tokens': 8, 'thinking': {'type': 'disabled'},
            'messages': [{'role': 'user', 'content': 'Reply with OK.'}]})
    return status == 200


def kimi_window_usage(args):
    """Kimi Code 5-hour window used ratio (0..1), or None when unknown."""
    status, body = proxy_request(args, '/coding/v1/usages', timeout=30)
    try:
        return float(body['usages']['limit_5h']['used_ratio']) if status == 200 else None
    except (KeyError, TypeError, ValueError):
        return None


def attempt_rate_limited(args, attempt):
    """True when the proxy saw an upstream 429 for this attempt (subscription quota or rate limit)."""
    if not args.proxy_log or not Path(args.proxy_log).exists():
        return False
    needle = json.dumps(attempt)
    with open(args.proxy_log) as handle:
        return any(needle in line and '"status":429' in line for line in handle)


def proxy_base(args):
    return f'http://host.docker.internal:{args.proxy_port}'


def prepare_lemon(container, args, token, model, disclosure_profile=None):
    spec = MODELS[model]
    config = f'''[defaults]
provider = "{spec['lemon_provider']}"
model = "{spec['lemon_provider']}:{model}"
thinking_level = "{args.thinking}"

[providers.{spec['lemon_provider']}]
base_url = "{proxy_base(args)}{spec['lemon_base']}"
'''
    container.write('/home/agent/.lemon/config.toml', config)
    env = {spec['lemon_env']: token, 'LEMON_SECRETS_MASTER_KEY': secrets.token_hex(32),
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


def lemon_argv(prompt, args, timeout, model):
    # `lemon -p` has no time option; its client gives up after a fixed 600s drain deadline.
    return ['lemon', '-p', prompt, '--output', 'stream-json', '--model', f"{MODELS[model]['lemon_provider']}:{model}",
            '--cwd', '/work', '--approval-policy', 'allow']


OMP_ROLES = ('default', 'smol', 'slow', 'plan', 'task', 'commit', 'scout', 'mechanic', 'research', 'review')


def prepare_omp(container, args, token, model):
    spec = MODELS[model]
    role_model = f"{spec['omp_provider']}/{model}:{args.thinking}"
    # The models.yml apiKey names the variable (kimi-code resolves no env key on its own).
    models_yml = f'''providers:
  {spec['omp_provider']}:
    baseUrl: {proxy_base(args)}{spec['omp_base']}
    apiKey: {spec['omp_env']}
'''
    container.write('/home/agent/.omp/agent/models.yml', models_yml)
    roles = ''.join(f'  {role}: {role_model}\n' for role in OMP_ROLES)
    container.write('/home/agent/.omp/agent/config.yml', f'modelRoles:\n{roles}')
    return {spec['omp_env']: token, 'HOME': '/home/agent'}


def omp_argv(prompt, args, timeout, model):
    return ['omp', '-p', prompt, '--mode', 'json', '--model', f"{MODELS[model]['omp_provider']}/{model}",
            '--thinking', args.thinking, '--cwd', '/work', '--no-session', '--no-title', '--auto-approve',
            '--max-time', str(timeout)]


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
          'lemon-coding': (lambda container, args, token, model: prepare_lemon(container, args, token, model, 'coding'),
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


def run_trial(trial, task, args, out, model):
    agent = trial['agent']
    prepare, argv_for, parse = AGENTS[agent]
    trial_dir = out / 'trials' / trial['id']
    trial_dir.mkdir(parents=True, exist_ok=True)
    # A rerun (after an interrupted campaign) must not inherit the aborted attempt's proxy traffic.
    attempt = f'{trial["id"]}#{secrets.token_hex(4)}'
    token = trial_token(args.proxy_secret, attempt)
    row = {**{key: trial[key] for key in ('id', 'task', 'agent', 'rep')}, 'proxy_trial': attempt,
           'language': task['language'], 'category': task['category'], 'difficulty': task['difficulty'],
           'model': model, 'thinking': args.thinking, 'passed': False, 'failure': None}
    container = None
    started = time.monotonic()
    try:
        container = Container(IMAGES[agent], f'arena-{trial["id"]}', args.cpus, args.memory)
        init_repo(container, task)
        env = prepare(container, args, token, model)
        timeout = min(task.get('timeout_s', args.timeout), args.timeout)
        prompt = task['prompt'].strip() + PROMPT_SUFFIX
        agent_started = time.monotonic()
        invocation = container.exec(argv_for(prompt, args, timeout, model), env=env, timeout=timeout + 30)
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
        # A quota or rate-limit 429 disturbs the trial whatever its outcome (and only long runs survive one to
        # pass), so it is unscorable either way; it is retried on the same model.
        if attempt_rate_limited(args, attempt):
            row['scored_failure'] = row['failure']
            row['passed'] = False
            row['failure'] = 'infrastructure'
            row['infrastructure_error'] = 'upstream 429 (provider quota or rate limit)'
            row['rate_limited'] = True
    except Exception as error:  # noqa: BLE001 - infrastructure failures are recorded, not fatal
        row['failure'] = 'infrastructure'
        row['infrastructure_error'] = redact(str(error), token)[-2000:]
    finally:
        if container:
            container.remove()
    row['trial_seconds'] = round(time.monotonic() - started, 1)
    row['finished_at'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    return row


def group_key(task, rep):
    return f'{task}::r{rep}'


def plan_trials(tasks, agents, repetitions, seed):
    """Comparison groups (task, repetition) in shuffled order, each group's arms adjacent.

    All arms of a group run on one model and close together in time, so a quota window that ends
    mid-campaign leaves few groups half-finished.
    """
    rng = random.Random(seed)
    groups = [(rep, task['id']) for rep in range(1, repetitions + 1) for task in tasks]
    rng.shuffle(groups)
    groups.sort(key=lambda group: group[0])
    trials = []
    for rep, task in groups:
        arms = list(agents)
        rng.shuffle(arms)
        trials += [{'id': f'{task}--{agent}--r{rep}', 'task': task, 'agent': agent, 'rep': rep} for agent in arms]
    return trials


def read_rows(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()] if path.exists() else []


class Scheduler:
    """Hands trials to workers so that every (task, repetition) group runs on exactly one model.

    A group's model is chosen when its first arm starts and persisted in groups.json: the primary
    model while it has quota (and, for Kimi, while its 5-hour window is below --kimi-usage-limit),
    otherwise the fallback. Every arm, including retries after infrastructure or 429 failures, runs on
    the group's model. A group without scored rows and with no arm running may move to another model.
    A group with scored rows waits for its model; only after its model has been unavailable for
    --reassign-after seconds is it moved wholesale to an available model, its old rows archived in
    results-archive.jsonl and all of its arms rerun. Upstream 429s mark a model unavailable until a
    tiny probe request succeeds.
    """

    def __init__(self, args, out, trials, by_id):
        self.args, self.out, self.by_id = args, out, by_id
        self.models = [args.model] + ([args.fallback_model] if args.fallback_model else [])
        self.results_path, self.archive_path = out / 'results.jsonl', out / 'results-archive.jsonl'
        self.groups_path = out / 'groups.json'
        self.cv = threading.Condition()
        self.groups = json.loads(self.groups_path.read_text()) if self.groups_path.exists() else {}
        self.scored = {}  # group -> agents with a scored (non-infrastructure) latest row
        latest = {}
        for row in read_rows(self.results_path):
            latest[row['id']] = row
        for row in latest.values():
            key = group_key(row['task'], row['rep'])
            # Rows recorded before groups.json existed pin their group to the model they ran on.
            self.groups.setdefault(key, {'model': row['model'], 'history': [
                {'model': row['model'], 'at': row.get('finished_at'), 'reason': 'recorded rows'}]})
            if row['failure'] != 'infrastructure':
                self.scored.setdefault(key, set()).add(row['agent'])
        self.save_groups()
        # Groups already started go first so pinned groups finish before new ones begin.
        self.pending = sorted(trials, key=lambda trial: group_key(trial['task'], trial['rep']) not in self.groups)
        self.running = {}  # group -> arms in flight
        self.unavailable = {}  # model -> monotonic time it became unavailable
        self.usage_checked, self.kimi_accepts_new = 0.0, True
        self.retries = {}
        self.model_running = {}  # model -> trials in flight
        self.caps = {args.fallback_model: args.fallback_concurrency} if args.fallback_model else {}
        self.finished = 0

    def save_groups(self):
        self.groups_path.write_text(json.dumps(self.groups, indent=1, sort_keys=True) + '\n')

    def assign(self, key, model, reason):
        entry = self.groups.setdefault(key, {'history': []})
        entry['model'] = model
        entry['history'].append({'model': model, 'at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                                 'reason': reason})
        self.save_groups()
        print(f'group {key} -> {model} ({reason})', flush=True)

    def available(self, model):
        return model not in self.unavailable

    def accepts_new_groups(self, model):
        if not self.available(model):
            return False
        if MODELS[model]['provider'] != 'kimi' or self.args.kimi_usage_limit >= 1:
            return True
        if time.monotonic() - self.usage_checked > 60:
            self.usage_checked = time.monotonic()
            used = kimi_window_usage(self.args)
            accepts = used is None or used < self.args.kimi_usage_limit
            if accepts != self.kimi_accepts_new:
                print(f'kimi 5h window used {used}: {"accepting" if accepts else "no longer accepting"} new groups',
                      flush=True)
            self.kimi_accepts_new = accepts
        return self.kimi_accepts_new

    def archive_group(self, key):
        """Move a group's recorded rows out of scoring before it is rerun on another model."""
        rows = read_rows(self.results_path)
        moved = [row for row in rows if group_key(row['task'], row['rep']) == key]
        with self.archive_path.open('a') as handle:
            for row in moved:
                handle.write(json.dumps({**row, 'archived_reason': 'group reassigned to another model'}) + '\n')
        self.results_path.write_text(''.join(json.dumps(row) + '\n' for row in rows if row not in moved))
        self.scored.pop(key, None)
        task, rep = key.rsplit('::r', 1)
        queued = {trial['id'] for trial in self.pending}
        for agent in self.args.agents.split(','):
            trial = {'id': f'{task}--{agent}--r{rep}', 'task': task, 'agent': agent, 'rep': int(rep)}
            if trial['id'] not in queued:
                self.pending.insert(0, trial)

    def has_room(self, model):
        cap = self.caps.get(model)
        return cap is None or self.model_running.get(model, 0) < cap

    def choose(self, trial):
        """The model to run this trial on now, or None to leave it pending. Caller holds the lock."""
        key = group_key(trial['task'], trial['rep'])
        pinned = self.groups.get(key, {}).get('model')
        if pinned and self.available(pinned):
            return pinned if self.has_room(pinned) else None
        if self.running.get(key):
            return None  # arms in flight pin the group to its model
        fresh = [model for model in self.models if self.has_room(model) and self.accepts_new_groups(model)]
        if not pinned:
            if fresh:
                self.assign(key, fresh[0], 'first arm')
                return fresh[0]
            return None
        others = [model for model in fresh if model != pinned]
        if not others:
            return None
        if not self.scored.get(key):
            self.assign(key, others[0], f'{pinned} unavailable; no scored rows')
            return others[0]
        if time.monotonic() - self.unavailable[pinned] > self.args.reassign_after:
            self.archive_group(key)
            self.assign(key, others[0], f'{pinned} unavailable > {self.args.reassign_after}s; rows archived')
            return others[0]
        return None

    def next_trial(self):
        with self.cv:
            while True:
                for trial in list(self.pending):
                    model = self.choose(trial)
                    if model:
                        # choose() may have queued a reassigned group's other arms, shifting indexes.
                        self.pending.remove(trial)
                        key = group_key(trial['task'], trial['rep'])
                        self.running[key] = self.running.get(key, 0) + 1
                        self.model_running[model] = self.model_running.get(model, 0) + 1
                        return trial, model
                if not self.pending and not any(self.running.values()):
                    return None
                self.cv.wait(timeout=60)

    def mark_unavailable(self, model):
        if model in self.unavailable:
            return
        self.unavailable[model] = time.monotonic()
        print(f'{model} quota exhausted or rate limited; pausing it', flush=True)
        threading.Thread(target=self.probe_until_available, args=(model,), daemon=True).start()

    def probe_until_available(self, model):
        while True:
            time.sleep(MODELS[model]['probe_interval'])
            if model_responds(self.args, model):
                with self.cv:
                    self.unavailable.pop(model, None)
                    print(f'{model} available again', flush=True)
                    self.cv.notify_all()
                return

    def finish(self, trial, model, row):
        key = group_key(trial['task'], trial['rep'])
        with self.cv:
            self.running[key] -= 1
            self.model_running[model] -= 1
            with self.results_path.open('a') as handle:
                handle.write(json.dumps({**row, 'group_model': self.groups[key]['model']}) + '\n')
            self.finished += 1
            verdict = 'PASS' if row['passed'] else f'FAIL({row["failure"]})'
            print(f'[{self.finished}] {row["id"]} on {model}: {verdict} {row.get("wall_seconds", "-")}s '
                  f'({len(self.pending)} pending)', flush=True)
            if row['failure'] != 'infrastructure':
                self.scored.setdefault(key, set()).add(trial['agent'])
            elif row.get('rate_limited'):
                self.mark_unavailable(model)
                self.pending.insert(0, trial)
            elif self.retries.get(trial['id'], 0) < 2:
                self.retries[trial['id']] = self.retries.get(trial['id'], 0) + 1
                self.pending.append(trial)
            self.cv.notify_all()

    def worker(self):
        while (item := self.next_trial()):
            trial, model = item
            self.finish(trial, model, run_trial(trial, self.by_id[trial['task']], self.args, self.out, model))


def cmd_run(args):
    out = Path(args.output_dir)
    out.mkdir(parents=True, exist_ok=True)
    tasks = load_tasks(args.tasks_dir, args.tasks.split(',') if args.tasks else None)
    by_id = {task['id']: task for task in tasks}
    agents = args.agents.split(',')
    done = set()
    for row in read_rows(out / 'results.jsonl'):
        if row.get('failure') != 'infrastructure' or not args.retry_infrastructure:
            done.add(row['id'])
    manifest = {'model': args.model, 'fallback_model': args.fallback_model, 'thinking': args.thinking,
                'agents': agents, 'repetitions': args.repetitions, 'timeout': args.timeout,
                'tasks': sorted(by_id), 'images': {agent: image_id(IMAGES[agent]) for agent in agents}}
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    pending = [trial for trial in plan_trials(tasks, agents, args.repetitions, args.seed) if trial['id'] not in done]
    print(f'{len(pending)} trials pending ({len(done)} already recorded)', flush=True)
    scheduler = Scheduler(args, out, pending, by_id)
    workers = [threading.Thread(target=scheduler.worker) for _ in range(args.concurrency)]
    for thread in workers:
        thread.start()
    for thread in workers:
        thread.join()
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
        stats = proxy.get(row.get('proxy_trial', row['id']))
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
    models = sorted({row['model'] for row in scored})
    # Comparison unit: (task, repetition, model). The scheduler runs every arm of a group on one model;
    # keying on the row model as well guarantees no cross-model pair is ever formed.
    cells = {}
    for row in scored:
        cells.setdefault((row['task'], row['rep'], row['model']), {})[row['agent']] = row
    complete = {key for key, cell in cells.items() if all(agent in cell for agent in agents)}

    def summary(subset):
        result = {}
        for agent in agents:
            mine = [row for row in subset if row['agent'] == agent]
            passed = sum(row['passed'] for row in mine)
            result[agent] = {'passed': passed, 'total': len(mine),
                             'rate': round(passed / len(mine), 3) if mine else None,
                             'ci95': wilson(passed, len(mine))}
        return result

    def efficiency(subset):
        result = {}
        for agent in agents:
            mine = [row for row in subset if row['agent'] == agent]
            entry = {key: median(row.get(key) for row in mine)
                     for key in ('wall_seconds', 'turns', 'model_requests', 'wire_input_tokens',
                                 'wire_cached_tokens', 'wire_output_tokens', 'files_changed')}
            entry['failures'] = {}
            for row in mine:
                if row['failure']:
                    entry['failures'][row['failure']] = entry['failures'].get(row['failure'], 0) + 1
            entry['wire_models'] = sorted({model for row in mine for model in row.get('wire_models', [])})
            mix = {}
            for row in mine:
                for name, count in (row.get('tools') or {}).items():
                    mix[name] = mix.get(name, 0) + count
            entry['tool_mix'] = dict(sorted(mix.items(), key=lambda item: -item[1]))
            result[agent] = entry
        return result

    def paired(keys):
        # Exact McNemar test over same-model (task, repetition) pairs for every agent pair.
        result = []
        for index, a in enumerate(agents):
            for b in agents[index + 1:]:
                both_ran = [cells[key] for key in keys if a in cells[key] and b in cells[key]]
                only_a = sum(cell[a]['passed'] and not cell[b]['passed'] for cell in both_ran)
                only_b = sum(cell[b]['passed'] and not cell[a]['passed'] for cell in both_ran)
                result.append({'a': a, 'b': b, 'pairs': len(both_ran), 'only_a': only_a, 'only_b': only_b,
                               'both': sum(cell[a]['passed'] and cell[b]['passed'] for cell in both_ran),
                               'neither': sum(not cell[a]['passed'] and not cell[b]['passed'] for cell in both_ran),
                               'mcnemar_exact_p': round(binomial_two_sided(only_a, only_a + only_b), 4)})
        return result

    per_model = {}
    for model in models:
        mine = [row for row in scored if row['model'] == model]
        per_model[model] = {'overall': summary(mine), 'efficiency': efficiency(mine),
                            'paired': paired([key for key in cells if key[2] == model]),
                            'groups': len({key for key in cells if key[2] == model}),
                            'complete_groups': len({key for key in complete if key[2] == model})}
    # Pooled across models, restricted to complete groups so every arm faces the same model mix.
    pooled_rows = [row for row in scored if (row['task'], row['rep'], row['model']) in complete]
    pooled = {'overall': summary(pooled_rows), 'paired': paired(sorted(complete)), 'complete_groups': len(complete)}
    breakdowns = {dimension: {value: summary([row for row in pooled_rows if row[dimension] == value])
                              for value in sorted({row[dimension] for row in pooled_rows})}
                  for dimension in ('model', 'category', 'language', 'difficulty')}
    per_task = {}
    for row in scored:
        entry = per_task.setdefault(row['task'], {}).setdefault(row['model'], {agent: [0, 0] for agent in agents})
        entry[row['agent']][0] += row['passed']
        entry[row['agent']][1] += 1
    report = {'manifest': json.loads((out / 'manifest.json').read_text()) if (out / 'manifest.json').exists() else {},
              'trials': len(rows), 'infrastructure_failures': len(rows) - len(scored),
              'models': per_model, 'pooled': pooled, 'breakdowns': breakdowns, 'per_task': per_task}
    (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    (out / 'report.md').write_text(render_markdown(report, agents))
    print(render_markdown(report, agents))
    return 0


def render_paired(lines, title, pairs):
    lines += ['', title, '', '| A | B | Pairs | Only A | Only B | Both | Neither | McNemar exact p |',
              '| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |']
    for p in pairs:
        lines.append(f"| {p['a']} | {p['b']} | {p['pairs']} | {p['only_a']} | {p['only_b']} | "
                     f"{p['both']} | {p['neither']} | {p['mcnemar_exact_p']} |")


def render_markdown(report, agents):
    lines = ['# Coding arena report', '']
    manifest = report['manifest']
    if manifest:
        fallback = f", fallback `{manifest['fallback_model']}`" if manifest.get('fallback_model') else ''
        lines.append(f"Primary model `{manifest.get('model')}`{fallback} (thinking {manifest.get('thinking')}), "
                     f"{manifest.get('repetitions')} repetitions, {len(manifest.get('tasks', []))} tasks, "
                     f"timeout {manifest.get('timeout')}s. Infrastructure failures excluded: {report['infrastructure_failures']}. "
                     'Every (task, repetition) group runs all arms on one model; comparisons never mix models.')
        lines.append('')
    for model, section in report['models'].items():
        lines += [f'## Model `{model}`', '',
                  f"{section['groups']} groups, {section['complete_groups']} with every arm scored.", '',
                  '| Agent | Passed | Rate | 95% CI | Median wall s | Median requests | Median input tok | Median cached tok | Median output tok |',
                  '| --- | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: |']
        for agent in agents:
            o, e = section['overall'][agent], section['efficiency'][agent]
            lines.append(f"| {agent} | {o['passed']}/{o['total']} | {o['rate']} | {o['ci95'][0]}–{o['ci95'][1]} | "
                         f"{e['wall_seconds']} | {e['model_requests']} | {e['wire_input_tokens']} | "
                         f"{e['wire_cached_tokens']} | {e['wire_output_tokens']} |")
        render_paired(lines, f'### Paired on `{model}` (same task and repetition)', section['paired'])
        lines += ['', f'### Failure modes and tool calls on `{model}`', '']
        for agent in agents:
            e = section['efficiency'][agent]
            lines.append(f"- {agent}: failures {e['failures'] or 'none'}; wire models {e['wire_models']}; tools {e['tool_mix']}")
        lines.append('')
    pooled = report['pooled']
    lines += ['## Pooled same-model comparison', '',
              f"{pooled['complete_groups']} complete groups across models; each pair below shares one model.", '',
              '| Agent | Passed | Rate | 95% CI |', '| --- | ---: | ---: | --- |']
    for agent in agents:
        o = pooled['overall'][agent]
        lines.append(f"| {agent} | {o['passed']}/{o['total']} | {o['rate']} | {o['ci95'][0]}–{o['ci95'][1]} |")
    render_paired(lines, '### Pooled paired (same model, task and repetition)', pooled['paired'])
    for dimension, groups in report['breakdowns'].items():
        lines += ['', f'## By {dimension} (complete groups)', '', '| ' + dimension + ' | ' + ' | '.join(agents) + ' |',
                  '| --- |' + ' ---: |' * len(agents)]
        for value, summary in groups.items():
            lines.append(f'| {value} | ' + ' | '.join(f"{summary[a]['passed']}/{summary[a]['total']}" for a in agents) + ' |')
    lines += ['', '## Per task', '', '| Task | Model | ' + ' | '.join(agents) + ' |', '| --- | --- |' + ' ---: |' * len(agents)]
    for task, by_model in sorted(report['per_task'].items()):
        for model, counts in sorted(by_model.items()):
            lines.append(f'| {task} | {model} | ' + ' | '.join(f'{counts[a][0]}/{counts[a][1]}' for a in agents) + ' |')
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
    run.add_argument('--model', default='k3.1-pro', choices=sorted(MODELS), help='primary wire model id')
    run.add_argument('--fallback-model', choices=sorted(MODELS),
                     help='model for new groups while the primary is out of quota (e.g. glm-5.3)')
    run.add_argument('--kimi-usage-limit', type=float, default=0.9,
                     help='stop starting new groups on Kimi once its 5-hour window reaches this used ratio')
    run.add_argument('--reassign-after', type=int, default=6 * 3600,
                     help='seconds a pinned model may stay unavailable before its unfinished groups move models')
    run.add_argument('--fallback-concurrency', type=int, default=3,
                     help='most trials in flight on the fallback model (Z.AI throttles concurrent requests)')
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
