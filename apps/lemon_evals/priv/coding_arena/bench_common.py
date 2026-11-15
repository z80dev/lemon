"""Shared production commands and content-free accounting for opt-in external lanes.

No provider credential is resolved here: only the host proxy signs trial tokens.
Missing counters remain unknown, including a stream interrupted before usage.
"""
import json
import math
import secrets
from collections import Counter
from pathlib import Path

import arena


HOME = '/tmp/lemon-arena-home'
ARMS = ('lemon', 'omp')


def command(agent, prompt, model, effort, deadline, cwd, stream=False):
    if agent not in ARMS or model not in arena.MODELS or deadline <= 0:
        raise ValueError('unsupported arm/model or nonpositive deadline')
    spec = arena.MODELS[model]
    if agent == 'lemon':
        return ['lemon', '-p', prompt, '--output', 'stream-json' if stream else 'json',
                '--model', f"{spec['lemon_provider']}:{model}", '--cwd', cwd,
                '--approval-policy', 'allow', '--max-time', str(deadline)]
    return ['omp', '-p', prompt, '--mode', 'json', '--model', f"{spec['omp_provider']}/{model}",
            '--thinking', effort, '--cwd', cwd, '--no-session', '--no-title',
            '--auto-approve', '--max-time', str(deadline)]


def configuration(agent, model, effort, proxy_url, token):
    """Return files and an allowlisted environment; never copy ambient settings."""
    spec = arena.MODELS[model]
    env = {'HOME': HOME, 'PATH': '/usr/local/bin:/usr/bin:/bin', 'LANG': 'C.UTF-8',
           spec[f'{agent}_env']: token}
    if agent == 'lemon':
        files = {'.lemon/config.toml': f'''[defaults]
provider = "{spec['lemon_provider']}"
model = "{spec['lemon_provider']}:{model}"
thinking_level = "{effort}"

[providers.{spec['lemon_provider']}]
base_url = "{proxy_url}{spec['lemon_base']}"
{spec.get('lemon_extra', '')}'''}
        env.update(LEMON_SECRETS_MASTER_KEY=secrets.token_hex(32),
                   LEMON_CONTROL_PLANE_OPERATOR_TOKEN=secrets.token_hex(32))
        env['RELEASE_TMP'] = f'{HOME}/runtime'
    else:
        files = {'.omp/agent/models.yml': f'''providers:
  {spec['omp_provider']}:
    baseUrl: {proxy_url}{spec['omp_base']}
    apiKey: {spec['omp_env']}
''', '.omp/agent/config.yml': 'modelRoles:\n' + ''.join(
            f"  {role}: {spec['omp_provider']}/{model}:{effort}\n" for role in arena.OMP_ROLES)}
        env.update(spec.get('omp_extra_env', {}))
    return files, env


def token_for(secret, trial, model):
    claims = arena.MODELS[model].get('claims')
    return arena.trial_token(secret, trial, claims() if claims else None)


def metrics(agent, output):
    parsed = arena.parse_omp(output) if agent == 'omp' else arena.parse_lemon(output)
    usage = parsed.get('usage') or {}
    result = parsed.get('metrics') or {}
    # Plain JSON has no tool events; do not turn an absent stream into zero calls.
    if agent == 'lemon':
        streamed = any(event.get('event') == 'agent' for event in arena.json_lines(output))
        result['tool_errors'] = usage.get('tool_errors', result.get('tool_errors') if streamed else None)
        if not streamed:
            result['tool_calls'] = None
    return {'agent_ok': parsed.get('ok') is True, 'turns': result.get('turns'),
            'tool_calls': result.get('tool_calls'), 'tool_errors': result.get('tool_errors')}


def wire_usage(path):
    """Read arena proxy JSONL, preserving incomplete/missing request usage."""
    groups = {}
    if not path or not Path(path).exists():
        return groups
    for line in Path(path).read_text().splitlines():
        if not line.strip():
            continue
        entry = json.loads(line)  # torn logs are evidence errors, not zero usage
        if not entry.get('path', '').endswith(('/messages', '/chat/completions', '/responses')):
            continue
        group = groups.setdefault(entry['trial'], {'requests': [], 'usage': []})
        group['usage' if entry.get('kind') == 'usage' else 'requests'].append(entry)
    result = {}
    for trial, group in groups.items():
        requests, usage = group['requests'], group['usage']
        complete = bool(requests) and len(requests) == len(usage)
        complete = complete and all(not row.get('usage_missing') and all(
            isinstance(row.get(key), (int, float)) and row[key] >= 0
            for key in ('input_tokens', 'output_tokens')) for row in usage)
        # Cache reads are a separately nullable dimension; absent != observed zero.
        cached = all(isinstance(row.get('cache_read_tokens'), (int, float)) for row in usage)
        result[trial] = {'model_requests': len(requests), 'wire_usage_complete': complete,
                         'wire_models': sorted({r['model'] for r in requests if r.get('model')}),
                         'wire_input_tokens': sum(r['input_tokens'] for r in usage) if complete else None,
                         'wire_output_tokens': sum(r['output_tokens'] for r in usage) if complete else None,
                         'wire_cached_tokens': sum(r['cache_read_tokens'] for r in usage)
                         if complete and cached else None}
    return result


