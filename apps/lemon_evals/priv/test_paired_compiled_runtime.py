"""Credential-free production boot and CLI over a real compiled runtime.

Requires a compiled dev build and LEMON_EVAL_OFFLINE_PROFILE_PYTHON pointing to
Python with tiktoken, plus LEMON_EVAL_OFFLINE_TOKENIZER_CACHE with cached encoder
data. Missing prerequisites fail the gate, never silently skip it. All provider
APIs are replaced inside the disposable VM by an in-memory fixture transport.
"""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import textwrap
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import coding_benchmark as benchmark
import coding_benchmark_paired as paired
from test_paired_native_cleanup import fixture_command


PROJECT = Path(__file__).resolve().parents[3]
FIXTURE = PROJECT / 'apps/lemon_evals/test/support/paired_runtime_offline.exs'


class CompiledRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        _, cls.sdk_bins = fixture_command()
        cls.profile_python = Path(os.environ.get('LEMON_EVAL_OFFLINE_PROFILE_PYTHON', sys.executable)).absolute()
        cls.cache = Path(os.environ.get('LEMON_EVAL_OFFLINE_TOKENIZER_CACHE', '/nonexistent-offline-tokenizer-cache'))
        if not cls.cache.is_dir() or not any(cls.cache.iterdir()):
            raise AssertionError('provide cached tokenizer data in LEMON_EVAL_OFFLINE_TOKENIZER_CACHE; network is forbidden')
        for app, beam in [('lemon_evals', 'Elixir.LemonEvals.PairedCleanup.beam'),
                          ('lemon_omp', 'Elixir.LemonOmp.Application.beam')]:
            if not (PROJECT / '_build/dev/lib' / app / 'ebin' / beam).is_file():
                raise AssertionError(f'compile dev runtime before this gate: {app}/{beam}')

    def exercise(self, variant):
        roots, observations, logs = [], [], []
        original_environment, original_state = paired.isolated_environment, paired.trial_state
        with socket.socket() as occupied:
            occupied.bind(('127.0.0.1', 0))
            occupied.listen()
            occupied_port = occupied.getsockname()[1]

            def environment(*args, **kwargs):
                env = original_environment(*args, **kwargs)
                state = Path(env['LEMON_EVAL_PROCESS_STORE']).parent
                roots.append(state)
                env['PATH'] = os.pathsep.join([*self.sdk_bins, env.get('PATH', os.defpath)])
                env['ERL_FLAGS'] = '+S 2:2 +SDcpu 1 +SDio 1'
                env['PYTHONDONTWRITEBYTECODE'] = '1'
                cache = state / 'tokenizer-cache'
                shutil.copytree(self.cache, cache)
                # Real tokenizer/profiler, with an explicit socket prohibition. No
                # missing cache may turn this offline gate into a network fetch.
                wrapper = state / 'profile-python'
                wrapper.write_text(f'#!{self.profile_python}\n' + textwrap.dedent('''\
                    import os, pathlib, runpy, socket, sys
                    sys.dont_write_bytecode = True
                    os.environ['TIKTOKEN_CACHE_DIR'] = str(pathlib.Path(__file__).parent / 'tokenizer-cache')
                    def forbidden(*args, **kwargs):
                        raise AssertionError('offline profiler attempted network access')
                    socket.socket.connect = forbidden
                    script = sys.argv.pop(1)
                    sys.argv[0] = script
                    runpy.run_path(script, run_name='__main__')
                '''))
                wrapper.chmod(0o700)
                return env

            @contextmanager
            def state_context():
                with original_state() as (state, cleanup):
                    yield state, cleanup
                    log = state / 'runtime.log'
                    logs.append(log.read_text(errors='replace') if log.exists() else '<no runtime log>')

            def run_case(case, agent, executable, model, args):
                state = Path(args.environment['LEMON_EVAL_STATE'])
                proof = json.loads((state / 'boot-proof.json').read_text())
                result = benchmark.run_case(case, agent, executable, model, args)
                proof['offline_requests'] = (state / 'offline-requests').read_text().splitlines()
                observations.append(proof)
                return result

            case = next(case for case in benchmark.tasks() if case['name'] == 'read_and_answer')
            entry = paired.schedule([case], ['baseline', 'coding'], 1, 107)
            entry = next(row for row in entry if row['variant'] == variant)
            configuration = paired.paired_configuration('[providers.zai]\napi_key = "offline-fixture-not-a-real-credential"\n', variant)
            expression = (
                f'Code.require_file({json.dumps(str(FIXTURE))}); '
                f'Application.put_env(:lemon_gateway, :health_port, {occupied_port}); '
                f'Application.put_env(:lemon_router, :health_port, {occupied_port}); '
                + paired.RUNTIME_EXPRESSION.replace(
                    'File.write!(System.fetch_env!("LEMON_EVAL_METADATA"), ',
                    'LemonEvals.PairedRuntimeOffline.install!(); File.write!(System.fetch_env!("LEMON_EVAL_METADATA"), '))
            command = paired.runtime_command(PROJECT)
            command[-1] = expression
            command = ['/bin/sh', '-c', 'exec "$@" > "$LEMON_EVAL_STATE/runtime.log" 2>&1', 'offline-runtime', *command]
            args = SimpleNamespace(timeout=90, profile_python='', lemon=str(PROJECT / 'bin/lemon'), failure_dir=None)
            # The wrapper's pathname is trial-specific and is selected only after
            # isolated_environment has allocated the private state.
            def configured_environment(*positional, **keywords):
                env = environment(*positional, **keywords)
                args.profile_python = str(Path(env['LEMON_EVAL_PROCESS_STORE']).parent / 'profile-python')
                return env
            with patch.object(paired, 'isolated_environment', side_effect=configured_environment), \
                    patch.object(paired, 'trial_state', side_effect=state_context):
                row = paired.execute_trial(PROJECT, entry, case, configuration, 'zai:glm-5.3', {},
                                           paired.runtime_ports(), args, run_case, paired.digest(case),
                                           runtime_argv=command)
            diagnostic = '\n'.join(logs)
            self.assertTrue(observations, diagnostic)
            proof = observations[0]
            self.assertEqual(proof['profile'], 'legacy' if variant == 'baseline' else 'coding', diagnostic)
            self.assertEqual(proof['unsupported'], 0, diagnostic)
            self.assertGreaterEqual(proof['tracked_live_groups'], 1, diagnostic)
            # Production may make ancillary in-memory completions as well as the
            # parent turn; every one must reach the installed offline transport.
            self.assertTrue(proof['offline_requests'], diagnostic)
            self.assertEqual(set(proof['offline_requests']), {'fixture'}, diagnostic)
            for name in ('control', 'gateway', 'router', 'web', 'sim'):
                self.assertEqual(len(proof['listeners'][name]), 1, (name, proof, diagnostic))
                listener = proof['listeners'][name][0]
                self.assertEqual(listener['ip'], '127.0.0.1', (name, listener))
                self.assertNotEqual(listener['port'], occupied_port)
                self.assertGreater(listener['port'], 0)
            self.assertTrue(row['verifier_passed'], (row, diagnostic))
            self.assertTrue(row['passed'], (row, diagnostic))
            self.assertTrue(row['cleanup_complete'], (row, diagnostic))
            self.assertTrue(row['disposal_complete'], (row, diagnostic))
            self.assertFalse(row['finalization_failed'], (row, diagnostic))
            self.assertTrue(all(not root.exists() for root in roots))
            self.assertEqual(occupied.getsockname(), ('127.0.0.1', occupied_port))
            evidence = os.environ.get('LEMON_EVAL_OFFLINE_EVIDENCE')
            if evidence:
                with Path(evidence).open('a') as output:
                    output.write(json.dumps({'variant': variant, 'proof': proof, 'row': paired.sanitize_row(row)}) + '\n')

    def test_baseline_boot_profile_health_cli_verifier_and_verified_disposal(self):
        self.exercise('baseline')

    def test_coding_boot_profile_health_cli_verifier_and_verified_disposal(self):
        self.exercise('coding')


if __name__ == '__main__':
    unittest.main()
