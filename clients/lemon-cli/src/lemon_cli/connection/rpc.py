import asyncio
import json
import os
from pathlib import Path
from lemon_cli.connection.base import AgentConnection
from lemon_cli.connection.protocol import parse_server_message

RESTART_EXIT_CODE = 75


class RPCConnection(AgentConnection):
    """JSON-line RPC connection via subprocess."""

    def __init__(self, cwd: str, model: str, lemon_path: str | None = None,
                 system_prompt: str | None = None, session_file: str | None = None,
                 debug: bool = False, ui: bool = True):
        super().__init__()
        self._cwd = cwd
        self._model = model
        self._lemon_path = lemon_path or self._discover_lemon_path()
        self._system_prompt = system_prompt
        self._session_file = session_file
        self._debug = debug
        self._ui = ui
        self._process: asyncio.subprocess.Process | None = None
        self._running = False
        self._loop: asyncio.AbstractEventLoop | None = None

    def _discover_lemon_path(self) -> str:
        """Walk up from CWD looking for lemon mix.exs, or check LEMON_PATH env."""
        env_path = os.environ.get("LEMON_PATH")
        if env_path and Path(env_path).exists():
            return env_path

        current = Path(self._cwd).resolve()
        while current != current.parent:
            mix = current / "mix.exs"
            if mix.exists():
                content = mix.read_text(errors="ignore")
                if "lemon" in content.lower():
                    return str(current)
            current = current.parent

        raise RuntimeError("Cannot find lemon project root. Set LEMON_PATH or use --lemon-path.")

    def _build_command(self) -> list[str]:
        """Build the mix run subprocess command."""
        script = os.environ.get("LEMON_AGENT_SCRIPT_PATH", "scripts/debug_agent_rpc.exs")
        command = os.environ.get("LEMON_AGENT_COMMAND", "mix")
        cmd = [command, "run", script, "--",
               "--cwd", self._cwd, "--model", self._model]
        if self._debug:
            cmd.append("--debug")
        if not self._ui:
            cmd.append("--no-ui")
        if self._system_prompt:
            cmd.extend(["--system-prompt", self._system_prompt])
        if self._session_file:
            cmd.extend(["--session-file", self._session_file])
        return cmd

    async def start(self) -> None:
        self._running = True
        self._loop = asyncio.get_event_loop()
        await self._spawn_process()

    async def _spawn_process(self) -> None:
        cmd = self._build_command()
        self._process = await asyncio.create_subprocess_exec(
            *cmd,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=self._lemon_path,
        )
        asyncio.create_task(self._read_stdout())
        asyncio.create_task(self._read_stderr())
        asyncio.create_task(self._watch_exit())

    async def _read_stdout(self) -> None:
        """Read JSON lines from stdout."""
        while self._running and self._process and self._process.stdout:
            try:
                line = await self._process.stdout.readline()
                if not line:
                    break
                text = line.decode("utf-8", errors="replace").strip()
                if not text:
                    continue
                try:
                    data = json.loads(text)
                    msg = parse_server_message(data)
                    if msg.type == "ready":
                        self._emit("ready", msg)
                    else:
                        self._emit("message", msg)
                except json.JSONDecodeError:
                    pass  # ignore non-JSON lines (e.g. Elixir Logger output)
            except Exception as e:
                self._emit("error", str(e))
                break

    async def _read_stderr(self) -> None:
        """Read stderr and surface errors."""
        lines: list[str] = []
        while self._running and self._process and self._process.stderr:
            line = await self._process.stderr.readline()
            if not line:
                break
            text = line.decode("utf-8", errors="replace").rstrip()
            if text:
                lines.append(text)
        self._stderr_output = "\n".join(lines)

    async def _watch_exit(self) -> None:
        """Watch for process exit and optionally restart."""
        if not self._process:
            return
        exit_code = await self._process.wait()
        if exit_code == RESTART_EXIT_CODE and self._running:
            await self._spawn_process()  # Auto-restart
        elif self._running:
            stderr = getattr(self, "_stderr_output", "")
            # Give stderr reader a moment to finish
            await asyncio.sleep(0.1)
            stderr = getattr(self, "_stderr_output", "")
            detail = f" (exit code {exit_code})"
            if stderr:
                detail += f"\n{stderr}"
            self._emit("error", f"Agent process exited{detail}")
            self._emit("close")

    def send_command(self, cmd: dict) -> None:
        if self._process and self._process.stdin:
            line = json.dumps(cmd) + "\n"
            self._process.stdin.write(line.encode("utf-8"))
            # Note: drain is async, but we fire-and-forget here
            if self._loop:
                asyncio.run_coroutine_threadsafe(
                    self._process.stdin.drain(), self._loop
                )

    async def stop(self) -> None:
        self._running = False
        if self._process:
            self.send_command({"type": "quit"})
            try:
                await asyncio.wait_for(self._process.wait(), timeout=5.0)
            except asyncio.TimeoutError:
                self._process.kill()
