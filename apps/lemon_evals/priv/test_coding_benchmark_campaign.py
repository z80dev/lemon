"""Offline contracts for the resumable multi-provider paired campaign. No network or paid calls:
trials run against a local fake runtime and a scripted client; prices come from catalog files."""
import contextlib
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import textwrap
import unittest
from collections import Counter, defaultdict
from types import SimpleNamespace
from unittest.mock import patch

import coding_benchmark as benchmark
import coding_benchmark_campaign as campaign
import coding_benchmark_paired as paired
import coding_benchmark_pricing as pricing

ROOT = Path(benchmark.__file__).resolve().parents[3]
SECRET = 'private-prompt-answer-and-workspace-text'
IDENTITY = {'revision': 'a' * 40, 'source_digest': 'b' * 64, 'dirty': False, 'build_files': [],
            'compiled_build_digest': 'c' * 64}

FAKE_RUNTIME = textwrap.dedent('''\
    import http.server, json, os, pathlib, threading, time
    state = pathlib.Path(os.environ['LEMON_EVAL_STATE'])

    class Health(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"ok": true}')
        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', int(os.environ['LEMON_CONTROL_PLANE_PORT'])), Health)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    profile = os.environ['LEMON_TOOL_DISCLOSURE_PROFILE']
    pathlib.Path(os.environ['LEMON_EVAL_PROFILE']).write_text(
        json.dumps({'event': 'disclosure_applied', 'profile': profile, 'active': True}) + '\\n')
    pathlib.Path(os.environ['LEMON_EVAL_METADATA']).write_text(
        json.dumps({'elixir': '1.19.5', 'otp': '28', 'pricing_catalog_digest': 'd' * 64}))
    while True:
        if (state / 'flush.request').exists():
            (state / 'flush.done').write_text('ok')
        time.sleep(0.02)
''')


def free_port():
    return paired.runtime_ports()[0]


def namespace(out, **overrides):
    values = dict(lemon=str(ROOT / 'bin' / 'lemon'), compare_omp=False, providers=campaign.DEFAULT_PROVIDERS,
                  variants='baseline,coding', repetitions=1, seed=107, timeout=20, config=None,
                  control_plane_port=None, output_dir=str(out), resume=False, live=True,
                  profile_python=sys.executable, profile_python_explicit=False, failure_dir=None, tasks=None)
    values.update(overrides)
    return SimpleNamespace(**values)


def cases():
    return [{'name': name, 'prompt': SECRET, 'files': {'f.txt': SECRET}, 'verify': 'assert True'}
            for name in ('bug_fix', 'read_and_answer')]


def counters(uncached=100, cached=900, write=0, output=50, **extra):
    return {'uncached_input_tokens': uncached, 'cached_input_tokens': cached, 'cache_write_tokens': write,
            'output_tokens': output, 'tokens': None if None in (uncached, cached, write, output) else uncached + cached + write + output,
            'turns': 3, 'tool_errors': 0, 'cost_usd': 0.01, **extra}


def client_row(case, passed=True, failure=None, **measurements):
    return {'task': case['name'], 'agent': 'lemon', 'passed': passed, 'failure': failure,
            'verifier_passed': passed, 'tests_passed': None, 'wall_seconds': 1.5, 'run_id': 'private-run-id',
            'answer': SECRET, 'prompt': SECRET, **(counters() if not measurements else measurements)}


class Harness:
    """Scripted client that records what each trial's isolated environment looked like."""

    def __init__(self, script=None, interrupt_after=None):
        self.script = script or (lambda entry_id: {})
        self.interrupt_after = interrupt_after
        self.calls, self.snapshots = [], []

    def __call__(self, case, agent, executable, model, args):
        if self.interrupt_after is not None and len(self.calls) >= self.interrupt_after:
            raise KeyboardInterrupt
        env = args.environment
        home = Path(env['HOME'])
        self.snapshots.append({
            'trial_id': args.trial_id, 'model': model, 'home': env['HOME'], 'store': env['LEMON_STORE_PATH'],
            'token': env['LEMON_CONTROL_PLANE_OPERATOR_TOKEN'], 'master': env['LEMON_SECRETS_MASTER_KEY'],
            'port': env['LEMON_CONTROL_PLANE_PORT'], 'profile': env['LEMON_TOOL_DISCLOSURE_PROFILE'],
            'credential_keys': sorted(key for key in env if key.endswith(('API_KEY', 'ACCESS_TOKEN', 'AUTH_TOKEN'))),
            'config': (home / '.lemon' / 'config.toml').read_text(),
            'prior_marker': (home / 'marker').exists()})
        (home / 'marker').write_text('trial-local state')
        self.calls.append(args.trial_id)
        spec = dict(self.script(args.trial_id))
        mode = spec.pop('mode', 'pass')
        if mode == 'timeout':
            return {**paired.failed_row({'task': case['name']}, 'timeout'), 'agent': 'lemon'}
        if mode == 'fail':
            return client_row(case, False, 'verifier_failed', **spec)
        return client_row(case, True, None, **spec)


def terminate_fixture_runtime(process, **_kwargs):
    """The local Python adapter admits no tracked native commands."""
    paired.terminate_runtime_group(process)
    return True


