"""Offline fixtures for the isolated coding arena's paired disclosure comparison (#107).

No Docker, proxy or model calls: containers are fakes and reports are built from
synthetic rows. These check runner/report mechanics, not model performance.
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent / 'coding_arena'))
import arena  # noqa: E402

TASKS = [{'id': f't{index}'} for index in range(6)]
ARMS = ['lemon-legacy', 'lemon-coding']


class FakeContainer:
    def __init__(self):
        self.writes, self.execs = {}, []

    def write(self, path, content, **_):
        self.writes[path] = content

    def exec(self, argv, env=None, **_):
        self.execs.append((argv, dict(env or {})))
        return SimpleNamespace(returncode=0, stdout='', stderr='')


def row(task, agent, rep, passed, model='glm-5.3', failure=None, **extra):
    return {'id': f'{task}--{agent}--r{rep}', 'task': task, 'agent': agent, 'rep': rep, 'model': model,
            'passed': passed, 'failure': None if passed else (failure or 'verifier_failed'),
            'language': 'python', 'category': 'bug_fix', 'difficulty': 'easy',
            'proxy_trial': f'{task}--{agent}--r{rep}#0', **extra}


def report(rows, proxy=()):
    with tempfile.TemporaryDirectory() as directory:
        out = Path(directory)
        (out / 'results.jsonl').write_text(''.join(json.dumps(item) + '\n' for item in rows))
        (out / 'proxy.jsonl').write_text(''.join(json.dumps(item) + '\n' for item in proxy))
        with patch('builtins.print'):
            arena.cmd_report(SimpleNamespace(output_dir=str(out), proxy_log=None))
        return json.loads((out / 'report.json').read_text()), (out / 'report.md').read_text()


class PairScheduling(unittest.TestCase):
    def test_every_group_has_each_arm_exactly_once_and_adjacent(self):
        trials = arena.plan_trials(TASKS, ARMS, 3, seed=107)
        self.assertEqual(len(trials), len(TASKS) * len(ARMS) * 3)
        self.assertEqual(len({trial['id'] for trial in trials}), len(trials))
        for index in range(0, len(trials), 2):
            first, second = trials[index], trials[index + 1]
            self.assertEqual((first['task'], first['rep']), (second['task'], second['rep']))
            self.assertEqual({first['agent'], second['agent']}, set(ARMS))

    def test_schedule_is_seeded_and_arm_order_is_counterbalanced(self):
        self.assertEqual(arena.plan_trials(TASKS, ARMS, 3, 107), arena.plan_trials(TASKS, ARMS, 3, 107))
        self.assertNotEqual(arena.plan_trials(TASKS, ARMS, 3, 107), arena.plan_trials(TASKS, ARMS, 3, 108))
        firsts = [trial['agent'] for trial in arena.plan_trials(TASKS, ARMS, 3, 107)[::2]]
        self.assertEqual(set(firsts), set(ARMS))

    def test_repetitions_run_in_order(self):
        reps = [trial['rep'] for trial in arena.plan_trials(TASKS, ARMS, 3, 1)]
        self.assertEqual(reps, sorted(reps))


class IsolationAndConfig(unittest.TestCase):
    def prepare(self, agent):
        container = FakeContainer()
        args = SimpleNamespace(thinking='high', proxy_port=18787)
        env = arena.AGENTS[agent][0](container, args, 'trial-token', 'glm-5.3')
        return container, env

    def test_arms_pin_disclosure_profile_and_share_everything_else(self):
        legacy_container, legacy = self.prepare('lemon-legacy')
        coding_container, coding = self.prepare('lemon-coding')
        default_container, default = self.prepare('lemon')
        self.assertEqual(legacy['LEMON_TOOL_DISCLOSURE_PROFILE'], 'legacy')
        self.assertEqual(coding['LEMON_TOOL_DISCLOSURE_PROFILE'], 'coding')
        self.assertNotIn('LEMON_TOOL_DISCLOSURE_PROFILE', default)
        config = legacy_container.writes['/home/agent/.lemon/config.toml']
        self.assertEqual(config, coding_container.writes['/home/agent/.lemon/config.toml'])
        self.assertEqual(config, default_container.writes['/home/agent/.lemon/config.toml'])
        self.assertIn('thinking_level = "high"', config)
        self.assertNotIn('trial-token', config)
        self.assertEqual(legacy['ZAI_API_KEY'], 'trial-token')
        self.assertEqual(coding_container.execs[0], (['lemon', 'daemon'], coding))

    def test_each_trial_gets_fresh_runtime_secrets(self):
        _, first = self.prepare('lemon-coding')
        _, second = self.prepare('lemon-coding')
        for key in ('LEMON_SECRETS_MASTER_KEY', 'LEMON_CONTROL_PLANE_OPERATOR_TOKEN'):
            self.assertNotEqual(first[key], second[key])

    def test_trial_records_requested_profile_as_unverified_and_fresh_container(self):
        created = []

        class Boom:
            def __init__(self, image, name, *_):
                created.append((image, name))
                raise RuntimeError('docker unavailable')

        task = {'language': 'python', 'category': 'bug_fix', 'difficulty': 'easy'}
        args = SimpleNamespace(proxy_secret='s', thinking='high', cpus='2', memory='3g')
        with tempfile.TemporaryDirectory() as directory, patch.object(arena, 'Container', Boom):
            result = arena.run_trial({'id': 't0--lemon-coding--r1', 'task': 't0', 'agent': 'lemon-coding', 'rep': 1},
                                     task, args, Path(directory), 'glm-5.3')
        self.assertEqual(created, [('lemon-arena-lemon', 'arena-t0--lemon-coding--r1')])
        self.assertEqual(result['requested_disclosure_profile'], 'coding')
        self.assertIsNone(result['observed_disclosure_profile'])
        self.assertEqual(result['disclosure_attribution'], 'unverified')
        self.assertEqual(result['failure'], 'infrastructure')
        self.assertFalse(result['passed'])


class Aggregation(unittest.TestCase):
    def test_paired_mcnemar_counts_only_same_model_groups(self):
        rows = []
        outcomes = {'t0': (True, True), 't1': (True, False), 't2': (False, True), 't3': (False, True),
                    't4': (False, False)}
        for task, (legacy, coding) in outcomes.items():
            rows += [row(task, 'lemon-legacy', 1, legacy, failure='timeout'), row(task, 'lemon-coding', 1, coding)]
        rows.append(row('t5', 'lemon-legacy', 1, True, model='k3.1-pro'))
        rows.append(row('t5', 'lemon-coding', 1, True, model='glm-5.3'))
        result, markdown = report(rows)
        [pair] = result['pooled']['paired']
        self.assertEqual((pair['a'], pair['b']), ('lemon-coding', 'lemon-legacy'))
        self.assertEqual((pair['pairs'], pair['only_a'], pair['only_b'], pair['both'], pair['neither']),
                         (5, 2, 1, 1, 1))
        self.assertEqual(pair['mcnemar_exact_p'], 1.0)
        self.assertEqual(result['pooled']['complete_groups'], 5)
        self.assertIn('McNemar exact p', markdown)

    def test_failures_and_timeouts_are_scored_and_infrastructure_is_retained_separately(self):
        rows = [row('t0', 'lemon-legacy', 1, False, failure='timeout'), row('t0', 'lemon-coding', 1, True),
                row('t1', 'lemon-legacy', 1, False, failure='infrastructure'),
                row('t1', 'lemon-coding', 1, False, failure='agent_error')]
        result, _ = report(rows)
        overall = result['models']['glm-5.3']['overall']
        self.assertEqual((overall['lemon-legacy']['passed'], overall['lemon-legacy']['total']), (0, 1))
        self.assertEqual((overall['lemon-coding']['passed'], overall['lemon-coding']['total']), (1, 2))
        self.assertEqual(result['infrastructure_failures'], 1)
        failures = result['all_attempt_efficiency']['lemon-legacy']['failures']
        self.assertEqual(failures, {'timeout': 1, 'infrastructure': 1})
        self.assertEqual(result['all_attempt_efficiency']['lemon-legacy']['token_totals']
                         ['wire_input_tokens']['attempted_trials'], 2)

    def test_latest_attempt_of_a_rerun_trial_is_scored(self):
        rows = [row('t0', 'lemon-coding', 1, False, failure='infrastructure'), row('t0', 'lemon-coding', 1, True),
                row('t0', 'lemon-legacy', 1, True)]
        result, _ = report(rows)
        self.assertEqual(result['trials'], 2)
        self.assertEqual(result['models']['glm-5.3']['overall']['lemon-coding']['total'], 1)
        self.assertEqual(result['all_attempt_efficiency']['lemon-coding']['token_totals']
                         ['wire_input_tokens']['attempted_trials'], 2)


class MissingCountersAndZeroSuccess(unittest.TestCase):
    def usage(self, trial, **counts):
        return {'trial': trial, 'path': '/zai/api/coding/paas/v4/chat/completions', 'kind': 'usage',
                'usage_style': 'uncached', **counts}

    def test_missing_wire_usage_stays_null_not_zero(self):
        legacy, coding = row('t0', 'lemon-legacy', 1, True), row('t0', 'lemon-coding', 1, True)
        proxy = [self.usage(legacy['proxy_trial'], input_tokens=100, cache_read_tokens=50, output_tokens=7),
                 {'trial': coding['proxy_trial'], 'path': '/zai/api/coding/paas/v4/chat/completions',
                  'kind': 'usage_missing'}]
        result, markdown = report([legacy, coding], proxy)
        totals = result['all_attempt_efficiency']
        self.assertEqual(totals['lemon-legacy']['token_totals']['wire_input_tokens']['sum'], 150)
        self.assertEqual(totals['lemon-legacy']['token_totals']['wire_cached_tokens']['sum'], 50)
        coding_input = totals['lemon-coding']['token_totals']['wire_input_tokens']
        self.assertIsNone(coding_input['sum'])
        self.assertEqual((coding_input['observed_sum'], coding_input['observed_trials']), (0, 0))
        self.assertIsNone(result['models']['glm-5.3']['efficiency']['lemon-coding']['wire_input_tokens'])
        self.assertIn('| lemon-coding | None |', markdown)

    def test_partially_missing_usage_keeps_sum_null_but_retains_observed_part(self):
        rows = [row('t0', 'lemon-coding', 1, True), row('t1', 'lemon-coding', 1, True)]
        result, _ = report(rows, [self.usage(rows[0]['proxy_trial'], input_tokens=10, output_tokens=1)])
        totals = result['all_attempt_efficiency']['lemon-coding']['token_totals']['wire_input_tokens']
        self.assertEqual((totals['sum'], totals['observed_sum'], totals['observed_trials'],
                          totals['attempted_trials']), (None, 10, 1, 2))

    def test_zero_successes_never_produce_cost_or_rate_artifacts(self):
        rows = [row('t0', 'lemon-legacy', 1, False), row('t0', 'lemon-coding', 1, False, failure='timeout')]
        result, markdown = report(rows)
        for agent in ARMS:
            efficiency = result['all_attempt_efficiency'][agent]
            self.assertEqual(efficiency['verified_successes'], 0)
            self.assertIsNone(efficiency['cost_per_verified_success_usd'])
            self.assertEqual(efficiency['pricing_status'], 'unknown_pricing')
            overall = result['models']['glm-5.3']['overall'][agent]
            self.assertEqual((overall['passed'], overall['rate']), (0, 0.0))
        [pair] = result['pooled']['paired']
        self.assertEqual((pair['neither'], pair['mcnemar_exact_p']), (1, 1.0))
        self.assertIn('unknown (unknown_pricing)', markdown)

    def test_no_scored_rows_report_null_rates_and_intervals(self):
        result, _ = report([row('t0', 'lemon-coding', 1, False, failure='infrastructure')])
        self.assertEqual(result['models'], {})
        self.assertEqual(result['pooled']['overall']['lemon-coding'],
                         {'passed': 0, 'total': 0, 'rate': None, 'ci95': [None, None]})
        self.assertEqual(arena.wilson(0, 0), (None, None))


if __name__ == '__main__':
    unittest.main()
