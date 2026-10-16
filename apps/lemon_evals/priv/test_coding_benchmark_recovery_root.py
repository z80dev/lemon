"""Offline executable contract for descriptor-pinned recovery ledger resolution."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

import coding_benchmark_paired as paired


class RecoveryRootTests(unittest.TestCase):
    def test_root_replacement_after_validation_cannot_redirect_either_ledger(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            state, retained, unrelated = [project / name for name in ('state', 'retained', 'unrelated')]
            state.mkdir(mode=0o700)
            unrelated.mkdir(mode=0o700)
            binaries = project / 'bin'
            binaries.mkdir()
            # Stand in only for BEAM, not the exec bootstrap. Resolve both ledgers
            # exactly as recovery does and record which proof authorized signalling.
            executable = binaries / 'elixir'
            executable.write_text(f'#!{sys.executable}\n' + '''import json, os
path = os.environ['LEMON_EVAL_PROCESS_STORE']
assert not os.path.isabs(path)
proofs = []
for name in (path, path + '.native'):
    with open(name) as source:
        proofs.append(json.load(source)['authorized_workload'])
    with open(name, 'a') as ledger:
        ledger.write('\\nrecovered')
print(json.dumps(proofs), flush=True)
''')
            executable.chmod(0o700)
            for suffix in ('', '.native'):
                (state / ('processes.dets' + suffix)).write_text(
                    json.dumps({'authorized_workload': 'original'}))
                (unrelated / ('processes.dets' + suffix)).write_text(
                    json.dumps({'authorized_workload': 'unrelated-do-not-signal'}))
            before = {path.name: path.read_bytes() for path in unrelated.iterdir()}
            descriptor = os.open(state, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            validate = paired.require_trial_root

            def replace_after_check(path, fd):
                validate(path, fd)
                state.rename(retained)
                state.symlink_to(unrelated, target_is_directory=True)

            environment = {'PATH': str(binaries), 'LEMON_EVAL_PROCESS_STORE': str(state / 'processes.dets')}
            try:
                with patch.object(paired, 'terminate_runtime_group'), \
                        patch.object(paired, 'require_trial_root', side_effect=replace_after_check):
                    complete = paired.terminate(Mock(), project_root=project,
                                                environment=environment, root_fd=descriptor)
                self.assertTrue(complete, (retained / 'cleanup.log').read_text())
                self.assertEqual(json.loads((retained / 'cleanup.log').read_text()),
                                 ['original', 'original'])
                for suffix in ('', '.native'):
                    self.assertTrue((retained / ('processes.dets' + suffix)).read_text().endswith('recovered'))
                self.assertEqual({path.name: path.read_bytes() for path in unrelated.iterdir()}, before)
                self.assertFalse((unrelated / 'cleanup.log').exists())
            finally:
                os.close(descriptor)


if __name__ == '__main__':
    unittest.main()
