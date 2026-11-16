"""Offline adapter/statistics contracts. No Harbor installation, Docker or model."""
import importlib.util
import json
import math
import os
from pathlib import Path, PurePosixPath
import shlex
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent / 'coding_arena'))
try:
    import arena
    import bench_common as common
    import terminal_bench as terminal
finally:
    sys.path.pop(0)


class ExternalBenchStatisticsTests(unittest.TestCase):
    def test_wilson_and_exact_mcnemar_known_values(self):
        self.assertEqual(common.wilson(0, 0), [None, None])
        low, high = common.wilson(5, 10)
        self.assertAlmostEqual(low, 0.236593, places=5)
        self.assertAlmostEqual(high, 0.763407, places=5)
        self.assertAlmostEqual(common.exact_mcnemar(0, 5), 0.0625)
        self.assertAlmostEqual(common.exact_mcnemar(5, 0), 0.0625)
        self.assertEqual(common.exact_mcnemar(0, 0), 1)
        self.assertEqual(common.exact_mcnemar(10, 10), 1)
        self.assertTrue(math.isfinite(common.exact_mcnemar(500, 500)))

    def test_pairs_never_cross_model_effort_deadline_or_missing_arms(self):
        def row(agent, task, passed, **extra):
            return dict(task=task, agent=agent, model='k3.1-pro', rep=1,
                        effort='high', deadline=600, passed=passed, failure=None, **extra)
        rows = [row('lemon', 'complete', True), row('omp', 'complete', False),
                row('lemon', 'deadline', True), row('omp', 'deadline', False),
                row('lemon', 'effort', True), row('omp', 'effort', False),
                row('lemon', 'model', True), row('omp', 'model', False)]
        rows[3]['deadline'] = 300
        rows[5]['effort'] = 'low'
        rows[7]['model'] = 'glm-5.3'
        result = common.aggregate(rows)['k3.1-pro']
        self.assertEqual(result['paired']['pairs'], 1)
        self.assertEqual(result['paired']['only_lemon'], 1)
        self.assertEqual(result['paired']['unpaired_cells'], 5)
        self.assertIsNone(result['arms']['lemon']['wire_input_tokens'])
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            common.aggregate([rows[0], rows[0]])

    def test_wire_usage_does_not_fabricate_missing_or_interrupted_counters(self):
        def request(trial):
            return {'trial': trial, 'path': '/coding/v1/messages', 'status': 200, 'model': 'k3.1-pro'}
        def usage(trial, **extra):
            return {'trial': trial, 'kind': 'usage', 'path': '/coding/v1/messages',
                    'input_tokens': 20, 'output_tokens': 4, **extra}
        entries = [request('complete'), usage('complete', cache_read_tokens=7),
                   request('missing'), usage('missing', usage_missing=True),
                   request('interrupted'), request('partial'), usage('partial'), request('partial'),
                   request('cache_unknown'), usage('cache_unknown')]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'proxy.jsonl'
            path.write_text('\n'.join(json.dumps(entry) for entry in entries))
            stats = common.wire_usage(path)
            self.assertEqual(stats['complete']['wire_input_tokens'], 20)
            self.assertEqual(stats['complete']['wire_cached_tokens'], 7)
            self.assertEqual(stats['complete']['wire_output_tokens'], 4)
            for trial in ('missing', 'interrupted', 'partial'):
                self.assertIsNone(stats[trial]['wire_input_tokens'])
                self.assertFalse(stats[trial]['wire_usage_complete'])
            self.assertIsNone(stats['cache_unknown']['wire_cached_tokens'])
            with path.open('a') as source:
                source.write('\n{"torn":')
            with self.assertRaises(ValueError):
                common.wire_usage(path)

    def test_plain_lemon_json_uses_terminal_metrics_without_invented_tool_calls(self):
        result = common.metrics('lemon', json.dumps({'type': 'result', 'ok': True,
                                                    'usage': {'turns': 3, 'tool_errors': 2}}))
        self.assertEqual(result['turns'], 3)
        self.assertEqual(result['tool_errors'], 2)
        self.assertIsNone(result['tool_calls'])
        self.assertIsNone(common.metrics('lemon', '{}')['tool_errors'])

    def test_commands_pin_model_effort_and_deadline_without_shell_interpolation(self):
        prompt = "do not execute: $(touch /bad); 'quoted'"
        for model, spec in arena.MODELS.items():
            lemon = common.command('lemon', prompt, model, 'high', 321, '.')
            omp = common.command('omp', prompt, model, 'high', 321, '.')
            self.assertEqual(lemon[lemon.index('--output') + 1], 'json')
            self.assertEqual(lemon[lemon.index('--model') + 1], f"{spec['lemon_provider']}:{model}")
            self.assertEqual(omp[omp.index('--model') + 1], f"{spec['omp_provider']}/{model}")
            self.assertEqual(omp[omp.index('--thinking') + 1], 'high')
            for argv in (lemon, omp):
                self.assertEqual(argv[2], prompt)
                self.assertEqual(argv[argv.index('--max-time') + 1], '321')
                self.assertEqual(shlex.split(shlex.join(argv)), argv)
            files, environment = common.configuration('lemon', model, 'high', 'http://proxy:18787', 'trial-token')
            self.assertIn('thinking_level = "high"', next(iter(files.values())))
            self.assertEqual(environment[spec['lemon_env']], 'trial-token')
            self.assertNotIn('ARENA_PROXY_SECRET', environment)


