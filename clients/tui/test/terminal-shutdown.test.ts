import { expect, test } from "bun:test";

const python = Bun.which("python3");

// A real non-reading PTY catches TCSADRAIN hangs that an in-memory terminal, or
// Bun.Terminal's continuously draining callback, cannot exercise.
test.skipIf(!python || process.platform === "win32")(
	"SIGTERM restores exact tty modes and exits while the terminal reader is paused",
	async () => {
		const proc = Bun.spawn(
			[
				python!,
				"-c",
				String.raw`
import fcntl, json, os, pty, select, shutil, signal, struct, subprocess, sys, tempfile, termios, time
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
original = termios.tcgetattr(slave)
env = {k: v for k, v in os.environ.items() if not k.startswith('TERN')}
home = tempfile.mkdtemp()  # prompt history is saved under $HOME; keep it off the real ~/.lemon
env.update(TERM='xterm-256color', TERM_PROGRAM='', PI_TUI_NATIVE='0', PI_TEST_RUNTIME='0', LEMON_EDITOR='true',
           LEMON_CONTROL_PLANE_OPERATOR_TOKEN='', LEMON_WS_TOKEN='', HOME=home)
child = subprocess.Popen([sys.argv[1], 'src/main.ts', '--ws-url', 'ws://127.0.0.1:1/ws'],
                         stdin=slave, stdout=slave, stderr=slave, env=env, start_new_session=True)
output = bytearray()
def until(predicate):
    deadline = time.monotonic() + 5
    while not predicate():
        if time.monotonic() >= deadline or child.poll() is not None:
            raise RuntimeError('terminal did not reach expected state: ' + repr(bytes(output[-1000:])))
        if select.select([master], [], [], 0.03)[0]:
            data = os.read(master, 65536)
            output.extend(data)
            if b'\x1b[6n' in data: os.write(master, b'\x1b[1;1R')
            if b'\x1b[c' in data: os.write(master, b'\x1b[?1;2c')
try:
    until(lambda: b'/help' in output)
    # Exercise the same terminal object leaving/re-entering raw mode twice.
    for index in range(2):
        text = f'reentry{index}'.encode()
        os.write(master, text)
        until(lambda: text in output)
        previous = output.count(b'\x1b[?2004h')
        os.write(master, b'\x07')
        until(lambda: output.count(b'\x1b[?2004h') > previous)
    raw_after_restart = not (termios.tcgetattr(slave)[3] & (termios.ICANON | termios.ECHO))
    # Stop consuming output and fill the actual transcript/OS output queue.
    for _ in range(12):
        os.write(master, b'\x1b[200~/help\x1b[201~\r')
    time.sleep(0.35)
    began = time.monotonic()
    child.send_signal(signal.SIGTERM)
    code = child.wait(timeout=3)
    print(json.dumps({'exit': code, 'elapsedMs': (time.monotonic()-began)*1000,
                      'restored': termios.tcgetattr(slave) == original,
                      'rawAfterRestart': raw_after_restart}))
finally:
    if child.poll() is None:
        child.kill()
        child.wait()
    os.close(master)
    os.close(slave)
    shutil.rmtree(home, ignore_errors=True)
`,
				process.execPath,
			],
			{
				cwd: new URL("..", import.meta.url).pathname,
				stdout: "pipe",
				stderr: "pipe",
			},
		);
		const [code, output, errors] = await Promise.all([
			proc.exited,
			new Response(proc.stdout).text(),
			new Response(proc.stderr).text(),
		]);
		expect(code, errors).toBe(0);
		const result = JSON.parse(output) as {
			exit: number;
			elapsedMs: number;
			restored: boolean;
			rawAfterRestart: boolean;
		};
		expect(result.exit).toBe(0);
		expect(result.elapsedMs).toBeLessThan(2500);
		expect(result.restored).toBe(true);
		expect(result.rawAfterRestart).toBe(true);
	},
	15000,
);
