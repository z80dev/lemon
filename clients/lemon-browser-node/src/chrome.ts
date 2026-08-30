import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { chromium, type Browser, type BrowserContext, type Page } from 'playwright-core';

export type BrowserTab = {
  targetId: string;
  active: boolean;
  url: string;
  title: string | null;
};

type PageTargetInfo = {
  targetId: string;
  title: string | null;
  url: string;
};

export type ChromeConfig = {
  cdpPort: number;
  cdpEndpoint?: string;
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
  private activeTargetId: string | null = null;
  private ownedBrowser = false;

  constructor(cfg: ChromeConfig) {
    this.cfg = cfg;
  }

  async start(): Promise<void> {
    const endpoint = this.cfg.cdpEndpoint || `http://127.0.0.1:${this.cfg.cdpPort}`;

    const reachable = await isCdpReachable(endpoint, 600);
    if (!reachable) {
      if (this.cfg.attachOnly || this.cfg.cdpEndpoint) {
        throw new Error(`CDP not reachable at ${redactEndpoint(endpoint)} (attachOnly=true)`);
      }
      await this.launchChrome();
      await waitForCdp(endpoint, 15_000);
      this.ownedBrowser = true;
    }

    this.browser = await chromium.connectOverCDP(normalizeCdpEndpoint(endpoint), {
      timeout: 15_000,
    });
    const page = await ensurePage(this.browser);
    this.activeTargetId = await targetIdForPage(page);
  }

  async withPage<T>(
    operation: (page: Page) => Promise<T>,
    targetId?: string,
  ): Promise<T> {
    const page = await this.getPage(targetId);

    try {
      return await operation(page);
    } catch (err) {
      if (!isClosedTargetError(err)) {
        throw err;
      }

      await this.reconnect();
      const retryPage = await this.getPage(targetId);
      return operation(retryPage);
    }
  }

  async stop(): Promise<void> {
    // `Browser.close()` terminates the real Chrome process for CDP connections.
    // Never send it to a browser we merely attached to (for example the user's
    // everyday Chrome via the extension relay).
    if (this.ownedBrowser) {
      try {
        await this.browser?.close();
      } catch {
        // ignore
      }
    }
    this.browser = null;
    this.activeTargetId = null;

    if (this.proc) {
      try {
        this.proc.kill('SIGTERM');
      } catch {
        // ignore
      }
      this.proc = null;
    }

    this.ownedBrowser = false;
  }

  async getPage(targetId?: string): Promise<Page> {
    if (!this.browser || !this.browser.isConnected()) {
      await this.reconnect();
    }

    if (!this.browser) {
      throw new Error('browser not started');
    }

    const pages = allPages(this.browser).filter((page) => !page.isClosed());

    if (targetId) {
      const page = await findPageByTargetId(pages, targetId);
      if (!page) {
        throw new Error(`browser target not found: ${targetId}`);
      }
      return page;
    }

    if (this.activeTargetId) {
      const active = await findPageByTargetId(pages, this.activeTargetId);
      if (active) return active;
    }

    const page = pages.at(-1) ?? (await ensurePage(this.browser));
    this.activeTargetId = await targetIdForPage(page);
    return page;
  }

  async getContext(): Promise<BrowserContext> {
    const page = await this.getPage();
    return page.context();
  }

  async listTabs(): Promise<{ tabs: BrowserTab[]; activeTargetId: string }> {
    const activePage = await this.getPage();
    const activeTargetId = await targetIdForPage(activePage);
    this.activeTargetId = activeTargetId;

    if (!this.browser) throw new Error('browser not started');

    const tabs = await Promise.all(
      allPages(this.browser)
        .filter((page) => !page.isClosed())
        .map(async (page): Promise<BrowserTab> => {
          const target = await targetInfoForPage(page);
          return {
            targetId: target.targetId,
            active: target.targetId === activeTargetId,
            url: target.url || page.url(),
            title: target.title,
          };
        }),
    );

    return { tabs, activeTargetId };
  }

  async openTab(url = 'about:blank'): Promise<BrowserTab> {
    if (!this.browser || !this.browser.isConnected()) await this.reconnect();
    if (!this.browser) throw new Error('browser not started');

    // Use the browser target directly so extension-backed sessions create the
    // final URL atomically. A synthetic relay target does not need to survive
    // Playwright's intermediate about:blank page lifecycle.
    const session = await this.browser.newBrowserCDPSession();
    let targetId: string;
    try {
      const created = (await session.send('Target.createTarget', { url })) as {
        targetId?: string;
      };
      if (!created.targetId) throw new Error('CDP did not return a created target ID');
      targetId = created.targetId;
    } finally {
      await session.detach().catch(() => undefined);
    }

    const page = await waitForPageByTargetId(this.browser, targetId, 10_000);
    if (url !== 'about:blank') {
      await waitForDocumentReady(page, url, 10_000);
    }
    await page.bringToFront();

    const target = await targetInfoForPage(page, true);
    this.activeTargetId = targetId;

    return {
      targetId,
      active: true,
      url: target.url || page.url(),
      title: target.title,
    };
  }

  async activateTab(targetId: string): Promise<BrowserTab> {
    const page = await this.getPage(targetId);
    await page.bringToFront();
    this.activeTargetId = targetId;
    const target = await targetInfoForPage(page, true);

    return {
      targetId,
      active: true,
      url: target.url || page.url(),
      title: target.title,
    };
  }

  async closeTab(targetId: string): Promise<{ closed: true; targetId: string; activeTargetId: string }> {
    const page = await this.getPage(targetId);
    await page.close();

    if (!this.browser) throw new Error('browser not started');
    const replacement = await ensurePage(this.browser);
    const activeTargetId = await targetIdForPage(replacement);
    if (this.activeTargetId === targetId) {
      this.activeTargetId = activeTargetId;
      await replacement.bringToFront().catch(() => undefined);
    }

    return { closed: true, targetId, activeTargetId: this.activeTargetId ?? activeTargetId };
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
    // If an owned Chrome process is still alive, preserve it while replacing a
    // stale Playwright connection. `start()` will attach to its CDP port.
    const proc = this.proc;
    const ownedBrowser = this.ownedBrowser;
    this.browser = null;
    this.activeTargetId = null;
    await this.start();
    this.proc = this.proc ?? proc;
    this.ownedBrowser = this.ownedBrowser || ownedBrowser;
  }
}

