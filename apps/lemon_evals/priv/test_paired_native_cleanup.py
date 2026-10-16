"""Real native process/durable-ledger teardown, using precompiled local BEAMs only.

Run separately from the lightweight paired contracts; no providers or listeners.
"""
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import coding_benchmark_paired as paired
from test_coding_benchmark_paired import assertion_safe_trial_state, dispose_test_trial_state


PROJECT = Path(__file__).resolve().parents[3]
FIXTURE = PROJECT / 'apps/lemon_evals/test/support/paired_native_workload.exs'
EBINS = sorted((PROJECT / '_build/test/lib').glob('*/ebin'))


def fixture_command():
    """Only reuse the test build; never let a launcher compile missing modules."""
    required = {
        'lemon_evals': 'Elixir.LemonEvals.PairedCleanup.beam',
        'lemon_core': 'Elixir.LemonCore.NativeProcess.beam',
        'coding_agent': 'Elixir.CodingAgent.ProcessManager.beam',
    }
    for app, beam in required.items():
        if not (PROJECT / '_build/test/lib' / app / 'ebin' / beam).is_file():
            raise AssertionError(f'precompile test BEAMs before this gate: missing {app}/{beam}')
    executable = shutil.which('elixir')
    if executable is None:
        raise AssertionError('elixir is required for the native recovery gate')
    # Ask the already-selected VM for its installations before replacing HOME.
    # Manager shims can depend on the operator's HOME; children must not.
    expression = """
    IO.puts("LEMON_ELIXIR=" <> Path.expand("../../bin", to_string(:code.lib_dir(:elixir))))
    IO.puts("LEMON_OTP=" <> Path.join(to_string(:code.root_dir()), "bin"))
    """
    discovery = subprocess.run(
        [executable, '-e', expression], cwd=PROJECT, capture_output=True, text=True,
        env={**os.environ, 'ERL_FLAGS': '+S 2:2 +SDcpu 1 +SDio 1'}, timeout=30)
    paths = dict(line.split('=', 1) for line in discovery.stdout.splitlines()
                 if line.startswith(('LEMON_ELIXIR=', 'LEMON_OTP=')))
    if discovery.returncode or set(paths) != {'LEMON_ELIXIR', 'LEMON_OTP'}:
        raise AssertionError(
            f'SDK discovery failed:\n{discovery.stdout}\n{discovery.stderr}')
    sdk_bins = [str(Path(paths[name]).resolve()) for name in ('LEMON_ELIXIR', 'LEMON_OTP')]
    installed = Path(sdk_bins[0]) / 'elixir'
    if not installed.is_file() or not (Path(sdk_bins[1]) / 'erl').is_file():
        raise AssertionError(f'SDK discovery returned missing executables: {sdk_bins}')
    command = [str(installed), *[item for path in EBINS for item in ('-pa', str(path))],
               str(FIXTURE)]
    return command, sdk_bins


def process_rows():
    result = subprocess.run(['/bin/ps', '-axo', 'pid=,pgid=,stat=,lstart='],
                            capture_output=True, text=True, check=True, timeout=5)
    rows = []
    for line in result.stdout.splitlines():
        pid, pgid, status, birth = line.strip().split(None, 3)
        rows.append({'pid': int(pid), 'pgid': int(pgid), 'status': status, 'birth': birth})
    return rows


def group_rows(pgid):
    return [row for row in process_rows() if row['pgid'] == pgid and not row['status'].startswith('Z')]


def emergency_stop(identity):
    """Fixture-only cleanup: use its original observed birth/member proof, not a PID guess."""
    rows = process_rows()
    root = next((row for row in rows if row['pid'] == identity['root_pid']), None)
    if root and not root['status'].startswith('Z'):
        if root['birth'] != identity['root_birth'] or root['pgid'] != identity['pgid']:
            raise AssertionError('fixture root identity changed; refusing cleanup signal')
    live = [row for row in rows if row['pgid'] == identity['pgid'] and not row['status'].startswith('Z')]
    if live:
        if not any(identity['members'].get(str(row['pid'])) == row['birth'] for row in live):
            raise AssertionError('fixture member proof lost; refusing cleanup signal')
        os.killpg(identity['pgid'], signal.SIGKILL)
        deadline = time.monotonic() + 5
        while group_rows(identity['pgid']):
            if time.monotonic() >= deadline:
                raise AssertionError('fixture group failed to stop')
            time.sleep(0.025)


