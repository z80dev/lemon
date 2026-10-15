"""Repeated disclosure experiments using the existing production coding runner.

No provider request is made until an exact bounded operator plan is approved.
"""
import hashlib
import json
import math
import os
from pathlib import Path
import random
import re
import secrets
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.request


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()).hexdigest()


def number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0 else None


def schedule(cases, variants, repetitions, seed):
    if repetitions < 1 or len(variants) < 2 or len(set(variants)) != len(variants):
        raise ValueError('positive repetitions and distinct paired variants required')
    rng = random.Random(seed)
    rows = []
    for case in cases:
        name = case['name']
        initial = list(variants)
        rng.shuffle(initial)
        for repetition in range(1, repetitions + 1):
            # Rotate all positions; for two variants this is AB/BA counterbalancing.
            shift = (repetition - 1) % len(initial)
            order = initial[shift:] + initial[:shift]
            pair = f'{name}:pair:{repetition:04d}'
            for position, variant in enumerate(order, 1):
                rows.append({'task': name, 'variant': variant, 'pair_id': pair,
                             'trial_id': f'{pair}:{variant}', 'repetition': repetition, 'order': position})
    return rows


def paired_configuration(base, variant):
    # Reject duplicate tables, including inline/quoted forms, using the TOML parser.
    import tomllib
    parsed = tomllib.loads(base)
    if 'disclosure' in parsed.get('runtime', {}).get('tools', {}):
        raise ValueError('base config must omit runtime.tools.disclosure')
    if variant not in ('baseline', 'coding'):
        raise ValueError('unknown disclosure variant')
    profile = 'legacy' if variant == 'baseline' else 'coding'
    return base.rstrip() + f'\n\n[runtime.tools.disclosure]\nprofile = "{profile}"\nenabled = true\nbudget_tokens = 40000\ncatalog_tokens = 2000\nmax_results = 5\n'


def isolated_environment(root, config, variant, credentials, ports):
    root = Path(root)
    home, cwd = root / 'home', root / 'config'
    home.mkdir(parents=True, mode=0o700)
    (home / '.lemon').mkdir(mode=0o700)
    cwd.mkdir(mode=0o700)
    path = home / '.lemon' / 'config.toml'
    path.write_text(config)
    path.chmod(0o600)
    # Never inherit ordinary Lemon settings, proxy endpoints, dotenv, or provider state.
    env = {key: os.environ[key] for key in ('PATH', 'LANG', 'LC_ALL', 'TMPDIR') if key in os.environ}
    env.update(credentials)
    env.update({'HOME': str(home), 'LEMON_AGENT_PROFILES_CWD': str(cwd),
                'LEMON_DOTENV_DIR': str(cwd), 'LEMON_STORE_PATH': str(root / 'store'),
                'LEMON_CONTROL_PLANE_PORT': str(ports[0]), 'LEMON_WEB_PORT': str(ports[1]),
                'LEMON_SIM_UI_PORT': str(ports[2]), 'LEMON_CONTROL_PLANE_OPERATOR_TOKEN': secrets.token_hex(32),
                'LEMON_TOOL_DISCLOSURE_PROFILE': 'legacy' if variant == 'baseline' else 'coding',
                'LEMON_SECRETS_MASTER_KEY': secrets.token_hex(32), 'MIX_ENV': 'dev'})
    return env


def validate_plan(plan, experiment, approval_digest):
    if not isinstance(plan, dict) or plan.get('approved') is not True:
        raise ValueError('operator-approved plan required')
    if not re.fullmatch(r'[0-9a-f]{64}', approval_digest or '') or digest(plan) != approval_digest:
        raise ValueError('explicit approval digest must match exact plan')
    if plan.get('experiment') != experiment:
        raise ValueError('approved experiment differs from requested run')
    attempts = len(experiment['tasks']) * len(experiment['variants']) * experiment['repetitions']
    if type(plan.get('max_attempts')) is not int or plan['max_attempts'] < attempts:
        raise ValueError('plan attempt bound too small')
    maximum, ceiling = number(plan.get('max_spend_usd')), number(plan.get('per_attempt_spend_ceiling_usd'))
    if not maximum or not ceiling or ceiling > maximum:
        raise ValueError('positive spend bound and per-attempt ceiling required')
    if plan.get('provider_budget_enforced') is not True:
        raise ValueError('an external hard provider/account budget must be enforced')
    credential_env = plan.get('credential_env')
    if (not isinstance(credential_env, list) or not credential_env
            or any(not isinstance(key, str) for key in credential_env)
            or len(set(credential_env)) != len(credential_env)):
        raise ValueError('explicit credential environment allowlist required')
    if any(not re.fullmatch(r'[A-Z][A-Z0-9_]*(?:API_KEY|ACCESS_TOKEN|AUTH_TOKEN)', key) for key in credential_env):
        raise ValueError('only explicit provider credential variables may be forwarded')
    return plan


