"""Deterministic production-benchmark contracts; no network or paid provider calls."""
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import time
import tomllib
import unittest
from collections import Counter, defaultdict
from contextlib import contextmanager
from types import SimpleNamespace
from unittest.mock import Mock, call, patch

import coding_benchmark as benchmark
import coding_benchmark_paired as paired


def dispose_test_trial_state(state):
    """Remove only test-owned fixtures, including roots replaced by these tests."""
    if state.is_symlink():
        state.unlink()
    elif state.exists():
        paired.repair_trial_directory(state)
        paired.dispose_trial_state(state)


@contextmanager
def assertion_safe_trial_state(test):
    """Reraise test failures outside production's exception-recording context."""
    error = None
    with paired.trial_state() as (state, cleanup):
        test.addCleanup(dispose_test_trial_state, state)
        try:
            yield state, cleanup
        except BaseException as caught:
            error = caught
    if error is not None:
        raise error.with_traceback(error.__traceback__)



def canonical_digest(value):
    return hashlib.sha256(json.dumps(
        value, sort_keys=True, separators=(',', ':'), allow_nan=False
    ).encode()).hexdigest()


def experiment():
    return {
        'tasks': ['bug_fix', 'read_and_answer'],
        'model': 'offline:model',
        'revision': '1' * 40,
        'source_digest': '2' * 64,
        'repetitions': 3,
        'seed': 17,
        'timeout': 10,
        'run_timeout': 120,
        'variants': ['baseline', 'coding'],
        'config_digest': '3' * 64,
    }


def approved_plan():
    return {
        'approved': True,
        'experiment': experiment(),
        'max_attempts': 12,
        'max_spend_usd': 12.0,
        'per_attempt_spend_ceiling_usd': 1.0,
        'provider_budget_enforced': True,
        'credential_env': ['BENCHMARK_PROVIDER_API_KEY'],
    }


class SchedulingTests(unittest.TestCase):
    def test_schedule_is_reproducible_complete_and_counterbalanced(self):
        cases = [{'name': 'bug_fix'}, {'name': 'read_and_answer'}]
        variants = ['baseline', 'coding']
        entries = paired.schedule(cases, variants, 6, 17)
        self.assertEqual(entries, paired.schedule(cases, variants, 6, 17))
        self.assertEqual(len(entries), 24)
        self.assertEqual(len({row['trial_id'] for row in entries}), len(entries))
        pairs = defaultdict(list)
        positions = defaultdict(Counter)
        for row in entries:
            self.assertIn(row['task'], {'bug_fix', 'read_and_answer'})
            self.assertIsInstance(row['trial_id'], str)
            self.assertTrue(row['trial_id'])
            self.assertIsInstance(row['pair_id'], str)
            self.assertTrue(row['pair_id'])
            pairs[row['pair_id']].append(row)
        self.assertEqual(len(pairs), 12)
        for start in range(0, len(entries), len(variants)):
            group = entries[start:start + len(variants)]
            self.assertEqual(len({row['pair_id'] for row in group}), 1)
            self.assertEqual(len({row['task'] for row in group}), 1)
            self.assertEqual(len({row['repetition'] for row in group}), 1)
            self.assertEqual({row['variant'] for row in group}, set(variants))
            self.assertEqual([row['order'] for row in group],
                             sorted(row['order'] for row in group))
            for position, row in enumerate(group):
                positions[(row['task'], row['variant'])][position] += 1
        for counts in positions.values():
            self.assertEqual(counts, Counter({0: 3, 1: 3}))
        self.assertEqual(
            {row['trial_id'] for row in entries},
            {row['trial_id'] for row in paired.schedule(cases, variants, 6, 29)},
        )

    def test_two_variant_order_alternates_within_each_task(self):
        entries = paired.schedule([{'name': 'bug_fix'}], ['baseline', 'coding'], 4, 5)
        first_positions = Counter(entries[index]['variant'] for index in range(0, 8, 2))
        self.assertEqual(first_positions, Counter({'baseline': 2, 'coding': 2}))
        self.assertEqual(len({row['pair_id'] for row in entries}), 4)


class PlanApprovalTests(unittest.TestCase):
    def assert_rejected(self, plan, expected=None, digest=None):
        with self.assertRaises(ValueError):
            paired.validate_plan(plan, expected or experiment(),
                                 digest if digest is not None else canonical_digest(plan))

    def test_exact_bounded_plan_requires_explicit_canonical_digest(self):
        plan = approved_plan()
        paired.validate_plan(plan, experiment(), canonical_digest(plan))
        reversed_plan = dict(reversed(list(plan.items())))
        self.assertEqual(canonical_digest(plan), canonical_digest(reversed_plan))
        paired.validate_plan(reversed_plan, experiment(), canonical_digest(plan))
        self.assert_rejected(plan, digest='0' * 64)
        self.assert_rejected(plan, digest='')
        changed = copy.deepcopy(plan)
        changed['max_spend_usd'] = 13.0
        self.assert_rejected(changed, digest=canonical_digest(plan))

    def test_unsigned_unbounded_or_unenforced_plans_fail_closed(self):
        for key, value in [
            ('approved', False), ('approved', 'true'),
            ('max_attempts', 11), ('max_spend_usd', 0), ('max_spend_usd', -1),
            ('per_attempt_spend_ceiling_usd', 0),
            ('provider_budget_enforced', False), ('provider_budget_enforced', 'true'),
            ('credential_env', 'BENCHMARK_PROVIDER_API_KEY'),
            ('credential_env', []), ('credential_env', ['HOME']),
            ('credential_env', ['BENCHMARK_PROVIDER_API_KEY'] * 2),
            ('credential_env', [None]), ('credential_env', [[]]),
            ('max_attempts', True), ('max_spend_usd', True),
            ('per_attempt_spend_ceiling_usd', 13),
        ]:
            with self.subTest(key=key, value=value):
                plan = approved_plan()
                plan[key] = value
                self.assert_rejected(plan)
        for key in ['approved', 'max_attempts', 'max_spend_usd',
                    'per_attempt_spend_ceiling_usd', 'provider_budget_enforced',
                    'credential_env']:
            with self.subTest(missing=key):
                plan = approved_plan()
                del plan[key]
                self.assert_rejected(plan)

    def test_every_experiment_setting_is_bound_to_approval(self):
        replacements = {
            'tasks': ['bug_fix'], 'model': 'offline:other', 'revision': '4' * 40,
            'source_digest': '5' * 64, 'repetitions': 2, 'seed': 18,
            'timeout': 11, 'run_timeout': 121, 'variants': ['baseline'],
            'config_digest': '6' * 64,
        }
        for key, value in replacements.items():
            with self.subTest(key=key):
                expected = experiment()
                expected[key] = value
                self.assert_rejected(approved_plan(), expected=expected)