class HarborResultParsingTests(unittest.TestCase):
    def document(self, arm='lemon', passed=True):
        return {'task_name': 'task-a', 'config': {'agent': {
            'import_path': f'harbor_adapter:Harbor{arm.title()}', 'model_name': 'k3.1-pro',
            'kwargs': {'effort': 'high', 'deadline': 600}}},
            'verifier_result': {'rewards': {'reward': int(passed)}},
            'agent_execution': {'started_at': '2026-11-14T00:00:00+00:00',
                                'finished_at': '2026-11-14T00:00:07+00:00'}}

    def test_harbor_verifier_and_timing_not_agent_self_report_determine_outcome(self):
        doc = self.document()
        row = terminal.harbor_row(doc, {'turns': 4, 'tool_errors': 1}, 2)
        self.assertTrue(row['passed'])
        self.assertEqual(row['wall_seconds'], 7)
        self.assertEqual(row['rep'], 2)
        doc['exception_info'] = {'exception_type': 'TimeoutError'}
        self.assertFalse(terminal.harbor_row(doc, {}, 2)['passed'])
        del doc['exception_info']
        doc['verifier_result'] = None
        self.assertFalse(terminal.harbor_row(doc, {}, 2)['passed'])

    def test_report_collects_real_trial_layout_and_wire_usage(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            (out / 'manifest.json').write_text(json.dumps({'identity': {'revision': 'fixture'},
                'jobs': [{'name': 'one', 'rep': 1}]}))
            for arm, passed in [('lemon', True), ('omp', False)]:
                trial = out / 'jobs' / 'one' / arm
                (trial / 'agent').mkdir(parents=True)
                (trial / 'result.json').write_text(json.dumps(self.document(arm, passed)))
                (trial / 'agent' / 'arena.json').write_text(json.dumps({'agent': arm,
                    'proxy_trial': arm, 'turns': 2, 'tool_errors': 1}))
            result = terminal.report(out, out / 'absent-proxy-log')
            self.assertEqual(result['models']['k3.1-pro']['paired']['only_lemon'], 1)
            self.assertIsNone(result['models']['k3.1-pro']['arms']['lemon']['wire_input_tokens'])
            self.assertTrue((out / 'report.md').is_file())

    def test_job_config_has_identical_settings_and_no_credential_forwarding(self):
        args = types.SimpleNamespace(lemon_bundle='/tmp/lemon.tar.gz', omp_bundle='/tmp/omp.tar.gz',
            lemon_revision='lemon-sha', omp_revision='omp-sha', deadline=300, effort='medium',
            proxy_url='http://proxy:18787', dataset='terminal-bench@2.0', tasks='a,b',
            max_tasks=2, keep_containers=False)
        config = terminal.job_config(args, 'glm-5.3', 2, Path('/tmp/out'))
        self.assertEqual(config['retry']['max_retries'], 0)
        self.assertEqual(config['n_attempts'], 1)
        for agent in config['agents']:
            self.assertNotIn('env', agent)
            self.assertEqual(agent['kwargs']['deadline'], 300)
            self.assertEqual(agent['kwargs']['effort'], 'medium')
            self.assertEqual(agent['model_name'], 'glm-5.3')
        self.assertEqual(config['datasets'][0]['n_tasks'], 2)
        self.assertTrue(config['environment']['delete'])
        self.assertFalse(config['environment']['kwargs']['keep_containers'])
        args.keep_containers = True
        retained = terminal.job_config(args, 'glm-5.3', 2, Path('/tmp/out'))
        self.assertFalse(retained['environment']['delete'])
        self.assertTrue(retained['environment']['kwargs']['keep_containers'])

    def test_artifact_paths_must_be_outside_checkout(self):
        with self.assertRaises(ValueError):
            terminal.external_directory(Path(__file__).parent / 'private-results')
        self.assertEqual(terminal.external_directory('/tmp/out'), Path('/tmp/out').resolve())


class HarborInstalledAdapterTests(unittest.IsolatedAsyncioTestCase):
    async def test_installed_adapter_never_forwards_host_credentials_or_proxy_signing_secret(self):
        class FakeInstalledBase:
            def __init__(self, logs_dir, model_name, **kwargs):
                self.logs_dir, self.model_name = logs_dir, model_name
                self.environment_logs_dir = PurePosixPath('/logs/agent')
                self.calls, self.files = [], {}

            async def exec_as_agent(self, environment, **kwargs):
                self.calls.append(kwargs)
                return types.SimpleNamespace(return_code=0)

            async def _upload_config_text(self, environment, **kwargs):
                self.files[kwargs['remote_path']] = kwargs['content']

        modules = {name: types.ModuleType(name) for name in
                   ('harbor', 'harbor.agents', 'harbor.agents.installed', 'harbor.agents.installed.base')}
        modules['harbor.agents.installed.base'].BaseInstalledAgent = FakeInstalledBase
        spec = importlib.util.spec_from_file_location('offline_harbor_adapter', Path(__file__).parent / 'coding_arena/harbor_adapter.py')
        module = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, modules), patch.dict(os.environ,
                {'ARENA_PROXY_SECRET': 'host-signing-secret', 'KIMI_API_KEY': 'REAL-DO-NOT-FORWARD'}):
            spec.loader.exec_module(module)
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                bundle = root / 'bundle.tar.gz'
                bundle.write_bytes(b'fixture bundle bytes')
                adapter = module.HarborLemon(root / 'logs', model_name='k3.1-pro', agent_bundle=bundle,
                    agent_revision='fixture-sha', proxy_url='http://proxy:18787', deadline=123)
                config_files = dict(adapter._arena_config_files)
                await adapter.configure(None)
                self.assertEqual(adapter._arena_config_files, config_files)
                self.assertIsNot(adapter._arena_config_files, adapter.files)
                self.assertEqual(adapter.files, {
                    f'{common.HOME}/{relative}': content for relative, content in config_files.items()})
                commands = []

                class Environment:
                    async def exec(self, **kwargs):
                        commands.append(kwargs)
                        (adapter.logs_dir / 'agent.stdout').write_text(json.dumps({
                            'type': 'result', 'ok': True, 'answer': adapter.token,
                            'usage': {'turns': 3, 'tool_errors': 1}}))
                        return types.SimpleNamespace(return_code=0)

                context = types.SimpleNamespace(metadata=None)
                await adapter.run("a 'quoted' prompt", Environment(), context)
                retained = json.dumps(adapter.calls + commands) + json.dumps(adapter.files)
                self.assertNotIn('host-signing-secret', retained)
                self.assertNotIn('REAL-DO-NOT-FORWARD', retained)
                self.assertIn('env -i', retained)
                self.assertIn('--output json', retained)
                self.assertIn('--max-time 123', retained)
                self.assertIn('lemon daemon', retained)
                self.assertEqual(context.metadata['deadline'], 123)
                self.assertNotIn(adapter.token, json.dumps(context.metadata))
                self.assertEqual(context.metadata['turns'], 3)
                self.assertEqual(context.metadata['tool_errors'], 1)
                self.assertNotIn(adapter.token, (adapter.logs_dir / 'agent.stdout').read_text())
                with self.assertRaisesRegex(ValueError, 'extra_env'):
                    module.HarborLemon(root, model_name='k3.1-pro', agent_bundle=bundle,
                        agent_revision='fixture', proxy_url='http://proxy:18787', extra_env={'KIMI_API_KEY': 'real'})


if __name__ == '__main__':
    unittest.main()
