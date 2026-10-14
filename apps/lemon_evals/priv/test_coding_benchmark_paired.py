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
from types import SimpleNamespace
from unittest.mock import patch

import coding_benchmark as benchmark
import coding_benchmark_paired as paired


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
            'LEMON_DOTENV_DIR': '/private/ordinary-dotenv',
            'LEMON_AGENT_PROFILES_CWD': '/private/ordinary-project',
            'LEMON_CONTROL_PLANE_PORT': '9999',
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
                self.assertTrue(Path(env['LEMON_AGENT_PROFILES_CWD']).is_relative_to(root))
                self.assertEqual(env['LEMON_DOTENV_DIR'], env['LEMON_AGENT_PROFILES_CWD'])
                self.assertEqual(env['LEMON_TOOL_DISCLOSURE_PROFILE'],
                                 'legacy' if variant == 'baseline' else 'coding')
                self.assertEqual(env['LEMON_CONTROL_PLANE_PORT'], str(4200 + index))
                self.assertEqual(env['LEMON_WEB_PORT'], str(4300 + index))
                self.assertEqual(env['LEMON_SIM_UI_PORT'], str(4400 + index))
                self.assertEqual(env['BENCHMARK_PROVIDER_API_KEY'], credentials['BENCHMARK_PROVIDER_API_KEY'])
                for key in ['OPENAI_API_KEY', 'HTTPS_PROXY', 'BASH_ENV']:
                    self.assertNotIn(key, env)
                self.assertNotIn('ambient-operator-secret', env.values())
                self.assertNotIn('ambient-master-secret', env.values())
            for key in ['HOME', 'LEMON_STORE_PATH', 'LEMON_AGENT_PROFILES_CWD',
                        'LEMON_CONTROL_PLANE_OPERATOR_TOKEN', 'LEMON_SECRETS_MASTER_KEY']:
                self.assertNotEqual(environments[0][key], environments[1][key])
            marker = Path(environments[0]['HOME']) / 'attempt-one-only'
            marker.write_text('private state')
            self.assertFalse((Path(environments[1]['HOME']) / marker.name).exists())


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
            'input_tokens': 20, 'output_tokens': 3, 'cache_read_tokens': 7})
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'profile.jsonl'

            def complete(records, turns=1):
                path.write_text('\n'.join(json.dumps(record) for record in records) + '\n')
                diagnostics = paired.collect_profile(path, 'private-run', turns)
                self.assertNotIn('private-run', json.dumps(diagnostics))
                self.assertNotIn('private-session', json.dumps(diagnostics))
                return diagnostics['parent_usage_complete']

            self.assertTrue(complete([payload, usage]))
            for records, turns in [
                ([], 0), ([], 1), ([payload], 1),
                ([payload, dict(usage, request_index=2)], 1),
                ([payload, usage, usage], 1),
                ([payload, usage], 2),
                ([payload, dict(usage, provider_usage={})], 1),
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
                paired.terminate(process)
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


if __name__ == '__main__':
    unittest.main()