def aggregate(rows):
    planned = len(rows)
    rows = [row for row in rows if row.get('attempted', True)]
    successes = sum(row['passed'] for row in rows)
    costs = [number(row.get('cost_usd')) for row in rows]
    measured = sum(value for value in costs if value is not None)
    complete = bool(rows) and all(value is not None for value in costs) and all(row.get('spend_complete', True) for row in rows)
    status = 'undefined_zero_successes' if successes == 0 else ('complete' if complete else 'incomplete_missing_spend')
    summary = {'attempts': len(rows), 'planned_trials': planned, 'skipped': planned - len(rows), 'successes': successes,
               'success_rate': successes / len(rows) if rows else None,
               'measured_spend_usd': measured, 'spend_complete': complete,
               'cost_per_verified_success_usd': measured / successes if successes and complete else None,
               'cost_per_success_status': status,
               'failures': sum(not row['passed'] for row in rows),
               'timeouts': sum(row.get('failure') in ('timeout', 'run_deadline') for row in rows)}
    for key in ('turns', 'uncached_input_tokens', 'cached_input_tokens', 'cache_write_tokens',
                'output_tokens', 'discovery_failures', 'incorrect_tool_calls', 'tool_errors', 'tool_error_recoveries'):
        values = [number(row.get(key)) for row in rows]
        summary[key] = sum(values) if values and all(value is not None for value in values) else None
    return summary


def clustered_interval(values_by_task, seed):
    """Equal-task mean and percentile bootstrap, resampling whole task clusters."""
    means = [statistics.mean(values) for _, values in sorted(values_by_task.items()) if values]
    if not means:
        return {'estimate': None, 'interval_95': None, 'task_clusters': 0}
    result = {'estimate': statistics.mean(means), 'interval_95': None, 'task_clusters': len(means)}
    if len(means) > 1:
        rng = random.Random(seed)
        samples = sorted(statistics.mean(rng.choices(means, k=len(means))) for _ in range(2000))
        result['interval_95'] = [samples[49], samples[1949]]
    return result


def summarize(rows, seed):
    variants = sorted({row['variant'] for row in rows})
    results = {'variants': {variant: aggregate([row for row in rows if row['variant'] == variant]) for variant in variants},
               'comparisons': {}, 'uncertainty_method': 'equal-task paired differences; percentile bootstrap of whole task clusters (2000 resamples)',
               'interpretation': 'exploratory; small selected task samples do not support global model rankings'}
    pairs = {}
    for row in rows:
        if not row.get('attempted', True):
            continue
        pairs.setdefault(row['pair_id'], {})[row['variant']] = row
    for variant in variants:
        if variant == 'baseline':
            continue
        wall, success = {}, {}
        for pair in pairs.values():
            if 'baseline' not in pair or variant not in pair:
                continue
            baseline, candidate = pair['baseline'], pair[variant]
            task = baseline['task']
            success.setdefault(task, []).append(int(candidate['passed']) - int(baseline['passed']))
            if number(candidate.get('wall_seconds')) is not None and number(baseline.get('wall_seconds')) is not None:
                wall.setdefault(task, []).append(candidate['wall_seconds'] - baseline['wall_seconds'])
        results['comparisons'][variant] = {'verified_success_difference': clustered_interval(success, seed),
                                         'wall_seconds_difference': clustered_interval(wall, seed),
                                         'paired_trials': sum(len(values) for values in success.values()),
                                         'direction': 'candidate minus baseline; failed/timeout attempts included'}
    return results


def write_report(path, report):
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + '.tmp')
    temporary.write_text(json.dumps(report, indent=2, allow_nan=False) + '\n')
    temporary.replace(destination)