async function waitForPageByTargetId(
  browser: Browser,
  targetId: string,
  timeoutMs: number,
): Promise<Page> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const page = await findPageByTargetId(
      allPages(browser).filter((candidate) => !candidate.isClosed()),
      targetId,
    );
    if (page) return page;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`timed out waiting for browser target: ${targetId}`);
}

async function waitForDocumentReady(page: Page, expectedUrl: string, timeoutMs: number): Promise<void> {
  const session = await page.context().newCDPSession(page);
  const expected = new URL(expectedUrl);
  const started = Date.now();
  try {
    while (Date.now() - started < timeoutMs) {
      const response = (await session.send('Runtime.evaluate', {
        expression: '({readyState: document.readyState, href: location.href})',
        returnByValue: true,
      })) as { result?: { value?: { readyState?: string; href?: string } } };
      const value = response.result?.value;
      if (value?.href && ['interactive', 'complete'].includes(value.readyState ?? '')) {
        const current = new URL(value.href);
        const matches = expectedUrl.startsWith('data:')
          ? current.protocol === 'data:'
          : current.origin === expected.origin && current.pathname === expected.pathname;
        if (matches) return;
      }
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
  } finally {
    await session.detach().catch(() => undefined);
  }
  throw new Error('timed out waiting for created browser target to become ready');
}

async function ensurePage(browser: Browser): Promise<Page> {
  const contexts = browser.contexts();
  const ctx = contexts[0] ?? (await browser.newContext());
  const pages = ctx.pages();
  const page = pages[0] ?? (await ctx.newPage());
  return page;
}

function allPages(browser: Browser): Page[] {
  return browser.contexts().flatMap((context) => context.pages());
}

async function findPageByTargetId(pages: Page[], targetId: string): Promise<Page | null> {
  for (const page of pages) {
    if ((await targetIdForPage(page)) === targetId) return page;
  }
  return null;
}

async function targetIdForPage(page: Page): Promise<string> {
  return (await targetInfoForPage(page)).targetId;
}

async function targetInfoForPage(page: Page, refresh = false): Promise<PageTargetInfo> {
  const targetPage = page as Page & { __lemonTargetInfo?: PageTargetInfo };
  if (!refresh && targetPage.__lemonTargetInfo) return targetPage.__lemonTargetInfo;

  const session = await page.context().newCDPSession(page);
  try {
    const response = (await session.send('Target.getTargetInfo')) as {
      targetInfo?: { targetId?: string; title?: string; url?: string };
    };
    const targetId = response.targetInfo?.targetId;
    if (!targetId) throw new Error('CDP target did not provide targetId');
    const targetInfo = {
      targetId,
      title: response.targetInfo?.title ?? null,
      url: response.targetInfo?.url ?? page.url(),
    };
    targetPage.__lemonTargetInfo = targetInfo;
    return targetInfo;
  } finally {
    await session.detach().catch(() => undefined);
  }
}

export async function isCdpReachable(endpoint: string, timeoutMs: number): Promise<boolean> {
  if (isWebSocketEndpoint(endpoint)) {
    // There is no discovery URL to probe for a direct WebSocket endpoint. The
    // subsequent Playwright connection is the authoritative reachability test.
    return true;
  }

  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(cdpDiscoveryUrl(endpoint), {
      signal: ctrl.signal,
    });
    return res.ok;
  } catch {
    return false;
  } finally {
    clearTimeout(t);
  }
}

