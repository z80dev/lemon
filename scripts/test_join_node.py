#!/usr/bin/env python3
"""Behavioral enrollment lifecycle tests: python3 scripts/test_join_node.py."""
import ast
import errno
import fcntl
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import subprocess
import tarfile
import tempfile
import sys
import termios
import threading
import time
import unittest

SCRIPT = Path(__file__).with_name('join-node.sh')
INSTALLER = Path(__file__).resolve().parent.parent / 'install.sh'
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
version = os.environ.get('TEST_VERSION', '2099.01.7-private')
record = {'args': args, 'exe': sys.argv[0], 'home': os.environ.get('HOME'), 'cwd': os.getcwd(),
          'envSecret': any('A' * 43 in v for v in os.environ.values()),
          'activated': os.path.lexists(os.path.join(os.environ.get('TEST_ROOT', '/nonexistent'), '.lemon/versions/current'))}
if args[:2] == ['node', 'join']:
    record['input'] = sys.stdin.buffer.read().decode()
with open(os.environ['TEST_LOG'], 'a') as out:
    out.write(json.dumps(record) + '\\n')
if args == ['version']:
    print(version)
    sys.exit(0)
if args[:2] == ['node', 'capabilities']:
    # Mirrors the shipped CLI contract: exact version pin, then bot readiness.
    expected = args[args.index('--expected-version') + 1] if '--expected-version' in args else version
    ready = os.environ.get('TEST_CAPABILITY', '0') == '0'
    print(json.dumps({'lemonVersion': version, 'botReady': ready}))
    sys.exit(0 if expected == version and (ready or '--require-bot' not in args) else 2)
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
        deadline = time.monotonic() + 60
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

    def release(self, channel='preview', profiles=('lemon_runtime_full', 'lemon_tui', 'lemon_bot'),
                manifest_version=VERSION, forged_digest=None):
        """Publish a schema-2 release and route the release host to it.

        The real install.sh is served exactly where join-node.sh downloads it; the
        only fixture is the runtime binary inside the ordinary release tarballs.
        """
        published = self.root / 'published'
        shutil.rmtree(published, ignore_errors=True)
        release_dir = published / 'releases' / 'download' / ('v' + VERSION)
        release_dir.mkdir(parents=True)
        shutil.copy(INSTALLER, release_dir / 'install.sh')
        machine = {'x86_64': 'x86_64', 'amd64': 'x86_64'}.get(os.uname().machine, 'arm64')
        self.platform = platform = os.uname().sysname.lower() + '-' + machine
        members = {'lemon_runtime_full': 'bin/lemon', 'lemon_tui': 'tui/bin/lemon-tui', 'lemon_bot': 'bot/bin/lemon-bot'}
        artifacts = []
        for profile in profiles:
            name = f'lemon-{VERSION}-{channel}-{platform}-{profile}.tar.gz'
            staging = self.root / 'stage' / profile
            shutil.rmtree(staging, ignore_errors=True)
            member = staging / members[profile]
            member.parent.mkdir(parents=True)
            # Only the runtime binary is a fixture; archives and manifest are ordinary release shapes.
            if profile == 'lemon_runtime_full':
                shutil.copy(self.fixture, member)
            else:
                member.write_text('#!/bin/sh\nexit 0\n')
            member.chmod(0o755)
            with tarfile.open(release_dir / name, 'w:gz') as archive:
                for entry in sorted(staging.iterdir()):
                    archive.add(entry, arcname=entry.name)
            artifacts.append({'file': name, 'profile': profile, 'platform': platform,
                              'os': platform.split('-')[0], 'arch': platform.split('-', 1)[1],
                              'size': (release_dir / name).stat().st_size,
                              'sha256': forged_digest or hashlib.sha256((release_dir / name).read_bytes()).hexdigest()})
        (release_dir / 'manifest.json').write_text(json.dumps(
            {'schema': 2, 'version': manifest_version, 'channel': channel, 'artifacts': artifacts}))

        requests = self.requests = []

        class Handler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *_args):
                requests.append(self.path)

        server = http.server.ThreadingHTTPServer(
            ('127.0.0.1', 0), functools.partial(Handler, directory=str(published)))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)

        # Real curl, with the HTTPS release host routed to the fixture server.
        tools = self.root / 'tools'
        tools.mkdir(exist_ok=True)
        curl = tools / 'curl'
        curl.write_text('''#!/bin/sh
n=$#
while [ "$n" -gt 0 ]; do
  arg=$1; shift; n=$((n - 1))
  case "$arg" in
    --proto|--proto-redir) shift; n=$((n - 1)); continue ;;
    https://releases.example/lemon*) arg="http://127.0.0.1:$TEST_PUBLISH_PORT${arg#https://releases.example/lemon}" ;;
  esac
  set -- "$@" "$arg"
done
exec "$TEST_REAL_CURL" "$@"
''')
        curl.chmod(0o700)
        self.env.update(PATH=str(tools) + ':' + os.environ['PATH'], TEST_REAL_CURL=shutil.which('curl'),
                        TEST_PUBLISH_PORT=str(server.server_address[1]), TEST_ROOT=str(self.root),
                        LEMON_INSTALL_IGNORE_GLIBC='1', LEMON_PROFILE='lemon_bot')
        return self.args[:4] + ['--version', VERSION, '--base-url', 'https://releases.example/lemon']

    def installed(self):
        return self.root / '.lemon' / 'versions' / VERSION / 'bin' / 'lemon'

    def joins(self):
        return [row for row in self.calls() if row['args'][:2] == ['node', 'join']]

    def test_missing_release_installs_selected_native_runtime_before_enrolling(self):
        args = self.release()
        self.assertEqual(self.launch(args)[0], 0)
        # The pinned preview release was resolved through its manifest, installed
        # as the bot-capable native runtime only, and is not the backend or TUI.
        self.assertTrue(self.installed().is_file())
        self.assertFalse((self.root / '.lemon' / 'versions' / VERSION / 'tui').exists())
        self.assertFalse((self.root / '.local' / 'bin' / 'lemon-bot').exists())
        self.assertFalse((self.root / '.lemon' / 'lemon_bot').exists())
        self.assertEqual(sorted(path for path in self.requests if path.endswith('.tar.gz')),
                         ['/releases/download/v' + VERSION + f'/lemon-{VERSION}-preview-{self.platform}-lemon_runtime_full.tar.gz'])
        self.assertNotIn('/main/', ' '.join(self.requests))
        # The staged runtime proved the exact version and worker APIs before activation, in
        # an isolated home; the enrolled process is the installed selected runtime.
        checks = [row for row in self.calls() if row['args'][:2] == ['node', 'capabilities']
                  and '--expected-version' in row['args']]
        self.assertEqual(len(checks), 1)
        self.assertEqual(checks[0]['args'][2:], ['--json', '--require-bot', '--expected-version', VERSION])
        self.assertFalse(checks[0]['activated'])
        self.assertNotEqual(Path(checks[0]['home']).resolve(), self.root.resolve())
        joins = self.joins()
        self.assertEqual(len(joins), 1)
        self.assertEqual(joins[0]['exe'], str(self.installed()))
        self.assertEqual(joins[0]['args'][2:], ['--name', "bot's machine", '--controller',
                                                 'wss://controller.example/ws', '--invite-code-stdin'])
        self.assertEqual(joins[0]['input'], CODE + '\n')
        self.assertFalse(joins[0]['envSecret'])
        self.assertNotIn(CODE, json.dumps([{key: value for key, value in row.items() if key != 'input'}
                                           for row in self.calls()]))
        # An existing compatible pin is reused without another download or install.
        requests_before = list(self.requests)
        self.assertEqual(self.launch(args)[0], 0)
        self.assertEqual(self.requests, requests_before)
        self.assertEqual(len(self.joins()), 2)

    def test_unverified_or_unsuitable_releases_never_install_or_enroll(self):
        cases = [
            dict(forged_digest='f' * 64),
            dict(manifest_version='2099.01.6-private'),
            dict(profiles=('lemon_tui', 'lemon_bot')),
        ]
        for case in cases:
            with self.subTest(case=case):
                args = self.release(**case)
                self.assertNotEqual(self.launch(args)[0], 0)
                self.assertEqual(self.joins(), [])
                self.assertFalse((self.root / '.lemon' / 'versions' / VERSION).exists())
                self.assertFalse((self.root / '.lemon' / 'versions' / 'current').exists())
                self.assertFalse((self.root / '.local' / 'bin' / 'lemon-bot').exists())

    def test_runtime_without_bot_worker_apis_is_not_promoted_or_enrolled(self):
        args = self.release()
        self.env['TEST_CAPABILITY'] = '1'
        self.assertNotEqual(self.launch(args)[0], 0)
        self.assertEqual(self.joins(), [])
        self.assertFalse((self.root / '.lemon' / 'versions' / VERSION).exists())
        self.assertFalse((self.root / '.lemon' / 'versions' / 'current').exists())

    def test_installed_runtime_that_regresses_is_reverified_not_trusted(self):
        args = self.release()
        self.assertEqual(self.launch(args)[0], 0)
        downloads = len(self.requests)
        self.env['TEST_CAPABILITY'] = '1'
        self.assertNotEqual(self.launch(args)[0], 0)
        self.assertGreater(len(self.requests), downloads)
        self.assertEqual(len(self.joins()), 1)
        # The failed reinstall left the previously activated runtime in place.
        self.assertTrue(self.installed().is_file())
        self.assertEqual(os.readlink(self.root / '.lemon' / 'versions' / 'current'), VERSION)

    def test_uncertain_join_failure_is_not_retried(self):
        self.env['TEST_JOIN_STATUS'] = '1'
        self.assertNotEqual(self.launch()[0], 0)
        self.assertEqual(len([row for row in self.calls() if row['args'][:2] == ['node', 'join']]), 1)


if __name__ == '__main__':
    unittest.main()