def terminate(process):
    if process is None:
        return
    # The entire runtime group (including bash/process children) belongs to this attempt.
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=5)
    except ProcessLookupError:
        pass
    except subprocess.TimeoutExpired:
        pass
    finally:
        # Reaping the leader does not imply its children honored SIGTERM.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


def runtime_ports():
    sockets = []
    try:
        for _ in range(3):
            sock = socket.socket()
            sock.bind(('127.0.0.1', 0))
            sockets.append(sock)
        return [sock.getsockname()[1] for sock in sockets]
    finally:
        for sock in sockets:
            sock.close()


def collect_profile(path, run_id=None, turns=None):
    """Only allowlisted numeric diagnostics and catalog hashes leave private state."""
    rows = []
    if Path(path).exists():
        for line in Path(path).read_text().splitlines():
            try:
                value = json.loads(line)
                if isinstance(value, dict):
                    rows.append(value)
            except ValueError:
                continue
    payloads = [row for row in rows if row.get('event') == 'payload']
    usages = [row.get('provider_usage') or {} for row in rows if row.get('event') == 'usage']
    hashes = sorted({row['tools_catalog_digest'] for row in payloads
                     if re.fullmatch(r'[0-9a-f]{64}', str(row.get('tools_catalog_digest', '')))})
    schema_values = [number(row.get('estimates', {}).get('tool_schemas')) for row in payloads]
    invokes = [row for row in rows if row.get('event') == 'disclosure_invoke']
    attributed = {}
    for row in invokes:
        target = row.get('resolved_tool_digest')
        if isinstance(target, str) and re.fullmatch(r'[0-9a-f]{64}', target) and row.get('status') in ('ok', 'error'):
            item = attributed.setdefault(target, {'calls': 0, 'errors': 0})
            item['calls'] += 1
            item['errors'] += row['status'] == 'error'
    applied = [row for row in rows if row.get('event') == 'disclosure_applied']
    full_catalogs = sorted({row['catalog_digest'] for row in applied
                           if isinstance(row.get('catalog_digest'), str) and re.fullmatch(r'[0-9a-f]{64}', row['catalog_digest'])})
    measurements = [{'profile': row['profile'], 'active': row.get('active') if type(row.get('active')) is bool else None,
                     **{key: number(row.get(key)) for key in ('estimated_tokens', 'disclosed_tokens', 'hidden_count', 'disclosed_count')}}
                    for row in applied if row.get('profile') in ('coding', 'legacy')]
    diagnostics_available = any(row.get('diagnostic_events_version') == 1 for row in applied)
    searches = [row for row in rows if row.get('event') == 'disclosure_search'
                and row.get('status') in ('ok', 'error') and number(row.get('matched_count')) is not None]
    rejections = [row for row in rows if row.get('event') == 'disclosure_rejected'
                  and row.get('reason') in ('unknown_tool', 'invalid_arguments', 'invalid_request')]
    # The CLI cost covers parent assistant messages, not nested sessions or unmatched
    # retries. Require one-to-one terminal observations for those completed turns.
    def request_keys(records):
        keys = []
        for row in records:
            if (not isinstance(row.get('run_id'), str) or row['run_id'] != run_id
                    or not isinstance(row.get('session_id'), str) or not row['session_id']
                    or type(row.get('request_index')) is not int or row['request_index'] < 1):
                return None
            keys.append((row['run_id'], row['session_id'], row['request_index']))
        return keys

    usage_rows = [row for row in rows if row.get('event') == 'usage']
    payload_keys, usage_keys = request_keys(payloads), request_keys(usage_rows)
    parent_usage_complete = (
        type(turns) is int and turns > 0 and len(payloads) == turns
        and payload_keys is not None and usage_keys is not None
        and len(set(payload_keys)) == len(payload_keys)
        and len(set(usage_keys)) == len(usage_keys)
        and set(payload_keys) == set(usage_keys)
        and len({key[1] for key in payload_keys}) == 1
        and all(all(number(usage.get(key)) is not None
                    for key in ('input_tokens', 'output_tokens', 'cache_read_tokens'))
                for usage in usages))
    return {'catalog_digests': hashes, 'requests_observed': len(payloads),
            'schema_tokens_estimate_sum': sum(schema_values) if schema_values and all(value is not None for value in schema_values) else None,
            'completed_usage_requests': len(usages), 'schema_estimate_basis': 'o200k_base visible wire JSON; not billed input',
            'parent_usage_complete': parent_usage_complete,
            'cache_regime': 'fresh_local_runtime; provider cache not controlled',
            'provider_cache_observable': any(number(row.get('cache_read_tokens')) is not None for row in usages),
            'applied_profiles': sorted({row['profile'] for row in applied if row.get('profile') in ('coding', 'legacy')}),
            'full_catalog_digests': full_catalogs, 'disclosure_measurements': measurements,
            'discovery_failures': sum(row['status'] == 'error' or row['matched_count'] == 0 for row in searches) if diagnostics_available else None,
            'incorrect_tool_calls': len(rejections) + sum(row['status'] == 'error' for row in searches) if diagnostics_available else None,
            'resolved_bridge_invocations': attributed,
            'bridge_attribution_basis': 'validated runtime catalog lookup/execution; target identities SHA256-redacted; unknown/schema-invalid calls excluded'}


