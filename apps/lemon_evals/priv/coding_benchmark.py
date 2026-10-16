#!/usr/bin/env python3
"""Opt-in production CLI benchmark. Only aggregate, code-authored data is retained."""
import argparse
from contextlib import nullcontext
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from coding_benchmark_tasks import additional_tasks
from coding_benchmark_campaign import CampaignError, DEFAULT_PROVIDERS, DEFAULT_VARIANTS, run_campaign
from coding_benchmark_paired import TrialInterrupted, number, run_paired


def task(name, prompt, files, verify):
    return {"name": name, "prompt": prompt, "files": files, "verify": verify}


def tasks():
    return [
        task("bug_fix", "Fix the slug function so punctuation does not leave repeated or edge hyphens. Run the existing tests.",
             {"slug.py": "def slug(text):\n    return text.lower().replace(' ', '-')\n",
              "test_slug.py": "import unittest\nfrom slug import slug\nclass SlugTest(unittest.TestCase):\n def test_slug(self):\n  self.assertEqual(slug(' Hello,   World!! '), 'hello-world')\n  self.assertEqual(slug('---'), '')\nif __name__ == '__main__': unittest.main()\n"},
             "from slug import slug\nassert slug(' Hello,   World!! ') == 'hello-world'\nassert slug('A_B / C') == 'a-b-c'\nassert slug('---') == ''\n"),
        task("multi_file_refactor", "Refactor currency formatting into money.py as format_money(cents). Update both consumers, preserve their public behavior, and remove duplicated formatting. Add tests.",
             {"invoice.py": "def invoice_total(cents):\n return '$%.2f' % (cents / 100)\n",
              "receipt.py": "def receipt_total(cents):\n return '$%.2f' % (cents / 100)\n"},
             "from money import format_money\nfrom invoice import invoice_total\nfrom receipt import receipt_total\nfrom pathlib import Path\nfor value in [0, 123, -450]:\n expected = '$%.2f' % (value / 100)\n assert format_money(value) == invoice_total(value) == receipt_total(value) == expected\nfor name in ['invoice.py','receipt.py']:\n text=Path(name).read_text()\n assert 'format_money' in text and ' / 100' not in text\nassert list(Path('.').glob('test*.py'))\n"),
        task("feature_and_test", "Add paginate(items, page, page_size) to paging.py: one-based pages, return the selected slice, reject nonpositive page/page_size with ValueError, and return [] beyond the end. Add unittest regression tests and run them.",
             {"paging.py": '"""Collection helpers."""\n'},
             "from paging import paginate\nfrom pathlib import Path\nassert paginate(list(range(8)),2,3)==[3,4,5]\nassert paginate([1],3,2)==[]\nfor args in [(0,2),(1,0),(-1,3)]:\n try: paginate([1],*args)\n except ValueError: pass\n else: raise AssertionError('invalid pagination accepted')\nassert list(Path('.').glob('test*.py'))\n"),
        task("read_and_answer", "Inspect the source and configuration. Explain which port production uses and why staging differs. Do not modify files. Include both numeric port values in your answer.",
             {"config.json": '{"base_port": 7300, "environments": {"production": {"offset": 17}, "staging": {"offset": 4}}}\n',
              "ports.py": "import json\ndef port(environment):\n with open('config.json') as f: config=json.load(f)\n return config['base_port']+config['environments'][environment]['offset']\n"},
             "import os\nanswer=os.environ['BENCHMARK_ANSWER']\nassert '7317' in answer and '7304' in answer\n"),
        task("bash_debugging", "The report command `python3 report.py` fails. Diagnose by running it and inspecting the local CSV. Fix parsing and aggregation so the command prints exactly TOTAL=42. Preserve the input file.",
             {"data.csv": "name,amount\nalpha, 10\nbeta,12\ngamma,20\n",
              "report.py": "from pathlib import Path\nrows=Path('data.csv').read_text().splitlines()\nprint('TOTAL=' + str(sum(int(row.split(',')[0]) for row in rows)))\n"},
             "import subprocess\nfrom pathlib import Path\nr=subprocess.run(['python3','report.py'],capture_output=True,text=True)\nassert r.returncode==0 and r.stdout.strip()=='TOTAL=42'\nassert Path('data.csv').read_text()=='name,amount\\nalpha, 10\\nbeta,12\\ngamma,20\\n'\n"),
        task("large_file_edit", "Fix lookup('target') in catalog.py to return 999999 instead of -1. Preserve every other catalog entry and formatting; this is a targeted edit in a large file.",
             {"catalog.py": "VALUES = {\n" + ''.join(f"    'item_{i:05d}': {i},\n" for i in range(12000)) + "    'target': -1,\n}\ndef lookup(key):\n    return VALUES[key]\n"},
             "from catalog import lookup, VALUES\nassert lookup('target')==999999\nassert len(VALUES)==12001\nfor i in range(12000): assert lookup('item_%05d' % i)==i\n"),
        task("repo_search", "Find every obsolete API_TOKEN_V1 environment reference across this repository, migrate them to API_TOKEN_V2, and update the shared credential reader to use the new name. Preserve unrelated settings and add a regression test.",
             {"service/auth.py": "import os\ndef token(): return os.environ.get('API_TOKEN_V1')\n",
              "scripts/launch.sh": "#!/bin/sh\nexport API_TOKEN_V1=local-example\n",
              "docs/config.txt": "API_TOKEN_V1 is the credential variable.\nTIMEOUT=30\n",
              "service/__init__.py": ""},
             "import os\nfrom pathlib import Path\nos.environ['API_TOKEN_V2']='benchmark-token'\nfrom service.auth import token\nassert token()=='benchmark-token'\nfor name in ['service/auth.py','scripts/launch.sh','docs/config.txt']:\n assert 'API_TOKEN_V1' not in Path(name).read_text()\n assert 'API_TOKEN_V2' in Path(name).read_text()\nassert 'TIMEOUT=30' in Path('docs/config.txt').read_text()\nassert list(Path('.').rglob('test*.py'))\n"),
        task("tool_failure_recovery", "First run `python3 missing_check.py` to observe its failure. Recover by inspecting calculator.py and running the real test_calculator.py instead. Fix the integer division bug in average; empty input must raise ValueError. Add an empty-input regression test.",
             {"calculator.py": "def average(values):\n return sum(values) // len(values)\n",
              "test_calculator.py": "import unittest\nfrom calculator import average\nclass AverageTest(unittest.TestCase):\n def test_fraction(self): self.assertEqual(average([1,2]),1.5)\nif __name__=='__main__': unittest.main()\n"},
             "from calculator import average\nassert average([1,2])==1.5\nassert average([-1,2])==0.5\ntry: average([])\nexcept ValueError: pass\nelse: raise AssertionError('empty average accepted')\n"),
    ] + additional_tasks(task)