def wilson(passed, total):
    if not total:
        return [None, None]
    z = 1.959963984540054
    p = passed / total
    denominator = 1 + z * z / total
    centre = (p + z * z / (2 * total)) / denominator
    half = z * math.sqrt(p * (1 - p) / total + z * z / (4 * total * total)) / denominator
    return [max(0.0, centre - half), min(1.0, centre + half)]


def exact_mcnemar(only_a, only_b):
    n, k = only_a + only_b, min(only_a, only_b)
    if not n:
        return 1.0
    return min(1.0, 2 * sum(math.exp(math.lgamma(n + 1) - math.lgamma(i + 1)
                                   - math.lgamma(n - i + 1) - n * math.log(2))
                          for i in range(k + 1)))


def complete_sum(rows, key):
    values = [row.get(key) for row in rows]
    return sum(values) if values and all(value is not None for value in values) else None


def aggregate(rows):
    """Pair only identical task/repetition/model/effort/deadline, never drop failures."""
    per_model = {}
    for model in sorted({row['model'] for row in rows}):
        mine = [row for row in rows if row['model'] == model]
        arms = {}
        for agent in ARMS:
            selected = [row for row in mine if row['agent'] == agent]
            passed = sum(row['passed'] is True for row in selected)
            arms[agent] = {'total': len(selected), 'passed': passed,
                           'rate': passed / len(selected) if selected else None,
                           'ci95': wilson(passed, len(selected)),
                           **{key: complete_sum(selected, key) for key in
                              ('wire_input_tokens', 'wire_output_tokens', 'wire_cached_tokens',
                               'turns', 'tool_errors', 'wall_seconds')},
                           'failures': dict(Counter(row['failure'] for row in selected if row.get('failure')))}
        cells = {}
        for row in mine:
            key = (row['task'], row['rep'], row['effort'], row['deadline'])
            cell = cells.setdefault(key, {})
            if row['agent'] in cell:
                raise ValueError('duplicate arm in paired cell')
            cell[row['agent']] = row
        pairs = [cell for cell in cells.values() if all(agent in cell for agent in ARMS)]
        only_a = sum(cell['lemon']['passed'] and not cell['omp']['passed'] for cell in pairs)
        only_b = sum(cell['omp']['passed'] and not cell['lemon']['passed'] for cell in pairs)
        per_model[model] = {'arms': arms, 'paired': {'pairs': len(pairs), 'only_lemon': only_a,
                            'only_omp': only_b, 'both': sum(all(c[a]['passed'] for a in ARMS) for c in pairs),
                            'neither': sum(not any(c[a]['passed'] for a in ARMS) for c in pairs),
                            'unpaired_cells': len(cells) - len(pairs),
                            'mcnemar_exact_p': exact_mcnemar(only_a, only_b)}}
    return per_model


def write_report(path, report):
    path = Path(path)
    path.write_text(json.dumps(report, indent=2) + '\n')
    lines = ['# External coding benchmark', '', '| Model | Arm | Passed | 95% Wilson CI | Input (uncached) | Output | Turns | Failed tools | Wall s |',
             '|---|---|---|---|---|---|---|---|---|']
    for model, group in report['models'].items():
        for arm, row in group['arms'].items():
            values = [model, arm, f"{row['passed']}/{row['total']}", str(row['ci95'])] + [
                str(row[key]) if row[key] is not None else 'n/a' for key in
                ('wire_input_tokens', 'wire_output_tokens', 'turns', 'tool_errors', 'wall_seconds')]
            lines.append('| ' + ' | '.join(values) + ' |')
        lines.append(f"\n{model}: paired exact McNemar: `{json.dumps(group['paired'])}`\n")
    path.with_suffix('.md').write_text('\n'.join(lines) + '\n')