def failed_row(entry, failure):
    return {**entry, 'agent': 'lemon', 'passed': False, 'failure': failure,
            'verifier_passed': None, 'tests_passed': None, 'wall_seconds': None,
            **{key: None for key in ('turns', 'tokens', 'uncached_input_tokens', 'cached_input_tokens',
                                    'cache_write_tokens', 'output_tokens', 'tool_errors', 'cost_usd',
                                    'discovery_failures', 'incorrect_tool_calls', 'tool_error_recoveries')}}


def sanitize_row(row):
    """Allowlist benchmark-owned identifiers, flags and numeric measurements."""
    clean = {}
    for key in ('task', 'variant', 'pair_id', 'trial_id'):
        value = row.get(key)
        if isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9_:-]{1,180}', value):
            clean[key] = value
    clean['agent'] = 'lemon'
    for key in ('passed', 'attempted', 'verifier_passed', 'tests_passed', 'spend_complete'):
        clean[key] = row.get(key) if type(row.get(key)) is bool else None
    failures = {'timeout', 'run_deadline', 'spend_limit', 'missing_spend', 'runtime_failed',
                'invalid_cli_json', 'agent_failed', 'verifier_failed', 'unexpected_mutation',
                'tests_failed', 'invocation_failed', 'recovery_not_observed', 'disclosure_not_observed'}
    clean['failure'] = row.get('failure') if row.get('failure') in failures else None
    for key in ('repetition', 'order', 'turns', 'tokens', 'uncached_input_tokens', 'cached_input_tokens',
                'cache_write_tokens', 'output_tokens', 'tool_errors', 'cost_usd', 'wall_seconds',
                'discovery_failures', 'incorrect_tool_calls', 'tool_error_recoveries'):
        clean[key] = number(row.get(key))
    for key in ('configuration_digest', 'fixture_digest'):
        value = row.get(key)
        clean[key] = value if isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value) else None
    versions = row.get('runtime_versions') or {}
    clean['runtime_versions'] = {}
    for key in ('elixir', 'otp', 'pricing_catalog_digest'):
        value = versions.get(key)
        if isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9_.+-]{1,80}', value):
            clean['runtime_versions'][key] = value
    diagnostics = row.get('schema_diagnostics')
    if isinstance(diagnostics, dict):
        safe = {}
        for key in ('requests_observed', 'schema_tokens_estimate_sum', 'completed_usage_requests'):
            if key in diagnostics:
                safe[key] = number(diagnostics[key])
        for key in ('flush_complete', 'provider_cache_observable', 'parent_usage_complete'):
            if key in diagnostics:
                safe[key] = diagnostics[key] if type(diagnostics[key]) is bool else None
        safe['catalog_digests'] = sorted({value for value in diagnostics.get('catalog_digests', [])
                                         if isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value)})
        safe['applied_profiles'] = sorted({value for value in diagnostics.get('applied_profiles', [])
                                          if value in ('coding', 'legacy')})
        safe['full_catalog_digests'] = sorted({value for value in diagnostics.get('full_catalog_digests', [])
                                              if isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value)})
        safe['disclosure_measurements'] = [
            {'profile': item['profile'], 'active': item.get('active') if type(item.get('active')) is bool else None,
             **{key: number(item.get(key)) for key in ('estimated_tokens', 'disclosed_tokens', 'hidden_count', 'disclosed_count')}}
            for item in diagnostics.get('disclosure_measurements', []) if isinstance(item, dict) and item.get('profile') in ('coding', 'legacy')]
        safe['resolved_bridge_invocations'] = {}
        for target, values in diagnostics.get('resolved_bridge_invocations', {}).items():
            if isinstance(target, str) and re.fullmatch(r'[0-9a-f]{64}', target) and isinstance(values, dict):
                safe['resolved_bridge_invocations'][target] = {key: number(values.get(key)) for key in ('calls', 'errors')}
        safe['schema_estimate_basis'] = 'o200k_base visible wire JSON; not billed input'
        safe['cache_regime'] = 'fresh_local_runtime; provider cache not controlled'
        safe['bridge_attribution_basis'] = 'validated runtime catalog lookup/execution; target identities SHA256-redacted; unknown/schema-invalid calls excluded'
        clean['schema_diagnostics'] = safe
    return clean


