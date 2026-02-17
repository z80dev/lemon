import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { chromium, type Browser, type BrowserContext, type Page } from 'playwright-core';

export type ChromeConfig = {
  cdpPort: number;
  userDataDir: string;
  executablePath?: string;
  headless: boolean;
  noSandbox: boolean;
  attachOnly: boolean;
};

export class ChromeSession {
  private cfg: ChromeConfig;
  private proc: ChildProcessWithoutNullStreams | null = null;
  private browser: Browser | null = null;
  private page: Page | null = null;

  constructor(cfg: ChromeConfig) {
    this.cfg = cfg;
  }

  async start(): Promise<void> {
    const endpoint = `http://127.0.0.1:${this.cfg.cdpPort}`;

    const reachable = await isCdpReachable(endpoint, 600);
    if (!reachable) {
      if (this.cfg.attachOnly) {
        throw new Error(`CDP not reachable at ${endpoint} (attachOnly=true)`);
      }
      await this.launchChrome();
      await waitForCdp(endpoint, 15_000);
    }

    this.browser = await chromium.connectOverCDP(endpoint, { timeout: 15_000 });
    this.page = await ensurePage(this.browser);
  }

  async withPage<T>(operation: (page: Page) => Promise<T>): Promise<T> {
    const page = await this.getPage();

    try {
      return await operation(page);
    } catch (err) {
      if (!isClosedTargetError(err)) {
        throw err;
      }

      await this.reconnect();
      const retryPage = await this.getPage();
      return operation(retryPage);
    }
  }

  async stop(): Promise<void> {
    try {
      await this.browser?.close();
    } catch {
      // ignore
    }
    this.browser = null;
    this.page = null;

    if (this.proc) {
      try {
        this.proc.kill('SIGTERM');
      } catch {
        // ignore
      }
      this.proc = null;
    }
  }

  async getPage(): Promise<Page> {
    if (!this.browser || !this.browser.isConnected()) {
      await this.reconnect();
    }

    if (!this.browser) {
      throw new Error('browser not started');
    }

    if (!this.page || this.page.isClosed()) {
      this.page = await ensurePage(this.browser);
    }

    return this.page;
  }

  async getContext(): Promise<BrowserContext> {
    const page = await this.getPage();
    return page.context();
  }

  private async launchChrome(): Promise<void> {
    const exe = this.cfg.executablePath || defaultChromeExecutable();
    if (!exe) {
      throw new Error(
        'Could not find Chrome/Chromium executable. Set --executable-path or LEMON_CHROME_EXECUTABLE.',
      );
    }

    fs.mkdirSync(this.cfg.userDataDir, { recursive: true });

    const args: string[] = [
      `--remote-debugging-port=${this.cfg.cdpPort}`,
      '--remote-debugging-address=127.0.0.1',
      `--user-data-dir=${this.cfg.userDataDir}`,
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-sync',
      '--disable-background-networking',
      '--disable-component-update',
      '--disable-features=Translate,MediaRouter',
      '--disable-session-crashed-bubble',
      '--hide-crash-restore-bubble',
      '--password-store=basic',
    ];

    if (this.cfg.headless) {
      args.push('--headless=new', '--disable-gpu');
    }

    if (this.cfg.noSandbox) {
      args.push('--no-sandbox', '--disable-setuid-sandbox');
    }

    if (process.platform === 'linux') {
      args.push('--disable-dev-shm-usage');
    }

    args.push('about:blank');

    this.proc = spawn(exe, args, {
      stdio: 'pipe',
      env: {
        ...process.env,
        HOME: os.homedir(),
      },
    });
  }

  private async reconnect(): Promise<void> {
    await this.stop();
    await this.start();
  }
}

async function ensurePage(browser: Browser): Promise<Page> {
  const contexts = browser.contexts();
  const ctx = contexts[0] ?? (await browser.newContext());
  const pages = ctx.pages();
  const page = pages[0] ?? (await ctx.newPage());
  return page;
}

async function isCdpReachable(endpoint: string, timeoutMs: number): Promise<boolean> {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(`${endpoint}/json/version`, { signal: ctrl.signal });
    return res.ok;
  } catch {
    return false;
  } finally {
    clearTimeout(t);
  }
}

async function waitForCdp(endpoint: string, timeoutMs: number): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    if (await isCdpReachable(endpoint, 500)) return;
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`Timed out waiting for CDP at ${endpoint}`);
}

function defaultChromeExecutable(): string | null {
  const envExe = (process.env.LEMON_CHROME_EXECUTABLE || process.env.CHROME_EXECUTABLE || '').trim();
  if (envExe) return envExe;

  if (process.platform === 'darwin') {
    const macCandidates = [
      '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      '/Applications/Chromium.app/Contents/MacOS/Chromium',
      '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
      '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
    ];
    for (const c of macCandidates) {
      if (fs.existsSync(c)) return c;
    }
    return null;
  }

  // Linux/Windows: rely on PATH resolution by spawn.
  const pathCandidates = process.platform === 'win32'
    ? ['chrome.exe', 'msedge.exe']
    : ['google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser', 'brave', 'microsoft-edge'];

  // If the command is on PATH, returning it is sufficient.
  return pathCandidates[0] ?? null;
}

function isClosedTargetError(err: unknown): boolean {
  const message = err instanceof Error ? err.message : String(err ?? '');
  const normalized = message.toLowerCase();

  return (
    normalized.includes('target page, context or browser has been closed') ||
    normalized.includes('target closed') ||
    normalized.includes('browser has been closed') ||
    normalized.includes('context closed') ||
    normalized.includes('page closed')
  );
}