export function normalizeCdpEndpoint(endpoint: string): string {
  const normalized = endpoint.trim();
  if (!/^https?:\/\//i.test(normalized) && !/^wss?:\/\//i.test(normalized)) {
    throw new Error('CDP endpoint must use http, https, ws, or wss');
  }
  return stripTrailingSlash(normalized);
}

export function cdpDiscoveryUrl(endpoint: string): string {
  const url = new URL(normalizeCdpEndpoint(endpoint));
  url.pathname = `${url.pathname.replace(/\/+$/, '')}/json/version`.replace(
    /\/+/g,
    '/',
  );
  return url.toString();
}

function isWebSocketEndpoint(endpoint: string): boolean {
  return /^wss?:\/\//i.test(endpoint.trim());
}

function stripTrailingSlash(endpoint: string): string {
  return endpoint.replace(/\/+$/, '');
}

async function waitForCdp(endpoint: string, timeoutMs: number): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    if (await isCdpReachable(endpoint, 500)) return;
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`Timed out waiting for CDP at ${redactEndpoint(endpoint)}`);
}

function redactEndpoint(endpoint: string): string {
  try {
    const url = new URL(endpoint);
    if (url.username || url.password) {
      url.username = url.username ? '[redacted]' : '';
      url.password = url.password ? '[redacted]' : '';
    }
    for (const key of ['token', 'ticket', 'key', 'api_key', 'access_token']) {
      if (url.searchParams.has(key)) url.searchParams.set(key, '[redacted]');
    }
    return url.toString();
  } catch {
    return endpoint.replace(/(wss?:\/\/[^:/\s]+:)[^@\s]+@/i, '$1[redacted]@');
  }
}

export function defaultChromeExecutable(): string | null {
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

  const pathCandidates = process.platform === 'win32'
    ? ['chrome.exe', 'msedge.exe']
    : ['google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser', 'brave', 'microsoft-edge'];

  return findExecutableOnPath(pathCandidates);
}

function findExecutableOnPath(candidates: string[]): string | null {
  const searchPath = process.env.PATH || '';

  for (const dir of searchPath.split(path.delimiter)) {
    if (!dir) continue;

    for (const candidate of candidates) {
      const fullPath = path.join(dir, candidate);

      try {
        fs.accessSync(fullPath, fs.constants.X_OK);
        return fullPath;
      } catch {
        // try next candidate
      }
    }
  }

  return null;
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
