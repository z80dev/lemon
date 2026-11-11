#!/usr/bin/env python3
"""Shell-only tunnel tests; never connects to SSH or touches the live HOME."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
RUNNER = ROOT / 'rel/overlays/libexec/lemon-tunnel'


class TunnelTests(unittest.TestCase):
    def setUp(self):
        scratch = Path('/tmp/second-tunnel-scratch')
        scratch.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.bin = self.home / 'bin'
        self.bin.mkdir()
        self.config = {'reapExit': 0, 'reapError': '', 'tunnelExit': 255,
                       'tunnelError': '', 'hold': False, 'executeReap': False,
                       'processes': {}, 'lsofPids': []}
        self.env = dict(os.environ, HOME=str(self.home), PATH=f'{self.bin}:' + os.environ['PATH'],
                        USER='tunnel-user', LOGNAME='tunnel-user', SSH_AUTH_SOCK='/fixture/agent',
                        LEMON_CONTROL_PLANE_OPERATOR_TOKEN='never-send-this',
                        LEMON_BOT_ENCRYPTION_KEY='never-send-this-either',
                        UNRELATED_SECRET='also-private')
        self.args = ['run', '--name', 'studio', '--ssh', 'me@studio', '--node-port', '45044',
                     '--gateway-port', '45045', '--product-port', '45100', '--backend-port', '45101']
        self.stub('ssh', '''import json, os, signal, subprocess, sys, time
from pathlib import Path
home = Path(os.environ['HOME'])
config = json.loads((home / 'config.json').read_text())
args = sys.argv[1:]
reap = '-N' not in args
script = sys.stdin.read() if reap else ''
with (home / 'calls.jsonl').open('a') as out:
    out.write(json.dumps({'args': args, 'env': dict(os.environ), 'script': script}) + '\\n')
if reap:
    if config['executeReap']:
        env = dict(os.environ, LEMON_TUNNEL_PROC_ROOT=str(home / 'proc'))
        result = subprocess.run(['sh', '-s', '--', *args[-2:]], input=script, text=True, env=env)
        sys.exit(result.returncode)
    print('reaped' if config['reapExit'] == 0 else 'remote_port_in_use' if config.get('busy') else '')
    print(config['reapError'], file=sys.stderr)
    sys.exit(config['reapExit'])
if config['hold']:
    (home / 'ssh.pid').write_text(str(os.getpid()))
    while True: time.sleep(1)
print(config['tunnelError'], file=sys.stderr)
sys.exit(config['tunnelExit'])
''')
        self.stub('ps', '''import json, os, sys
from pathlib import Path
config = json.loads((Path(os.environ['HOME']) / 'config.json').read_text())
row = config['processes'].get(sys.argv[sys.argv.index('-p') + 1])
if row is None: sys.exit(1)
print(row['uid'] if sys.argv[-1] == 'uid=' else row['comm'])
''')
        self.stub('lsof', '''import json, os
from pathlib import Path
config = json.loads((Path(os.environ['HOME']) / 'config.json').read_text())
print('\\n'.join(str(pid) for pid in config['lsofPids']))
''')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text(f'#!{sys.executable}\n' + body)
        path.chmod(0o700)

    def save(self):
        (self.home / 'config.json').write_text(json.dumps(self.config))

    def launch(self, args=None, launcher=None):
        self.save()
        return subprocess.Popen([str(launcher or RUNNER), *(self.args if args is None else args)],
                                env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def finish(self, process):
        stdout, stderr = process.communicate(timeout=12)
        self.assertEqual(stdout, b'')
        self.assertNotIn(b'never-send-this', stderr)
        return process.returncode

    def run_tunnel(self, args=None, launcher=None):
        process = self.launch(args, launcher)
        return self.finish(process)

    def state(self):
        path = self.home / '.lemon/run/service/tunnel-studio.json'
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        state = json.loads(path.read_text())
        self.assertEqual(state['schema'], 1)
        self.assertIsInstance(state['sinceMs'], int)
        self.assertLess(abs(state['sinceMs'] - time.time() * 1000), 15000)
        return state

    def calls(self):
        path = self.home / 'calls.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_classification_and_exit_convention(self):
        cases = [('Permission denied (publickey).', 'failed', 'ssh_auth_failed', 0),
                 ('REMOTE HOST IDENTIFICATION HAS CHANGED!', 'failed', 'host_key_changed', 0),
                 ('Host key verification failed.', 'failed', 'host_key_changed', 0),
                 ('remote port forwarding failed for listen port 45044', 'failed', 'forward_refused', 0),
                 ('Could not resolve hostname studio', 'reconnecting', 'host_unreachable', 75),
                 ('Connection refused', 'reconnecting', 'host_unreachable', 75),
                 ('Connection timed out', 'reconnecting', 'host_unreachable', 75),
                 ('No route to host', 'reconnecting', 'host_unreachable', 75),
                 ('Connection reset by peer', 'reconnecting', None, 75)]
        for error, state, detail, code in cases:
            with self.subTest(error=error):
                self.config['tunnelError'] = error
                self.assertEqual(self.run_tunnel(), code)
                self.assertEqual((self.state()['state'], self.state()['detail']), (state, detail))

    def test_reap_failure_prevents_forwarding(self):
        for error, busy, detail, code in [('Permission denied', False, 'ssh_auth_failed', 0),
                                          ('Host key verification failed', False, 'host_key_changed', 0),
                                          ('Connection refused', False, 'host_unreachable', 75),
                                          ('', True, 'remote_port_in_use', 75)]:
            with self.subTest(detail=detail):
                self.config.update(reapExit=255, reapError=error, busy=busy)
                before = len(self.calls())
                self.assertEqual(self.run_tunnel(), code)
                self.assertEqual(len(self.calls()), before + 1)
                self.assertEqual(self.state()['detail'], detail)

    def test_only_allowlisted_environment_and_safe_forwards(self):
        self.assertEqual(self.run_tunnel(), 75)
        calls = self.calls()
        self.assertEqual(len(calls), 2)
        for call in calls:
            # Python/macOS may synthesize locale metadata during stub startup.
            self.assertEqual(set(call['env']) - {'LC_CTYPE', '__CF_USER_TEXT_ENCODING'},
                             {'HOME', 'PATH', 'USER', 'LOGNAME', 'SSH_AUTH_SOCK', 'LC_ALL'})
            self.assertEqual(call['env']['LC_ALL'], 'C')
            for option in ['BatchMode=yes', 'ConnectTimeout=10', 'StrictHostKeyChecking=accept-new',
                           'ExitOnForwardFailure=yes', 'ServerAliveInterval=15', 'ServerAliveCountMax=3',
                           'ControlMaster=no', 'ControlPath=none', 'ForwardAgent=no',
                           'ForwardX11=no', 'PermitLocalCommand=no']:
                self.assertIn(option, call['args'])
            self.assertNotIn('ClearAllForwardings=yes', call['args'])
        self.assertIn('127.0.0.1:45044:127.0.0.1:45045', calls[1]['args'])
        self.assertIn('127.0.0.1:45100:127.0.0.1:45101', calls[1]['args'])
        self.assertEqual(calls[1]['args'][-2:], ['--', 'me@studio'])

    def test_node_only_and_ipv6_destination(self):
        args = self.args[:9]
        args[4] = 'me@[fe80::1%en0]'
        self.assertEqual(self.run_tunnel(args), 75)
        self.assertEqual(self.calls()[-1]['args'].count('-R'), 1)

    def test_validation_before_ssh(self):
        for flag, values in {'--name': ['', '../escape', '-bad', 'a' * 65],
                             '--ssh': ['', '-oProxyCommand=sh', '@host', 'me@', 'host;id', 'a b', 'a\nb', 'a' * 256],
                             '--node-port': ['0', '65536', '-1', 'abc', '1;id']}.items():
            for value in values:
                with self.subTest(flag=flag, value=value):
                    args = self.args.copy()
                    args[args.index(flag) + 1] = value
                    self.assertEqual(self.run_tunnel(args), 2)
        self.assertEqual(self.run_tunnel(self.args[:-2]), 2)
        self.assertEqual(self.run_tunnel(self.args + ['--bad']), 2)
        self.assertEqual(self.calls(), [])

    def test_online_drop_and_supervisor_restart(self):
        self.config['hold'] = True
        process = self.launch()
        self.addCleanup(lambda: self.stop(process))
        deadline = time.monotonic() + 9
        while time.monotonic() < deadline:
            path = self.home / '.lemon/run/service/tunnel-studio.json'
            if path.exists() and json.loads(path.read_text())['state'] == 'online':
                break
            time.sleep(0.05)
        self.assertEqual(self.state()['state'], 'online')
        os.kill(int((self.home / 'ssh.pid').read_text()), signal.SIGTERM)
        self.assertEqual(self.finish(process), 75)
        self.assertEqual(self.state()['state'], 'reconnecting')
        # The manager, not a nested retry loop, restarts the foreground runner.
        self.config.update(hold=False, tunnelError='Permission denied')
        self.assertEqual(self.run_tunnel(), 0)
        self.assertEqual(self.state()['detail'], 'ssh_auth_failed')

    @staticmethod
    def stop(process):
        if process.poll() is None:
            process.terminate()
            process.communicate(timeout=3)

    def sleeper(self):
        child = subprocess.Popen(['sleep', '30'])
        self.addCleanup(lambda: self.stop(child))
        return child

    def proc_listener(self, child, port, uid=None, comm='sshd: fixture@notty'):
        proc = self.home / 'proc'
        (proc / 'net').mkdir(parents=True, exist_ok=True)
        uid = os.getuid() if uid is None else uid
        inode = child.pid + port
        with (proc / 'net/tcp').open('a') as out:
            out.write(f' 0: 0100007F:{port:04X} 00000000:0000 0A 0:0 0:0 0 {uid} 0 {inode}\n')
        fd = proc / str(child.pid) / 'fd'
        fd.mkdir(parents=True, exist_ok=True)
        (fd / str(port)).symlink_to(f'socket:[{inode}]')
        self.config['processes'][str(child.pid)] = {'uid': uid, 'comm': comm}
        self.config['executeReap'] = True

    def test_reap_only_same_uid_sshd_and_both_ports(self):
        node = self.sleeper()
        product = self.sleeper()
        self.proc_listener(node, 45044)
        self.proc_listener(product, 45100)
        self.assertEqual(self.run_tunnel(), 75)
        self.assertEqual(node.wait(timeout=2), -signal.SIGTERM)
        self.assertEqual(product.wait(timeout=2), -signal.SIGTERM)
        self.assertEqual(len(self.calls()), 2)

    def test_reap_refuses_non_sshd_before_killing_any_listener(self):
        node = self.sleeper()
        product = self.sleeper()
        self.proc_listener(node, 45044)
        self.proc_listener(product, 45100, comm='python')
        self.assertEqual(self.run_tunnel(), 75)
        self.assertEqual(self.state()['detail'], 'remote_port_in_use')
        self.assertIsNone(node.poll())
        self.assertIsNone(product.poll())
        self.assertEqual(len(self.calls()), 1)

    def test_reap_refuses_foreign_uid(self):
        child = self.sleeper()
        self.proc_listener(child, 45044, uid=os.getuid() + 1)
        self.assertEqual(self.run_tunnel(), 75)
        self.assertEqual(self.state()['detail'], 'remote_port_in_use')
        self.assertIsNone(child.poll())

    def test_reap_fails_closed_when_socket_pid_cannot_be_proven(self):
        child = self.sleeper()
        self.proc_listener(child, 45044)
        shutil.rmtree(self.home / 'proc' / str(child.pid))
        self.assertEqual(self.run_tunnel(), 75)
        self.assertEqual(self.state()['detail'], 'remote_port_in_use')
        self.assertIsNone(child.poll())

    def test_macos_lsof_reaping(self):
        child = self.sleeper()
        self.config.update(executeReap=True, lsofPids=[child.pid])
        self.config['processes'][str(child.pid)] = {'uid': os.getuid(), 'comm': '/usr/sbin/sshd'}
        self.assertEqual(self.run_tunnel(), 75)
        self.assertEqual(child.wait(timeout=2), -signal.SIGTERM)
        self.assertEqual(len(self.calls()), 2)

    def test_launcher_dispatch_requires_no_runtime_vm(self):
        self.config['tunnelError'] = 'Permission denied'
        self.assertEqual(self.run_tunnel(['tunnel', *self.args], ROOT / 'bin/lemon'), 0)
        release = self.home / 'release'
        (release / 'bin').mkdir(parents=True)
        (release / 'libexec').mkdir()
        shutil.copy2(ROOT / 'rel/overlays/bin/lemon', release / 'bin/lemon')
        shutil.copy2(RUNNER, release / 'libexec/lemon-tunnel')
        # There deliberately is no runtime release executable or BEAM here.
        self.assertEqual(self.run_tunnel(['tunnel', *self.args], release / 'bin/lemon'), 0)
        self.assertEqual(self.state()['detail'], 'ssh_auth_failed')


if __name__ == '__main__':
    unittest.main()