def command(argv, cwd, **kwargs):
    deadline = kwargs.pop('deadline', None)
    if deadline is not None:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise subprocess.TimeoutExpired(argv, 0)
        kwargs['timeout'] = min(kwargs.get('timeout', remaining), remaining)
    timeout, check = kwargs.pop('timeout', None), kwargs.pop('check', False)
    with subprocess.Popen(argv, cwd=cwd, stdin=subprocess.DEVNULL, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          start_new_session=True, **kwargs) as process:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except BaseException:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            raise
        finally:
            # Deadline-owned fixture/client commands must not leave background children.
            if deadline is not None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        result = subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)
        if check:
            result.check_returncode()
        return result


def parse_omp(output):
    events = [json.loads(line) for line in output.splitlines() if line.strip()]
    assistants = [event['message'] for event in events if event.get('type') == 'message_end' and event.get('message', {}).get('role') == 'assistant']
    last = assistants[-1] if assistants else {}
    usage = [message.get('usage') or {} for message in assistants]
    answer = ''.join(part.get('text', '') for part in last.get('content', []) if part.get('type') == 'text')
    return {'ok': bool(assistants) and any(event.get('type') == 'agent_end' for event in events) and last.get('stopReason') not in ('error', 'aborted'),
            'answer': answer, 'model': last.get('model'),
            'usage': {'totalTokens': sum(value.get('totalTokens', 0) for value in usage),
                      'inputTokens': sum(value.get('input', 0) for value in usage),
                      'outputTokens': sum(value.get('output', 0) for value in usage),
                      'cacheReadTokens': sum(value.get('cacheRead', 0) for value in usage)},
            'metrics': {'turns': sum(event.get('type') == 'turn_end' for event in events),
                        'tool_errors': sum(event.get('type') == 'tool_execution_end' and event.get('isError') is True for event in events)}}


