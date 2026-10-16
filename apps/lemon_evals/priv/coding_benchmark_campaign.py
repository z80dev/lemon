"""Resumable multi-provider paired disclosure campaign over the existing production coding benchmark.

One operator command runs every provider x task x variant x repetition trial sequentially, each in a
fresh runtime, home, store and fixture (`coding_benchmark_paired.execute_trial`). Without `--live`
it only writes a plan and makes no model call. Reports contain code-authored identifiers and numeric
counters only: no prompts, model output, workspace paths or credentials.
"""
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys

import coding_benchmark_paired as paired
import coding_benchmark_pricing as pricing

DEFAULT_PROVIDERS = 'openai-codex:gpt-6.1-sol,zai:glm-5.3'
DEFAULT_VARIANTS = 'baseline,coding'
VARIANTS = ('baseline', 'coding')
TOKEN_KEYS = ('tokens', 'uncached_input_tokens', 'cached_input_tokens', 'cache_write_tokens', 'output_tokens')
SCHEMA_VERSION = 1


class CampaignError(ValueError):
    """Invalid options or an unusable environment, raised before the affected trial starts."""


def split_list(value):
    items = value if isinstance(value, (list, tuple)) else str(value or '').split(',')
    return [item.strip() for item in items if item.strip()]


def parse_providers(value):
    parsed = []
    for item in split_list(value):
        try:
            parsed.append(pricing.parse_provider_model(item))
        except ValueError as error:
            raise CampaignError(f'--providers: {error}') from None
    if not parsed or len({provider for provider, _ in parsed}) != len(parsed):
        raise CampaignError('--providers needs distinct provider:model entries')
    return parsed


def parse_variants(value):
    variants = split_list(value)
    if (len(set(variants)) != len(variants) or not set(variants) <= set(VARIANTS)
            or 'baseline' not in variants or len(variants) < 2):
        raise CampaignError('--variants must name baseline and coding (each once)')
    return variants


def campaign_schedule(providers, cases, variants, repetitions, seed):
    """Per-provider counterbalanced schedule with provider-qualified stable pair/trial IDs."""
    rows = []
    for provider, _ in providers:
        for entry in paired.schedule(cases, variants, repetitions, seed):
            pair = f'{provider}:{entry["pair_id"]}'
            rows.append({'provider': provider, **entry, 'pair_id': pair, 'trial_id': f'{pair}:{entry["variant"]}'})
    return rows


def sanitized_command(args, providers, variants):
    """The operator command with every path/secret option replaced by a placeholder."""
    parts = ['mix', 'lemon.eval.coding', '--campaign']
    if args.live:
        parts.append('--live')
    parts += ['--providers', ','.join(f'{provider}:{model}' for provider, model in providers),
              '--variants', ','.join(variants), '--repetitions', str(args.repetitions),
              '--seed', str(args.seed), '--timeout', str(args.timeout)]
    if getattr(args, 'tasks', None):
        parts += ['--tasks', args.tasks]
    if getattr(args, 'control_plane_port', None):
        parts += ['--control-plane-port', str(args.control_plane_port)]
    parts += ['--output-dir', '<output-dir>']
    if args.config:
        parts += ['--config', '<config>']
    if getattr(args, 'profile_python_explicit', False):
        parts += ['--profile-python', '<profile-python>']
    if args.resume:
        parts.append('--resume')
    return ' '.join(parts)


def port_available(port):
    with socket.socket() as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind(('127.0.0.1', port))
        except OSError:
            return False
    return True


def read_trials(path, scheduled_ids):
    """Recorded attempted trials.

    A torn final line from an interrupted write is durably truncated so later appends start on a
    clean line; a malformed interior record is an error rather than silently skipped.
    """
    rows, seen = [], set()
    if not Path(path).exists():
        return rows
    data = Path(path).read_bytes()
    lines = data.split(b'\n')
    tail = lines.pop()  # '' when the file ends with a newline
    parsed = []
    for number, line in enumerate(lines, 1):
        try:
            parsed.append(json.loads(line))
        except ValueError:
            raise CampaignError(f'{path}: malformed trial record on line {number}; refusing to resume') from None
    if tail:
        try:
            parsed.append(json.loads(tail))
            repair = b'\n'
        except ValueError:
            repair = None
        with open(path, 'r+b') as handle:
            if repair is None:
                handle.truncate(len(data) - len(tail))
            else:
                handle.seek(0, os.SEEK_END)
                handle.write(repair)
            handle.flush()
            os.fsync(handle.fileno())
    for row in parsed:
        if (isinstance(row, dict) and row.get('trial_id') in scheduled_ids
                and row.get('attempted') is True and row['trial_id'] not in seen):
            seen.add(row['trial_id'])
            rows.append(row)
    return rows