def recovered_record(command, environment, state, identifier):
    expression = """
    [path, id] = System.argv()
    {:ok, table} = :dets.open_file(:fixture_evidence, file: String.to_charlist(path), repair: false)
    [{^id, record, _logs}] = :dets.lookup(table, id)
    :ok = :dets.close(table)
    IO.puts(Jason.encode!(Map.take(record,
      [:backend, :workload_identity, :capacity_held, :termination_confirmed])))
    """
    result = subprocess.run(
        command[:-1] + ['-e', expression, '--', str(state / 'processes.dets'), identifier],
        cwd=PROJECT, env=environment, capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise AssertionError(f'evidence reader failed:\n{result.stdout}\n{result.stderr}')
    return json.loads(result.stdout)


class NativeCleanupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.name != 'posix' or not Path('/bin/ps').is_file():
            raise unittest.SkipTest('native recovery requires POSIX process groups and /bin/ps')
        cls.command, cls.sdk_bins = fixture_command()

    def exercise(self, mode, expected, *, native_survives=None, replace_after_check=False):
        if native_survives is None:
            native_survives = not expected
        with assertion_safe_trial_state(self) as (state, cleanup):
            env = paired.isolated_environment(state, '', 'baseline', {}, paired.runtime_ports())
            env['PATH'] = os.pathsep.join([*self.sdk_bins, env.get('PATH', os.defpath)])
            env.update({'MIX_ENV': 'test',
                        'ERL_FLAGS': '+S 2:2 +SDcpu 1 +SDio 1',
                        'LEMON_EVAL_CLEANUP_ROOT': str(state), 'LEMON_EVAL_CLEANUP_MODE': mode})
            evidence_root = state
            if replace_after_check:
                external = Path(self.enterContext(tempfile.TemporaryDirectory(
                    prefix='lemon-paired-foreign-')))
                foreign = {name: b'foreign ledger must never be opened\n' + name.encode()
                           for name in ('processes.dets', 'processes.dets.native', 'cleanup.log')}
                for name, content in foreign.items():
                    (external / name).write_bytes(content)
                    (external / name).chmod(0o640)
                external.chmod(0o750)

                def assert_foreign_untouched():
                    self.assertEqual(external.stat().st_mode & 0o777, 0o750)
                    self.assertEqual({path.name for path in external.iterdir()}, set(foreign))
                    for name, content in foreign.items():
                        self.assertEqual((external / name).read_bytes(), content)
                        self.assertEqual((external / name).stat().st_mode & 0o777, 0o640)

                evidence_root = state.with_name(state.name + '-retained')
                self.addCleanup(dispose_test_trial_state, evidence_root)
                require_root = paired.require_trial_root

                def replace_validated_root(root, descriptor):
                    require_root(root, descriptor)
                    self.assertEqual(root, state)
                    self.assertEqual(descriptor, cleanup['root_fd'])
                    state.rename(evidence_root)
                    state.symlink_to(external, target_is_directory=True)
            for name in ('ready', 'hold'):
                os.mkfifo(state / name, 0o600)
            hold = os.open(state / 'hold', os.O_RDWR | os.O_NONBLOCK)
            process = sentinel = None
            identity = None
            try:
                sentinel = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)'],
                                            start_new_session=True)
                with (state / 'fixture.log').open('wb') as log:
                    process = subprocess.Popen(
                        self.command,
                        cwd=PROJECT, env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                        start_new_session=True)
                    deadline = time.monotonic() + 30
                    while not (state / 'native.json').exists():
                        try:
                            self.assertIsNone(process.poll(), 'native fixture exited before durable barrier')
                            self.assertLess(time.monotonic(), deadline, 'native fixture durable barrier timed out')
                        except AssertionError as error:
                            self.fail(f'{error}\nPrivate fixture.log ({log.name}):\n'
                                      + Path(log.name).read_text(errors='replace'))
                        time.sleep(0.025)
                    native = json.loads((state / 'native.json').read_text())
                    identity = native['identity']
                    self.assertEqual(native['ledger'],
                                     'native' if mode in ('preboot', 'validation', 'kernel', 'browser')
                                     else 'process_manager')
                    self.assertTrue(native['id'])
                    self.assertEqual(native['tracked_before_boot'], mode in ('preboot', 'validation'))
                    if mode in ('preboot', 'validation', 'foreground', 'browser'):
                        self.assertEqual(identity['root_pid'], int((state / 'workload.pid').read_text()))
                    if mode == 'kernel':
                        result = json.loads((state / 'kernel-result.json').read_text())
                        self.assertEqual(result, {'total': 285, 'pid': identity['root_pid']})
                    self.assertNotEqual(identity['pgid'], process.pid)
                    self.assertEqual(identity['root_pid'], identity['pgid'])
                    self.assertFalse(identity['ownership_lost'])
                    self.assertTrue(identity['root_birth'])
                    self.assertTrue(any(
                        identity['members'].get(str(row['pid'])) == row['birth']
                        for row in group_rows(identity['pgid'])),
                        'fixture lacks a birth-bound live member witness')
                    self.assertTrue(group_rows(identity['pgid']))
                    self.assertEqual(native['root_exited'], mode == 'descendant')
                    if mode == 'descendant':
                        self.assertFalse(any(row['pid'] == identity['root_pid']
                                             for row in group_rows(identity['pgid'])))
                    if replace_after_check:
                        with patch.object(paired, 'require_trial_root',
                                          side_effect=replace_validated_root) as checked:
                            complete = paired.terminate(
                                process, project_root=PROJECT, environment=env,
                                root_fd=cleanup['root_fd'])
                        checked.assert_called_once_with(state, cleanup['root_fd'])
                        self.assertTrue(state.is_symlink(), 'recovery root race was not injected')
                        assert_foreign_untouched()
                    else:
                        complete = paired.terminate(
                            process, project_root=PROJECT, environment=env,
                            root_fd=cleanup['root_fd'])
                    self.assertIs(complete, expected)
                    cleanup['complete'] = complete
                    self.assertIsNotNone(process.poll())
                    if mode != 'graceful':
                        self.assertEqual(process.returncode, -signal.SIGKILL,
                                         'fixture did not force VM death')
                    else:
                        self.assertEqual(process.returncode, 0, 'fixture did not exit gracefully')
                    self.assertIsNone(sentinel.poll(), 'unrelated same-host group was signalled')
                    self.assertEqual(bool(group_rows(identity['pgid'])), native_survives)
                    # Recovery must retain the original durable evidence, not replace
                    # it with an empty ledger or release native capacity speculatively.
                    self.assertTrue((evidence_root / 'processes.dets').is_file())
                    self.assertTrue((evidence_root / 'processes.dets.native').is_file())
                    if native.get('durable_record') is not None:
                        self.assertEqual(
                            recovered_record(self.command, env, evidence_root, native['id']),
                            native['durable_record'],
                            'unverified workload evidence or capacity was mutated')
                    cleanup['complete'] = complete
            finally:
                try:
                    if process is not None and process.poll() is None:
                        paired.terminate_runtime_group(process)
                finally:
                    try:
                        if identity is not None:
                            emergency_stop(identity)
                        else:
                            # Release only our private FIFO if setup failed before its proof.
                            os.write(hold, b'release\n')
                    finally:
                        try:
                            if sentinel is not None:
                                sentinel.kill()  # Direct child, unreaped and never delegated.
                                sentinel.wait(timeout=5)
                        finally:
                            os.close(hold)
        if replace_after_check:
            self.assertTrue(cleanup['complete'])
            self.assertFalse(cleanup['disposal_complete'])
            self.assertTrue(cleanup['disposal_failed'])
            self.assertFalse(cleanup['finalization_failed'])
            self.assertFalse(cleanup['interrupted'])
            self.assertTrue(state.is_symlink())
            assert_foreign_untouched()
            self.assertEqual(evidence_root.stat().st_mode & 0o777, 0o700)
            self.assertTrue((evidence_root / 'processes.dets').is_file())
            self.assertTrue((evidence_root / 'processes.dets.native').is_file())
            dispose_test_trial_state(state)
            dispose_test_trial_state(evidence_root)
            self.assertFalse(state.exists())
            self.assertFalse(evidence_root.exists())
        elif expected:
            self.assertFalse(state.exists())
        else:
            self.assertTrue(state.exists(), 'unverified trial evidence was erased')
            self.assertEqual(state.stat().st_mode & 0o777, 0o700)
            # Test cleanup happens only AFTER separately verifying the original
            # fixture ownership and termination above. Production retains this state.
            paired.repair_trial_directory(state)
            paired.dispose_trial_state(state)
            self.assertFalse(state.exists())

    def test_forced_vm_exit_stops_independent_native_group(self):
        self.exercise('forced', True)

    def test_root_replaced_after_validation_recovers_original_native_group_only(self):
        self.exercise('forced', True, replace_after_check=True)

    def test_graceful_vm_exit_still_recovers_native_group(self):
        self.exercise('graceful', True)

    def test_naturally_exited_root_keeps_durable_member_proof(self):
        self.exercise('descendant', True)

    def test_missing_identity_remains_unverified_and_unsignalled(self):
        self.exercise('missing', False)

    def test_lost_identity_remains_unverified_and_unsignalled(self):
        self.exercise('lost', False)

    def test_stale_root_birth_never_signals_live_group(self):
        self.exercise('stale', False)

    def test_unsupported_backend_never_claims_host_group_is_whole_workload(self):
        self.exercise('unsupported', False)

    def test_public_foreground_bash_survives_until_forced_vm_cleanup(self):
        self.exercise('foreground', True)

    @unittest.skipUnless(shutil.which('python3'), 'Python kernel requires python3')
    def test_real_python_eval_kernel_is_recovered_after_forced_vm_death(self):
        self.exercise('kernel', True)

    def test_native_launch_is_tracked_before_coding_agent_boot(self):
        self.exercise('preboot', True)

    @unittest.skipUnless(shutil.which('node'), 'browser driver requires node')
    def test_browser_driver_group_is_reaped_but_whole_workload_stays_unverified(self):
        self.exercise('browser', False, native_survives=False)

    def test_prelaunch_refusals_leave_no_intent_and_valid_commands_preserve_io(self):
        self.exercise('validation', True)


if __name__ == '__main__':
    unittest.main()