def run_case(case, agent, executable, model, args):
    # Paired fixtures must survive until independent native groups are proven dead.
    fixture_root = getattr(args, 'fixture_root', None)
    if fixture_root is not None:
        Path(fixture_root).mkdir(mode=0o700)
    with (nullcontext(fixture_root) if fixture_root is not None else
          tempfile.TemporaryDirectory(prefix='lemon-coding-bench-' + agent + '-')) as tmp:
        root = Path(tmp)
        deadline = getattr(args, 'attempt_deadline', None)
        environment = getattr(args, 'environment', None)
        (root / '.gitignore').write_text('__pycache__/\n*.py[cod]\n')
        for name, content in case['files'].items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        started = time.monotonic()
        result, failure = {}, None
        invocation = verifier = tests = None
        prompt = case['prompt'] + ' Use Python standard-library unittest for any tests; do not install dependencies.'
        if agent == 'lemon':
            argv = [executable, '-p', prompt, '--output', 'json', '--model', model, '--cwd', str(root), '--approval-policy', 'allow']
        else:
            argv = [executable, '-p', prompt, '--mode', 'json', '--model', model, '--cwd', str(root), '--no-session', '--no-title', '--auto-approve', '--max-time', str(args.timeout)]
        verifier_passed = tests_passed = None
        interrupted = False
        try:
            for fixture_argv in [['git','init','-q'], ['git','add','.'], ['git','-c','user.name=Lemon Benchmark','-c','user.email=benchmark@example.invalid','commit','-qm','fixture']]:
                command(fixture_argv, root, check=True, env=environment, deadline=deadline)
            invocation = command(argv, root, timeout=args.timeout if deadline else args.timeout + 15,
                                 env=environment, deadline=deadline)
            try:
                result = json.loads(invocation.stdout) if agent == 'lemon' else parse_omp(invocation.stdout)
            except (ValueError, TypeError):
                failure = 'invalid_cli_json'
            if not isinstance(result, dict):
                result = {}
                failure = 'invalid_cli_json'
            if not failure and (invocation.returncode != 0 or result.get('ok') is not True):
                failure = 'agent_failed'
            env = dict(environment if environment is not None else os.environ, BENCHMARK_ANSWER=result.get('answer') or '')
            verifier = command([sys.executable, '-c', case['verify']], root, env=env, timeout=30, deadline=deadline)
            verifier_passed = verifier.returncode == 0
            if not verifier_passed and not failure: failure = 'verifier_failed'
            if case['name'] == 'read_and_answer' and command(['git','status','--porcelain'], root, env=environment, deadline=deadline).stdout:
                failure = 'unexpected_mutation'
            requires_tests = case['name'] in {'multi_file_refactor','feature_and_test','repo_search'} or any(Path(name).name.startswith('test') and name.endswith('.py') for name in case['files'])
            if requires_tests:
                tests = command([sys.executable,'-m','unittest','discover','-v'], root, env=env, timeout=30, deadline=deadline)
                tests_passed = tests.returncode == 0 and 'Ran 0 tests' not in tests.stderr
                if not tests_passed and not failure: failure = 'tests_failed'
        except subprocess.TimeoutExpired:
            failure = 'timeout'
        except (OSError, subprocess.CalledProcessError):
            failure = 'invocation_failed'
        except BaseException:
            if fixture_root is None:
                raise
            interrupted = True
            failure = failure or 'finalization_failed'
        usage = result.get('usage') if isinstance(result.get('usage'), dict) else {}
        metrics = result.get('metrics') if isinstance(result.get('metrics'), dict) else {}
        tool_errors = number(metrics.get('tool_errors', usage.get('tool_errors')))
        if case['name'] == 'tool_failure_recovery' and not failure:
            if not isinstance(tool_errors, int) or tool_errors < 1: failure = 'recovery_not_observed'
        if failure and args.failure_dir and not interrupted:
            try:
                bundle = Path(args.failure_dir) / agent / getattr(args, 'trial_id', case['name']).replace(':', '-')
                bundle.mkdir(parents=True, mode=0o700, exist_ok=False)
                shutil.copytree(root, bundle / 'repo')
                (bundle / 'verify.py').write_text(case['verify'])
                for label, completed in [('cli', invocation), ('verifier', verifier), ('tests', tests)]:
                    if completed is not None:
                        (bundle / (label + '.stdout')).write_text(completed.stdout)
                        (bundle / (label + '.stderr')).write_text(completed.stderr)
            except BaseException:
                if fixture_root is None:
                    raise
                interrupted = True
        row = {'task': case['name'], 'agent': agent, 'passed': failure is None, 'failure': failure,
                'verifier_passed': verifier_passed, 'tests_passed': tests_passed,
                'turns': number(metrics.get('turns', usage.get('turns'))), 'tokens': number(usage.get('totalTokens')),
                'uncached_input_tokens': number(usage.get('inputTokens')), 'cached_input_tokens': number(usage.get('cacheReadTokens')),
                'cache_write_tokens': number(usage.get('cacheWriteTokens')),
                'output_tokens': number(usage.get('outputTokens')), 'wall_seconds': round(time.monotonic()-started, 2),
                'cost_usd': number(usage.get('costUsd')),
                'discovery_failures': number(metrics.get('discovery_failures')),
                'incorrect_tool_calls': number(metrics.get('incorrect_tool_calls')),
                'tool_error_recoveries': number(metrics.get('tool_error_recoveries')),
                'tool_errors': tool_errors, 'run_id': result.get('run_id')}
        if interrupted:
            raise TrialInterrupted(row)
        return row


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--lemon', required=True)
    parser.add_argument('--model', default='openai-codex:gpt-6.1-sol')
    parser.add_argument('--output')
    parser.add_argument('--timeout', type=int, default=660)
    parser.add_argument('--failure-dir', help='Opt-in private failure bundles; may contain raw model output')
    parser.add_argument('--compare-omp', action='store_true')
    parser.add_argument('--omp', default='omp')
    parser.add_argument('--omp-model')
    parser.add_argument('--tasks', help='Comma-separated task names; omitted runs all twelve')
    parser.add_argument('--paired', action='store_true', help='Repeated controlled disclosure trials; plan-only unless --live')
    parser.add_argument('--repetitions', type=int, default=4)
    parser.add_argument('--seed', type=int, default=107)
    parser.add_argument('--config', help='Dedicated base TOML, without disclosure overrides')
    parser.add_argument('--run-timeout', type=int, default=7200)
    parser.add_argument('--plan', help='Operator-approved bounded JSON plan')
    parser.add_argument('--approve-plan-digest', help='Explicit SHA256 approval of exact canonical plan')
    parser.add_argument('--live', action='store_true', help='Authorize live calls only with exact approved plan')
    parser.add_argument('--profile-python', help='Python 3.11+ environment with tiktoken installed; default: this interpreter')
    parser.add_argument('--campaign', action='store_true',
                        help='Resumable multi-provider paired campaign; plan-only unless --live')
    parser.add_argument('--providers', default=DEFAULT_PROVIDERS, help='Comma-separated provider:model (openai-codex, zai)')
    parser.add_argument('--variants', default=DEFAULT_VARIANTS, help='Comma-separated disclosure variants')
    parser.add_argument('--control-plane-port', type=int, help='Fixed isolated runtime control-plane port (default: a free port per trial)')
    parser.add_argument('--output-dir', help='Campaign directory for manifest, per-trial records and sanitized report')
    parser.add_argument('--resume', action='store_true', help='Continue (or start) a campaign in --output-dir')
    args = parser.parse_args()
    args.profile_python_explicit = args.profile_python is not None
    args.profile_python = args.profile_python or sys.executable
    lemon = str(Path(args.lemon).resolve())
    agents = [('lemon', lemon, args.model)]
    if args.compare_omp:
        executable = shutil.which(args.omp)
        if not executable: parser.error('omp executable is required for --compare-omp')
        agents.append(('omp', executable, args.omp_model or args.model.replace(':', '/', 1)))
    cases = tasks()
    if args.tasks:
        names = set(args.tasks.split(','))
        if not names <= {case['name'] for case in cases}: parser.error('unknown task selection')
        cases = [case for case in cases if case['name'] in names]
    campaign_flags = {'--providers', '--variants', '--control-plane-port', '--output-dir', '--resume'}
    given = {argument.split('=', 1)[0] for argument in sys.argv[1:]}
    if args.campaign:
        if args.paired or args.compare_omp or args.plan or args.approve_plan_digest or args.output or given & {'--run-timeout', '--model', '--failure-dir'}:
            parser.error('--campaign cannot be combined with --paired, --compare-omp, --plan, --approve-plan-digest, --output, --run-timeout, --failure-dir or --model (use --providers)')
        if '--repetitions' not in given:
            args.repetitions = 3
        try:
            return run_campaign(args, cases, run_case)
        except (CampaignError, ValueError, OSError, subprocess.SubprocessError) as error:
            parser.error(f'Campaign configuration failed: {error}')
    if given & campaign_flags:
        parser.error('campaign options require --campaign')
    if not args.output:
        parser.error('--output is required')
    if args.paired:
        try:
            return run_paired(args, cases, run_case)
        except (ValueError, OSError, subprocess.SubprocessError):
            parser.error('Paired configuration/authorization failed; review the dedicated config and exact bounded plan')
    paired_flags = {'--live', '--plan', '--approve-plan-digest',
                    '--repetitions', '--seed', '--config', '--run-timeout', '--profile-python'}
    if any(argument.split('=', 1)[0] in paired_flags for argument in sys.argv[1:]):
        parser.error('paired authorization/options require --paired')
    rows = []
    with ThreadPoolExecutor(max_workers=len(agents)) as pool:
        for case in cases:
            futures = [pool.submit(run_case, case, agent, executable, model, args) for agent, executable, model in agents]
            for future in futures:
                row = future.result()
                rows.append(row)
                checkpoint = Path(args.output)
                checkpoint.parent.mkdir(parents=True, exist_ok=True)
                checkpoint.write_text(json.dumps({'schema_version': 2, 'suite': 'live_agentic_coding',
                    'model': args.model, 'models': {agent: model for agent, _, model in agents},
                    'passed': sum(item['passed'] for item in rows), 'total': len(rows),
                    'complete': False, 'results': rows}, indent=2) + '\n')
                print(f"{row['task']} / {row['agent']}: {'PASS' if row['passed'] else 'FAIL ('+row['failure']+')'}", flush=True)
    report = {'schema_version': 2, 'suite': 'live_agentic_coding', 'model': args.model,
              'models': {agent: model for agent, _, model in agents},
              'passed': sum(row['passed'] for row in rows), 'total': len(rows), 'complete': True, 'results': rows}
    destination = Path(args.output)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + '.tmp')
    temporary.write_text(json.dumps(report, indent=2) + '\n')
    temporary.replace(destination)
    if args.compare_omp:
        table = ['| Task | Lemon | Turns | Tokens | Wall (s) | omp | Turns | Tokens | Wall (s) |',
                 '| --- | --- | ---: | ---: | ---: | --- | ---: | ---: | ---: |']
        for case in cases:
            values = [case['name']]
            for agent, _, _ in agents:
                row = next(row for row in rows if row['task'] == case['name'] and row['agent'] == agent)
                values.extend(['PASS' if row['passed'] else 'FAIL', row['turns'], row['tokens'], row['wall_seconds']])
            table.append('| ' + ' | '.join('n/a' if value is None else str(value) for value in values) + ' |')
    else:
        table = ['| Task | Result | Turns | Tokens | Wall (s) | Tool errors |', '| --- | --- | ---: | ---: | ---: | ---: |']
        for row in rows:
            values = [row['task'], 'PASS' if row['passed'] else 'FAIL', row['turns'], row['tokens'], row['wall_seconds'], row['tool_errors']]
            table.append('| ' + ' | '.join('n/a' if value is None else str(value) for value in values) + ' |')
    markdown = '\n'.join(table) + '\n\nTokens include provider-reported cached input. Turns are completed parent assistant turns. Missing metrics are n/a. One trial per task, not a statistical ranking.\n'
    destination.with_suffix('.md').write_text(markdown)
    print(markdown)
    return 0 if report['passed'] == report['total'] else 1


if __name__ == '__main__':
    sys.exit(main())