def append_trial(path, row):
    with open(path, 'a') as handle:
        handle.write(json.dumps(row, allow_nan=False, sort_keys=True) + '\n')
        handle.flush()
        os.fsync(handle.fileno())


def counter_summary(rows, key, convert=paired.number):
    values = [convert(row.get(key)) for row in rows]
    observed = [value for value in values if value is not None]
    return {'sum': sum(observed) if observed and len(observed) == len(values) else None,
            'observed_sum': sum(observed) if observed else None,
            'trials_observed': len(observed), 'trials_missing': len(values) - len(observed)}


def variant_summary(rows, scheduled):
    """Verified outcomes, wall time, tokens and equivalent spend over every attempted trial."""
    base = paired.aggregate(rows)
    wall = counter_summary(rows, 'wall_seconds')
    wall['mean'] = wall['sum'] / len(rows) if wall['sum'] is not None and rows else None
    summary = {key: base[key] for key in ('attempts', 'successes', 'success_rate', 'failures', 'timeouts', 'turns',
                                          'discovery_failures', 'incorrect_tool_calls', 'tool_errors',
                                          'tool_error_recoveries')}
    summary.update({
        'scheduled_trials': scheduled, 'wall_seconds': wall,
        'token_usage': {key: counter_summary(rows, key) for key in TOKEN_KEYS},
        'equivalent_spend': pricing.summarize_spend(rows),
        'runtime_reported_cost': {
            'measured_usd': base['measured_spend_usd'], 'complete': base['spend_complete'],
            'per_verified_success_usd': base['cost_per_verified_success_usd'],
            'status': base['cost_per_success_status'],
            'basis': 'runtime costUsd from model-catalog estimates; not an invoice'}})
    return summary


def paired_differences(rows):
    """Candidate-minus-baseline per completed pair (attempted trials only); missing wall stays null."""
    pairs = {}
    for row in rows:
        pairs.setdefault(row['pair_id'], {})[row['variant']] = row
    result = []
    for pair_id, pair in sorted(pairs.items()):
        if 'baseline' not in pair or 'coding' not in pair:
            continue
        baseline, candidate = pair['baseline'], pair['coding']
        a, b = paired.number(baseline.get('wall_seconds')), paired.number(candidate.get('wall_seconds'))
        result.append({'pair_id': pair_id, 'task': baseline['task'], 'repetition': baseline.get('repetition'),
                       'baseline_passed': baseline['passed'], 'coding_passed': candidate['passed'],
                       'wall_seconds_difference': candidate['wall_seconds'] - baseline['wall_seconds'] if a is not None and b is not None else None})
    return result


def build_report(experiment, experiment_id, command, providers, variants, scheduled, rows, bases, seed, complete):
    provider_reports = {}
    for provider, model in providers:
        provider_rows = [row for row in rows if row['provider'] == provider]
        counts = {variant: sum(1 for entry in scheduled if entry['provider'] == provider and entry['variant'] == variant)
                  for variant in variants}
        comparison = paired.summarize(provider_rows, seed)
        provider_reports[provider] = {
            'model': model,
            'variants': {variant: variant_summary([row for row in provider_rows if row['variant'] == variant], counts[variant])
                         for variant in variants},
            'comparisons': comparison['comparisons'],
            'uncertainty_method': comparison['uncertainty_method'],
            'paired_differences': paired_differences(provider_rows)}
    return {
        'schema_version': SCHEMA_VERSION, 'suite': 'disclosure_campaign', 'experiment_id': experiment_id,
        'experiment': experiment, 'complete': complete,
        'progress': {'scheduled_trials': len(scheduled), 'recorded_trials': len(rows)},
        'commands': {
            'campaign': command,
            'runtime': 'mix run --no-start --no-halt --no-compile --no-deps-check -e <RUNTIME_EXPRESSION>',
            'runtime_expression_sha256': paired.digest(paired.RUNTIME_EXPRESSION),
            'client': 'lemon -p <fixture prompt> --output json --model <provider:model> --cwd <fixture> --approval-policy allow'},
        'runtime': {'python': sys.version.split()[0], 'boot': 'LemonCore.Runtime.Boot.start!(:runtime_full)',
                    'isolation': 'fresh runtime, HOME, config, store, tokens and fixture per trial; one trial at a time',
                    'permissions': 'approval-policy allow'},
        'equivalent_spend_basis': {'label': pricing.LABEL, 'pricing': bases},
        'cost_basis': 'Equivalent spend = recorded token counters x public catalog list price; ' + pricing.LABEL
                      + '. Runtime-reported costUsd is a separate catalog estimate, not an invoice.',
        'uncontrolled': ['provider cache/queue/load', 'provider pricing/route drift', 'OS scheduling'],
        'interpretation': 'exploratory; task-cluster uncertainty only; no default promotion implied',
        'providers': provider_reports,
        'results': rows}


