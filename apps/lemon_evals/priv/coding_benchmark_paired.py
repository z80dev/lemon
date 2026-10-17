"""Repeated disclosure experiments using the existing production coding runner.

No provider request is made until an exact bounded operator plan is approved.
"""
from contextlib import contextmanager
import hashlib
import json
import math
import os
from pathlib import Path
import random
import re
import secrets
import signal
import shutil
import socket
import statistics
import subprocess
import stat
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
    # Fix SDK paths against the original HOME/cwd, before isolating either.
    original_home = Path.home()
    toolchain = {key: str(Path(os.environ.get(key, original_home / directory)).expanduser().resolve())
                 for key, directory in (('MIX_HOME', '.mix'), ('HEX_HOME', '.hex'))}
    root = Path(root)
    home, cwd = root / 'home', root / 'config'
    home.mkdir(parents=True, mode=0o700)
    (home / '.lemon').mkdir(mode=0o700)
    cwd.mkdir(mode=0o700)
    (root / 'tmp').mkdir(mode=0o700)
    path = home / '.lemon' / 'config.toml'
    path.write_text(config)
    path.chmod(0o600)
    # Never inherit ordinary Lemon settings, proxy endpoints, dotenv, or provider state.
    env = {key: os.environ[key] for key in ('PATH', 'LANG', 'LC_ALL') if key in os.environ}
    env.update(credentials)
    env.update(toolchain)
    env.update({'HOME': str(home), 'LEMON_AGENT_PROFILES_CWD': str(cwd),
                'LEMON_DOTENV_DIR': str(cwd), 'LEMON_STORE_PATH': str(root / 'store'),
                'LEMON_EVAL_PROCESS_STORE': str(root / 'processes.dets'),
                'TMPDIR': str(root / 'tmp'),
                'LEMON_CONTROL_PLANE_PORT': str(ports[0]), 'LEMON_WEB_PORT': str(ports[1]),
                'LEMON_GATEWAY_HEALTH_PORT': '0', 'LEMON_ROUTER_HEALTH_PORT': '0',
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


def terminate_runtime_group(process):
    """Bound shutdown of the runner session, not independently grouped workloads."""
    if process is None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=5)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        pass
    finally:
        # Reaping the leader does not imply its same-group children honored TERM.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)


def require_trial_root(state, descriptor):
    original = os.fstat(descriptor)
    current = os.stat(state, follow_symlinks=False)
    if ((current.st_dev, current.st_ino) != (original.st_dev, original.st_ino)
            or current.st_uid != os.getuid() or not stat.S_ISDIR(current.st_mode)):
        raise PermissionError('trial root identity changed')


def trial_file(state, descriptor, name, mode='r'):
    """Open only owned, single-link regular files in the pinned trial root."""
    require_trial_root(state, descriptor)
    flags = os.O_RDONLY if mode == 'r' else os.O_WRONLY | os.O_CREAT | os.O_EXCL
    fd = os.open(name, flags | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=descriptor)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
            raise PermissionError('unsafe trial file')
        return os.fdopen(fd, mode)
    except BaseException:
        os.close(fd)
        raise


def trial_file_exists(state, descriptor, name):
    try:
        with trial_file(state, descriptor, name):
            return True
    except FileNotFoundError:
        return False


def recovery_command(project_root, environment, root_fd):
    """Load precompiled BEAMs with ledger resolution pinned by the kernel cwd.

    Darwin cannot traverse /dev/fd/N/ledger. A tiny exec-only child instead
    fchdirs through the inherited root FD before BEAM starts. Relative DETS
    filenames (including repair temporaries) then stay in that original inode,
    even if a surviving workload renames or replaces the trial pathname.
    """
    ebins = sorted((Path(project_root).resolve() / '_build' /
                    environment.get('MIX_ENV', 'dev') / 'lib').glob('*/ebin'))
    expression = ('result = LemonEvals.PairedCleanup.recover(System.fetch_env!("LEMON_EVAL_PROCESS_STORE")); '
                  'System.halt(if result == :ok, do: 0, else: 1)')
    bootstrap = ('import os, sys; os.fchdir(int(sys.argv[1])); os.close(int(sys.argv[1])); '
                 'os.execvpe(sys.argv[2], sys.argv[2:], os.environ)')
    return [sys.executable, '-c', bootstrap, str(root_fd), 'elixir',
            *[item for path in ebins for item in ('-pa', str(path))], '-e', expression]


def terminate(process, *, project_root, environment, root_fd=None):
    """Verify both private ledgers after graceful OR forced runtime exit."""
    if process is None:
        return True  # Popen never acquired a runtime; no work could be admitted.
    recovery = None
    owned_descriptor = None
    try:
        terminate_runtime_group(process)
        ledger = Path(environment['LEMON_EVAL_PROCESS_STORE'])
        if root_fd is None:
            owned_descriptor = os.open(ledger.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            root_fd = owned_descriptor
        require_trial_root(ledger.parent, root_fd)
        # Precompiled code loading only: no Mix project, Boot or provider config.
        env = {key: environment[key] for key in
               ('PATH', 'LANG', 'LC_ALL', 'TMPDIR', 'HOME', 'MIX_ENV', 'MIX_HOME', 'HEX_HOME', 'ERL_FLAGS')
               if key in environment}
        env['LEMON_EVAL_PROCESS_STORE'] = ledger.name
        log_fd = os.open('cleanup.log',
                         os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK,
                         0o600, dir_fd=root_fd)
        with os.fdopen(log_fd, 'wb') as log:
            info = os.fstat(log.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
                return False
            os.fchmod(log.fileno(), 0o600)
            recovery = subprocess.Popen(
                recovery_command(project_root, env, root_fd),
                cwd=project_root, env=env, stdin=subprocess.DEVNULL, pass_fds=(root_fd,),
                stdout=log, stderr=log, start_new_session=True)
            return recovery.wait(timeout=20) == 0
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        return False
    finally:
        if owned_descriptor is not None:
            os.close(owned_descriptor)
        if recovery is not None and recovery.poll() is None:
            try:
                os.killpg(recovery.pid, signal.SIGKILL)
                recovery.wait(timeout=5)
            except (OSError, subprocess.SubprocessError):
                pass


def repair_trial_directory(directory, *, parent_fd=None):
    """Repair owned directories through pinned FDs, never fixture symlinks."""
    identity = os.stat(directory, dir_fd=parent_fd, follow_symlinks=False)
    if not stat.S_ISDIR(identity.st_mode) or identity.st_uid != os.getuid():
        raise PermissionError('trial directory ownership changed')
    path_only = getattr(os, 'O_PATH', 0)
    flags = os.O_DIRECTORY | os.O_NOFOLLOW | (path_only or os.O_RDONLY)
    try:
        descriptor = os.open(directory, flags, dir_fd=parent_fd)
    except PermissionError:
        # Darwin search-only descriptors pin executable but unreadable dirs.
        # No searchable descriptor means fail closed, never pathname chmod.
        if sys.platform != 'darwin':
            raise
        descriptor = os.open(directory, os.O_DIRECTORY | os.O_NOFOLLOW |
                             getattr(os, 'O_SEARCH', 0x40100000), dir_fd=parent_fd)
    try:
        pinned = os.fstat(descriptor)
        if ((pinned.st_dev, pinned.st_ino) != (identity.st_dev, identity.st_ino)
                or pinned.st_uid != os.getuid() or not stat.S_ISDIR(pinned.st_mode)):
            raise PermissionError('trial directory identity changed')
        if path_only:
            # proc names the checked inode, not an agent-controlled path.
            pinned_path = f'/proc/self/fd/{descriptor}'
            os.chmod(pinned_path, 0o700)
            readable = os.open(pinned_path, os.O_RDONLY | os.O_DIRECTORY)
            os.close(descriptor)
            descriptor = readable
        else:
            os.fchmod(descriptor, 0o700)
            # Search-only descriptors cannot enumerate directories. Reopen only
            # after permission repair, then validate before using the new FD.
            readable = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                               dir_fd=parent_fd)
            reopened = os.fstat(readable)
            if (reopened.st_dev, reopened.st_ino) != (pinned.st_dev, pinned.st_ino):
                os.close(readable)
                raise PermissionError('trial directory identity changed')
            os.close(descriptor)
            descriptor = readable
        with os.scandir(descriptor) as children:
            for child in children:
                if child.is_dir(follow_symlinks=False):
                    repair_trial_directory(child.name, parent_fd=descriptor)
    finally:
        os.close(descriptor)


def dispose_trial_state(state, *, root_fd=None):
    """Dispose through the original root FD; never traverse a replaced pathname."""
    if not os.access(state.parent, os.W_OK | os.X_OK):
        raise PermissionError('trial parent does not permit disposal')
    if not shutil.rmtree.avoids_symlink_attacks:
        raise PermissionError('descriptor-safe disposal unavailable')
    parent = os.open(state.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    descriptor = None
    try:
        descriptor = (os.dup(root_fd) if root_fd is not None else
                      os.open(state.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent))
        original = os.fstat(descriptor)

        def require_original_root():
            current = os.stat(state.name, dir_fd=parent, follow_symlinks=False)
            if ((current.st_dev, current.st_ino) != (original.st_dev, original.st_ino)
                    or current.st_uid != os.getuid() or not stat.S_ISDIR(current.st_mode)):
                raise PermissionError('trial root identity changed')

        require_original_root()
        repair_trial_directory('.', parent_fd=descriptor)
        require_original_root()
        # Anchor every recursive removal to the pinned root, never its pathname.
        with os.scandir(descriptor) as children:
            for child in children:
                require_original_root()
                if child.is_dir(follow_symlinks=False):
                    shutil.rmtree(child.name, dir_fd=descriptor)
                else:
                    os.unlink(child.name, dir_fd=descriptor)
        require_original_root()
        os.rmdir(state.name, dir_fd=parent)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        os.close(parent)


@contextmanager
def trial_state():
    """Retain private evidence until teardown AND finalization are verified."""
    state = Path(tempfile.mkdtemp(prefix='lemon-paired-runtime-'))
    descriptor = os.open(state, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    cleanup = {'complete': False, 'disposal_complete': False, 'disposal_failed': False,
               'finalization_failed': False, 'interrupted': False, 'root_fd': descriptor}
    try:
        yield state, cleanup
    except BaseException as error:
        cleanup['finalization_failed'] = True
        cleanup['interrupted'] = not isinstance(error, Exception)
    finally:
        try:
            original = os.fstat(descriptor)
            if original.st_uid != os.getuid() or not stat.S_ISDIR(original.st_mode):
                raise PermissionError('trial root ownership changed')
            os.fchmod(descriptor, 0o700)
            if cleanup['complete'] and not cleanup['finalization_failed']:
                current = state.lstat()
                if ((current.st_dev, current.st_ino) != (original.st_dev, original.st_ino)
                        or not stat.S_ISDIR(current.st_mode)):
                    raise PermissionError('trial root identity changed')
                dispose_trial_state(state, root_fd=descriptor)
                cleanup['disposal_complete'] = True
        except BaseException as error:
            # Even disposal interrupts must return through the paid row's owner.
            cleanup['disposal_failed'] = True
            cleanup['interrupted'] = cleanup['interrupted'] or not isinstance(error, Exception)
        finally:
            try:
                os.close(descriptor)
            except BaseException as error:
                cleanup['disposal_complete'] = False
                cleanup['disposal_failed'] = True
                cleanup['interrupted'] = cleanup['interrupted'] or not isinstance(error, Exception)


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


def collect_profile(path, run_id=None, turns=None, *, root_fd=None):
    """Only allowlisted numeric diagnostics and catalog hashes leave private state."""
    rows = []
    try:
        source = (trial_file(Path(path).parent, root_fd, Path(path).name) if root_fd is not None
                  else open(path))
    except FileNotFoundError:
        source = None
    if source is not None:
        with source:
            lines = source.read().splitlines()
        for line in lines:
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
    for key in ('passed', 'attempted', 'verifier_passed', 'tests_passed', 'spend_complete',
                'cleanup_complete', 'disposal_complete', 'finalization_failed'):
        clean[key] = row.get(key) if type(row.get(key)) is bool else None
    failures = {'timeout', 'run_deadline', 'spend_limit', 'missing_spend', 'runtime_failed',
                'invalid_cli_json', 'agent_failed', 'verifier_failed', 'unexpected_mutation',
                'tests_failed', 'invocation_failed', 'recovery_not_observed', 'disclosure_not_observed',
                'cleanup_unverified', 'disposal_unverified', 'finalization_failed',
                'provider_quota', 'provider_auth', 'provider_failed'}
    clean['failure'] = row.get('failure') if row.get('failure') in failures else None
    for key in ('repetition', 'order', 'turns', 'tokens', 'uncached_input_tokens', 'cached_input_tokens',
                'cache_write_tokens', 'output_tokens', 'tool_errors', 'cost_usd', 'wall_seconds',
                'discovery_failures', 'incorrect_tool_calls', 'tool_error_recoveries'):
        clean[key] = number(row.get(key))
    if 'provider_status' in row:
        status = row.get('provider_status')
        clean['provider_status'] = status if type(status) is int and 100 <= status <= 599 else None
    if 'provider_failure' in row:
        clean['provider_failure'] = (row.get('provider_failure')
                                     if row.get('provider_failure') in ('quota', 'auth', 'provider_failed') else None)
    # Campaign-only fields; absent from the single-provider paired lane's rows.
    if isinstance(row.get('provider'), str) and re.fullmatch(r'[a-z0-9-]{1,40}', row['provider']):
        clean['provider'] = row['provider']
    if 'equivalent_spend_usd' in row:
        clean['equivalent_spend_usd'] = number(row['equivalent_spend_usd'])
        clean['equivalent_spend_status'] = (row.get('equivalent_spend_status')
                                            if row.get('equivalent_spend_status') in ('priced', 'missing_counters') else None)
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


def source_identity(root):
    """Exact revision plus content digests of the working tree and compiled development build."""
    revision = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=root, capture_output=True, text=True, check=True).stdout.strip()
    # Bind dirty/untracked source contents too; never falsely label a dirty run as an exact commit.
    files = subprocess.run(['git', 'ls-files', '--cached', '--others', '--exclude-standard'], cwd=root,
                           capture_output=True, text=True, check=True).stdout.splitlines()
    source_digest = digest({name: hashlib.sha256((root / name).read_bytes()).hexdigest()
                            for name in sorted(set(files)) if (root / name).is_file()})
    build_files = sorted((root / '_build' / 'dev' / 'lib').glob('*/ebin/*.beam'))
    build_digest = digest({str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in build_files})
    dirty = bool(subprocess.run(['git', 'status', '--porcelain'], cwd=root, capture_output=True, text=True, check=True).stdout.strip())
    return {'revision': revision, 'source_digest': source_digest, 'dirty': dirty,
            'build_files': build_files, 'compiled_build_digest': build_digest}


RUNTIME_EXPRESSION = (
    'File.cd!(System.fetch_env!("LEMON_AGENT_PROFILES_CWD")); '
    'LemonEvals.PairedCleanup.configure!(); '
    'Application.put_env(:lemon_control_plane, :ip, {127, 0, 0, 1}); '
    'for {app, variable} <- [{:lemon_gateway, "LEMON_GATEWAY_HEALTH_PORT"}, '
    '{:lemon_router, "LEMON_ROUTER_HEALTH_PORT"}] do '
    'Application.put_env(app, :health_ip, :loopback); '
    'Application.put_env(app, :health_port, String.to_integer(System.fetch_env!(variable))) end; '
    'LemonCore.Runtime.Boot.start!(:runtime_full); '
    'LemonEvals.PairedCleanup.verify!(); '
    'unless Process.whereis(LemonControlPlane.Supervisor), '
    'do: raise("paired runtime did not acquire its own listener"); '
    'expected = System.fetch_env!("LEMON_TOOL_DISCLOSURE_PROFILE"); '
    'unless LemonCore.Config.load().agent.tools.disclosure[:profile] == expected, '
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


def runtime_command(root):
    """Argv of the production runtime boot; `root` is the umbrella source checkout."""
    return ['mix', 'run', '--no-start', '--no-halt', '--no-compile', '--no-deps-check', '-e', RUNTIME_EXPRESSION]


class TrialInterrupted(KeyboardInterrupt):
    """An interrupted attempt whose teardown evidence must be persisted."""

    def __init__(self, row):
        super().__init__()
        self.row = row


def execute_trial(root, entry, case, configuration, model, credentials, ports, args, run_case,
                  fixture_digest, run_deadline=None, runtime_argv=None):
    """Run one attempt in a fresh runtime, home, store and fixture; teardown always runs.

    `runtime_argv` is a test seam for the offline fixture runtime; production uses `runtime_command`.
    """
    runtime = None
    attempt_start = time.monotonic()
    row = {**failed_row(entry, None), 'attempted': True, 'spend_complete': False}
    outcome_observed = False
    interrupted = False
    with trial_state() as (state, cleanup):
        env = {}
        profile, metadata = state / 'profile.jsonl', state / 'runtime.json'
        try:
            env = isolated_environment(state, configuration, entry['variant'], credentials, ports)
            env.update({'LEMON_EVAL_PROFILE': str(profile), 'LEMON_EVAL_PYTHON': args.profile_python,
                        'LEMON_EVAL_METADATA': str(metadata), 'LEMON_EVAL_STATE': str(state)})
            runtime = subprocess.Popen(runtime_argv or runtime_command(root),
                                       cwd=root, env=env, stdin=subprocess.DEVNULL,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            deadline = attempt_start + args.timeout
            if run_deadline is not None:
                deadline = min(run_deadline, deadline)
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
            attempt_args.fixture_root = state / 'fixture'
            row = {**run_case(case, 'lemon', args.lemon, model, attempt_args), **entry}
            outcome_observed = True
            row['attempted'], row['spend_complete'] = True, False
            with trial_file(state, cleanup['root_fd'], 'runtime.json') as source:
                row['runtime_versions'] = json.load(source)
            with trial_file(state, cleanup['root_fd'], 'flush.request', 'w') as request:
                request.write('flush')
            while not trial_file_exists(state, cleanup['root_fd'], 'flush.done') and time.monotonic() < deadline and runtime.poll() is None:
                time.sleep(0.05)
        except subprocess.TimeoutExpired:
            row['passed'] = False
            row['failure'] = row.get('failure') or 'timeout'
            cleanup['finalization_failed'] = outcome_observed
        except (OSError, ValueError, subprocess.SubprocessError):
            row['passed'] = False
            row['failure'] = row.get('failure') or 'runtime_failed'
            cleanup['finalization_failed'] = outcome_observed
        except TrialInterrupted as error:
            row = {**error.row, **entry, 'attempted': True, 'spend_complete': False}
            interrupted = True
            cleanup['finalization_failed'] = True
        except BaseException as error:
            interrupted = not isinstance(error, Exception)
            cleanup['finalization_failed'] = True
            row['passed'] = False
            row['failure'] = row.get('failure') or 'finalization_failed'
        finally:
            try:
                cleanup['complete'] = terminate(runtime, project_root=root, environment=env,
                                                root_fd=cleanup['root_fd'])
            except BaseException as error:
                interrupted = interrupted or not isinstance(error, Exception)
                cleanup['complete'] = False
        if not cleanup['complete']:
            row['passed'] = False
            row['failure'] = row.get('failure') or 'cleanup_unverified'
        try:
            row['schema_diagnostics'] = collect_profile(profile, row.get('run_id'), row.get('turns'),
                                                        root_fd=cleanup['root_fd'])
            row['schema_diagnostics']['flush_complete'] = trial_file_exists(state, cleanup['root_fd'], 'flush.done')
            expected_profile = 'legacy' if entry['variant'] == 'baseline' else 'coding'
            if row['passed'] and row['schema_diagnostics']['applied_profiles'] != [expected_profile]:
                row['passed'], row['failure'] = False, 'disclosure_not_observed'
            if number(row.get('tool_errors')) is not None:
                row['tool_error_recoveries'] = int(row['tool_errors'] > 0 and row['passed'])
            row['discovery_failures'] = row['schema_diagnostics']['discovery_failures']
            row['incorrect_tool_calls'] = row['schema_diagnostics']['incorrect_tool_calls']
            row['spend_complete'] = (
                number(row.get('cost_usd')) is not None
                and row['schema_diagnostics']['flush_complete']
                and row['schema_diagnostics']['parent_usage_complete'])
        except BaseException as error:
            interrupted = interrupted or not isinstance(error, Exception)
            cleanup['finalization_failed'] = True
    try:
        row['cleanup_complete'] = cleanup['complete']
        interrupted = interrupted or cleanup['interrupted']
        row['disposal_complete'] = cleanup['disposal_complete']
        row['finalization_failed'] = cleanup['finalization_failed']
        if cleanup['finalization_failed']:
            row['passed'] = False
            row['spend_complete'] = False
            row['failure'] = row.get('failure') or 'finalization_failed'
        if not cleanup['complete']:
            row['passed'] = False
            row['failure'] = row.get('failure') or 'cleanup_unverified'
        elif cleanup['disposal_failed']:
            row['passed'] = False
            row['failure'] = row.get('failure') or 'disposal_unverified'
        # These facts do not depend on fallible profiling or disposal.
        row['wall_seconds'] = round(time.monotonic() - attempt_start, 4)
        row['configuration_digest'] = digest(configuration)
        row['fixture_digest'] = fixture_digest
        if interrupted:
            raise TrialInterrupted(row)
        return row
    except TrialInterrupted:
        raise
    except BaseException:
        row.update(passed=False, spend_complete=False, finalization_failed=True,
                   cleanup_complete=cleanup['complete'], disposal_complete=cleanup['disposal_complete'])
        row['failure'] = row.get('failure') or 'finalization_failed'
        raise TrialInterrupted(row) from None


def teardown_failure(row):
    """Safety stop independent of a trial's prior failure or paid counters."""
    if row.get('cleanup_complete') is False:
        return 'cleanup_unverified'
    if row.get('finalization_failed') is True:
        return 'finalization_failed'
    if row.get('disposal_complete') is False:
        return 'disposal_unverified'
    return None


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
    identity = source_identity(root)
    revision, source_digest = identity['revision'], identity['source_digest']
    build_files, build_digest = identity['build_files'], identity['compiled_build_digest']
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
        interrupted = False
        remaining = args.run_timeout - (time.monotonic() - start)
        if stop_reason or remaining <= 0 or measured + plan['per_attempt_spend_ceiling_usd'] > plan['max_spend_usd']:
            stop_reason = stop_reason or ('run_deadline' if remaining <= 0 else 'spend_limit')
            row = {**failed_row(entry, stop_reason), 'attempted': False, 'cost_usd': 0}
        else:
            try:
                row = execute_trial(root, entry, cases_by_name[entry['task']], configurations[entry['variant']],
                                    args.model, credentials, runtime_ports(), args, run_case,
                                    experiment['fixture_digests'][entry['task']],
                                    run_deadline=start + args.run_timeout)
            except TrialInterrupted as error:
                row, interrupted = error.row, True
        raw_row = row
        recorded_count = len(report['results'])
        try:
            # Runtime IDs, prompts and arbitrary metadata never leave private state.
            row = sanitize_row(row)
            report['results'].append(row)
            cost = number(row.get('cost_usd'))
            if cost is not None:
                measured += cost
            stop_reason = stop_reason or teardown_failure(row)
            if stop_reason not in ('cleanup_unverified', 'disposal_unverified', 'finalization_failed'):
                if row['attempted'] and (cost is None or row.get('spend_complete') is False):
                    stop_reason = 'missing_spend'
                elif cost is not None and cost > plan['per_attempt_spend_ceiling_usd']:
                    stop_reason = 'spend_limit'
            report['summary'] = summarize(report['results'], args.seed)
            report['stop_reason'] = stop_reason
            write_report(args.output, report)
        except BaseException as error:
            raw_row.update(passed=False, spend_complete=False, finalization_failed=True)
            raw_row['failure'] = raw_row.get('failure') or 'finalization_failed'
            row = sanitize_row(raw_row)
            report['results'][recorded_count:] = [row]
            report['summary'] = summarize(report['results'], args.seed)
            report['stop_reason'] = teardown_failure(row)
            write_report(args.output, report)
            if isinstance(error, Exception):
                raise
            return 130
        if interrupted:
            return 130
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
