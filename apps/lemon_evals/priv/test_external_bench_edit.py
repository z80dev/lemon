"""Offline fixture-runner smoke with a scripted mock model and tool transport.

This tests adaptation/accounting, not a substitute implementation of Lemon's
edit semantics. The orchestrator separately runs the real tool ExUnit suites.
"""
import io
import json
from pathlib import Path
import shutil
import sys
import tarfile
import tempfile
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent / 'coding_arena'))
try:
    import arena
    import edit_benchmark as benchmark
    import edit_errors
    import terminal_bench
finally:
    sys.path.pop(0)


def lemon_event(phase, identifier, name, args, result=None, ok=True):
    detail = {'tool_call_id': identifier, 'name': name, 'args': args}
    if result is not None:
        detail['result'] = {'content': [{'type': 'text', 'text': result}]}
    return {'type': 'event', 'event': 'agent', 'payload': {'type': 'tool_use',
            'phase': phase, 'ok': ok, 'action': {'detail': detail}}}


class ExternalEditParsingTests(unittest.TestCase):
    def test_error_classes_link_verified_producers_or_explicit_propagation(self):
        cases = [('edit', 'Could not find the exact text to replace.', 'text_not_found', 'edit.ex#L492'),
                 ('edit', 'Found 2 occurrences of the text', 'ambiguous_text', 'edit.ex#L499'),
                 ('edit', 'Unseen lines 4 in snapshot', 'unseen_lines', 'edit.ex#L437'),
                 ('patch', 'Context not found for patch hunk', 'context_not_found', 'patch.ex#L1756'),
                 ('patch', 'Ambiguous patch hunk', 'ambiguous_context', 'patch.ex#L1756'),
                 ('patch', 'Invalid patch syntax at line 3', 'invalid_patch', 'patch.ex#L649')]
        for tool, text, category, site in cases:
            with self.subTest(category=category):
                result = edit_errors.classify(tool, text)
                self.assertEqual(result['class'], category)
                self.assertTrue(result['site'].endswith(site))
                self.assertEqual(result['attribution'], 'producer')
        unknown = edit_errors.classify('edit', 'arbitrary unrecognized failure')
        self.assertEqual(unknown['class'], 'unclassified_tool_error')
        self.assertEqual(unknown['attribution'], 'propagation')
        self.assertEqual(edit_errors.classify('edit', 'snapshot hash is stale')['attribution'], 'propagation')

    def test_retries_are_target_bound_and_duplicate_completions_are_not_double_counted(self):
        events = []
        for identifier, path, failed in [('one', 'a.ts', True), ('two', 'b.ts', False),
                                          ('three', 'a.ts', False), ('four', 'a.ts', False)]:
            args = {'path': path}
            events += [lemon_event('started', identifier, 'edit', args),
                       lemon_event('completed', identifier, 'edit', args, 'Could not find the exact text' if failed else 'ok', not failed)]
        events.append(events[-1])
        # A different tool is not an edit attempt.
        events.append(lemon_event('completed', 'read', 'read', {'path': 'a.ts'}, 'text'))
        attempts = edit_errors.edit_attempts('lemon', '\n'.join(map(json.dumps, events)))
        self.assertEqual(len(attempts), 4)
        self.assertEqual([entry['retry'] for entry in attempts], [False, False, True, False])
        self.assertEqual(sum(entry['failed'] for entry in attempts), 1)
        self.assertNotIn('a.ts', json.dumps(attempts))

    def test_non_tool_and_non_dictionary_agent_actions_are_ignored(self):
        valid = lemon_event('completed', 'edit-one', 'edit', {'path': 'a.ts'})
        other = lemon_event('completed', 'not-a-tool', 'edit', {'path': 'b.ts'})
        other['payload']['type'] = 'status'
        events = [
            {'event': 'agent', 'payload': 'heartbeat'},
            {'event': 'agent', 'payload': {'type': 'status', 'action': 'started'}},
            {'event': 'agent', 'payload': {'type': 'tool_use', 'action': 'started'}},
            {'event': 'agent', 'payload': {'type': 'tool_use', 'action': {'detail': 'started'}}},
            other, valid,
        ]
        self.assertEqual(edit_errors.edit_attempts('lemon', '\n'.join(map(json.dumps, events))),
                         [{'tool': 'edit', 'failed': False, 'retry': False}])

    def test_unknown_targets_and_external_errors_are_not_falsely_attributed(self):
        events = [{'type': 'tool_execution_end', 'toolCallId': 'one', 'toolName': 'edit',
                   'isError': True, 'result': {'content': [{'text': 'Context not found for patch hunk'}]}}]
        attempt = edit_errors.edit_attempts('omp', json.dumps(events[0]))[0]
        self.assertIsNone(attempt['retry'])
        self.assertEqual(attempt['class'], 'omp_tool_error')
        self.assertIsNone(attempt['site'])

    def test_patch_retry_targets_include_all_files(self):
        patch_text = '*** Update File: a.ts\n@@\n-old\n+new\n*** Update File: b.ts\n@@\n-x\n+y'
        self.assertEqual(edit_errors.target_key('patch', {'patch_text': patch_text}), ('a.ts', 'b.ts'))
        self.assertIsNone(edit_errors.target_key('patch', {}))

    def test_each_lemon_tool_is_isolated_and_omp_cannot_bypass_edit(self):
        for mode in ('edit', 'patch'):
            args = types.SimpleNamespace(model='k3.1-pro', effort='high', deadline=200, lemon_tool=mode)
            lemon = benchmark.edit_command('lemon', 'prompt', args)
            omp = benchmark.edit_command('omp', 'prompt', args)
            self.assertEqual(lemon[lemon.index('--allowed-tools') + 1], 'read,' + mode)
            self.assertEqual(omp[omp.index('--tools') + 1], 'read,edit')
            self.assertEqual(lemon[lemon.index('--output') + 1], 'stream-json')