def render_markdown(report):
    lines = ['# Disclosure campaign: baseline vs coding profile', '',
             f'Command: `{report["commands"]["campaign"]}`',
             f'Revision: `{report["experiment"]["revision"]}` (dirty working tree: {str(report["experiment"]["dirty"]).lower()}), '
             f'source digest `{report["experiment"]["source_digest"]}`',
             f'Trials recorded: {report["progress"]["recorded_trials"]} / {report["progress"]["scheduled_trials"]}'
             f' ({"complete" if report["complete"] else "INCOMPLETE"})', '',
             f'**Equivalent spend is a {pricing.LABEL}**: recorded token counters x public catalog list price.', '']

    def cell(value, digits=None):
        if value is None:
            return 'n/a'
        return f'{value:.{digits}f}' if digits is not None and isinstance(value, float) else str(value)

    def interval(values):
        return 'n/a' if values is None else '[' + ', '.join(f'{value:.3f}' for value in values) + ']'

    for provider, data in report['providers'].items():
        basis = report['equivalent_spend_basis']['pricing'][provider]
        lines += [f'## {provider}:{data["model"]}', '',
                  f'Pricing basis: {basis["basis"]}; `{basis["catalog_file"]}` sha256 `{basis["catalog_sha256"]}`; '
                  f'{basis["unit"]}: ' + ', '.join(f'{name} {price}' for name, price in basis['prices'].items()), '',
                  '| Variant | Verified successes / attempts | Success rate | Timeouts | Mean wall (s) | Uncached input | Cached input | Output '
                  f'| Equivalent spend USD ({pricing.LABEL}) | Equivalent spend / verified success USD | Status |',
                  '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |']
        for variant, summary in data['variants'].items():
            usage, spend = summary['token_usage'], summary['equivalent_spend']
            lines.append('| ' + ' | '.join([
                variant, f'{summary["successes"]} / {summary["attempts"]}', cell(summary['success_rate'], 3),
                str(summary['timeouts']), cell(summary['wall_seconds']['mean'], 2),
                cell(usage['uncached_input_tokens']['sum']), cell(usage['cached_input_tokens']['sum']),
                cell(usage['output_tokens']['sum']), cell(spend['total_usd'], 6),
                cell(spend['per_verified_success_usd'], 6), spend['per_verified_success_status']]) + ' |')
        for variant, comparison in data['comparisons'].items():
            wall, success = comparison['wall_seconds_difference'], comparison['verified_success_difference']
            lines += ['', f'Paired {variant} minus baseline over {comparison["paired_trials"]} pairs: '
                      f'verified-success difference {cell(success["estimate"], 3)} (95% interval {interval(success["interval_95"])}); '
                      f'wall-time difference {cell(wall["estimate"], 2)} s (95% interval {interval(wall["interval_95"])}).']
        lines.append('')
    lines += ['n/a means a counter was not reported (never estimated). A variant total and cost per verified success are n/a '
              'unless every attempted trial reported all four token counters; cost per success is undefined with zero '
              'verified successes. Failed and timed-out trials are included. Exploratory sample; not a model ranking.', '']
    return '\n'.join(lines)


def write_outputs(out, report):
    paired.write_report(out / 'report.json', report)
    temporary = out / 'report.md.tmp'
    temporary.write_text(render_markdown(report))
    temporary.replace(out / 'report.md')


def build_experiment(args, cases, providers, variants, configurations, identity, bases):
    return {
        'providers': [{'provider': provider, 'model': model, 'catalog_sha256': bases[provider]['catalog_sha256']}
                      for provider, model in providers],
        'tasks': [case['name'] for case in cases], 'variants': variants, 'repetitions': args.repetitions,
        'seed': args.seed, 'timeout': args.timeout, 'revision': identity['revision'], 'dirty': identity['dirty'],
        'source_digest': identity['source_digest'], 'compiled_build_digest': identity['compiled_build_digest'],
        'config_digests': {variant: paired.digest(text) for variant, text in configurations.items()},
        'fixture_digests': {case['name']: paired.digest(case) for case in cases},
        'profile_python_digest': hashlib.sha256(Path(args.profile_python).resolve().read_bytes()).hexdigest()}