class Fixture(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='lemon-campaign-offline-')
        self.addCleanup(self.directory.cleanup)
        self.out = Path(self.directory.name) / 'campaign'
        self.runtime = Path(self.directory.name) / 'fake_runtime.py'
        self.runtime.write_text(FAKE_RUNTIME)
        for patcher in (patch.object(paired, 'source_identity', return_value=dict(IDENTITY)),
                        patch.object(paired, 'terminate', side_effect=terminate_fixture_runtime),
                        patch.dict(os.environ, {'OPENAI_CODEX_API_KEY': 'codex-offline-secret',
                                                'ZAI_API_KEY': 'zai-offline-secret',
                                                'OPENAI_API_KEY': 'unrelated-ambient-secret'})):
            patcher.start()
            self.addCleanup(patcher.stop)

    def run_campaign(self, harness, **overrides):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return campaign.run_campaign(namespace(self.out, **overrides), cases(), harness, root=ROOT,
                                         runtime_argv=[sys.executable, str(self.runtime)])

    def report(self):
        return json.loads((self.out / 'report.json').read_text())

    def trial_rows(self):
        return [json.loads(line) for line in (self.out / 'trials.jsonl').read_text().splitlines()]


class ScheduleTests(unittest.TestCase):
    def test_twelve_tasks_two_variants_three_repeats_two_providers_is_144_stable_unique_trials(self):
        providers = campaign.parse_providers(campaign.DEFAULT_PROVIDERS)
        real = benchmark.tasks()
        self.assertEqual(len(real), 12)
        entries = campaign.campaign_schedule(providers, real, ['baseline', 'coding'], 3, 107)
        self.assertEqual(len(entries), 144)
        self.assertEqual(entries, campaign.campaign_schedule(providers, real, ['baseline', 'coding'], 3, 107))
        self.assertEqual(len({entry['trial_id'] for entry in entries}), 144)
        self.assertEqual(len({entry['pair_id'] for entry in entries}), 72)
        self.assertEqual({entry['provider'] for entry in entries}, {'openai-codex', 'zai'})
        for entry in entries:
            self.assertRegex(entry['trial_id'], r'^[A-Za-z0-9_:-]{1,180}$')
            self.assertEqual(entry['trial_id'], f'{entry["pair_id"]}:{entry["variant"]}')
            self.assertTrue(entry['pair_id'].startswith(f'{entry["provider"]}:{entry["task"]}:pair:'))

    def test_each_pair_has_both_variants_and_position_is_counterbalanced(self):
        providers = campaign.parse_providers(campaign.DEFAULT_PROVIDERS)
        entries = campaign.campaign_schedule(providers, cases(), ['baseline', 'coding'], 4, 5)
        positions = defaultdict(Counter)
        for start in range(0, len(entries), 2):
            pair = entries[start:start + 2]
            self.assertEqual(len({entry['pair_id'] for entry in pair}), 1)
            self.assertEqual({entry['variant'] for entry in pair}, {'baseline', 'coding'})
            self.assertEqual([entry['order'] for entry in pair], [1, 2])
            for position, entry in enumerate(pair):
                positions[(entry['provider'], entry['task'], entry['variant'])][position] += 1
        self.assertEqual(len(positions), 8)
        for counts in positions.values():
            self.assertEqual(counts, Counter({0: 2, 1: 2}))

    def test_provider_and_variant_options_reject_unsupported_values(self):
        for value in ['', 'openai-codex', 'openai:gpt-6.1-sol', 'zai:glm-5.3,zai:glm-5.3', 'anthropic:claude']:
            with self.subTest(value=value), self.assertRaises(campaign.CampaignError):
                campaign.parse_providers(value)
        for value in ['baseline', 'coding', 'baseline,baseline', 'baseline,coding_budget_500', 'coding,other']:
            with self.subTest(value=value), self.assertRaises(campaign.CampaignError):
                campaign.parse_variants(value)
        self.assertEqual(campaign.parse_variants('coding,baseline'), ['coding', 'baseline'])


