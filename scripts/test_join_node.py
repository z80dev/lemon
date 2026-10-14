#!/usr/bin/env python3
"""Behavioral enrollment lifecycle tests: python3 scripts/test_join_node.py."""
import ast
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import tempfile
import sys
import termios
import time
import unittest

SCRIPT = Path(__file__).with_name('join-node.sh')
CODE = 'A' * 43
VERSION = '2099.01.7-private'


class JoinLifecycle(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.log = self.root / 'calls.jsonl'
        self.source = self.root / "source's checkout"
        self.source.mkdir()
        (self.source / 'mix.exs').touch()
        self.fixture = self.root / 'runtime'
        self.fixture.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
record = {'args': args, 'cwd': os.getcwd(), 'envSecret': any('A' * 43 in v for v in os.environ.values())}
if args[:2] == ['node', 'join']:
    record['input'] = sys.stdin.buffer.read().decode()
with open(os.environ['TEST_LOG'], 'a') as out:
    out.write(json.dumps(record) + '\\n')
if args == ['version']:
    print(os.environ.get('TEST_VERSION', '2099.01.7-private'))
    sys.exit(0)
if args[:2] == ['node', 'capabilities']:
    sys.exit(int(os.environ.get('TEST_CAPABILITY', '0')))
if args[:2] == ['node', 'join']:
    sys.exit(int(os.environ.get('TEST_JOIN_STATUS', '0')))
sys.exit(64)
''')
        self.fixture.chmod(0o700)
        (self.source / 'bin').mkdir()
        (self.source / 'bin' / 'lemon').symlink_to(self.fixture)
        self.env = dict(os.environ, HOME=str(self.root), TEST_LOG=str(self.log))
        self.args = ['--name', "bot's machine", '--controller', 'wss://controller.example/ws', '--source', str(self.source)]

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def launch(self, args=None, payload=(CODE + '\n').encode(), interrupt=False):
        master, slave = pty.openpty()
        before = termios.tcgetattr(slave)
        state_reader, state_writer = os.pipe()

        # A persistent session models the user's shell and lets Darwin keep the
        # slave valid while observing the child script's restored settings.
        keeper = """import fcntl, os, signal, subprocess, sys, termios
slave, report = int(sys.argv[1]), int(sys.argv[2])
os.setsid()
fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
signal.signal(signal.SIGINT, signal.SIG_IGN)
child = subprocess.Popen(['bash', '-s', '--', *sys.argv[3:]],
                         preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
status = child.wait()
os.write(report, repr(termios.tcgetattr(slave)).encode())
sys.exit(status)
"""
        process = subprocess.Popen([sys.executable, '-c', keeper, str(slave), str(state_writer),
                                    *(args or self.args)], stdin=subprocess.PIPE,
                                   stdout=slave, stderr=slave, pass_fds=(slave, state_writer),
                                   cwd=self.root, env=self.env)
        os.close(state_writer)
        process.stdin.write(SCRIPT.read_bytes())
        process.stdin.close()
        output = b''
        deadline = time.monotonic() + 10
        sent = False
        try:
            while time.monotonic() < deadline:
                readable, _, _ = select.select([master], [], [], 0.05)
                if readable:
                    try:
                        output += os.read(master, 65536)
                    except OSError as error:
                        if error.errno != errno.EIO:
                            raise
                        break
                if not sent and b'One-use enrollment code: ' in output:
                    self.assertFalse(termios.tcgetattr(slave)[3] & termios.ECHO)
                    if interrupt:
                        os.killpg(process.pid, signal.SIGINT)
                    else:
                        os.write(master, payload)
                    sent = True
                if process.poll() is not None:
                    break
            status = process.wait(timeout=2)
            restored = ast.literal_eval(os.read(state_reader, 65536).decode())
            self.assertEqual(restored[3] & termios.ECHO, before[3] & termios.ECHO)
            self.assertNotIn(CODE.encode(), output)
            return status, output
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            os.close(master)
            os.close(slave)
            os.close(state_reader)

    def test_source_reuses_runtime_and_sends_code_once_only_on_stdin(self):
        self.assertEqual(self.launch()[0], 0)
        joins = [row for row in self.calls() if row['args'][:2] == ['node', 'join']]
        self.assertEqual(len(joins), 1)
        self.assertEqual(joins[0]['input'], CODE + '\n')
        self.assertFalse(joins[0]['envSecret'])
        self.assertNotIn(CODE, json.dumps(joins[0]['args']))
        self.assertTrue(Path(joins[0]['cwd']).samefile(self.root))

    def test_invalid_code_never_probes_or_enrolls(self):
        for payload in [b'short\n\x04', b'A' * 44, b'A' * 42 + b'!\n', b'A' * 43 + b'\0', b'\x04']:
            self.assertNotEqual(self.launch(payload=payload)[0], 0)
            self.assertEqual(self.calls(), [])

    def test_interrupt_restores_echo_without_enrollment(self):
        self.assertNotEqual(self.launch(interrupt=True)[0], 0)
        self.assertEqual(self.calls(), [])

    def test_incompatible_source_and_version_mismatch_do_not_enroll(self):
        self.env['TEST_CAPABILITY'] = '127'
        self.assertNotEqual(self.launch()[0], 0)
        self.assertFalse(any(row['args'][:2] == ['node', 'join'] for row in self.calls()))
        self.env['TEST_CAPABILITY'] = '0'
        self.env['TEST_VERSION'] = '2099.01.6-private'
        self.assertNotEqual(self.launch(self.args + ['--version', VERSION])[0], 0)
        self.assertFalse(any(row['args'][:2] == ['node', 'join'] for row in self.calls()))

    def test_missing_source_and_no_tty_do_not_enroll(self):
        self.assertNotEqual(self.launch(self.args[:-1] + [str(self.root / 'missing')])[0], 0)
        result = subprocess.run(['bash', str(SCRIPT), *self.args], stdin=subprocess.DEVNULL,
                                capture_output=True, env=self.env, start_new_session=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'terminal', result.stderr)
        self.assertEqual(self.calls(), [])

    def release(self):
        tools = self.root / 'tools'
        tools.mkdir()
        installer = self.root / 'installer'
        installer.write_text('''#!/bin/sh
[ "${TEST_INSTALL_FAIL:-0}" = 0 ] || exit 1
mkdir -p "$HOME/.lemon/versions/$LEMON_VERSION/bin"
cp "$TEST_RUNTIME" "$HOME/.lemon/versions/$LEMON_VERSION/bin/lemon"
''')
        curl = tools / 'curl'
        curl.write_text('''#!/bin/sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then cp "$TEST_INSTALLER" "$2"; exit; fi
  shift
done
exit 1
''')
        curl.chmod(0o700)
        self.env.update(PATH=str(tools) + ':' + self.env['PATH'], TEST_INSTALLER=str(installer),
                        TEST_RUNTIME=str(self.fixture))
        return self.args[:4] + ['--version', VERSION, '--base-url', 'https://releases.example/lemon']

    def test_missing_release_installs_then_checks_compatibility(self):
        args = self.release()
        self.assertEqual(self.launch(args)[0], 0)
        self.assertEqual(len([row for row in self.calls() if row['args'][:2] == ['node', 'join']]), 1)
        self.env['TEST_INSTALL_FAIL'] = '1'
        self.assertEqual(self.launch(args)[0], 0)  # Existing compatible pin is reused.

    def test_failed_install_and_incompatible_installed_runtime_never_enroll(self):
        args = self.release()
        self.env['TEST_INSTALL_FAIL'] = '1'
        self.assertNotEqual(self.launch(args)[0], 0)
        self.assertEqual(self.calls(), [])
        self.env['TEST_INSTALL_FAIL'] = '0'
        self.env['TEST_CAPABILITY'] = '1'
        self.assertNotEqual(self.launch(args)[0], 0)
        self.assertFalse(any(row['args'][:2] == ['node', 'join'] for row in self.calls()))

    def test_uncertain_join_failure_is_not_retried(self):
        self.env['TEST_JOIN_STATUS'] = '1'
        self.assertNotEqual(self.launch()[0], 0)
        self.assertEqual(len([row for row in self.calls() if row['args'][:2] == ['node', 'join']]), 1)


if __name__ == '__main__':
    unittest.main()
