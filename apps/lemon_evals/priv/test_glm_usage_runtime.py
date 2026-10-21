"""OFFLINE native ZAI-provider -> CLI -> paired-row usage replay.

Run separately in the exact combined F-0112 + F-0111 tree, after compiling dev
and test. No provider implementation is replaced: Req uses the in-memory Plug
fixture. All usage is synthetic fixture data, never operator campaign evidence.
Requires cached tiktoken and the read-only interpreter specified in the README.
"""
from contextlib import contextmanager, redirect_stdout, redirect_stderr
import io
import json
import os
from pathlib import Path
import shutil
import socket
import sys
import tempfile
import textwrap
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import coding_benchmark as benchmark
import coding_benchmark_campaign as campaign
import coding_benchmark_paired as paired
from test_paired_native_cleanup import fixture_command

PROJECT = Path(__file__).resolve().parents[3]
TRANSPORT = PROJECT / 'apps/lemon_evals/test/support/glm_usage_runtime_offline.exs'
SSE = PROJECT / 'apps/lemon_ai/test/fixtures/openai_completions/compatible_complete.sse'
OBSERVED = PROJECT / 'apps/lemon_evals/test/fixtures/glm_passed_four_turns_missing_usage.json'
COUNTERS = {'tokens': 520, 'uncached_input_tokens': 280, 'cached_input_tokens': 80,
            'cache_write_tokens': 40, 'output_tokens': 120}


class GlmUsageRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not hasattr(campaign, 'admission_stop'):
            raise AssertionError('native gate requires the separately recorded F-0111 harness component')
        _, cls.sdk_bins = fixture_command()
        cls.python = Path(os.environ.get('LEMON_EVAL_OFFLINE_PROFILE_PYTHON', sys.executable)).absolute()
        cls.cache = Path(os.environ.get('LEMON_EVAL_OFFLINE_TOKENIZER_CACHE', '/nonexistent-offline-cache'))
        if not cls.cache.is_dir() or not any(cls.cache.iterdir()):
            raise AssertionError('provide cached tokenizer data; this gate must not fetch it')
        if not (PROJECT / '_build/dev/lib/lemon_evals/ebin/Elixir.LemonEvals.PayloadProfile.beam').is_file():
            raise AssertionError('compile the exact dev tree before the native gate')

    def evidence(self, record):
        path = os.environ.get('LEMON_EVAL_OFFLINE_EVIDENCE')
        if path:
            with Path(path).open('a') as output:
                output.write(json.dumps({'fixture': True, **record}) + '\n')

    def exercise(self, variant, missing=False):
        captured = {'profiles': [], 'requests': [], 'cli': [], 'logs': [], 'roots': []}
        environment, trial_state, command = paired.isolated_environment, paired.trial_state, benchmark.command
        args = SimpleNamespace(timeout=120, profile_python='', lemon=str(PROJECT / 'bin/lemon'), failure_dir=None)

        def configured_environment(*positional, **keywords):
            env = environment(*positional, **keywords)
            root = Path(env['LEMON_EVAL_PROCESS_STORE']).parent
            captured['roots'].append(root)
            env['PATH'] = os.pathsep.join([*self.sdk_bins, env.get('PATH', os.defpath)])
            (root / 'offline.config').write_text('[{tzdata, [{autoupdate, disabled}]}].\n')
            env['ERL_FLAGS'] = f'+S 2:2 +SDcpu 1 +SDio 1 -config {root / "offline"}'
            env['PYTHONDONTWRITEBYTECODE'] = '1'
            env['LEMON_EVAL_USAGE_FIXTURE'] = str(SSE)
            env['LEMON_EVAL_USAGE_MODE'] = 'missing' if missing else 'complete'
            shutil.copytree(self.cache, root / 'tokenizer-cache')
            wrapper = root / 'profile-python'
            wrapper.write_text(f'#!{self.python}\n' + textwrap.dedent('''\
                import os, pathlib, runpy, socket, sys
                sys.dont_write_bytecode = True
                os.environ['TIKTOKEN_CACHE_DIR'] = str(pathlib.Path(__file__).parent / 'tokenizer-cache')
                def forbidden(*args, **kwargs):
                    raise AssertionError('offline fixture attempted network access')
                socket.socket.connect = forbidden
                socket.socket.connect_ex = forbidden
                socket.create_connection = forbidden
                socket.getaddrinfo = forbidden
                script = sys.argv.pop(1)
                sys.argv[0] = script
                runpy.run_path(script, run_name='__main__')
            '''))
            wrapper.chmod(0o700)
            args.profile_python = str(wrapper)
            return env

        @contextmanager
        def observed_state():
            with trial_state() as (root, cleanup):
                yield root, cleanup
                for filename, key in [('profile.jsonl', 'profiles'), ('offline-requests.jsonl', 'requests')]:
                    if (root / filename).exists():
                        captured[key].extend(json.loads(line) for line in (root / filename).read_text().splitlines())
                if (root / 'runtime.log').exists():
                    captured['logs'].append((root / 'runtime.log').read_text(errors='replace'))

        def observed_command(argv, *positional, **keywords):
            result = command(argv, *positional, **keywords)
            if '--output' in argv and 'json' in argv:
                data = json.loads(result.stdout)
                captured['cli'].append({key: data.get(key) for key in ('run_id', 'model', 'usage', 'metrics', 'ok')})
            return result

        case = next(case for case in benchmark.tasks() if case['name'] == 'read_and_answer')
        case = {**case, 'files': {**case['files'], 'test_ports.py':
                'import unittest\nfrom ports import port\nclass PortsTest(unittest.TestCase):\n'
                ' def test_ports(self):\n  self.assertEqual(port("production"), 7317)\n'
                '  self.assertEqual(port("staging"), 7304)\n'}}
        entry = next(row for row in paired.schedule([case], ['baseline', 'coding'], 1, 107)
                     if row['variant'] == variant)
        configuration = paired.paired_configuration(
            '[providers.zai]\napi_key = "offline-fixture-not-a-real-credential"\n', variant)
        expression = (f'Code.require_file({json.dumps(str(TRANSPORT))}); '
                      'Application.put_env(:tzdata, :autoupdate, :disabled); '
                      'LemonEvals.GlmUsageRuntimeOffline.install!(); ' + paired.RUNTIME_EXPRESSION)
        argv = paired.runtime_command(PROJECT)
        argv[-1] = expression
        argv = ['/bin/sh', '-c', 'exec "$@" > "$LEMON_EVAL_STATE/runtime.log" 2>&1', 'offline-runtime', *argv]
        with patch.object(paired, 'isolated_environment', side_effect=configured_environment), \
                patch.object(paired, 'trial_state', side_effect=observed_state), \
                patch.object(benchmark, 'command', side_effect=observed_command):
            row = paired.execute_trial(PROJECT, entry, case, configuration, 'zai:glm-5.3', {},
                                       paired.runtime_ports(), args, benchmark.run_case, paired.digest(case),
                                       runtime_argv=argv)
        diagnostic = '\n'.join(captured['logs'])
        self.assertTrue(row['passed'], (row, diagnostic))
        self.assertTrue(row['verifier_passed'], (row, diagnostic))
        self.assertTrue(row['tests_passed'], (row, diagnostic))
        self.assertEqual(row['turns'], 4, (row, diagnostic))
        self.assertTrue(row['cleanup_complete'], (row, diagnostic))
        self.assertTrue(row['disposal_complete'], (row, diagnostic))
        self.assertFalse(row['finalization_failed'], (row, diagnostic))
        self.assertTrue(all(not root.exists() for root in captured['roots']))
        self.assertEqual(len(captured['cli']), 1, diagnostic)
        cli = captured['cli'][0]
        parent = [item for item in captured['profiles'] if item.get('run_id') == cli['run_id']]
        payloads = [item for item in parent if item['event'] == 'payload']
        usages = [item for item in parent if item['event'] == 'usage']
        self.assertEqual(len(payloads), 4)
        self.assertEqual({item['request_index'] for item in payloads}, {1, 2, 3, 4})
        self.assertEqual(len({item['session_id'] for item in payloads}), 1)
        self.assertTrue(all(item['provider'] == 'zai' and item['model'] == 'glm-5.3' for item in payloads))
        receipts = [item for item in captured['requests'] if item['parent']]
        self.assertEqual([item['turn'] for item in receipts], [1, 2, 3, 4])
        self.assertEqual(row['schema_diagnostics']['requests_observed'], 4)
        self.assertEqual(row['schema_diagnostics']['applied_profiles'], ['legacy' if variant == 'baseline' else 'coding'])
        self.assertTrue(row['schema_diagnostics']['flush_complete'])
        if missing:
            self.assertEqual(usages, [])
            for key in (*COUNTERS, 'cost_usd'):
                self.assertIsNone(row[key], key)
            for key in ('totalTokens', 'inputTokens', 'cacheReadTokens', 'cacheWriteTokens', 'outputTokens', 'costUsd'):
                self.assertIsNone(cli['usage'][key], key)
            self.assertFalse(row['spend_complete'])
            self.assertFalse(row['schema_diagnostics']['parent_usage_complete'])
        else:
            self.assertEqual({key: row[key] for key in COUNTERS}, COUNTERS)
            self.assertEqual({key: cli['usage'][key] for key in (
                'totalTokens', 'inputTokens', 'cacheReadTokens', 'cacheWriteTokens', 'outputTokens')}, {
                    'totalTokens': 520, 'inputTokens': 280, 'cacheReadTokens': 80,
                    'cacheWriteTokens': 40, 'outputTokens': 120})
            self.assertEqual(len(usages), 4)
            self.assertTrue(all(item['provider_usage']['reasoning_output_tokens'] == 12 for item in usages))
            self.assertTrue(all(item['provider_usage']['total_tokens'] == 130 for item in usages))
            self.assertTrue(all(
                {key: item['provider_usage'][key] for key in (
                    'input_tokens', 'cache_read_tokens', 'cache_write_tokens', 'output_tokens')} == {
                        'input_tokens': 70, 'cache_read_tokens': 20,
                        'cache_write_tokens': 10, 'output_tokens': 30}
                for item in usages))
            self.assertAlmostEqual(row['cost_usd'], 4 * (70 * 1.4 + 20 * 0.26 + 30 * 4.4) / 1_000_000)
            self.assertAlmostEqual(cli['usage']['costUsd'], row['cost_usd'])
            self.assertTrue(row['spend_complete'])
            self.assertTrue(row['schema_diagnostics']['parent_usage_complete'])
            self.assertEqual(campaign.admission_stop(row), None)
        self.evidence({'variant': variant, 'mode': 'missing' if missing else 'complete',
                       'cli': cli, 'row': paired.sanitize_row(row), 'requests': receipts,
                       'parent_provider_usage': [item['provider_usage'] for item in usages]})
        return row, case

    def test_baseline_native_cli_paired_row_exact_fixture_counters(self):
        self.exercise('baseline')

    def test_coding_native_cli_paired_row_exact_fixture_counters(self):
        self.exercise('coding')

    def assert_durable_stop(self, row, case):
        with tempfile.TemporaryDirectory(prefix='glm-usage-stop-fixture-') as directory:
            out = Path(directory) / 'campaign'
            args = SimpleNamespace(lemon=str(PROJECT / 'bin/lemon'), compare_omp=False,
                providers='zai:glm-5.3', variants='baseline,coding', repetitions=1, seed=107,
                timeout=120, run_timeout=3600, config=None, control_plane_port=None,
                output_dir=str(out), resume=False, live=True, profile_python=str(self.python),
                profile_python_explicit=False, failure_dir=None, tasks=None, continue_after_stop=None)

            def replay(*positional, **keywords):
                return {**row, **positional[1]}

            with patch.dict(os.environ, {'ZAI_API_KEY': 'offline-fixture-not-a-real-credential'}), \
                    patch.object(paired, 'execute_trial', side_effect=replay) as admitted, \
                    redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                self.assertEqual(campaign.run_campaign(args, [case], benchmark.run_case, root=PROJECT,
                                                      runtime_argv=['offline-row-replay-only']), 1)
                self.assertEqual(admitted.call_count, 1)
                retained = (out / 'trials.jsonl').read_bytes()
                state = (out / 'campaign-state.json').read_bytes()
                saved = json.loads(retained)
                self.assertTrue(saved['passed'])
                self.assertEqual(saved['turns'], 4)
                self.assertEqual(json.loads(state)['stops'][-1]['reason'], 'missing_usage')
                self.assertEqual(json.loads(state)['continuations'], [])
                args.resume = True
                with self.assertRaisesRegex(campaign.CampaignError, 'campaign stopped: missing_usage'):
                    campaign.run_campaign(args, [case], benchmark.run_case, root=PROJECT,
                                          runtime_argv=['offline-row-replay-only'])
                self.assertEqual(admitted.call_count, 1)
                self.assertEqual((out / 'trials.jsonl').read_bytes(), retained)
                self.assertEqual((out / 'campaign-state.json').read_bytes(), state)
                self.evidence({'mode': 'durable_missing_usage_stop', 'row': saved,
                               'stop': json.loads(state)['stops'][-1], 'admissions': admitted.call_count})

    def test_missing_usage_four_successful_turns_retains_row_and_durable_stop(self):
        row, case = self.exercise('coding', missing=True)
        self.assert_durable_stop(row, case)

    def test_operator_described_fixture_copy_never_implicitly_resumes(self):
        original = OBSERVED.read_bytes()
        fixture = json.loads(original)
        self.assertTrue(fixture['fixture'])
        self.assert_durable_stop(fixture['row'], {'name': 'bug_fix', 'files': {}, 'verify': 'assert True'})
        self.assertEqual(OBSERVED.read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