class PricingTests(unittest.TestCase):
    def catalog_root(self, directory, **prices):
        models = Path(directory) / pricing.CATALOG_DIRECTORY
        models.mkdir(parents=True)
        cost = {'input': 1, 'output': 8, 'cache_read': 0.5, 'cache_write': 2, **prices}
        (models / 'open_ai.json').write_text(json.dumps({'m': {'id': 'm', 'provider': 'openai', 'cost': cost}}))
        return Path(directory)

    def test_equivalent_spend_multiplies_every_counter_by_its_list_price(self):
        with tempfile.TemporaryDirectory() as directory:
            basis = pricing.pricing_basis('openai-codex', 'm', self.catalog_root(directory))
        row = {'uncached_input_tokens': 1_000_000, 'cached_input_tokens': 2_000_000,
               'cache_write_tokens': 500_000, 'output_tokens': 250_000}
        self.assertEqual(pricing.equivalent_spend(row, basis), (1 + 1 + 1 + 2, 'priced'))
        self.assertEqual(basis['label'], 'list-price equivalent, not billed')
        self.assertEqual(basis['unit'], 'USD per 1,000,000 tokens')
        self.assertEqual(basis['prices'], {'input': 1, 'cache_read': 0.5, 'cache_write': 2, 'output': 8})
        self.assertEqual(basis['catalog_file'], 'apps/lemon_ai/priv/models/open_ai.json')
        self.assertRegex(basis['catalog_sha256'], r'^[0-9a-f]{64}$')

    def test_missing_or_invalid_counters_are_unpriced_never_zero(self):
        with tempfile.TemporaryDirectory() as directory:
            basis = pricing.pricing_basis('openai-codex', 'm', self.catalog_root(directory))
        full = {'uncached_input_tokens': 10, 'cached_input_tokens': 0, 'cache_write_tokens': 0, 'output_tokens': 1}
        self.assertEqual(pricing.equivalent_spend(full, basis)[1], 'priced')
        for key in full:
            for bad in (None, -1, True, float('nan'), '7'):
                with self.subTest(key=key, bad=bad):
                    self.assertEqual(pricing.equivalent_spend({**full, key: bad}, basis), (None, 'missing_counters'))
            absent = dict(full)
            del absent[key]
            self.assertEqual(pricing.equivalent_spend(absent, basis), (None, 'missing_counters'))

    def test_incomplete_catalog_entries_and_unknown_models_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.catalog_root(directory, cache_read=None)
            with self.assertRaises(ValueError):
                pricing.pricing_basis('openai-codex', 'm', root)
            with self.assertRaises(ValueError):
                pricing.pricing_basis('openai-codex', 'absent', root)
        with self.assertRaises(ValueError):
            pricing.pricing_basis('anthropic', 'm', ROOT)

    def test_codex_uses_openai_api_list_price_and_glm_uses_zai_catalog(self):
        for provider, model, catalog, catalog_provider in [
            ('openai-codex', 'gpt-6.1-sol', 'open_ai.json', 'openai'), ('zai', 'glm-5.3', 'zai.json', 'zai')]:
            with self.subTest(provider=provider):
                basis = pricing.pricing_basis(provider, model, ROOT)
                path = ROOT / 'apps' / 'lemon_ai' / 'priv' / 'models' / catalog
                entry = json.loads(path.read_text())[model]
                self.assertEqual(entry['provider'], catalog_provider)
                self.assertEqual(basis['catalog_file'], f'apps/lemon_ai/priv/models/{catalog}')
                self.assertEqual(basis['catalog_provider'], catalog_provider)
                self.assertEqual(basis['prices'], {name: entry['cost'][name]
                                                   for name in ('input', 'cache_read', 'cache_write', 'output')})
                self.assertEqual(basis['label'], 'list-price equivalent, not billed')
                self.assertIn('list price', basis['basis'])

    def test_variant_spend_covers_failures_and_is_undefined_at_zero_successes(self):
        def trial(passed, spend):
            return {'attempted': True, 'passed': passed, 'equivalent_spend_usd': spend}

        zero = pricing.summarize_spend([trial(False, 1.5), trial(False, 0.5)])
        self.assertEqual(zero['total_usd'], 2.0)
        self.assertIsNone(zero['per_verified_success_usd'])
        self.assertEqual(zero['per_verified_success_status'], 'undefined_zero_successes')
        unpriced_zero = pricing.summarize_spend([trial(False, None)])
        self.assertEqual(unpriced_zero['per_verified_success_status'], 'undefined_zero_successes')
        self.assertIsNone(unpriced_zero['per_verified_success_usd'])
        complete = pricing.summarize_spend([trial(True, 1.0), trial(False, 3.0)])
        self.assertEqual((complete['total_usd'], complete['per_verified_success_usd']), (4.0, 4.0))
        self.assertEqual(complete['per_verified_success_status'], 'complete')
        partial = pricing.summarize_spend([trial(True, 1.0), trial(False, None), trial(True, 2.0)])
        self.assertIsNone(partial['total_usd'])
        self.assertEqual(partial['observed_total_usd'], 3.0)
        self.assertIsNone(partial['per_verified_success_usd'])
        self.assertEqual(partial['per_verified_success_status'], 'incomplete_missing_counters')
        self.assertEqual((partial['trials_priced'], partial['trials_unpriced']), (2, 1))
        self.assertEqual(partial['label'], 'list-price equivalent, not billed')
        unattempted = pricing.summarize_spend([{'attempted': False, 'passed': False}])
        self.assertEqual(unattempted['trials_priced'] + unattempted['trials_unpriced'], 0)


