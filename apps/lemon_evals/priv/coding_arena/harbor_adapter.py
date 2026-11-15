"""Harbor installed agents using arena bundles and the host substituting proxy.

API: laude-institute/harbor ec6aeab7fe0eb51df52b4e72c524daf5ea9cc5f4.
Only the adapters' host process reads ARENA_PROXY_SECRET. No Harbor credential
resolver, agent-env, host HOME, or provider credential is forwarded to a task.
"""
import hashlib
import json
import os
import shlex
import uuid
from pathlib import Path
from urllib.parse import urlsplit

from harbor.agents.installed.base import BaseInstalledAgent

from bench_common import HOME, command, configuration, metrics, token_for
import arena


class ArenaInstalledAgent(BaseInstalledAgent):
    arm = None

    def __init__(self, *args, agent_bundle, agent_revision, proxy_url,
                 effort='high', deadline=600, rep=1, **kwargs):
        # Harbor's general env forwarding is deliberately unsupported here.
        if kwargs.get('extra_env') or kwargs.get('skip_install'):
            raise ValueError('arena adapters forbid extra_env and skip_install')
        super().__init__(*args, **kwargs)
        if self.model_name not in arena.MODELS:
            raise ValueError('use a wire model id from arena.MODELS')
        if effort not in ('minimal', 'low', 'medium', 'high', 'xhigh'):
            raise ValueError('unsupported effort')
        parsed = urlsplit(proxy_url)
        if parsed.scheme not in ('http', 'https') or not parsed.hostname or parsed.username or parsed.password:
            raise ValueError('proxy_url must be a credential-free HTTP(S) origin')
        if parsed.path not in ('', '/') or parsed.query or parsed.fragment:
            raise ValueError('proxy_url must be an origin, not a provider endpoint')
        self.bundle = Path(agent_bundle).resolve(strict=True)
        self.agent_revision = agent_revision
        self.proxy_url = proxy_url.rstrip('/')
        self.effort, self.deadline, self.rep = effort, int(deadline), int(rep)
        if self.deadline <= 0 or self.rep <= 0:
            raise ValueError('deadline and repetition must be positive')
        self.trial = 'harbor-' + uuid.uuid4().hex
        self.token = token_for(os.environ['ARENA_PROXY_SECRET'], self.trial, self.model_name)
        self._arena_config_files, self.runtime_env = configuration(self.arm, self.model_name, effort, self.proxy_url, self.token)
        with self.bundle.open('rb') as source:
            bundle_sha256 = hashlib.file_digest(source, 'sha256').hexdigest()
        self.record = {'agent': self.arm, 'model': self.model_name, 'effort': self.effort,
                       'deadline': self.deadline, 'rep': self.rep, 'proxy_trial': self.trial,
                       'agent_revision': self.agent_revision, 'bundle_sha256': bundle_sha256}

    def get_version_command(self):
        return f'{self.arm} --version'

    async def install(self, environment):
        # Bundles come from the existing arena images, not an unpinned installer.
        await self.exec_as_root(environment, command=(
            'apt-get update && apt-get install -y --no-install-recommends '
            'libstdc++6 openssl libncurses6 libtinfo6 inotify-tools curl ca-certificates coreutils '
            '&& rm -rf /var/lib/apt/lists/*'))
        remote = '/installed-agent/arena-bundle.tar.gz'
        await environment.upload_file(self.bundle, remote)
        target = '/opt/lemon' if self.arm == 'lemon' else '/opt/bun'
        links = ('ln -sf /opt/lemon/bin/lemon /usr/local/bin/lemon' if self.arm == 'lemon' else
                 'ln -sf /opt/bun/bin/bun /usr/local/bin/bun && ln -sf /opt/bun/bin/omp /usr/local/bin/omp')
        await self.exec_as_root(environment, command=(
            f'mkdir -p {target} && tar -xzf {remote} -C {target} && chmod -R a+rX {target} && {links} '
            f'&& rm {remote}'))

    def isolated(self, argv):
        return shlex.join(['env', '-i', *[f'{key}={value}' for key, value in self.runtime_env.items()], *argv])

    async def configure(self, environment):
        await self.exec_as_agent(environment, command=f'umask 077; mkdir -p {HOME}/.lemon {HOME}/.omp/agent')
        for index, (relative, content) in enumerate(self._arena_config_files.items()):
            await self._upload_config_text(environment, content=content,
                                           remote_path=f'{HOME}/{relative}', filename=f'config-{index}')
        self.logs_dir.mkdir(parents=True, exist_ok=True)
        self._save()
        if self.arm == 'lemon':
            # A daemon is local to this fresh task container and HOME.
            await self.exec_as_agent(environment, command=self.isolated(['lemon', 'daemon']), timeout_sec=240)

    def _save(self):
        (self.logs_dir / 'arena.json').write_text(json.dumps(self.record, indent=2) + '\n')

    async def run(self, instruction, environment, context):
        log = shlex.quote(str(self.environment_logs_dir / 'agent.stdout'))
        err = shlex.quote(str(self.environment_logs_dir / 'agent.stderr'))
        # Preserve Harbor's task WORKDIR; /work is an arena convention, not TB's.
        argv = command(self.arm, instruction, self.model_name, self.effort, self.deadline, '.')
        invocation = self.isolated(['timeout', '--signal=TERM', '--kill-after=10', str(self.deadline), *argv])
        result = await environment.exec(command=f'{invocation} > {log} 2> {err}',
                                        timeout_sec=self.deadline + 15)
        self.record['exit_code'] = result.return_code
        self._save()
        context.metadata = dict(self.record)
        if result.return_code != 0:
            raise RuntimeError(f'{self.arm} exited with code {result.return_code}; see private agent logs')

    def populate_context_post_run(self, context):
        path = self.logs_dir / 'agent.stdout'
        if path.exists():
            text = path.read_text()
            self.record.update(metrics(self.arm, text))
            # Only scoped proxy tokens can be present; still remove them from retained logs.
            path.write_text(text.replace(self.token, '[TRIAL_TOKEN]'))
        error = self.logs_dir / 'agent.stderr'
        if error.exists():
            error.write_text(error.read_text().replace(self.token, '[TRIAL_TOKEN]'))
        self._save()
        context.metadata = dict(self.record)
        # Usage comes from the proxy during report generation, not CLI guesses.


class HarborLemon(ArenaInstalledAgent):
    arm = 'lemon'

    @staticmethod
    def name():
        return 'arena-lemon'


class HarborOmp(ArenaInstalledAgent):
    arm = 'omp'

    @staticmethod
    def name():
        return 'arena-omp'