def run_campaign(args, cases, run_case, root=None, runtime_argv=None):
    """Plan (without `--live`) or run the campaign; returns a process exit status."""
    root = Path(root).resolve() if root else Path(__file__).resolve().parents[3]
    if Path(args.lemon).resolve() != root / 'bin' / 'lemon':
        raise CampaignError('campaign runs require this revision\'s source launcher')
    if args.compare_omp:
        raise CampaignError('--campaign cannot be combined with --compare-omp')
    providers, variants = parse_providers(args.providers), parse_variants(args.variants)
    if args.repetitions < 1 or args.timeout <= 0:
        raise CampaignError('positive --repetitions and --timeout required')
    port = getattr(args, 'control_plane_port', None)
    if port is not None and not 1024 <= port <= 65535:
        raise CampaignError('--control-plane-port must be an unprivileged TCP port')
    if not args.output_dir:
        raise CampaignError('--output-dir required')
    out = Path(args.output_dir).resolve()
    if out == root or root in out.parents:
        raise CampaignError('--output-dir must be outside the source checkout')
    base = Path(args.config).read_text() if args.config else ''
    configurations = {variant: paired.paired_configuration(base, variant) for variant in variants}
    bases = {provider: pricing.pricing_basis(provider, model, root) for provider, model in providers}
    identity = paired.source_identity(root)
    experiment = build_experiment(args, cases, providers, variants, configurations, identity, bases)
    experiment_id = paired.digest(experiment)
    command = sanitized_command(args, providers, variants)
    scheduled = campaign_schedule(providers, cases, variants, args.repetitions, args.seed)
    out.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not args.live:
        paired.write_report(out / 'plan.json', {
            'schema_version': SCHEMA_VERSION, 'suite': 'disclosure_campaign_plan', 'experiment_id': experiment_id,
            'experiment': experiment, 'commands': {'campaign': command}, 'scheduled_trials': scheduled,
            'equivalent_spend_basis': {'label': pricing.LABEL, 'pricing': bases}, 'live_calls': 0})
        print(f'Planned {len(scheduled)} trials; no model calls were made (add --live to run).', flush=True)
        return 0
    credentials = {}
    for provider, _ in providers:
        name = pricing.PROVIDERS[provider]['credential_env']
        if not os.environ.get(name):
            raise CampaignError(f'{name} must be set for provider {provider}')
        credentials[provider] = {name: os.environ[name]}
    if runtime_argv is None:
        if not identity['build_files']:
            raise CampaignError('compile the exact source revision (MIX_ENV=dev mix compile) before a live campaign')
        probe = subprocess.run([args.profile_python, '-c', 'import tiktoken'],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if probe.returncode != 0:
            raise CampaignError('--profile-python must be an interpreter with tiktoken installed')
    manifest, trials = out / 'manifest.json', out / 'trials.jsonl'
    if manifest.exists():
        if not args.resume:
            raise CampaignError('--output-dir already holds a campaign; pass --resume to continue it or choose a new directory')
        if json.loads(manifest.read_text()).get('experiment_id') != experiment_id:
            raise CampaignError('the existing campaign used a different experiment (revision, source, options or fixtures); use a new --output-dir')
    else:
        paired.write_report(manifest, {'schema_version': SCHEMA_VERSION, 'suite': 'disclosure_campaign_manifest',
                                       'experiment_id': experiment_id, 'experiment': experiment})
    rows = read_trials(trials, {entry['trial_id'] for entry in scheduled})
    done = {row['trial_id'] for row in rows}
    cases_by_name = {case['name']: case for case in cases}
    models = dict(providers)
    if done:
        print(f'Resuming: {len(done)} of {len(scheduled)} trials already recorded.', flush=True)
    try:
        for entry in scheduled:
            if entry['trial_id'] in done:
                continue
            if port is not None and not port_available(port):
                raise CampaignError('--control-plane-port is already in use; re-run with --resume once it is free')
            ports = paired.runtime_ports()
            if port is not None:
                ports[0] = port
            row = paired.execute_trial(root, entry, cases_by_name[entry['task']], configurations[entry['variant']],
                                       models[entry['provider']], credentials[entry['provider']], ports, args, run_case,
                                       experiment['fixture_digests'][entry['task']], runtime_argv=runtime_argv)
            row['provider'] = entry['provider']
            row['equivalent_spend_usd'], row['equivalent_spend_status'] = pricing.equivalent_spend(row, bases[entry['provider']])
            row = paired.sanitize_row(row)
            append_trial(trials, row)
            rows.append(row)
            outcome = 'PASS' if row['passed'] else 'FAIL (' + str(row['failure']) + ')'
            print(f'[{len(rows)}/{len(scheduled)}] {entry["trial_id"]}: {outcome}', flush=True)
            write_outputs(out, build_report(experiment, experiment_id, command, providers, variants, scheduled, rows, bases,
                                            args.seed, len(rows) == len(scheduled)))
    except KeyboardInterrupt:
        print('Interrupted; re-run the same command with --resume to continue.', file=sys.stderr, flush=True)
        return 130
    write_outputs(out, build_report(experiment, experiment_id, command, providers, variants, scheduled, rows, bases,
                                    args.seed, len(rows) == len(scheduled)))
    return 0 if len(rows) == len(scheduled) else 1