class CampaignRunTests(Fixture):
    def assert_safety_stop(self, reason, patcher):
        harness = Harness(lambda _trial_id: {'mode': 'fail'})
        with patch.object(paired.tempfile, 'tempdir', self.directory.name), patcher:
            self.assertEqual(self.run_campaign(harness), 1)
        self.assertEqual(len(harness.calls), 1)
        rows = self.trial_rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['failure'], 'verifier_failed')
        self.assertEqual(rows[0]['cost_usd'], 0.01)
        self.assertEqual(rows[0]['uncached_input_tokens'], 100)
        self.assertEqual(paired.teardown_failure(rows[0]), reason)
        self.assertFalse(self.report()['complete'])
        self.assertTrue(list(Path(self.directory.name).glob('lemon-paired-runtime-*')))
        resumed = Harness()
        with self.assertRaisesRegex(campaign.CampaignError, 'independent recovery'):
            self.run_campaign(resumed, resume=True)
        self.assertEqual(resumed.calls, [])

    def test_cleanup_failure_records_paid_row_and_halts_campaign_and_resume(self):
        def unverified(process, **kwargs):
            terminate_fixture_runtime(process, **kwargs)
            return False
        self.assert_safety_stop(
            'cleanup_unverified', patch.object(paired, 'terminate', side_effect=unverified))

    def test_interrupt_with_failed_recovery_persists_paid_row_and_blocks_resume(self):
        harness = Harness(lambda _trial_id: {'mode': 'fail'})

        def unverified(process, **kwargs):
            terminate_fixture_runtime(process, **kwargs)
            return False
        trial_file = paired.trial_file

        def interrupt_metadata(state, root_fd, name, *args, **kwargs):
            if name == 'runtime.json':
                raise KeyboardInterrupt
            return trial_file(state, root_fd, name, *args, **kwargs)

        # Interrupt after run_case has returned its paid counters.
        with patch.object(paired.tempfile, 'tempdir', self.directory.name), \
                patch.object(paired, 'terminate', side_effect=unverified), \
                patch.object(paired, 'trial_file', interrupt_metadata):
            self.assertEqual(self.run_campaign(harness), 130)
        rows = self.trial_rows()
        self.assertEqual(len(rows), 1)
        self.assertFalse(rows[0]['cleanup_complete'])
        self.assertEqual(rows[0]['cost_usd'], 0.01)
        self.assertEqual(rows[0]['uncached_input_tokens'], 100)
        self.assertEqual(rows[0]['failure'], 'verifier_failed')
        self.assertFalse(rows[0]['disposal_complete'])
        self.assertTrue(list(Path(self.directory.name).glob('lemon-paired-runtime-*')))
        resumed = Harness()
        with self.assertRaisesRegex(campaign.CampaignError, 'independent recovery'):
            self.run_campaign(resumed, resume=True)
        self.assertEqual(resumed.calls, [])

    def test_disposal_failure_records_paid_row_and_halts_campaign_and_resume(self):
        self.assert_safety_stop(
            'disposal_unverified', patch.object(paired, 'dispose_trial_state', side_effect=PermissionError('offline')))

    def test_disposal_interrupt_persists_paid_row_and_blocks_resume(self):
        harness = Harness(lambda _trial_id: {'mode': 'fail'})
        with patch.object(paired.tempfile, 'tempdir', self.directory.name), \
                patch.object(paired, 'dispose_trial_state', side_effect=KeyboardInterrupt):
            self.assertEqual(self.run_campaign(harness), 130)
        self.assertEqual(len(harness.calls), 1)
        rows = self.trial_rows()
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertTrue(row['attempted'])
        self.assertEqual(row['failure'], 'verifier_failed')
        for key, value in counters().items():
            self.assertEqual(row[key], value)
        self.assertTrue(row['cleanup_complete'])
        self.assertFalse(row['disposal_complete'])
        self.assertEqual(paired.teardown_failure(row), 'disposal_unverified')
        self.assertFalse(self.report()['complete'])
        self.assertEqual(self.report()['progress']['recorded_trials'], 1)
        self.assertTrue(list(Path(self.directory.name).glob('lemon-paired-runtime-*')))
        resumed = Harness()
        with self.assertRaisesRegex(campaign.CampaignError, 'independent recovery'):
            self.run_campaign(resumed, resume=True)
        self.assertEqual(resumed.calls, [])

    def test_final_row_metadata_interrupt_persists_paid_row_and_blocks_resume(self):
        harness = Harness(lambda _trial_id: {'mode': 'fail'})
        digest = paired.digest
        interrupted = []

        def interrupt_configuration_digest(value):
            if harness.calls and isinstance(value, str) and not interrupted:
                interrupted.append(True)
                raise KeyboardInterrupt
            return digest(value)

        with patch.object(paired, 'digest', side_effect=interrupt_configuration_digest):
            self.assertEqual(self.run_campaign(harness), 130)
        self.assertEqual(interrupted, [True])
        self.assertEqual(len(harness.calls), 1)
        rows = self.trial_rows()
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertTrue(row['attempted'])
        self.assertTrue(row['finalization_failed'])
        self.assertFalse(row['spend_complete'])
        self.assertEqual(row['failure'], 'verifier_failed')
        for key, value in counters().items():
            self.assertEqual(row[key], value)
        self.assertEqual(paired.teardown_failure(row), 'finalization_failed')
        self.assertFalse(self.report()['complete'])
        self.assertEqual(self.report()['progress']['recorded_trials'], 1)
        resumed = Harness()
        with self.assertRaisesRegex(campaign.CampaignError, 'independent recovery'):
            self.run_campaign(resumed, resume=True)
        self.assertEqual(resumed.calls, [])

    def test_post_trial_interrupt_persists_paid_row_before_propagation(self):
        for owner, name in ((pricing, 'equivalent_spend'), (paired, 'sanitize_row')):
            with self.subTest(stage=name):
                self.out = Path(self.directory.name) / name
                original = getattr(owner, name)
                calls = []

                def interrupt_once(*args, **kwargs):
                    calls.append(True)
                    if len(calls) == 1:
                        raise KeyboardInterrupt
                    return original(*args, **kwargs)

                harness = Harness(lambda _trial_id: {'mode': 'fail'})
                with patch.object(owner, name, side_effect=interrupt_once):
                    self.assertEqual(self.run_campaign(harness), 130)
                self.assertEqual(len(harness.calls), 1)
                rows = self.trial_rows()
                self.assertEqual(len(rows), 1)
                self.assertTrue(rows[0]['attempted'])
                self.assertTrue(rows[0]['finalization_failed'])
                self.assertEqual(rows[0]['failure'], 'verifier_failed')
                self.assertEqual(rows[0]['cost_usd'], 0.01)
                self.assertEqual(rows[0]['uncached_input_tokens'], 100)
                self.assertEqual(self.report()['progress']['recorded_trials'], 1)
                resumed = Harness()
                with self.assertRaisesRegex(campaign.CampaignError, 'independent recovery'):
                    self.run_campaign(resumed, resume=True)
                self.assertEqual(resumed.calls, [])

    def test_interrupted_append_reconciles_missing_partial_and_complete_row(self):
        append_trial = campaign.append_trial
        for stage in ('before', 'partial', 'complete'):
            with self.subTest(stage=stage):
                self.out = Path(self.directory.name) / stage
                calls = []

                def interrupt_once(path, row):
                    calls.append(True)
                    if len(calls) == 1:
                        if stage == 'partial':
                            with open(path, 'a') as handle:
                                handle.write('{"trial_id":')
                        elif stage == 'complete':
                            append_trial(path, row)
                        raise KeyboardInterrupt
                    return append_trial(path, row)

                harness = Harness(lambda _trial_id: {'mode': 'fail'})
                with patch.object(campaign, 'append_trial', side_effect=interrupt_once):
                    self.assertEqual(self.run_campaign(harness), 130)
                self.assertEqual(len(harness.calls), 1)
                rows = self.trial_rows()
                self.assertEqual(len(rows), 1)
                self.assertTrue(rows[0]['attempted'])
                self.assertEqual(rows[0]['failure'], 'verifier_failed')
                self.assertEqual(rows[0]['cost_usd'], 0.01)
                self.assertEqual(rows[0]['uncached_input_tokens'], 100)
                self.assertEqual(self.report()['progress']['recorded_trials'], 1)

    def test_append_interrupt_takes_precedence_over_finalization_error(self):
        harness = Harness(lambda _trial_id: {'mode': 'fail'})
        append_trial = campaign.append_trial
        calls = []

        def interrupt_once(path, row):
            calls.append(True)
            if len(calls) == 1:
                raise KeyboardInterrupt
            return append_trial(path, row)

        with patch.object(pricing, 'equivalent_spend', side_effect=ValueError('offline')), \
                patch.object(campaign, 'append_trial', side_effect=interrupt_once):
            self.assertEqual(self.run_campaign(harness), 130)
        self.assertEqual(len(calls), 2)
        self.assertEqual(len(harness.calls), 1)
        rows = self.trial_rows()
        self.assertEqual(len(rows), 1)
        self.assertTrue(rows[0]['attempted'])
        self.assertTrue(rows[0]['finalization_failed'])
        self.assertFalse(rows[0]['spend_complete'])
        self.assertEqual(rows[0]['failure'], 'verifier_failed')
        for key, value in counters().items():
            self.assertEqual(rows[0][key], value)
        self.assertFalse(self.report()['complete'])
        self.assertEqual(self.report()['progress']['recorded_trials'], 1)

    def test_trial_interrupt_takes_precedence_over_persistence_error(self):
        harness = Harness(lambda _trial_id: {'mode': 'fail'})
        with patch.object(paired.tempfile, 'tempdir', self.directory.name), \
                patch.object(paired, 'dispose_trial_state', side_effect=KeyboardInterrupt), \
                patch.object(pricing, 'equivalent_spend', side_effect=ValueError('offline')):
            self.assertEqual(self.run_campaign(harness), 130)
        self.assertEqual(len(harness.calls), 1)
        rows = self.trial_rows()
        self.assertEqual(len(rows), 1)
        self.assertTrue(rows[0]['attempted'])
        self.assertTrue(rows[0]['finalization_failed'])
        self.assertFalse(rows[0]['spend_complete'])
        self.assertTrue(rows[0]['cleanup_complete'])
        self.assertFalse(rows[0]['disposal_complete'])
        self.assertEqual(rows[0]['failure'], 'verifier_failed')
        for key, value in counters().items():
            self.assertEqual(rows[0][key], value)
        self.assertFalse(self.report()['complete'])
        self.assertEqual(self.report()['progress']['recorded_trials'], 1)

    def test_post_trial_base_exception_preserves_row_before_reraising(self):
        harness = Harness(lambda _trial_id: {'mode': 'fail'})
        with patch.object(pricing, 'equivalent_spend', side_effect=SystemExit(17)), \
                self.assertRaises(SystemExit) as raised:
            self.run_campaign(harness)
        self.assertEqual(raised.exception.code, 17)
        self.assertEqual(len(harness.calls), 1)
        rows = self.trial_rows()
        self.assertEqual(len(rows), 1)
        self.assertTrue(rows[0]['attempted'])
        self.assertTrue(rows[0]['finalization_failed'])
        self.assertEqual(rows[0]['failure'], 'verifier_failed')
        self.assertEqual(rows[0]['cost_usd'], 0.01)
        self.assertEqual(rows[0]['uncached_input_tokens'], 100)
        resumed = Harness()
        with self.assertRaisesRegex(campaign.CampaignError, 'independent recovery'):
            self.run_campaign(resumed, resume=True)
        self.assertEqual(resumed.calls, [])

    def test_report_interrupt_rebuilds_from_persisted_trial(self):
        write_outputs = campaign.write_outputs
        calls = []

        def interrupt_once(*args, **kwargs):
            calls.append(True)
            if len(calls) == 1:
                raise KeyboardInterrupt
            return write_outputs(*args, **kwargs)

        harness = Harness(lambda _trial_id: {'mode': 'fail'})
        with patch.object(campaign, 'write_outputs', side_effect=interrupt_once):
            self.assertEqual(self.run_campaign(harness), 130)
        self.assertEqual(len(harness.calls), 1)
        self.assertEqual(len(self.trial_rows()), 1)
        self.assertEqual(self.report()['results'], self.trial_rows())
        self.assertEqual(self.report()['progress']['recorded_trials'], 1)

    def test_finalization_failure_records_paid_row_and_halts_campaign_and_resume(self):
        self.assert_safety_stop(
            'finalization_failed', patch.object(paired, 'collect_profile', side_effect=OSError('offline')))

    def script(self, trial_id):
        if trial_id.endswith('bug_fix:pair:0001:baseline') and trial_id.startswith('zai'):
            return {'mode': 'timeout'}
        if trial_id.startswith('openai-codex:read_and_answer') and trial_id.endswith(':coding'):
            return {'mode': 'fail'}
        if trial_id.startswith('zai:read_and_answer') and trial_id.endswith(':baseline'):
            return counters(uncached=None)
        return {}

    def test_full_campaign_retains_failures_and_nulls_with_equivalent_spend_and_basis(self):
        harness = Harness(self.script)
        self.assertEqual(self.run_campaign(harness), 0)
        report = self.report()
        self.assertTrue(report['complete'])
        self.assertEqual(report['progress'], {'scheduled_trials': 8, 'recorded_trials': 8})
        rows = {row['trial_id']: row for row in report['results']}
        self.assertEqual(set(rows), set(harness.calls))
        for row in rows.values():
            self.assertTrue(row['attempted'])
            self.assertIn(row['provider'], ('openai-codex', 'zai'))
            self.assertTrue(row['pair_id'].startswith(f'{row["provider"]}:{row["task"]}:pair:'))
        timeout = rows['zai:bug_fix:pair:0001:baseline']
        self.assertEqual((timeout['passed'], timeout['failure']), (False, 'timeout'))
        for key in ('turns', 'tokens', 'uncached_input_tokens', 'cached_input_tokens', 'output_tokens'):
            self.assertIsNone(timeout[key])
        self.assertIsNone(timeout['equivalent_spend_usd'])
        self.assertEqual(timeout['equivalent_spend_status'], 'missing_counters')
        failed = rows['openai-codex:read_and_answer:pair:0001:coding']
        self.assertEqual((failed['passed'], failed['failure']), (False, 'verifier_failed'))
        self.assertEqual(failed['equivalent_spend_status'], 'priced')
        missing = rows['zai:read_and_answer:pair:0001:baseline']
        self.assertIsNone(missing['uncached_input_tokens'])
        self.assertIsNone(missing['tokens'])
        self.assertEqual(missing['cached_input_tokens'], 900)
        self.assertIsNone(missing['equivalent_spend_usd'])

        prices = {name: report['equivalent_spend_basis']['pricing'][name]['prices'] for name in ('openai-codex', 'zai')}
        expected = (100 * prices['openai-codex']['input'] + 900 * prices['openai-codex']['cache_read']
                    + 50 * prices['openai-codex']['output']) / 1_000_000
        passed_codex = rows['openai-codex:bug_fix:pair:0001:baseline']
        self.assertAlmostEqual(passed_codex['equivalent_spend_usd'], expected, places=9)

        for provider in ('openai-codex', 'zai'):
            basis = report['equivalent_spend_basis']['pricing'][provider]
            self.assertEqual(basis['label'], 'list-price equivalent, not billed')
            self.assertRegex(basis['catalog_sha256'], r'^[0-9a-f]{64}$')
        self.assertEqual(report['equivalent_spend_basis']['pricing']['openai-codex']['catalog_file'],
                         'apps/lemon_ai/priv/models/open_ai.json')
        self.assertEqual(report['equivalent_spend_basis']['pricing']['zai']['catalog_file'],
                         'apps/lemon_ai/priv/models/zai.json')
        self.assertIn('list-price equivalent, not billed', report['cost_basis'])

        codex = report['providers']['openai-codex']['variants']
        self.assertEqual((codex['baseline']['successes'], codex['baseline']['attempts']), (2, 2))
        self.assertEqual((codex['coding']['successes'], codex['coding']['attempts']), (1, 2))
        self.assertEqual(codex['coding']['success_rate'], 0.5)
        self.assertEqual(codex['baseline']['equivalent_spend']['per_verified_success_status'], 'complete')
        self.assertAlmostEqual(codex['baseline']['equivalent_spend']['per_verified_success_usd'], expected, places=9)
        self.assertAlmostEqual(codex['coding']['equivalent_spend']['total_usd'], 2 * expected, places=9)
        glm = report['providers']['zai']['variants']
        self.assertEqual((glm['baseline']['successes'], glm['baseline']['timeouts']), (1, 1))
        self.assertIsNone(glm['baseline']['equivalent_spend']['total_usd'])
        self.assertEqual(glm['baseline']['equivalent_spend']['per_verified_success_status'], 'incomplete_missing_counters')
        self.assertIsNone(glm['baseline']['token_usage']['uncached_input_tokens']['sum'])
        self.assertEqual(glm['baseline']['token_usage']['uncached_input_tokens']['trials_missing'], 2)
        self.assertEqual(glm['baseline']['token_usage']['output_tokens']['observed_sum'], 50)
        self.assertEqual(glm['coding']['equivalent_spend']['per_verified_success_status'], 'complete')
        for data in report['providers'].values():
            comparison = data['comparisons']['coding']
            self.assertEqual(comparison['paired_trials'], 2)
            self.assertEqual(len(data['paired_differences']), 2)

    def test_zero_successes_leave_cost_per_success_undefined_in_report_and_markdown(self):
        harness = Harness(lambda trial_id: {'mode': 'fail'})
        self.assertEqual(self.run_campaign(harness), 0)
        report = self.report()
        for data in report['providers'].values():
            for summary in data['variants'].values():
                spend = summary['equivalent_spend']
                self.assertEqual(summary['successes'], 0)
                self.assertIsNotNone(spend['total_usd'])
                self.assertIsNone(spend['per_verified_success_usd'])
                self.assertEqual(spend['per_verified_success_status'], 'undefined_zero_successes')
        markdown = (self.out / 'report.md').read_text()
        self.assertIn('undefined_zero_successes', markdown)
        self.assertIn('list-price equivalent, not billed', markdown)

    def test_every_trial_has_an_isolated_runtime_and_only_its_own_provider_credential(self):
        port = free_port()
        harness = Harness()
        self.assertEqual(self.run_campaign(harness, control_plane_port=port), 0)
        self.assertEqual(len(harness.snapshots), 8)
        for key in ('home', 'store', 'token', 'master'):
            self.assertEqual(len({snapshot[key] for snapshot in harness.snapshots}), 8, key)
        for snapshot in harness.snapshots:
            provider = snapshot['trial_id'].split(':')[0]
            self.assertEqual(snapshot['port'], str(port))
            self.assertFalse(snapshot['prior_marker'])
            self.assertFalse(Path(snapshot['home']).exists(), 'runtime state must be removed after each trial')
            expected_key = {'openai-codex': 'OPENAI_CODEX_API_KEY', 'zai': 'ZAI_API_KEY'}[provider]
            self.assertEqual(snapshot['credential_keys'], [expected_key])
            self.assertEqual(snapshot['model'], {'openai-codex': 'gpt-6.1-sol', 'zai': 'glm-5.3'}[provider])
            expected_profile = 'legacy' if snapshot['trial_id'].endswith(':baseline') else 'coding'
            self.assertEqual(snapshot['profile'], expected_profile)
            self.assertIn(f'profile = "{expected_profile}"', snapshot['config'])
        self.assertTrue(all(row['passed'] for row in self.report()['results']),
                        'observed applied profile must confirm each variant')

    def test_default_ports_are_distinct_free_ports_per_trial(self):
        harness = Harness()
        self.assertEqual(self.run_campaign(harness), 0)
        self.assertTrue(all(snapshot['port'].isdigit() for snapshot in harness.snapshots))

    def test_reports_contain_no_prompts_outputs_paths_or_credentials(self):
        self.assertEqual(self.run_campaign(Harness(self.script), config=None), 0)
        for name in ('report.json', 'report.md', 'trials.jsonl', 'manifest.json'):
            text = (self.out / name).read_text()
            for forbidden in (SECRET, 'private-run-id', 'codex-offline-secret', 'zai-offline-secret',
                              'unrelated-ambient-secret', self.directory.name, str(ROOT), sys.executable):
                self.assertNotIn(forbidden, text, f'{name} leaked {forbidden}')
        report = self.report()
        for row in report['results']:
            for key in ('prompt', 'answer', 'run_id', 'workspace', 'environment'):
                self.assertNotIn(key, row)

    def test_report_records_exact_revision_source_and_sanitized_commands(self):
        self.assertEqual(self.run_campaign(Harness(), config=None, control_plane_port=free_port(), resume=True,
                                           tasks='bug_fix,read_and_answer'), 0)
        report = self.report()
        experiment = report['experiment']
        self.assertEqual((experiment['revision'], experiment['source_digest']), (IDENTITY['revision'], IDENTITY['source_digest']))
        self.assertEqual(experiment['compiled_build_digest'], IDENTITY['compiled_build_digest'])
        self.assertEqual(experiment['variants'], ['baseline', 'coding'])
        self.assertEqual(experiment['timeout'], 20)
        self.assertEqual([item['provider'] + ':' + item['model'] for item in experiment['providers']],
                         ['openai-codex:gpt-6.1-sol', 'zai:glm-5.3'])
        command = report['commands']['campaign']
        self.assertTrue(command.startswith('mix lemon.eval.coding --campaign --live '))
        for fragment in ('--providers openai-codex:gpt-6.1-sol,zai:glm-5.3', '--variants baseline,coding',
                         '--repetitions 1', '--timeout 20', '--output-dir <output-dir>', '--resume',
                         '--tasks bug_fix,read_and_answer'):
            self.assertIn(fragment, command)
        self.assertIn('--control-plane-port', command)
        self.assertEqual(report['commands']['runtime_expression_sha256'], paired.digest(paired.RUNTIME_EXPRESSION))
        self.assertIn('Revision: `' + 'a' * 40 + '`', (self.out / 'report.md').read_text())

    def test_without_live_only_a_plan_is_written_and_no_trial_or_credential_is_needed(self):
        harness = Harness()
        with patch.dict(os.environ, {}, clear=True):
            status = self.run_campaign(harness, live=False)
        self.assertEqual(status, 0)
        self.assertEqual(harness.calls, [])
        plan = json.loads((self.out / 'plan.json').read_text())
        self.assertEqual(plan['live_calls'], 0)
        self.assertEqual(len(plan['scheduled_trials']), 8)
        self.assertFalse((self.out / 'trials.jsonl').exists())
        self.assertFalse((self.out / 'manifest.json').exists())

    def test_live_run_requires_each_named_provider_credential_before_any_trial(self):
        for missing in ('OPENAI_CODEX_API_KEY', 'ZAI_API_KEY'):
            with self.subTest(missing=missing):
                harness = Harness()
                environment = {key: value for key, value in os.environ.items() if key != missing}
                with patch.dict(os.environ, environment, clear=True), self.assertRaises(campaign.CampaignError):
                    self.run_campaign(harness)
                self.assertEqual(harness.calls, [])

    def test_occupied_control_plane_port_aborts_before_a_trial_runs(self):
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            sock.listen()
            harness = Harness()
            with self.assertRaises(campaign.CampaignError):
                self.run_campaign(harness, control_plane_port=sock.getsockname()[1])
        self.assertEqual(harness.calls, [])

    def test_output_directory_inside_the_source_checkout_is_refused(self):
        with self.assertRaises(campaign.CampaignError):
            campaign.run_campaign(namespace(ROOT / 'campaign-output'), cases(), Harness(), root=ROOT,
                                  runtime_argv=[sys.executable, str(self.runtime)])
        self.assertFalse((ROOT / 'campaign-output').exists())