class ConfigurationIsolationTests(unittest.TestCase):
    base = '''[agent]
default_model = "offline:model"
default_thinking_level = "high"

[runtime.tools]
auto_approve = true
'''

    def test_only_disclosure_changes_across_variants(self):
        original = tomllib.loads(self.base)
        for variant, profile in [('baseline', 'legacy'), ('coding', 'coding')]:
            with self.subTest(variant=variant):
                configured = tomllib.loads(paired.paired_configuration(self.base, variant))
                disclosure = configured['runtime']['tools'].pop('disclosure')
                self.assertEqual(configured, original)
                self.assertEqual(disclosure['profile'], profile)
                self.assertEqual(disclosure['budget_tokens'], 40000)

    def test_existing_disclosure_and_unknown_variants_are_rejected(self):
        bases = [
            self.base + '\n[runtime.tools.disclosure]\nprofile = "legacy"\n',
            '[runtime.tools]\ndisclosure = {profile = "legacy"}\n',
            '[runtime.tools."disclosure"]\nprofile = "legacy"\n',
        ]
        for base in bases:
            with self.subTest(base=base), self.assertRaises(ValueError):
                paired.paired_configuration(base, 'coding')
        for variant in ['unknown', 'coding_budget_500', 'coding_budget_50000']:
            with self.subTest(variant=variant), self.assertRaises(ValueError):
                paired.paired_configuration(self.base, variant)

    def test_each_attempt_has_private_config_store_home_and_explicit_credentials(self):
        ambient = {
            'PATH': os.environ.get('PATH', ''),
            'HOME': '/private/ordinary-user-home',
            'LEMON_STORE_PATH': '/private/ordinary-store',
            'LEMON_EVAL_PROCESS_STORE': '/private/ordinary-process-store',
            'TMPDIR': '/private/ordinary-tmp',
            'LEMON_DOTENV_DIR': '/private/ordinary-dotenv',
            'LEMON_AGENT_PROFILES_CWD': '/private/ordinary-project',
            'LEMON_CONTROL_PLANE_PORT': '9999',
            'LEMON_GATEWAY_HEALTH_PORT': '4042',
            'LEMON_ROUTER_HEALTH_PORT': '4043',
            'LEMON_TOOL_DISCLOSURE_PROFILE': 'ambient-profile',
            'LEMON_CONTROL_PLANE_OPERATOR_TOKEN': 'ambient-operator-secret',
            'LEMON_SECRETS_MASTER_KEY': 'ambient-master-secret',
            'OPENAI_API_KEY': 'unapproved-secret',
            'HTTPS_PROXY': 'https://private-proxy.invalid',
            'BASH_ENV': '/private/startup-script',
        }
        credentials = {'BENCHMARK_PROVIDER_API_KEY': 'explicit-offline-secret'}
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, ambient, clear=True):
            environments = []
            for index, variant in enumerate(['baseline', 'coding']):
                root = Path(directory) / str(index)
                config = paired.paired_configuration(self.base, variant)
                env = paired.isolated_environment(root, config, variant, credentials,
                                                  [4200 + index, 4300 + index, 4400 + index])
                environments.append(env)
                home = Path(env['HOME'])
                config_file = home / '.lemon' / 'config.toml'
                self.assertTrue(home.is_relative_to(root))
                self.assertEqual(config_file.read_text(), config)
                self.assertEqual(config_file.stat().st_mode & 0o777, 0o600)
                self.assertEqual(home.stat().st_mode & 0o077, 0)
                self.assertTrue(Path(env['LEMON_STORE_PATH']).is_relative_to(root))
                self.assertTrue(Path(env['LEMON_EVAL_PROCESS_STORE']).is_relative_to(root))
                self.assertTrue(Path(env['TMPDIR']).is_relative_to(root))
                self.assertEqual(Path(env['TMPDIR']).stat().st_mode & 0o777, 0o700)
                self.assertTrue(Path(env['LEMON_AGENT_PROFILES_CWD']).is_relative_to(root))
                self.assertEqual(env['LEMON_DOTENV_DIR'], env['LEMON_AGENT_PROFILES_CWD'])
                self.assertEqual(env['LEMON_TOOL_DISCLOSURE_PROFILE'],
                                 'legacy' if variant == 'baseline' else 'coding')
                self.assertEqual(env['LEMON_CONTROL_PLANE_PORT'], str(4200 + index))
                self.assertEqual(env['LEMON_WEB_PORT'], str(4300 + index))
                self.assertEqual(env['LEMON_SIM_UI_PORT'], str(4400 + index))
                self.assertEqual(env['LEMON_GATEWAY_HEALTH_PORT'], '0')
                self.assertEqual(env['LEMON_ROUTER_HEALTH_PORT'], '0')
                self.assertEqual(env['BENCHMARK_PROVIDER_API_KEY'], credentials['BENCHMARK_PROVIDER_API_KEY'])
                for key in ['OPENAI_API_KEY', 'HTTPS_PROXY', 'BASH_ENV']:
                    self.assertNotIn(key, env)
                self.assertNotIn('ambient-operator-secret', env.values())
                self.assertNotIn('ambient-master-secret', env.values())
            for key in ['HOME', 'LEMON_STORE_PATH', 'LEMON_EVAL_PROCESS_STORE', 'TMPDIR',
                        'LEMON_AGENT_PROFILES_CWD', 'LEMON_CONTROL_PLANE_OPERATOR_TOKEN',
                        'LEMON_SECRETS_MASTER_KEY']:
                self.assertNotEqual(environments[0][key], environments[1][key])
            marker = Path(environments[0]['HOME']) / 'attempt-one-only'
            marker.write_text('private state')
            self.assertFalse((Path(environments[1]['HOME']) / marker.name).exists())

    def test_sdk_homes_are_resolved_before_replacing_home_and_runtime_cwd(self):
        with tempfile.TemporaryDirectory() as directory:
            original_home = Path(directory) / 'operator-home'
            for index, overrides in enumerate([
                {},
                {'MIX_HOME': '~/installed-mix', 'HEX_HOME': 'relative-installed-hex'},
            ]):
                ambient = {'HOME': str(original_home), **overrides}
                with self.subTest(overrides=overrides), patch.dict(os.environ, ambient, clear=True):
                    environment = paired.isolated_environment(
                        Path(directory) / str(index), self.base, 'baseline', {}, [4201, 4301, 4401])
                    expected_mix = original_home / ('installed-mix' if overrides else '.mix')
                    expected_hex = (Path.cwd() / overrides['HEX_HOME']
                                    if overrides else original_home / '.hex')
                    self.assertEqual(environment['MIX_HOME'], str(expected_mix.resolve()))
                    self.assertEqual(environment['HEX_HOME'], str(expected_hex.resolve()))
                    self.assertNotEqual(environment['HOME'], str(original_home))
                    self.assertEqual(os.environ['HOME'], str(original_home))


def outcome(task, repetition, variant, passed, cost, wall, failure=None, **metrics):
    return {
        'task': task, 'pair_id': f'{task}:{repetition}',
        'trial_id': f'{task}:{repetition}:{variant}', 'variant': variant,
        'passed': passed, 'failure': failure, 'cost_usd': cost,
        'wall_seconds': wall, **metrics,
    }


class AggregationTests(unittest.TestCase):
    def test_spend_includes_failed_attempts_and_missing_spend_is_incomplete(self):
        rows = [
            outcome('bug_fix', 1, 'baseline', True, 1, 1, turns=2),
            outcome('bug_fix', 2, 'baseline', False, 2, 3, 'verifier_failed', turns=4),
            outcome('bug_fix', 3, 'baseline', False, 3, 5, 'timeout', turns=None),
            outcome('bug_fix', 1, 'coding', True, 0.4, 2),
            outcome('bug_fix', 2, 'coding', False, 0.7, 4, 'agent_failed'),
            outcome('bug_fix', 3, 'coding', False, None, 6, 'timeout'),
        ]
        report = paired.summarize(rows, 17)
        baseline = report['variants']['baseline']
        self.assertEqual(baseline['attempts'], 3)
        self.assertEqual(baseline['successes'], 1)
        self.assertEqual(baseline['success_rate'], 1 / 3)
        self.assertEqual(baseline['failures'], 2)
        self.assertEqual(baseline['timeouts'], 1)
        self.assertEqual(baseline['measured_spend_usd'], 6)
        self.assertTrue(baseline['spend_complete'])
        self.assertEqual(baseline['cost_per_verified_success_usd'], 6)
        self.assertEqual(baseline['cost_per_success_status'], 'complete')
        self.assertIsNone(baseline['turns'])
        self.assertIsNone(baseline['cached_input_tokens'])
        coding = report['variants']['coding']
        self.assertAlmostEqual(coding['measured_spend_usd'], 1.1)
        self.assertFalse(coding['spend_complete'])
        self.assertIsNone(coding['cost_per_verified_success_usd'])
        self.assertEqual(coding['cost_per_success_status'], 'incomplete_missing_spend')
        comparison = report['comparisons']['coding']
        self.assertEqual(comparison['paired_trials'], 3)
        self.assertEqual(comparison['wall_seconds_difference']['estimate'], 1)

    def test_partial_numeric_spend_is_retained_without_claiming_complete_cost(self):
        rows = [
            outcome('bug_fix', 1, 'baseline', True, 1.25, 1, spend_complete=False),
            outcome('bug_fix', 2, 'baseline', False, 0.75, 2, 'agent_failed',
                    spend_complete=True),
        ]
        result = paired.summarize(rows, 17)['variants']['baseline']
        self.assertEqual(result['attempts'], 2)
        self.assertEqual(result['successes'], 1)
        self.assertEqual(result['measured_spend_usd'], 2)
        self.assertFalse(result['spend_complete'])
        self.assertIsNone(result['cost_per_verified_success_usd'])
        self.assertEqual(result['cost_per_success_status'], 'incomplete_missing_spend')

    def test_zero_successes_are_undefined_even_with_complete_measured_spend(self):
        for cost, complete in [(2, True), (None, False)]:
            with self.subTest(cost=cost):
                rows = [outcome('bug_fix', 1, 'baseline', False, cost, 3, 'timeout')]
                result = paired.summarize(rows, 17)['variants']['baseline']
                self.assertEqual(result['success_rate'], 0)
                self.assertEqual(result['spend_complete'], complete)
                self.assertIsNone(result['cost_per_verified_success_usd'])
                self.assertEqual(result['cost_per_success_status'], 'undefined_zero_successes')

    def test_missing_counters_stay_null_but_observed_zero_and_cache_usage_survive(self):
        metrics = {'turns': 0, 'uncached_input_tokens': 11, 'cached_input_tokens': 7,
                   'cache_write_tokens': 2, 'output_tokens': 3, 'tool_errors': 1,
                   'discovery_failures': 0, 'incorrect_tool_calls': 0,
                   'tool_error_recoveries': 1}
        rows = [outcome('bug_fix', index, 'baseline', True, 0, 1, **metrics)
                for index in range(2)]
        complete = paired.summarize(rows, 17)['variants']['baseline']
        for key, value in metrics.items():
            self.assertEqual(complete[key], value * 2, key)
        self.assertEqual(complete['cost_per_verified_success_usd'], 0)
        for key in metrics:
            with self.subTest(missing=key):
                incomplete = copy.deepcopy(rows)
                incomplete[0][key] = None
                result = paired.summarize(incomplete, 17)['variants']['baseline']
                self.assertIsNone(result[key])

    def test_task_clusters_not_repetitions_determine_uncertainty(self):
        rows = []
        for repetition in range(9):
            rows.extend([
                outcome('many_trials', repetition, 'baseline', False, 1, 1, 'agent_failed'),
                outcome('many_trials', repetition, 'coding', True, 1, 11),
            ])
        rows.extend([
            outcome('one_trial', 0, 'baseline', True, 1, 5),
            outcome('one_trial', 0, 'coding', False, 1, 1, 'timeout'),
        ])
        report = paired.summarize(rows, 17)
        self.assertEqual(report, paired.summarize(list(reversed(rows)), 17))
        comparison = report['comparisons']['coding']
        self.assertEqual(comparison['paired_trials'], 10)
        success = comparison['verified_success_difference']
        wall = comparison['wall_seconds_difference']
        self.assertEqual(success, {'estimate': 0, 'interval_95': [-1, 1], 'task_clusters': 2})
        self.assertEqual(wall, {'estimate': 3, 'interval_95': [-4, 10], 'task_clusters': 2})
        self.assertIn('exploratory', report['interpretation'])
        self.assertIn('task clusters', report['uncertainty_method'])
        single_task = paired.summarize(rows[:-2], 17)['comparisons']['coding']
        self.assertEqual(single_task['verified_success_difference']['task_clusters'], 1)
        self.assertIsNone(single_task['verified_success_difference']['interval_95'])

    def test_unpaired_rows_and_missing_wall_times_do_not_fabricate_pair_evidence(self):
        rows = [
            outcome('bug_fix', 1, 'baseline', False, 1, None, 'timeout'),
            outcome('bug_fix', 1, 'coding', True, 1, 2),
            outcome('unpaired', 1, 'coding', False, 1, 3, 'agent_failed'),
        ]
        report = paired.summarize(rows, 17)
        self.assertEqual(report['variants']['coding']['attempts'], 2)
        comparison = report['comparisons']['coding']
        self.assertEqual(comparison['paired_trials'], 1)
        self.assertEqual(comparison['verified_success_difference']['estimate'], 1)
        self.assertEqual(comparison['wall_seconds_difference'],
                         {'estimate': None, 'interval_95': None, 'task_clusters': 0})

    def test_unstarted_trials_are_recorded_but_not_counted_as_attempts(self):
        attempted = outcome('bug_fix', 1, 'baseline', True, 2, 1)
        skipped = outcome('bug_fix', 2, 'baseline', False, None, None, 'run_deadline',
                          attempted=False)
        result = paired.summarize([attempted, skipped], 17)['variants']['baseline']
        self.assertEqual(result['planned_trials'], 2)
        self.assertEqual(result['skipped'], 1)
        self.assertEqual(result['attempts'], 1)
        self.assertEqual(result['success_rate'], 1)
        self.assertEqual(result['measured_spend_usd'], 2)
        self.assertTrue(result['spend_complete'])
        self.assertEqual(result['cost_per_verified_success_usd'], 2)