class ExternalEditFixtureTests(unittest.TestCase):
    def make_fixture(self, root):
        fixture = root / 'operator-swap-comparison-001'
        for name, content in [('input', 'const value = 1;\n'), ('expected', 'const value = 2;\n')]:
            (fixture / name).mkdir(parents=True)
            (fixture / name / 'index.ts').write_text(content)
        (fixture / 'prompt.md').write_text('Change the value to 2.')
        (fixture / 'metadata.json').write_text(json.dumps({'mutationType': 'operator-swap-comparison'}))
        return fixture

    def test_archive_loading_preserves_upstream_layout_and_prompt_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = self.make_fixture(root / 'source')
            archive = root / 'fixtures.tar.gz'
            with tarfile.open(archive, 'w:gz') as output:
                output.add(fixture, arcname='fixtures/' + fixture.name)
            extracted = benchmark.extract_fixtures(archive, root / 'extracted')
            tasks = benchmark.fixture_tasks(extracted, {fixture.name}, 1)
            self.assertEqual((tasks[0] / 'prompt.md').read_bytes(), (fixture / 'prompt.md').read_bytes())
            self.assertEqual(benchmark.byte_verification(tasks[0] / 'expected', fixture / 'expected')['success'], True)
            with self.assertRaisesRegex(ValueError, 'unknown'):
                benchmark.fixture_tasks(extracted, {'absent'})

    def test_archive_traversal_and_symlink_artifacts_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, type_ in [('fixtures/../../escape', tarfile.REGTYPE), ('fixtures/link', tarfile.SYMTYPE)]:
                archive = root / 'bad.tar.gz'
                with tarfile.open(archive, 'w:gz') as output:
                    member = tarfile.TarInfo(name)
                    member.type, member.size, member.linkname = type_, 0, '/etc/passwd'
                    output.addfile(member, io.BytesIO())
                with self.assertRaises(ValueError):
                    benchmark.extract_fixtures(archive, root / 'output')
            actual = root / 'actual'
            actual.mkdir()
            (actual / 'index.ts').symlink_to('/etc/passwd')
            with self.assertRaisesRegex(ValueError, 'nonregular'):
                benchmark.regular_files(actual)

    def test_byte_check_is_strict_even_when_upstream_would_normalize_whitespace(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.make_fixture(Path(directory))
            actual = Path(directory) / 'actual'
            actual.mkdir()
            (actual / 'index.ts').write_text('const value=2;\n')
            self.assertFalse(benchmark.byte_verification(fixture / 'expected', actual)['success'])
            (actual / 'index.ts').write_bytes((fixture / 'expected' / 'index.ts').read_bytes())
            (actual / 'extra.ts').write_text('extra')
            self.assertEqual(benchmark.byte_verification(fixture / 'expected', actual)['extra_files'], 1)

    def test_scripted_mock_model_smoke_rejects_then_recovers_for_both_tools_and_arms(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = self.make_fixture(root / 'source')
            instances = {}
            current = {}

            class ScriptedMockModel:
                """Two predetermined model tool calls, not a provider/network client."""
                def calls(self, tool):
                    if tool == 'edit':
                        return [{'path': 'index.ts', 'old_text': 'absent', 'new_text': '2'},
                                {'path': 'index.ts', 'old_text': '1', 'new_text': '2'}]
                    return [{'patch_text': '*** Update File: index.ts\n@@\n-absent\n+2'},
                            {'patch_text': '*** Update File: index.ts\n@@\n-const value = 1;\n+const value = 2;'}]

            class ScriptedContainer:
                def __init__(self, image, name, cpus, memory):
                    self.name, self.removed = name, False
                    self.work = root / name
                    self.work.mkdir()
                    self.configs = {}
                    instances[name] = self

                def copy_in(self, source, destination):
                    self.assert_no_expected = not (source / 'expected').exists()
                    shutil.copytree(source, self.work, dirs_exist_ok=True)

                def write(self, path, content):
                    self.configs[path] = content

                def exec(self, argv, **kwargs):
                    if argv[-1] == 'daemon':
                        return types.SimpleNamespace(returncode=0)
                    self.argv = argv
                    agent, tool = current['agent'], current['tool'] if current['agent'] == 'lemon' else 'edit'
                    events = []
                    for index, args in enumerate(ScriptedMockModel().calls(tool)):
                        identifier = f'call-{index}'
                        failed = index == 0
                        if not failed:
                            path = self.work / 'index.ts'
                            # Offline transport applies the scripted successful mutation.
                            path.write_text(path.read_text().replace('1', '2'))
                        text = ('Could not find the exact text' if tool == 'edit' else 'Context not found for patch hunk') if failed else 'ok'
                        if agent == 'lemon':
                            events += [lemon_event('started', identifier, tool, args),
                                       lemon_event('completed', identifier, tool, args, text, not failed)]
                        else:
                            events += [{'type': 'tool_execution_start', 'toolCallId': identifier, 'toolName': tool, 'args': args},
                                       {'type': 'tool_execution_end', 'toolCallId': identifier, 'toolName': tool,
                                        'isError': failed, 'result': {'content': [{'text': text}]}}]
                    if agent == 'lemon':
                        events.append({'type': 'result', 'ok': True, 'usage': {'turns': 2, 'tool_errors': 1}})
                    else:
                        events += [{'type': 'turn_end'}, {'type': 'turn_end'},
                                   {'type': 'message_end', 'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': 'done'}]}},
                                   {'type': 'agent_end'}]
                    return types.SimpleNamespace(returncode=0, stdout='\n'.join(map(json.dumps, events)), stderr='')

                def remove(self):
                    self.removed = True

            def copy_artifacts(*argv, **kwargs):
                self.assertEqual(argv[0], 'cp')
                container = instances[argv[1].split(':')[0]]
                shutil.copytree(container.work, Path(argv[2]), dirs_exist_ok=True)

            out = root / 'run'
            out.mkdir()
            rows = []
            for mode in ('edit', 'patch'):
                for agent in ('lemon', 'omp'):
                    current.update(agent=agent, tool=mode)
                    args = types.SimpleNamespace(model='k3.1-pro', effort='high', deadline=90,
                        lemon_tool=mode, cpus=1, memory='1g', proxy_secret='host-only', proxy_url='http://proxy:18787')
                    with patch.object(arena, 'docker', side_effect=copy_artifacts):
                        row = benchmark.run_fixture(fixture, agent, 1, args, out, container_factory=ScriptedContainer,
                            formatted_verifier=lambda args, expected, actual: benchmark.byte_verification(expected, actual))
                    self.assertTrue(row['passed'], row)
                    self.assertTrue(row['byte_exact'])
                    self.assertEqual(row['edit_calls'], 2)
                    self.assertEqual(row['edit_failures'], 1)
                    self.assertEqual(row['edit_retries'], 1)
                    rows.append(row)
            self.assertTrue(all(container.removed for container in instances.values()))
            result = benchmark.edit_report(rows, {'lemon_revision': 'fixture-sha'}, out, root / 'no-proxy-log')
            group = result['edit_metrics']['k3.1-pro']['patch:lemon']
            self.assertEqual(group['retries_per_edit'], 0.5)
            self.assertEqual(group['errors']['context_not_found']['count'], 1)
            self.assertIn('/blob/fixture-sha/apps/coding_agent/', group['errors']['context_not_found']['url'])
            report = (out / 'report.json').read_text()
            for private in ('host-only', 'const value', 'index.ts', 'Could not find'):
                self.assertNotIn(private, report)

    def test_both_lanes_are_plan_only_without_explicit_live(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'omp'
            fixture = self.make_fixture(root / 'source')
            package = source / 'packages/typescript-edit-benchmark'
            package.mkdir(parents=True)
            with tarfile.open(package / 'fixtures.tar.gz', 'w:gz') as output:
                output.add(fixture, arcname='fixtures/' + fixture.name)
            argv = ['edit_benchmark.py', '--omp-source', str(source), '--output-dir', str(root / 'edit-plan'),
                    '--proxy-log', str(root / 'log'), '--lemon-revision', 'fixture-sha']
            with patch.object(sys, 'argv', argv), patch.object(benchmark.subprocess, 'run', return_value=
                    types.SimpleNamespace(stdout=benchmark.UPSTREAM_REVISION)), \
                    patch.object(benchmark, 'run_fixture', side_effect=AssertionError('paid trial')):
                self.assertEqual(benchmark.main(), 0)
            argv = ['terminal_bench.py', 'run', '--output-dir', str(root / 'tb-plan'), '--proxy-log', str(root / 'log'),
                    '--lemon-bundle', str(package / 'fixtures.tar.gz'), '--omp-bundle', str(package / 'fixtures.tar.gz'),
                    '--lemon-revision', 'fixture-lemon', '--omp-revision', 'fixture-omp']
            with patch.object(sys, 'argv', argv), patch.object(terminal_bench.subprocess, 'run', side_effect=AssertionError('paid trial')):
                self.assertEqual(terminal_bench.main(), 0)


if __name__ == '__main__':
    unittest.main()