class ResumeTests(Fixture):
    def test_interrupted_campaign_records_incomplete_attempt_and_refuses_resume(self):
        script = lambda trial_id: {'mode': 'timeout'} if trial_id == 'zai:bug_fix:pair:0001:baseline' else {}

        interrupted = Harness(script, interrupt_after=3)
        self.assertEqual(self.run_campaign(interrupted, resume=True), 130)
        self.assertEqual(len(self.trial_rows()), 4)
        self.assertFalse(self.report()['complete'])
        self.assertEqual(self.report()['progress']['recorded_trials'], 4)

        resumed = Harness(script)
        with self.assertRaisesRegex(campaign.CampaignError, 'independent recovery'):
            self.run_campaign(resumed, resume=True)
        self.assertEqual(resumed.calls, [])

    def test_torn_trailing_record_is_ignored_and_that_trial_reruns(self):
        harness = Harness()
        self.assertEqual(self.run_campaign(harness, resume=True), 0)
        lines = (self.out / 'trials.jsonl').read_text().splitlines()
        (self.out / 'trials.jsonl').write_text('\n'.join(lines[:-1]) + '\n' + lines[-1][:25])
        torn_id = json.loads(lines[-1])['trial_id']
        rerun = Harness(lambda entry_id: {'mode': 'timeout'} if entry_id == torn_id else {})
        self.assertEqual(self.run_campaign(rerun, resume=True), 0)
        self.assertEqual(rerun.calls, [torn_id])
        records = [json.loads(line) for line in (self.out / 'trials.jsonl').read_text().splitlines()]
        self.assertEqual(len(records), len(lines))
        self.assertEqual(records[-1]['trial_id'], torn_id)
        self.assertEqual(records[-1]['failure'], 'timeout')
        again = Harness()
        self.assertEqual(self.run_campaign(again, resume=True), 0)
        self.assertEqual(again.calls, [])

    def test_malformed_interior_record_is_rejected(self):
        self.assertEqual(self.run_campaign(Harness(), resume=True), 0)
        lines = (self.out / 'trials.jsonl').read_text().splitlines()
        lines[0] = lines[0][:25]
        (self.out / 'trials.jsonl').write_text('\n'.join(lines) + '\n')
        harness = Harness()
        with self.assertRaises(campaign.CampaignError):
            self.run_campaign(harness, resume=True)
        self.assertEqual(harness.calls, [])

    def test_existing_campaign_requires_resume_and_the_same_experiment(self):
        self.assertEqual(self.run_campaign(Harness()), 0)
        harness = Harness()
        with self.assertRaises(campaign.CampaignError):
            self.run_campaign(harness)
        with self.assertRaises(campaign.CampaignError):
            self.run_campaign(harness, resume=True, repetitions=2)
        with self.assertRaises(campaign.CampaignError):
            self.run_campaign(harness, resume=True, timeout=21)
        self.assertEqual(harness.calls, [])
        with patch.object(paired, 'source_identity', return_value={**IDENTITY, 'revision': 'f' * 40}), \
                self.assertRaises(campaign.CampaignError):
            self.run_campaign(harness, resume=True)
        self.assertEqual(harness.calls, [])