class RedactionAndDryPlanTests(unittest.TestCase):
    def test_operator_described_passed_four_turn_fixture_keeps_unknown_usage(self):
        path = Path(__file__).resolve().parents[1] / 'test/fixtures/glm_passed_four_turns_missing_usage.json'
        original = path.read_bytes()
        fixture = json.loads(original)
        self.assertTrue(fixture['fixture'])
        row = paired.sanitize_row(fixture['row'])
        self.assertTrue(row['passed'])
        self.assertTrue(row['verifier_passed'])
        self.assertTrue(row['tests_passed'])
        self.assertEqual(row['turns'], 4)
        for key in ('tokens', 'uncached_input_tokens', 'cached_input_tokens',
                    'cache_write_tokens', 'output_tokens', 'cost_usd'):
            self.assertIsNone(row[key])
        self.assertFalse(row['spend_complete'])
        self.assertFalse(row['schema_diagnostics']['parent_usage_complete'])
        self.assertEqual(path.read_bytes(), original)

    def test_profile_diagnostics_allow_only_counts_and_valid_catalog_digests(self):
        secret = 'private-profile-output-and-credential'
        records = [
            {'event': 'payload', 'tools_catalog_digest': 'a' * 64,
             'estimates': {'tool_schemas': 12}, 'prompt': secret, 'arguments': secret},
            {'event': 'payload', 'tools_catalog_digest': secret,
             'estimates': {'tool_schemas': None}, 'workspace': '/private/workspace'},
            {'event': 'usage', 'provider_usage': {'cache_read_tokens': 7,
                                                'hidden_reasoning': secret}},
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'profile.jsonl'
            path.write_text('\n'.join(json.dumps(record) for record in records) +
                            '\nnot-json\n')
            report = paired.collect_profile(path)
            self.assertEqual(report['catalog_digests'], ['a' * 64])
            self.assertEqual(report['requests_observed'], 2)
            self.assertEqual(report['completed_usage_requests'], 1)
            self.assertIsNone(report['schema_tokens_estimate_sum'])
            self.assertTrue(report['provider_cache_observable'])
            self.assertIn('not billed input', report['schema_estimate_basis'])
            serialized = json.dumps(report)
            self.assertNotIn(secret, serialized)
            self.assertNotIn('/private/workspace', serialized)
            self.assertIn('provider cache not controlled', report['cache_regime'])

    def test_bridge_invocations_are_counted_by_redacted_resolved_tool_identity(self):
        private_target = 'private.bridge.resolved-tool-name'
        first = hashlib.sha256(private_target.encode()).hexdigest()
        second = hashlib.sha256(b'second-resolved-tool').hexdigest()
        records = [
            {'event': 'disclosure_applied', 'profile': 'coding', 'active': True},
            {'event': 'disclosure_applied', 'profile': 'coding', 'active': True},
            {'event': 'disclosure_applied', 'profile': private_target, 'active': True},
            {'event': 'disclosure_invoke', 'resolved_tool_digest': first, 'status': 'ok',
             'tool_name': private_target, 'arguments': private_target, 'duration_us': 7},
            {'event': 'disclosure_invoke', 'resolved_tool_digest': first, 'status': 'error',
             'error': private_target, 'duration_us': 11},
            {'event': 'disclosure_invoke', 'resolved_tool_digest': first, 'status': 'ok'},
            {'event': 'disclosure_invoke', 'resolved_tool_digest': second, 'status': 'error'},
            {'event': 'disclosure_invoke', 'resolved_tool_digest': private_target, 'status': 'ok'},
            {'event': 'disclosure_invoke', 'resolved_tool_digest': 'a' * 63, 'status': 'ok'},
            {'event': 'unrelated_event', 'resolved_tool_digest': first, 'status': 'ok'},
        ]
        records.extend({'event': 'disclosure_invoke', 'resolved_tool_digest': first,
                        'status': status}
                       for status in ['unknown', 'schema_invalid', 'pending', None, True])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'owner-only-profile.jsonl'
            path.write_text('\n'.join(json.dumps(record) for record in records) + '\n')
            path.chmod(0o600)
            report = paired.collect_profile(path)
        self.assertEqual(report['applied_profiles'], ['coding'])
        self.assertEqual(report['resolved_bridge_invocations'], {
            first: {'calls': 3, 'errors': 1},
            second: {'calls': 1, 'errors': 1},
        })
        self.assertIn('SHA256-redacted', report['bridge_attribution_basis'])
        self.assertNotIn(private_target, json.dumps(report))
        self.assertEqual(report['requests_observed'], 0)
        self.assertEqual(report['completed_usage_requests'], 0)
        self.assertIsNone(report['schema_tokens_estimate_sum'])

    def test_complete_parent_spend_requires_matching_observed_terminal_usage(self):
        base = {'run_id': 'private-run', 'session_id': 'private-session', 'request_index': 1}
        payload = dict(base, event='payload')
        usage = dict(base, event='usage', provider_usage={
            'input_tokens': 20, 'output_tokens': 3, 'cache_read_tokens': 7,
            'cache_write_tokens': 0, 'total_tokens': 30})
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'profile.jsonl'

            def complete(records, turns=1):
                path.write_text('\n'.join(json.dumps(record) for record in records) + '\n')
                diagnostics = paired.collect_profile(path, 'private-run', turns)
                self.assertNotIn('private-run', json.dumps(diagnostics))
                self.assertNotIn('private-session', json.dumps(diagnostics))
                return diagnostics['parent_usage_complete']

            self.assertTrue(complete([payload, usage]))
            # A sibling/child run's observations cannot either supply missing
            # parent usage or contaminate otherwise complete parent evidence.
            self.assertTrue(complete([
                payload, usage, dict(payload, run_id='child-run'),
                dict(usage, run_id='child-run')]))
            for records, turns in [
                ([], 0), ([], 1), ([payload], 1),
                ([payload, dict(usage, request_index=2)], 1),
                ([payload, usage, usage], 1),
                ([payload, usage], 2),
                ([payload, dict(usage, provider_usage={})], 1),
                ([payload, dict(usage, provider_usage={
                    **usage['provider_usage'], 'cache_write_tokens': None})], 1),
                ([payload, dict(usage, run_id='different-run')], 1),
                ([payload, usage, dict(payload, session_id='nested-session'),
                  dict(usage, session_id='nested-session')], 2),
            ]:
                with self.subTest(records=records, turns=turns):
                    self.assertFalse(complete(records, turns))

    def test_discovery_and_incorrect_call_counters_require_versioned_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'owner-only-diagnostics.jsonl'

            def collect(records):
                path.write_text('\n'.join(json.dumps(record) for record in records) + '\n')
                path.chmod(0o600)
                return paired.collect_profile(path)

            evidence = [
                {'event': 'disclosure_search', 'status': 'ok', 'matched_count': 0},
                {'event': 'disclosure_search', 'status': 'error', 'matched_count': 0},
                {'event': 'disclosure_rejected', 'reason': 'unknown_tool'},
            ]
            for applied in [None, {'event': 'disclosure_applied', 'profile': 'coding'},
                            {'event': 'disclosure_applied', 'profile': 'coding',
                             'diagnostic_events_version': 0}]:
                with self.subTest(unversioned=applied):
                    report = collect(([applied] if applied else []) + evidence)
                    self.assertIsNone(report['discovery_failures'])
                    self.assertIsNone(report['incorrect_tool_calls'])

            versioned = {'event': 'disclosure_applied', 'profile': 'coding',
                         'active': True, 'diagnostic_events_version': 1}
            empty = collect([versioned])
            self.assertEqual(empty['discovery_failures'], 0)
            self.assertEqual(empty['incorrect_tool_calls'], 0)
            records = [versioned] + evidence + [
                {'event': 'disclosure_search', 'status': 'ok', 'matched_count': 3},
                {'event': 'disclosure_search', 'status': 'unknown', 'matched_count': 0},
                {'event': 'disclosure_rejected', 'reason': 'invalid_arguments'},
                {'event': 'disclosure_rejected', 'reason': 'invalid_request'},
                {'event': 'disclosure_rejected', 'reason': 'private-unknown-reason'},
            ]
            counted = collect(records)
            self.assertEqual(counted['discovery_failures'], 2)
            self.assertEqual(counted['incorrect_tool_calls'], 4)
            self.assertNotIn('private-unknown-reason', json.dumps(counted))

    def test_trial_redaction_removes_untrusted_text_and_runtime_identifiers(self):
        secret = 'private-prompt-output-credential-and-workspace'
        row = outcome('bug_fix', 1, 'coding', False, 1, 2, 'agent_failed',
                      turns=3, tool_errors=1)
        row.update({
            'answer': secret, 'prompt': secret, 'credentials': secret,
            'workspace': secret, 'hidden_reasoning': secret, 'tool_output': secret,
            'run_id': secret, 'model': secret,
            'schema_diagnostics': {'catalog_digests': ['a' * 64], 'raw': secret},
            'runtime_versions': {'elixir': '1.19.5', 'otp': '28', 'private': secret},
        })
        sanitized = paired.sanitize_row(row)
        self.assertEqual(sanitized['task'], 'bug_fix')
        self.assertFalse(sanitized['passed'])
        self.assertEqual(sanitized['cost_usd'], 1)
        self.assertEqual(sanitized['turns'], 3)
        self.assertNotIn(secret, json.dumps(sanitized))
        for key in ['prompt', 'answer', 'credentials', 'workspace', 'hidden_reasoning',
                    'tool_output', 'run_id', 'model']:
            self.assertNotIn(key, sanitized)

    def test_paired_only_config_cannot_fall_through_to_the_paid_legacy_lane(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / 'dedicated.toml'
            config.write_text(ConfigurationIsolationTests.base)
            output = Path(directory) / 'must-not-exist.json'
            absent_client = Path(directory) / 'nonexistent-client'
            result = subprocess.run(
                [sys.executable, benchmark.__file__, '--lemon', str(absent_client),
                 '--output', str(output), '--config', str(config)],
                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10,
                env={'PATH': os.environ.get('PATH', os.defpath)},
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn('paired authorization/options require --paired', result.stderr)
            self.assertNotIn('Traceback', result.stderr)
            self.assertFalse(output.exists())
            self.assertFalse(output.with_suffix('.md').exists())

    def test_schema_budgets_are_rejected_before_any_paid_or_paired_runner(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'must-not-exist.json'
            for lane in [[], ['--paired'], ['--paired', '--live']]:
                for option in [
                    ['--schema-budgets', '500,50000'],
                    ['--schema-budgets=500,50000'],
                ]:
                    with self.subTest(lane=lane, option=option):
                        result = subprocess.run(
                            [sys.executable, '-c', textwrap.dedent('''\
                                import sys
                                import coding_benchmark as benchmark
                                def forbidden(*args, **kwargs):
                                    raise AssertionError('unsupported option reached a runner')
                                benchmark.run_case = forbidden
                                benchmark.run_paired = forbidden
                                sys.exit(benchmark.main())
                            '''), '--lemon', str(Path(directory) / 'absent-client'),
                             '--output', str(output), *lane, *option],
                            cwd=Path(benchmark.__file__).parent,
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10,
                            env={'PATH': os.environ.get('PATH', os.defpath)},
                        )
                        self.assertEqual(result.returncode, 2, result.stderr)
                        self.assertIn('unrecognized arguments: --schema-budgets', result.stderr)
                        self.assertNotIn('Traceback', result.stderr)
                        self.assertFalse(output.exists())
                        self.assertFalse(output.with_suffix('.md').exists())

    def test_default_runner_writes_only_unsigned_redacted_plan_and_never_runs_a_case(self):
        secret = 'private-config-api-key-and-fixture-prompt'
        root = Path(benchmark.__file__).resolve().parents[3]
        cases = [{'name': 'bug_fix', 'prompt': secret, 'files': {'secret.txt': secret},
                  'verify': 'assert True'}]
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / 'private-config.toml'
            config.write_text(ConfigurationIsolationTests.base +
                              '\n[providers.offline]\napi_key = "' + secret + '"\n')
            output = Path(directory) / 'plan.json'
            args = SimpleNamespace(
                lemon=str(root / 'bin' / 'lemon'), model='offline:model',
                compare_omp=False, config=str(config), timeout=10, run_timeout=120,
                repetitions=2, seed=17,
                profile_python=sys.executable, live=False, output=str(output),
                plan=None, approve_plan_digest=None,
            )

            def forbidden_case(*arguments):
                self.fail('unsigned offline planning invoked the coding client')

            self.assertEqual(paired.run_paired(args, cases, forbidden_case), 0)
            report = json.loads(output.read_text())
            self.assertEqual(report['live_calls'], 0)
            self.assertEqual(len(report['scheduled_trials']), 4)
            plan = report['plan']
            self.assertIs(plan['approved'], False)
            self.assertIs(plan['provider_budget_enforced'], False)
            self.assertIsNone(plan['max_spend_usd'])
            self.assertIsNone(plan['per_attempt_spend_ceiling_usd'])
            self.assertEqual(plan['credential_env'], [])
            self.assertEqual(plan['max_attempts'], 4)
            self.assertEqual(report['plan_digest'], canonical_digest(plan))
            self.assertEqual(plan['experiment']['variants'], ['baseline', 'coding'])
            self.assertEqual(plan['experiment']['repetitions'], 2)
            self.assertEqual(plan['experiment']['seed'], 17)
            self.assertEqual(len(plan['experiment']['revision']), 40)
            self.assertEqual(len(plan['experiment']['source_digest']), 64)
            self.assertIn('keep-current-defaults', report['decision'])
            self.assertIn('keep-opt-in', report['decision'])
            for forbidden in [secret, str(config), directory, str(root), sys.executable]:
                self.assertNotIn(forbidden, output.read_text())
            args.live = True
            approved_file = Path(directory) / 'unsigned-approval.json'
            approved_file.write_text(json.dumps(plan))
            args.plan = str(approved_file)
            args.approve_plan_digest = canonical_digest(plan)
            with self.assertRaises(ValueError):
                paired.run_paired(args, cases, forbidden_case)


class FixtureAssertionSafetyTests(unittest.TestCase):
    def test_body_failures_propagate_after_production_teardown_and_do_not_leak(self):
        for error in (AssertionError('fixture assertion'), RuntimeError('fixture error'),
                      KeyboardInterrupt(), SystemExit(3)):
            with self.subTest(error=type(error).__name__):
                owner = unittest.TestCase()
                self.addCleanup(owner.doCleanups)
                with self.assertRaises(type(error)) as caught:
                    with assertion_safe_trial_state(owner) as (state, cleanup):
                        (state / 'private-evidence').write_text('fixture')
                        raise error
                self.assertIs(caught.exception, error)
                self.assertFalse(cleanup['finalization_failed'])
                self.assertFalse(cleanup['interrupted'])
                with self.assertRaises(OSError):
                    os.fstat(cleanup['root_fd'])
                self.assertTrue(state.exists())
                self.assertTrue(owner.doCleanups())
                self.assertFalse(state.exists())

    @unittest.skipUnless(os.name == 'posix', 'native fixture uses POSIX FIFOs')
    def test_unexpected_native_recovery_success_fails_the_actual_gate(self):
        import test_paired_native_cleanup as native

        gate = native.NativeCleanupTests(
            'test_missing_identity_remains_unverified_and_unsignalled')
        # Run this single TestCase directly, bypassing its BEAM-discovering class setup.
        gate.command, gate.sdk_bins = ['offline-native-fixture'], []
        sentinel = Mock()
        sentinel.poll.return_value = None
        runtime = Mock(pid=12345)
        runtime.poll.return_value = None
        identity = {'root_pid': 23456, 'pgid': 23456, 'root_birth': 'fixture-birth',
                    'ownership_lost': False, 'members': {'23456': 'fixture-birth'}}
        witness = {'pid': 23456, 'pgid': 23456, 'birth': 'fixture-birth'}
        states = []

        def launch(argv, **kwargs):
            if argv[0] != 'offline-native-fixture':
                return sentinel
            state = Path(kwargs['env']['LEMON_EVAL_CLEANUP_ROOT'])
            states.append(state)
            (state / 'native.json').write_text(json.dumps({
                'identity': identity, 'ledger': 'process_manager', 'id': 'fixture-id',
                'tracked_before_boot': False, 'root_exited': False,
            }))
            (state / 'processes.dets').write_bytes(b'private fixture evidence')
            return runtime

        def unexpected_success(process, **kwargs):
            self.assertIs(process, runtime)
            runtime.poll.return_value = runtime.returncode = -paired.signal.SIGKILL
            return True

        result = unittest.TestResult()
        with patch.object(native.paired, 'runtime_ports', return_value=[4201, 4301, 4401]), \
                patch.object(native.paired, 'isolated_environment', return_value={}), \
                patch.object(native.subprocess, 'Popen', side_effect=launch), \
                patch.object(native, 'group_rows', return_value=[witness]), \
                patch.object(native.paired, 'terminate', side_effect=unexpected_success) as recover, \
                patch.object(native, 'emergency_stop') as emergency:
            gate.run(result)
        recover.assert_called_once()
        self.assertEqual(result.testsRun, 1)
        self.assertEqual(result.errors, [])
        self.assertEqual(len(result.failures), 1, 'unexpected success passed the native gate')
        self.assertIn('True is not False', result.failures[0][1])
        emergency.assert_called_once_with(identity)
        sentinel.kill.assert_called_once_with()
        sentinel.wait.assert_called_once_with(timeout=5)
        self.assertEqual(len(states), 1)
        self.assertFalse(states[0].exists(), 'failed gate leaked its private fixture')


class ProcessCleanupTests(unittest.TestCase):
    def parent_script(self, directory, return_normally):
        ready, escaped = Path(directory) / 'ready', Path(directory) / 'escaped'
        child = textwrap.dedent('''\
            import os, pathlib, signal, sys, time
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            parent = os.getppid()
            pathlib.Path(sys.argv[1]).write_text('ready')
            while os.getppid() == parent:
                time.sleep(0.01)
            time.sleep(0.1)
            pathlib.Path(sys.argv[2]).write_text('leaked')
        ''')
        parent = textwrap.dedent('''\
            import pathlib, subprocess, sys, time
            subprocess.Popen([sys.executable, '-c', sys.argv[1], sys.argv[2], sys.argv[3]],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            deadline = time.monotonic() + 5
            while not pathlib.Path(sys.argv[2]).exists():
                if time.monotonic() >= deadline:
                    raise RuntimeError('child unavailable')
                time.sleep(0.01)
            print('ready', flush=True)
            if sys.argv[4] != 'return':
                time.sleep(10)
        ''')
        return [sys.executable, '-c', parent, child, str(ready), str(escaped),
                'return' if return_normally else 'wait'], escaped

    def test_runtime_teardown_kills_children_that_ignore_term_after_leader_exits(self):
        with tempfile.TemporaryDirectory() as directory:
            argv, escaped = self.parent_script(directory, False)
            process = subprocess.Popen(argv, stdout=subprocess.PIPE, text=True,
                                       start_new_session=True)
            try:
                self.assertEqual(process.stdout.readline().strip(), 'ready')
            finally:
                paired.terminate_runtime_group(process)
                process.stdout.close()
            time.sleep(0.2)
            self.assertFalse(escaped.exists())

    def test_successful_deadline_owned_command_cannot_leave_background_children(self):
        with tempfile.TemporaryDirectory() as directory:
            argv, escaped = self.parent_script(directory, True)
            result = benchmark.command(argv, directory, deadline=time.monotonic() + 5)
            self.assertEqual(result.returncode, 0, result.stderr)
            time.sleep(0.2)
            self.assertFalse(escaped.exists())

    def test_runtime_boot_configures_ownership_before_start_and_verifies_afterward(self):
        argv = paired.runtime_command(Path(__file__).resolve().parents[3])
        self.assertEqual(argv[:2], ['mix', 'run'])
        for flag in ['--no-start', '--no-halt', '--no-compile', '--no-deps-check']:
            self.assertIn(flag, argv)
        expression = argv[argv.index('-e') + 1]
        configure = expression.index('LemonEvals.PairedCleanup.configure!()')
        boot = expression.index('LemonCore.Runtime.Boot.start!(:runtime_full)')
        verify = expression.index('LemonEvals.PairedCleanup.verify!()')
        self.assertLess(configure, boot)
        self.assertLess(boot, verify)
        self.assertLess(verify, expression.index('LemonEvals.PayloadProfile.install!'))

    def test_runtime_group_waits_are_bounded_even_when_term_is_ignored(self):
        process = Mock(pid=12345)
        process.wait.side_effect = [subprocess.TimeoutExpired('runtime', 5), 0]
        with patch.object(paired.os, 'killpg') as killpg:
            paired.terminate_runtime_group(process)
        self.assertEqual(process.wait.call_args_list, [call(timeout=5), call(timeout=5)])
        self.assertEqual(killpg.call_args_list, [
            call(process.pid, paired.signal.SIGTERM),
            call(process.pid, paired.signal.SIGKILL),
        ])

    def test_unstarted_runtime_needs_no_recovery_process(self):
        with patch.object(paired.subprocess, 'Popen') as launch:
            self.assertTrue(paired.terminate(None, project_root=Path.cwd(), environment={}))
        launch.assert_not_called()

    def test_recovery_runs_only_after_runtime_stop_without_provider_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = paired.isolated_environment(
                root / 'state', ConfigurationIsolationTests.base, 'coding',
                {'BENCHMARK_PROVIDER_API_KEY': 'private-approved-credential'}, [4201, 4301, 4401])
            environment.update({'ERL_FLAGS': '+S 2:2', 'HTTPS_PROXY': 'private-proxy',
                                'OPENAI_API_KEY': 'private-unapproved-credential'})
            ebins = [root / '_build' / environment.get('MIX_ENV', 'dev') / 'lib' / app / 'ebin'
                     for app in ('lemon_core', 'lemon_evals')]
            for ebin in ebins:
                ebin.mkdir(parents=True)
            events = []
            runtime = Mock()
            recovery = Mock()
            recovery.wait.return_value = 0
            recovery.poll.return_value = 0

            def stop(process):
                self.assertIs(process, runtime)
                events.append('stop')

            def launch(*args, **kwargs):
                events.append('recover')
                return recovery

            with patch.object(paired, 'terminate_runtime_group', side_effect=stop), \
                    patch.object(paired.subprocess, 'Popen', side_effect=launch) as popen:
                self.assertTrue(paired.terminate(runtime, project_root=root, environment=environment))
            self.assertEqual(events, ['stop', 'recover'])
            argv = popen.call_args.args[0]
            self.assertEqual(argv[:2], [sys.executable, '-c'])
            descriptor = int(argv[3])
            self.assertEqual(argv[4], 'elixir')
            self.assertEqual(argv[5:-2], [
                item for ebin in ebins for item in ('-pa', str(ebin.resolve()))])
            self.assertEqual(argv[-2], '-e')
            self.assertNotIn('mix', argv)
            self.assertNotIn('--no-halt', argv)
            expression = argv[argv.index('-e') + 1]
            self.assertIn('LemonEvals.PairedCleanup.recover(', expression)
            self.assertNotIn('Boot.start!', expression)
            self.assertNotIn('Application.', expression)
            self.assertNotIn('PayloadProfile', expression)
            options = popen.call_args.kwargs
            self.assertEqual(options['pass_fds'], (descriptor,))
            allowed = {'PATH', 'LANG', 'LC_ALL', 'TMPDIR', 'HOME', 'MIX_ENV',
                       'MIX_HOME', 'HEX_HOME', 'ERL_FLAGS'}
            expected_environment = {key: value for key, value in environment.items()
                                    if key in allowed}
            expected_environment['LEMON_EVAL_PROCESS_STORE'] = 'processes.dets'
            self.assertEqual(options['env'], expected_environment)
            # Execute the actual bootstrap with every process operation intercepted:
            # it must only pin the inherited directory, close its FD and exec Elixir.
            operations = Mock()
            with patch.object(os, 'fchdir', operations.pin), \
                    patch.object(os, 'close', operations.close), \
                    patch.object(os, 'execvpe', operations.execute), \
                    patch.object(os, 'environ', expected_environment), \
                    patch.object(sys, 'argv', ['-c', *argv[3:]]):
                exec(argv[2], {})
            self.assertEqual(operations.mock_calls, [
                call.pin(descriptor),
                call.close(descriptor),
                call.execute('elixir', argv[4:], expected_environment),
            ])
            self.assertEqual(options['cwd'], root)
            self.assertEqual(options['stdin'], subprocess.DEVNULL)
            self.assertTrue(options['start_new_session'])
            self.assertIs(options['stdout'], options['stderr'])
            log_path = Path(environment['LEMON_EVAL_PROCESS_STORE']).parent / 'cleanup.log'
            self.assertEqual(log_path.stat().st_mode & 0o777, 0o600)
            recovery.wait.assert_called_once_with(timeout=20)

    def test_replaced_trial_root_cannot_redirect_recovery_or_log_mutation(self):
        for existing in (False, True):
            with self.subTest(existing=existing), tempfile.TemporaryDirectory() as directory:
                external = Path(directory) / 'external'
                external.mkdir(mode=0o700)
                log = external / 'cleanup.log'
                if existing:
                    log.write_bytes(b'operator evidence')
                    log.chmod(0o640)
                with assertion_safe_trial_state(self) as (state, cleanup):
                    retained = state.with_name(state.name + '-retained')
                    self.addCleanup(dispose_test_trial_state, retained)
                    (state / 'processes.dets').write_bytes(b'ownership evidence')
                    state.rename(retained)
                    state.symlink_to(external, target_is_directory=True)
                    with patch.object(paired, 'terminate_runtime_group') as stop, \
                            patch.object(paired.subprocess, 'Popen') as launch:
                        cleanup['complete'] = paired.terminate(
                            Mock(), project_root=Path(directory),
                            environment={'LEMON_EVAL_PROCESS_STORE': str(state / 'processes.dets')},
                            root_fd=cleanup['root_fd'])
                    stop.assert_called_once()
                    launch.assert_not_called()
                try:
                    self.assertFalse(cleanup['complete'])
                    self.assertFalse(cleanup['disposal_complete'])
                    self.assertEqual(external.stat().st_mode & 0o777, 0o700)
                    self.assertEqual(log.exists(), existing)
                    if existing:
                        self.assertEqual(log.read_bytes(), b'operator evidence')
                        self.assertEqual(log.stat().st_mode & 0o777, 0o640)
                    self.assertEqual((retained / 'processes.dets').read_bytes(), b'ownership evidence')
                finally:
                    state.unlink()
                    paired.dispose_trial_state(retained)

    def test_finalization_files_reject_replaced_roots_and_fixture_links(self):
        with tempfile.TemporaryDirectory() as directory:
            external = Path(directory) / 'external'
            external.mkdir()
            secret = external / 'runtime.json'
            secret.write_text('operator evidence')
            secret.chmod(0o640)
            with assertion_safe_trial_state(self) as (state, cleanup):
                (state / 'runtime.json').symlink_to(secret)
                with self.assertRaises(OSError):
                    paired.trial_file(state, cleanup['root_fd'], 'runtime.json')
                (state / 'flush.request').symlink_to(secret)
                with self.assertRaises(OSError):
                    paired.trial_file(state, cleanup['root_fd'], 'flush.request', 'w')
                retained = state.with_name(state.name + '-retained')
                self.addCleanup(dispose_test_trial_state, retained)
                state.rename(retained)
                state.symlink_to(external, target_is_directory=True)
                with self.assertRaises(PermissionError):
                    paired.trial_file(state, cleanup['root_fd'], 'runtime.json')
            try:
                self.assertEqual(secret.read_text(), 'operator evidence')
                self.assertEqual(secret.stat().st_mode & 0o777, 0o640)
            finally:
                state.unlink()
                paired.dispose_trial_state(retained)

    def test_recovery_log_cannot_follow_a_fixture_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / 'state'
            state.mkdir()
            external = root / 'external'
            external.write_bytes(b'private operator evidence')
            (state / 'cleanup.log').symlink_to(external)
            environment = {'LEMON_EVAL_PROCESS_STORE': str(state / 'processes.dets')}
            with patch.object(paired, 'terminate_runtime_group'), \
                    patch.object(paired.subprocess, 'Popen') as launch:
                self.assertFalse(paired.terminate(Mock(), project_root=root, environment=environment))
            launch.assert_not_called()
            self.assertEqual(external.read_bytes(), b'private operator evidence')

    def test_failed_or_timed_out_recovery_never_proves_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = {'LEMON_EVAL_PROCESS_STORE': str(root / 'processes.dets')}
            for outcome in ['failed', 'timeout']:
                with self.subTest(outcome=outcome):
                    recovery = Mock(pid=12345)
                    if outcome == 'timeout':
                        recovery.wait.side_effect = [subprocess.TimeoutExpired('recovery', 20), 0]
                        recovery.poll.return_value = None
                    else:
                        recovery.wait.return_value = 1
                        recovery.poll.return_value = 1
                    with patch.object(paired, 'terminate_runtime_group'), \
                            patch.object(paired.subprocess, 'Popen', return_value=recovery), \
                            patch.object(paired.os, 'killpg') as killpg:
                        self.assertFalse(paired.terminate(
                            Mock(), project_root=root, environment=environment))
                    if outcome == 'timeout':
                        killpg.assert_called_once_with(recovery.pid, paired.signal.SIGKILL)
                        self.assertEqual(recovery.wait.call_args_list,
                                         [call(timeout=20), call(timeout=5)])
                    else:
                        killpg.assert_not_called()
                        recovery.wait.assert_called_once_with(timeout=20)

    def test_darwin_unpinnable_directory_fails_without_permission_repair(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'target'
            target.mkdir(mode=0o500)
            with patch.object(paired.sys, 'platform', 'darwin'), \
                    patch.object(paired.os, 'open', side_effect=PermissionError('cannot pin')), \
                    self.assertRaises(PermissionError):
                paired.repair_trial_directory(target)
            self.assertEqual(target.stat().st_mode & 0o777, 0o500)

    def test_darwin_unreadable_directory_replacement_is_not_chmodded(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'target'
            target.mkdir(mode=0o700)
            original = Path(directory) / 'original'
            real_open = os.open
            calls = []

            def replace_on_open(path, flags, **kwargs):
                calls.append(flags)
                if len(calls) == 1:
                    target.rename(original)
                    target.mkdir(mode=0o500)
                    raise PermissionError('unreadable directory')
                # Emulate Darwin search-only pinning on any contract-test host.
                return real_open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, **kwargs)

            with patch.object(paired.sys, 'platform', 'darwin'), \
                    patch.object(paired.os, 'open', side_effect=replace_on_open), \
                    self.assertRaisesRegex(PermissionError, 'identity changed'):
                paired.repair_trial_directory(target)
            self.assertEqual(target.stat().st_mode & 0o777, 0o500)
            self.assertEqual(len(calls), 2)

    def test_unverified_cleanup_retains_private_state_even_with_forged_done_file(self):
        with assertion_safe_trial_state(self) as (state, cleanup):
            (state / 'cleanup.done').write_text('not an ownership witness')
            (state / 'processes.dets').write_bytes(b'private durable evidence')
        try:
            self.assertFalse(cleanup['complete'])
            self.assertFalse(cleanup['disposal_complete'])
            self.assertEqual(state.stat().st_mode & 0o777, 0o700)
            self.assertEqual((state / 'processes.dets').read_bytes(), b'private durable evidence')
        finally:
            paired.dispose_trial_state(state)

    def test_verified_cleanup_removes_trial_state(self):
        with assertion_safe_trial_state(self) as (state, cleanup):
            (state / 'private-output').write_text('private')
            cleanup['complete'] = True
        self.assertFalse(state.exists())
        self.assertTrue(cleanup['disposal_complete'])

    def test_retained_root_permissions_are_repaired_through_its_original_descriptor(self):
        with assertion_safe_trial_state(self) as (state, cleanup):
            (state / 'processes.dets').write_bytes(b'private ownership evidence')
            state.chmod(0o000)
        try:
            self.assertFalse(cleanup['complete'])
            self.assertFalse(cleanup['disposal_complete'])
            self.assertEqual(state.stat().st_mode & 0o777, 0o700)
            self.assertEqual((state / 'processes.dets').read_bytes(),
                             b'private ownership evidence')
        finally:
            paired.dispose_trial_state(state)

    def test_replaced_root_symlink_cannot_redirect_permission_repair_or_disposal(self):
        with tempfile.TemporaryDirectory() as directory:
            external = Path(directory) / 'external'
            external.mkdir(mode=0o500)
            with assertion_safe_trial_state(self) as (state, cleanup):
                (state / 'processes.dets').write_bytes(b'private ownership evidence')
                retained = state.with_name(state.name + '-retained')
                self.addCleanup(dispose_test_trial_state, retained)
                state.rename(retained)
                retained.chmod(0o000)
                state.symlink_to(external, target_is_directory=True)
                cleanup['complete'] = True
            try:
                self.assertTrue(cleanup['complete'])
                self.assertFalse(cleanup['disposal_complete'])
                self.assertTrue(cleanup['disposal_failed'])
                self.assertTrue(state.is_symlink())
                self.assertEqual(external.stat().st_mode & 0o777, 0o500)
                self.assertEqual(retained.stat().st_mode & 0o777, 0o700)
                self.assertEqual((retained / 'processes.dets').read_bytes(),
                                 b'private ownership evidence')
            finally:
                state.unlink()
                paired.dispose_trial_state(retained)
                external.chmod(0o700)

    def test_disposal_never_repairs_or_deletes_an_external_symlink_target(self):
        with tempfile.TemporaryDirectory() as directory:
            external = Path(directory) / 'external'
            external.mkdir(mode=0o700)
            marker = external / 'marker'
            marker.write_text('unrelated private data')
            external.chmod(0o500)
            try:
                with assertion_safe_trial_state(self) as (state, cleanup):
                    (state / 'external-link').symlink_to(external, target_is_directory=True)
                    cleanup['complete'] = True
                self.assertFalse(state.exists())
                self.assertTrue(cleanup['disposal_complete'])
                self.assertEqual(external.stat().st_mode & 0o777, 0o500)
                self.assertEqual(marker.read_text(), 'unrelated private data')
            finally:
                external.chmod(0o700)


    def test_root_replacement_during_disposal_cannot_delete_the_replacement(self):
        dispose = paired.dispose_trial_state
        retained = None

        def replace_before_disposal(state, **kwargs):
            nonlocal retained
            retained = state.with_name(state.name + '-retained')
            self.addCleanup(dispose_test_trial_state, retained)
            state.rename(retained)
            state.mkdir(mode=0o700)
            (state / 'unrelated-marker').write_text('unrelated private data')
            state.chmod(0o500)
            dispose(state, **kwargs)

        with patch.object(paired, 'dispose_trial_state', side_effect=replace_before_disposal):
            with assertion_safe_trial_state(self) as (state, cleanup):
                (state / 'processes.dets').write_bytes(b'private ownership evidence')
                cleanup['complete'] = True
        try:
            self.assertTrue(cleanup['complete'])
            self.assertFalse(cleanup['disposal_complete'])
            self.assertTrue(cleanup['disposal_failed'])
            self.assertEqual(state.stat().st_mode & 0o777, 0o500)
            self.assertEqual((state / 'unrelated-marker').read_text(), 'unrelated private data')
            self.assertEqual((retained / 'processes.dets').read_bytes(),
                             b'private ownership evidence')
        finally:
            state.chmod(0o700)
            dispose(state)
            if retained is not None:
                dispose(retained)

class RealFixtureExecutionTests(unittest.TestCase):
    """Exercise the real fixture/client/verifier path with a local deterministic CLI."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='lemon-paired-offline-')
        self.addCleanup(self.directory.cleanup)
        self.cli = Path(self.directory.name) / 'offline-client'
        self.environment = paired.isolated_environment(
            Path(self.directory.name) / 'runtime',
            paired.paired_configuration(ConfigurationIsolationTests.base, 'coding'),
            'coding', {'BENCHMARK_PROVIDER_API_KEY': 'explicit-offline-secret'},
            [4201, 4301, 4401],
        )
        self.cli.write_text('#!' + sys.executable + '\n' + textwrap.dedent('''\
            import json, os, pathlib, sys, time
            prompt = sys.argv[sys.argv.index('-p') + 1]
            root = pathlib.Path(sys.argv[sys.argv.index('--cwd') + 1])
            assert (root / 'fixture.txt').read_text() == 'identical fixture\\n'
            assert not (root / 'prior-attempt.txt').exists()
            assert os.environ['BENCHMARK_PROVIDER_API_KEY'] == 'explicit-offline-secret'
            assert os.environ['LEMON_TOOL_DISCLOSURE_PROFILE'] == 'coding'
            if prompt.startswith('timeout'):
                time.sleep(5)
            (root / 'prior-attempt.txt').write_text('attempt-local')
            print(json.dumps({
                'ok': not prompt.startswith('failure'),
                'answer': 'wrong answer' if prompt.startswith('verifier_failure') else 'verified answer',
                'usage': {'inputTokens': 11, 'cacheReadTokens': 7,
                          'outputTokens': 3, 'totalTokens': 21, 'costUsd': 0.125},
                'metrics': {'turns': 2, 'tool_errors': 1},
            }))
        '''))
        self.cli.chmod(0o700)

    def case(self, mode):
        return {
            'name': 'offline_fixture',
            'prompt': mode,
            'files': {'fixture.txt': 'identical fixture\n'},
            'verify': ("import os\n"
                       "assert os.environ['BENCHMARK_ANSWER'] == 'verified answer'\n"
                       "assert os.environ['LEMON_TOOL_DISCLOSURE_PROFILE'] == 'coding'\n"
                       "assert os.environ['BENCHMARK_PROVIDER_API_KEY'] == 'explicit-offline-secret'\n"),
        }

    def run_case(self, mode):
        args = SimpleNamespace(timeout=2, failure_dir=None, run_timeout=2)
        args.environment = self.environment
        if mode == 'timeout':
            args.attempt_deadline = time.monotonic() + 2
        return benchmark.run_case(self.case(mode), 'lemon', str(self.cli),
                                  'offline:model', args)

    def test_verifier_interrupt_keeps_observed_paid_counters_and_prior_failure(self):
        command = benchmark.command

        def interrupt_verifier(argv, *args, **kwargs):
            if argv[:2] == [sys.executable, '-c']:
                raise KeyboardInterrupt
            return command(argv, *args, **kwargs)

        with assertion_safe_trial_state(self) as (state, cleanup):
            args = SimpleNamespace(timeout=2, failure_dir=None, environment=self.environment,
                                   fixture_root=state / 'fixture')
            with patch.object(benchmark, 'command', side_effect=interrupt_verifier):
                with self.assertRaises(paired.TrialInterrupted) as caught:
                    benchmark.run_case(self.case('failure'), 'lemon', str(self.cli),
                                       'offline:model', args)
            row = caught.exception.row
            self.assertFalse(row['passed'])
            self.assertEqual(row['failure'], 'agent_failed')
            self.assertEqual(row['cost_usd'], 0.125)
            self.assertEqual(row['tokens'], 21)
            self.assertTrue((state / 'fixture').exists())
            cleanup['complete'] = True

    def test_failure_bundle_interrupt_keeps_paid_counters(self):
        with assertion_safe_trial_state(self) as (state, cleanup):
            args = SimpleNamespace(timeout=2, failure_dir=str(state / 'bundles'),
                                   environment=self.environment, fixture_root=state / 'fixture')
            with patch.object(benchmark.shutil, 'copytree', side_effect=KeyboardInterrupt):
                with self.assertRaises(paired.TrialInterrupted) as caught:
                    benchmark.run_case(self.case('failure'), 'lemon', str(self.cli),
                                       'offline:model', args)
            self.assertEqual(caught.exception.row['failure'], 'agent_failed')
            self.assertEqual(caught.exception.row['cost_usd'], 0.125)
            self.assertEqual(caught.exception.row['tokens'], 21)
            cleanup['complete'] = True

    def test_success_and_failure_use_fresh_fixtures_and_independent_verification(self):
        success = self.run_case('success')
        failed = self.run_case('failure')
        self.assertTrue(success['passed'])
        self.assertTrue(success['verifier_passed'])
        self.assertFalse(failed['passed'])
        self.assertTrue(failed['verifier_passed'])
        self.assertEqual(failed['failure'], 'agent_failed')
        for row in [success, failed]:
            self.assertEqual(row['turns'], 2)
            self.assertEqual(row['uncached_input_tokens'], 11)
            self.assertEqual(row['cached_input_tokens'], 7)
            self.assertEqual(row['output_tokens'], 3)
            self.assertEqual(row['tool_errors'], 1)
            self.assertEqual(row['cost_usd'], 0.125)
            self.assertGreaterEqual(row['wall_seconds'], 0)

    def test_cli_success_without_external_verifier_success_is_a_failure(self):
        row = self.run_case('verifier_failure')
        self.assertFalse(row['passed'])
        self.assertFalse(row['verifier_passed'])
        self.assertEqual(row['failure'], 'verifier_failed')
        self.assertEqual(row['turns'], 2)
        self.assertEqual(row['cached_input_tokens'], 7)

    def test_timeout_is_retained_with_nullable_counters(self):
        row = self.run_case('timeout')
        self.assertFalse(row['passed'])
        self.assertEqual(row['failure'], 'timeout')
        self.assertIsNone(row['verifier_passed'])
        for counter in ['turns', 'tokens', 'uncached_input_tokens',
                        'cached_input_tokens', 'output_tokens', 'tool_errors']:
            self.assertIsNone(row[counter], counter)
        self.assertGreaterEqual(row['wall_seconds'], 0)

    def test_paired_fixture_survives_case_until_verified_runtime_teardown(self):
        with assertion_safe_trial_state(self) as (state, cleanup):
            args = SimpleNamespace(timeout=2, failure_dir=None, environment=self.environment,
                                   fixture_root=state / 'fixture')
            row = benchmark.run_case(self.case('success'), 'lemon', str(self.cli),
                                     'offline:model', args)
            self.assertTrue(row['passed'])
            self.assertEqual((args.fixture_root / 'prior-attempt.txt').read_text(), 'attempt-local')
            cleanup['complete'] = True
        self.assertFalse(state.exists())


class TrialDisposalConsumerTests(unittest.TestCase):
    """Real fixtures, private directories and reports; only runtime boot is local."""

    def consume(self, fault=None):
        with tempfile.TemporaryDirectory(prefix='lemon-disposal-consumer-') as directory:
            root = Path(directory)
            trial_parent = root / 'trials'
            trial_parent.mkdir(mode=0o700)
            disposal_probe = trial_parent / 'empty-disposal-probe'
            disposal_probe.mkdir(mode=0o700)
            source = root / 'apps' / 'lemon_evals' / 'priv' / 'coding_benchmark_paired.py'
            source.parent.mkdir(parents=True)
            source.write_text('offline consumer source\n')
            beam = root / '_build' / 'dev' / 'lib' / 'offline' / 'ebin' / 'offline.beam'
            beam.parent.mkdir(parents=True)
            beam.write_bytes(b'offline consumer build identity')
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            subprocess.run(['git', 'add', '.'], cwd=root, check=True)
            subprocess.run(['git', '-c', 'user.name=Offline Consumer',
                            '-c', 'user.email=offline@example.invalid',
                            'commit', '-qm', 'offline fixture'], cwd=root, check=True)
            config = root / 'base.toml'
            config.write_text(ConfigurationIsolationTests.base)
            cli = root / 'bin' / 'lemon'
            cli.parent.mkdir()
            cli.write_text('#!' + sys.executable + '\n' + textwrap.dedent('''\
                import json, os, pathlib, sys
                root = pathlib.Path(sys.argv[sys.argv.index('--cwd') + 1])
                assert (root / 'fixture.txt').read_text() == 'fixture input'
                cache = pathlib.Path(os.environ['HOME']) / 'go' / 'pkg' / 'mod'
                cache.mkdir(parents=True)
                (cache / 'module.txt').write_text('private module cache')
                for item in [cache, cache.parent, cache.parent.parent]:
                    item.chmod(0o500)
                nested = root / 'readonly' / 'nested'
                nested.mkdir(parents=True)
                (nested / 'result').write_text('private fixture output')
                nested.chmod(0o100 if sys.platform == 'darwin' else 0o000)
                nested.parent.chmod(0o500)
                print(json.dumps({
                    'ok': False, 'answer': 'verified answer', 'run_id': 'offline-run',
                    'usage': {'inputTokens': 11, 'cacheReadTokens': 7,
                              'outputTokens': 3, 'totalTokens': 21, 'costUsd': 0.125},
                    'metrics': {'turns': 1, 'tool_errors': 1},
                }))
            '''))
            cli.chmod(0o700)
            runtime_code = textwrap.dedent('''\
                import http.server, json, os, pathlib, threading, time
                state = pathlib.Path(os.environ['LEMON_EVAL_STATE'])
                class Health(http.server.BaseHTTPRequestHandler):
                    def do_GET(self):
                        self.send_response(200)
                        self.end_headers()
                        self.wfile.write(b'{"ok": true}')
                    def log_message(self, *args):
                        pass
                server = http.server.HTTPServer(
                    ('127.0.0.1', int(os.environ['LEMON_CONTROL_PLANE_PORT'])), Health)
                threading.Thread(target=server.serve_forever, daemon=True).start()
                profile = os.environ['LEMON_TOOL_DISCLOSURE_PROFILE']
                key = {'run_id': 'offline-run', 'session_id': 'offline-session',
                       'request_index': 1}
                events = [
                    dict(key, event='payload'),
                    dict(key, event='usage', provider_usage={
                        'input_tokens': 11, 'output_tokens': 3, 'cache_read_tokens': 7,
                        'cache_write_tokens': 0, 'total_tokens': 21}),
                    {'event': 'disclosure_applied', 'profile': profile,
                     'diagnostic_events_version': 1},
                ]
                pathlib.Path(os.environ['LEMON_EVAL_PROFILE']).write_text(
                    ''.join(json.dumps(event) + '\\n' for event in events))
                pathlib.Path(os.environ['LEMON_EVAL_METADATA']).write_text(
                    json.dumps({'elixir': 'offline', 'otp': 'offline'}))
                while True:
                    if (state / 'flush.request').exists():
                        (state / 'flush.done').write_text('ok')
                    time.sleep(0.01)
            ''')
            args = SimpleNamespace(
                lemon=str(cli), model='offline:model', compare_omp=False,
                config=str(config), timeout=10, run_timeout=60, repetitions=1,
                seed=17, profile_python=sys.executable, live=False,
                output=str(root / '.git' / 'consumer-report.json'), plan=None, approve_plan_digest=None,
                failure_dir=None,
            )
            case = {'name': 'offline_fixture', 'prompt': 'offline attempt',
                    'files': {'fixture.txt': 'fixture input'},
                    'verify': "import os\nassert os.environ['BENCHMARK_ANSWER'] == 'verified answer'\n"}
            real_execute_trial = paired.execute_trial
            real_mkdtemp = tempfile.mkdtemp
            states, calls, retained_until_cleanup = [], [], []
            disposal_refusals = []

            def execute_trial(*arguments, **kwargs):
                return real_execute_trial(
                    *arguments, **kwargs, runtime_argv=[sys.executable, '-c', runtime_code])

            def new_trial(*arguments, **kwargs):
                if kwargs.get('prefix') == 'lemon-paired-runtime-':
                    kwargs['dir'] = trial_parent
                return real_mkdtemp(*arguments, **kwargs)

            def stop_runtime(process, **kwargs):
                state = Path(kwargs['environment']['LEMON_EVAL_STATE'])
                retained_until_cleanup.append((state / 'fixture' / 'fixture.txt').exists())
                paired.terminate_runtime_group(process)
                if fault == 'cleanup_exception':
                    raise RuntimeError('private unexpected cleanup error')
                return fault != 'cleanup_false'  # Local adapter has no native admission/ledger.

            def run_case(case, agent, executable, model, attempt_args):
                calls.append(attempt_args.trial_id)
                state = attempt_args.fixture_root.parent
                states.append(state)
                # Keep independent evidence to check retention, not a forged witness.
                (state / 'processes.dets').write_bytes(b'private ownership evidence')
                row = benchmark.run_case(case, agent, executable, model, attempt_args)
                if fault == 'parent_permissions':
                    trial_parent.chmod(0o500)
                    try:
                        disposal_probe.rmdir()
                    except PermissionError:
                        disposal_refusals.append(True)
                    else:
                        raise AssertionError('read-only trial parent unexpectedly allowed deletion')
                elif fault == 'metadata':
                    (state / 'runtime.json').write_text('invalid private metadata')
                return row

            try:
                with patch.object(paired, '__file__', str(source)), \
                        patch.object(paired, 'execute_trial', side_effect=execute_trial), \
                        patch.object(paired.tempfile, 'mkdtemp', side_effect=new_trial), \
                        patch.object(paired, 'terminate', side_effect=stop_runtime), \
                        patch.dict(os.environ, {'BENCHMARK_PROVIDER_API_KEY': 'offline-only'}):
                    self.assertEqual(paired.run_paired(args, [case], run_case), 0)
                    plan = json.loads(Path(args.output).read_text())['plan']
                    plan.update(approved=True, max_spend_usd=1,
                                per_attempt_spend_ceiling_usd=0.25,
                                provider_budget_enforced=True,
                                credential_env=['BENCHMARK_PROVIDER_API_KEY'])
                    args.plan = str(root / '.git' / 'consumer-approved.json')
                    Path(args.plan).write_text(json.dumps(plan))
                    args.approve_plan_digest = canonical_digest(plan)
                    args.live = True
                    if fault == 'disposal_exception':
                        with patch.object(paired, 'dispose_trial_state',
                                          side_effect=RuntimeError('private disposal error')):
                            status = paired.run_paired(args, [case], run_case)
                    elif fault == 'profile_exception':
                        with patch.object(paired, 'collect_profile',
                                          side_effect=RuntimeError('private profile error')):
                            status = paired.run_paired(args, [case], run_case)
                    elif fault == 'report_interrupt':
                        write_report = paired.write_report
                        interrupted = []

                        def interrupt_once(path, report):
                            if report.get('results') and not interrupted:
                                interrupted.append(True)
                                raise KeyboardInterrupt
                            return write_report(path, report)

                        with patch.object(paired, 'write_report', side_effect=interrupt_once):
                            status = paired.run_paired(args, [case], run_case)
                    else:
                        status = paired.run_paired(args, [case], run_case)
                report_text = Path(args.output).read_text()
                return {
                    'status': status, 'report': json.loads(report_text), 'calls': calls,
                    'exists': [state.exists() for state in states],
                    'private': [state.stat().st_mode & 0o777 == 0o700
                                for state in states if state.exists()],
                    'evidence': [(state / 'processes.dets').read_bytes().decode()
                                 for state in states if state.exists()],
                    'retained_until_cleanup': retained_until_cleanup,
                    'os_disposal_refused': bool(disposal_refusals),
                    'redacted': all(secret not in report_text for secret in
                                    [directory, 'private disposal error',
                                     'private unexpected cleanup error', 'private profile error']),
                }
            finally:
                trial_parent.chmod(0o700)
                for state in states:
                    if state.exists():
                        paired.dispose_trial_state(state)

    def assert_retained_attempt(self, result, reason, process_cleanup):
        report = result['report']
        self.assertEqual(result['status'], 1)
        self.assertEqual(len(result['calls']), 1)
        self.assertEqual(report['stop_reason'], reason)
        self.assertEqual(len(report['results']), 2)
        attempted, skipped = report['results']
        self.assertTrue(attempted['attempted'])
        self.assertEqual(attempted['failure'], 'agent_failed')
        self.assertEqual(attempted['cost_usd'], 0.125)
        self.assertEqual(attempted['turns'], 1)
        self.assertEqual(attempted['tokens'], 21)
        self.assertEqual(attempted['uncached_input_tokens'], 11)
        self.assertEqual(attempted['cached_input_tokens'], 7)
        self.assertIsNone(attempted['cache_write_tokens'])
        self.assertEqual(attempted['output_tokens'], 3)
        self.assertEqual(attempted['tool_errors'], 1)
        self.assertEqual(attempted['cleanup_complete'], process_cleanup)
        self.assertFalse(attempted['disposal_complete'])
        self.assertEqual(attempted['finalization_failed'], reason == 'finalization_failed')
        self.assertFalse(skipped['attempted'])
        self.assertEqual(skipped['failure'], reason)
        self.assertEqual(report['all_attempt_measured_spend_usd'], 0.125)
        self.assertEqual(result['exists'], [True])
        self.assertEqual(result['private'], [True])
        self.assertEqual(result['evidence'], ['private ownership evidence'])
        self.assertEqual(result['retained_until_cleanup'], [True])
        self.assertTrue(result['redacted'])

    def test_readonly_home_and_fixture_disposal_uses_real_consumer(self):
        result = self.consume()
        self.assertEqual(len(result['calls']), 2)
        self.assertEqual(result['exists'], [False, False])
        self.assertEqual(result['retained_until_cleanup'], [True, True])
        self.assertIsNone(result['report']['stop_reason'])
        self.assertEqual(result['report']['all_attempt_measured_spend_usd'], 0.25)
        for row in result['report']['results']:
            self.assertTrue(row['attempted'])
            self.assertTrue(row['cleanup_complete'])
            self.assertTrue(row['disposal_complete'])
            self.assertFalse(row['finalization_failed'])
            self.assertEqual(row['failure'], 'agent_failed')
            self.assertEqual(row['cost_usd'], 0.125)
            self.assertTrue(row['spend_complete'])
        self.assertTrue(result['redacted'])

    @unittest.skipUnless(hasattr(os, 'O_PATH'), 'requires the Linux descriptor contract')
    def test_linux_consumer_does_not_require_nofollow_chmod_support(self):
        real_chmod = os.chmod

        def supported_chmod(path, mode, **kwargs):
            if kwargs.get('follow_symlinks') is False:
                raise NotImplementedError('platform does not support no-follow chmod')
            return real_chmod(path, mode, **kwargs)

        with patch.object(os, 'chmod', side_effect=supported_chmod):
            self.test_readonly_home_and_fixture_disposal_uses_real_consumer()

    def test_actual_disposal_failure_retains_paid_row_in_isolated_consumer(self):
        # A private subprocess confines permission changes and drops root before
        # creating its fixture, so this is a real OS refusal, not an rmtree mock.
        script = textwrap.dedent('''\
            import json, os
            from test_coding_benchmark_paired import TrialDisposalConsumerTests
            if os.geteuid() == 0:
                os.setgroups([])
                os.setgid(65534)
                os.setuid(65534)
            print(json.dumps(TrialDisposalConsumerTests().consume('parent_permissions')))
        ''')
        process = subprocess.run([sys.executable, '-c', script],
                                 cwd=Path(__file__).parent, capture_output=True,
                                 text=True, timeout=30)
        self.assertEqual(process.returncode, 0, process.stderr)
        result = json.loads(process.stdout)
        self.assert_retained_attempt(result, 'disposal_unverified', True)
        self.assertTrue(result['os_disposal_refused'])

    def test_unexpected_disposal_exception_retains_paid_row(self):
        self.assert_retained_attempt(self.consume('disposal_exception'),
                                     'disposal_unverified', True)

    def test_unexpected_cleanup_exception_retains_paid_row(self):
        self.assert_retained_attempt(self.consume('cleanup_exception'),
                                     'cleanup_unverified', False)

    def test_unverified_cleanup_retains_paid_row(self):
        self.assert_retained_attempt(self.consume('cleanup_false'), 'cleanup_unverified', False)

    def test_metadata_exception_after_paid_row_does_not_replace_it(self):
        self.assert_retained_attempt(self.consume('metadata'), 'finalization_failed', True)

    def test_unexpected_profile_exception_retains_paid_row(self):
        self.assert_retained_attempt(self.consume('profile_exception'),
                                     'finalization_failed', True)

    def test_direct_paired_report_interrupt_persists_paid_attempt_before_exit(self):
        result = self.consume('report_interrupt')
        self.assertEqual(result['status'], 130)
        self.assertEqual(len(result['calls']), 1)
        self.assertEqual(len(result['report']['results']), 1)
        row = result['report']['results'][0]
        self.assertEqual(row['cost_usd'], 0.125)
        self.assertEqual(row['failure'], 'agent_failed')
        self.assertTrue(row['finalization_failed'])
        self.assertFalse(result['report']['complete'])


if __name__ == '__main__':
    unittest.main()