def run_paired(args, cases, run_case):
    root = Path(__file__).resolve().parents[3]
    if Path(args.lemon).resolve() != root / 'bin' / 'lemon':
        raise ValueError('paired runs require this revision\'s source launcher')
    if args.compare_omp:
        raise ValueError('--paired cannot be combined with --compare-omp')
    if not args.config or args.timeout <= 0 or args.run_timeout <= 0:
        raise ValueError('--config and positive attempt/run deadlines required')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+', args.model):
        raise ValueError('explicit provider:model identifier required')
    base = Path(args.config).read_text()
    variants = ['baseline', 'coding']
    configurations = {variant: paired_configuration(base, variant) for variant in variants}
    revision = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=root, capture_output=True, text=True, check=True).stdout.strip()
    # Bind dirty/untracked source contents too; never falsely label a dirty run as an exact commit.
    files = subprocess.run(['git', 'ls-files', '--cached', '--others', '--exclude-standard'], cwd=root,
                           capture_output=True, text=True, check=True).stdout.splitlines()
    source_digest = digest({name: hashlib.sha256((root / name).read_bytes()).hexdigest()
                            for name in sorted(set(files)) if (root / name).is_file()})
    build_files = sorted((root / '_build' / 'dev' / 'lib').glob('*/ebin/*.beam'))
    build_digest = digest({str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in build_files})
    experiment = {'tasks': [case['name'] for case in cases], 'model': args.model, 'revision': revision,
                  'source_digest': source_digest, 'repetitions': args.repetitions, 'seed': args.seed,
                  'compiled_build_digest': build_digest,
                  'timeout': args.timeout, 'run_timeout': args.run_timeout, 'variants': variants,
                  'config_digest': digest(configurations),
                  'fixture_digests': {case['name']: digest(case) for case in cases},
                  'profile_python_digest': hashlib.sha256(Path(args.profile_python).resolve().read_bytes()).hexdigest()}
    entries = schedule(cases, variants, args.repetitions, args.seed)
    if not args.live:
        template = {'approved': False, 'experiment': experiment, 'max_attempts': len(entries),
                    'max_spend_usd': None, 'per_attempt_spend_ceiling_usd': None,
                    'provider_budget_enforced': False, 'credential_env': []}
        write_report(args.output, {'schema_version': 3, 'suite': 'paired_disclosure_plan',
                                  'plan': template, 'plan_digest': digest(template), 'scheduled_trials': entries,
                                  'live_calls': 0, 'decision': 'keep-current-defaults; keep-opt-in; authorized evidence pending'})
        return 0
    if not build_files:
        raise ValueError('compile the exact source revision before preparing an authorized live plan')
    if not args.plan:
        raise ValueError('--live requires --plan and --approve-plan-digest')
    plan = validate_plan(json.loads(Path(args.plan).read_text()), experiment, args.approve_plan_digest)
    credentials = {key: os.environ[key] for key in plan['credential_env'] if os.environ.get(key)}
    if len(credentials) != len(plan['credential_env']):
        raise ValueError('approved credential variables must be present')
    report = {'schema_version': 3, 'suite': 'live_agentic_coding_paired', 'experiment': experiment,
              'plan_digest': digest(plan), 'complete': False, 'results': [],
              'experiment_id': digest(experiment),
              'runtime': {'client': 'lemon -p --output json', 'boot': 'LemonCore.Runtime.Boot.start!(:runtime_full)',
                          'python': sys.version.split()[0], 'permissions': 'approval-policy allow',
                          'reasoning': 'identical base configuration; provider default if unspecified'},
              'cost_basis': 'runtime reported costUsd; model catalog estimates, not an invoice; missing attempts stay null',
              'uncontrolled': ['provider cache/queue/load', 'provider pricing/route drift', 'OS scheduling'],
              'decision': 'keep-current-defaults; keep-opt-in; rollout pending review of authorized evidence'}
    write_report(args.output, report)
    start = time.monotonic()
    stop_reason = None
    cases_by_name = {case['name']: case for case in cases}
    measured = 0.0
    for entry in entries:
        remaining = args.run_timeout - (time.monotonic() - start)
        if stop_reason or remaining <= 0 or measured + plan['per_attempt_spend_ceiling_usd'] > plan['max_spend_usd']:
            stop_reason = stop_reason or ('run_deadline' if remaining <= 0 else 'spend_limit')
            row = {**failed_row(entry, stop_reason), 'attempted': False, 'cost_usd': 0}
        else:
            runtime = None
            attempt_start = time.monotonic()
            with tempfile.TemporaryDirectory(prefix='lemon-paired-runtime-') as temporary:
                state = Path(temporary)
                env = isolated_environment(state, configurations[entry['variant']], entry['variant'], credentials, runtime_ports())
                profile = state / 'profile.jsonl'
                metadata = state / 'runtime.json'
                env.update({'LEMON_EVAL_PROFILE': str(profile), 'LEMON_EVAL_PYTHON': args.profile_python,
                            'LEMON_EVAL_METADATA': str(metadata), 'LEMON_EVAL_STATE': str(state)})
                # Load project code first, then change config cwd before boot. This is the
                # same runtime boot and production CLI, with a dev-only profiling adapter.
                expression = ('File.cd!(System.fetch_env!("LEMON_AGENT_PROFILES_CWD")); '
                              'LemonCore.Runtime.Boot.start!(:runtime_full); '
                              'unless Process.whereis(LemonControlPlane.Supervisor), '
                              'do: raise("paired runtime did not acquire its own listener"); '
                              'expected = System.fetch_env!("LEMON_TOOL_DISCLOSURE_PROFILE"); '
                              'unless LemonCore.Config.load().tools.disclosure[:profile] == expected, '
                              'do: raise("paired disclosure profile unavailable"); '
                              'LemonEvals.PayloadProfile.install!(System.fetch_env!("LEMON_EVAL_PROFILE"), '
                              'python: System.fetch_env!("LEMON_EVAL_PYTHON"), paired: true); '
                              'File.write!(System.fetch_env!("LEMON_EVAL_METADATA"), '
                              'Jason.encode!(%{elixir: System.version(), otp: to_string(:erlang.system_info(:otp_release)), '
                              'pricing_catalog_digest: Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(LemonAi.Models.list_models())), case: :lower)})); '
                              'Task.start(fn -> wait = fn wait -> '
                              'if File.exists?(Path.join(System.fetch_env!("LEMON_EVAL_STATE"), "flush.request")), '
                              'do: (LemonEvals.PayloadProfile.flush!(); File.write!(Path.join(System.fetch_env!("LEMON_EVAL_STATE"), "flush.done"), "ok")), '
                              'else: (Process.sleep(50); wait.(wait)) end; wait.(wait) end)')
                try:
                    runtime = subprocess.Popen(['mix', 'run', '--no-start', '--no-halt', '--no-compile', '--no-deps-check', '-e', expression],
                                               cwd=root, env=env, stdin=subprocess.DEVNULL,
                                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
                    deadline = min(start + args.run_timeout, attempt_start + args.timeout)
                    while not metadata.exists():
                        if runtime.poll() is not None:
                            raise OSError('isolated runtime failed')
                        if time.monotonic() >= deadline:
                            raise subprocess.TimeoutExpired('runtime', args.timeout)
                        time.sleep(0.1)
                    # Avoid client auto-start: only proceed after OUR runtime is ready.
                    with urllib.request.urlopen(f'http://127.0.0.1:{env["LEMON_CONTROL_PLANE_PORT"]}/healthz', timeout=min(5, max(0.01, deadline-time.monotonic()))) as response:
                        if json.load(response).get('ok') is not True:
                            raise OSError('runtime unhealthy')
                    import argparse
                    attempt_args = argparse.Namespace(**vars(args))
                    attempt_args.timeout = max(0.01, deadline - time.monotonic())
                    attempt_args.environment = env
                    attempt_args.attempt_deadline = deadline
                    attempt_args.trial_id = entry['trial_id']
                    row = {**run_case(cases_by_name[entry['task']], 'lemon', args.lemon, args.model, attempt_args), **entry}
                    row['runtime_versions'] = json.loads(metadata.read_text())
                    (state / 'flush.request').write_text('flush')
                    while not (state / 'flush.done').exists() and time.monotonic() < deadline and runtime.poll() is None:
                        time.sleep(0.05)
                except subprocess.TimeoutExpired:
                    row = failed_row(entry, 'timeout')
                except (OSError, ValueError, subprocess.SubprocessError):
                    row = failed_row(entry, 'runtime_failed')
                finally:
                    terminate(runtime)
                row['schema_diagnostics'] = collect_profile(profile, row.get('run_id'), row.get('turns'))
                row['schema_diagnostics']['flush_complete'] = (state / 'flush.done').exists()
                expected_profile = 'legacy' if entry['variant'] == 'baseline' else 'coding'
                if row['passed'] and row['schema_diagnostics']['applied_profiles'] != [expected_profile]:
                    row['passed'], row['failure'] = False, 'disclosure_not_observed'
                # This is an outcome-level recovery indicator, not a guess at tool calls.
                if number(row.get('tool_errors')) is not None:
                    row['tool_error_recoveries'] = int(row['tool_errors'] > 0 and row['passed'])
                row['discovery_failures'] = row['schema_diagnostics']['discovery_failures']
                row['incorrect_tool_calls'] = row['schema_diagnostics']['incorrect_tool_calls']
                row['spend_complete'] = (
                    number(row.get('cost_usd')) is not None
                    and row['schema_diagnostics']['flush_complete']
                    and row['schema_diagnostics']['parent_usage_complete'])
                row['attempted'] = True
                row['wall_seconds'] = round(time.monotonic() - attempt_start, 4)
                row['configuration_digest'] = digest(configurations[entry['variant']])
                row['fixture_digest'] = experiment['fixture_digests'][entry['task']]
        # Runtime IDs, prompts and arbitrary metadata never leave private state.
        row = sanitize_row(row)
        report['results'].append(row)
        cost = number(row.get('cost_usd'))
        if cost is not None:
            measured += cost
        if row['attempted'] and (cost is None or row.get('spend_complete') is False):
            stop_reason = 'missing_spend'
        elif cost is not None and cost > plan['per_attempt_spend_ceiling_usd']:
            stop_reason = 'spend_limit'
        report['summary'] = summarize(report['results'], args.seed)
        report['stop_reason'] = stop_reason
        write_report(args.output, report)
    report['complete'] = True
    report['elapsed_seconds'] = round(time.monotonic() - start, 4)
    report['all_attempt_measured_spend_usd'] = measured
    report['all_attempt_spend_complete'] = all(summary['spend_complete'] for summary in report['summary']['variants'].values())
    write_report(args.output, report)
    lines = ['# Paired disclosure experiment', '', 'Exploratory; no default promotion or model ranking.', '',
             '| Variant | Successes / attempts | Skipped | Measured spend USD | Cost / success USD | Cost status |',
             '| --- | ---: | ---: | ---: | ---: | --- |']
    for variant, summary in report['summary']['variants'].items():
        cost = summary['cost_per_verified_success_usd']
        lines.append(f'| {variant} | {summary["successes"]} / {summary["attempts"]} | {summary["skipped"]} | {summary["measured_spend_usd"]} | {cost if cost is not None else "n/a"} | {summary["cost_per_success_status"]} |')
    lines += ['', 'Schema diagnostics are estimates, separate from externally verified outcomes.',
              'Paired differences and task-cluster uncertainty are in the JSON. Missing spend remains incomplete.',
              report['decision'], '']
    Path(args.output).with_suffix('.md').write_text('\n'.join(lines))
    return 0 if all(row['passed'] for row in report['results']) else 1