class CommandLineTests(unittest.TestCase):
    def invoke(self, *arguments):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [sys.executable, benchmark.__file__, '--lemon', str(ROOT / 'bin' / 'lemon'),
                 *[argument.replace('<dir>', directory) for argument in arguments]],
                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120,
                env={'PATH': os.environ.get('PATH', os.defpath)})
            plan = Path(directory) / 'campaign' / 'plan.json'
            return result, json.loads(plan.read_text()) if plan.exists() else None

    def test_one_documented_command_plans_the_full_144_trial_campaign_offline(self):
        result, plan = self.invoke('--campaign', '--output-dir', '<dir>/campaign')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(plan['live_calls'], 0)
        self.assertEqual(len(plan['scheduled_trials']), 144)
        self.assertEqual(plan['experiment']['repetitions'], 3)
        self.assertEqual(plan['experiment']['timeout'], 660)
        self.assertEqual(plan['experiment']['variants'], ['baseline', 'coding'])
        self.assertEqual([item['provider'] + ':' + item['model'] for item in plan['experiment']['providers']],
                         ['openai-codex:gpt-6.1-sol', 'zai:glm-5.3'])
        self.assertEqual(len(plan['experiment']['tasks']), 12)
        self.assertNotIn('<dir>', json.dumps(plan))
        self.assertIn('--output-dir <output-dir>', plan['commands']['campaign'])

    def test_campaign_and_paid_lane_options_cannot_be_mixed(self):
        for arguments in [
            ['--campaign', '--paired', '--output-dir', '<dir>/campaign'],
            ['--campaign', '--output', '<dir>/out.json', '--output-dir', '<dir>/campaign'],
            ['--campaign', '--model', 'zai:glm-5.3', '--output-dir', '<dir>/campaign'],
            ['--campaign', '--run-timeout', '10', '--output-dir', '<dir>/campaign'],
            ['--campaign', '--plan', 'p.json', '--output-dir', '<dir>/campaign'],
            ['--campaign', '--failure-dir', '<dir>/f', '--output-dir', '<dir>/campaign'],
            ['--output', '<dir>/out.json', '--providers', 'zai:glm-5.3'],
            ['--paired', '--output', '<dir>/out.json', '--output-dir', '<dir>/campaign'],
            ['--output', '<dir>/out.json', '--resume'],
            ['--campaign', '--output-dir', '<dir>/campaign', '--providers', 'anthropic:claude'],
            ['--campaign', '--output-dir', '<dir>/campaign', '--variants', 'baseline'],
            ['--campaign'],
        ]:
            with self.subTest(arguments=arguments):
                result, plan = self.invoke(*arguments)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertNotIn('Traceback', result.stderr)
                self.assertIsNone(plan)


if __name__ == '__main__':
    unittest.main()
