import { LemonSocket } from './lemon-socket.js';
import { ChromeSession } from './chrome.js';
import { handleBrowserMethod } from './browser-methods.js';

export type BrowserNodeConfig = {
  wsUrl: string;
  token: string;
  cdpPort: number;
  userDataDir: string;
  executablePath?: string;
  headless: boolean;
  noSandbox: boolean;
  attachOnly: boolean;
};

export async function runBrowserNode(cfg: BrowserNodeConfig): Promise<void> {
  const chrome = new ChromeSession({
    cdpPort: cfg.cdpPort,
    userDataDir: cfg.userDataDir,
    executablePath: cfg.executablePath,
    headless: cfg.headless,
    noSandbox: cfg.noSandbox,
    attachOnly: cfg.attachOnly,
  });
  await chrome.start();

  const { socket, hello } = await LemonSocket.connect(cfg.wsUrl, {
    auth: { token: cfg.token },
  });

  const nodeId = hello.auth?.clientId;
  if (!nodeId) {
    throw new Error('Connected as node, but server did not provide auth.clientId in hello-ok');
  }

  // Process invocations serially to avoid concurrent Playwright operations colliding.
  let queue = Promise.resolve();

  socket.onEvent((ev) => {
    if (ev.event !== 'node.invoke.request') return;
    const payload: any = ev.payload ?? {};
    if (payload.nodeId !== nodeId) return;

    const invokeId = String(payload.invokeId ?? '');
    const method = String(payload.method ?? '');
    const args = payload.args ?? {};
    const timeoutMs = payload.timeoutMs;

    queue = queue.then(async () => {
      try {
        if (!method.startsWith('browser.')) {
          throw new Error(`Unsupported invocation method: ${method}`);
        }

        const result = await withTimeout(
          () => chrome.withPage((page) => handleBrowserMethod(page, method, args)),
          typeof timeoutMs === 'number' && timeoutMs > 0 ? timeoutMs : 30_000,
        );

        await socket.call('node.invoke.result', { invokeId, result });
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        await socket.call('node.invoke.result', { invokeId, error: msg });
      }
    });
  });

  process.on('SIGINT', () => {
    socket.close();
    void chrome.stop().finally(() => process.exit(0));
  });
  process.on('SIGTERM', () => {
    socket.close();
    void chrome.stop().finally(() => process.exit(0));
  });
}

async function withTimeout<T>(fn: () => Promise<T>, timeoutMs: number): Promise<T> {
  let t: NodeJS.Timeout | null = null;
  try {
    return await Promise.race([
      fn(),
      new Promise<T>((_, reject) => {
        t = setTimeout(() => reject(new Error(`timeout after ${timeoutMs}ms`)), timeoutMs);
      }),
    ]);
  } finally {
    if (t) clearTimeout(t);
  }
}
