import fs from 'node:fs/promises';
import path from 'node:path';

import type { ConsoleMessage, Dialog, Page } from 'playwright-core';

export async function handleBrowserMethod(page: Page, method: string, args: any): Promise<unknown> {
  const m = method.startsWith('browser.') ? method : `browser.${method}`;
  const a = args ?? {};
  const eventBuffer = ensureEventBuffer(page);

  switch (m) {
    case 'browser.events': {
      const limit = Math.min(normalizePositiveInt(a.limit, 50), MAX_BROWSER_EVENTS);
      const events = eventBuffer.events.slice(-limit);
      const count = eventBuffer.events.length;
      const cleared = a.clear === true;

      if (cleared) {
        eventBuffer.events.length = 0;
      }

      return { events, count, cleared };
    }
    case 'browser.navigate': {
      const url = String(a.url ?? '');
      if (!url) throw new Error('navigate requires args.url');
      const resp = await page.goto(url, { waitUntil: 'domcontentloaded' });
      return {
        url: page.url(),
        status: resp?.status() ?? null,
        title: await page.title().catch(() => null),
      };
    }
    case 'browser.screenshot': {
      const fullPage = a.fullPage === true;
      const type = (a.type === 'jpeg' ? 'jpeg' : 'png') as 'png' | 'jpeg';
      const buf = await page.screenshot({ fullPage, type });
      return {
        contentType: type === 'jpeg' ? 'image/jpeg' : 'image/png',
        base64: buf.toString('base64'),
      };
    }
    case 'browser.click': {
      const selector = String(a.selector ?? '');
      if (!selector) throw new Error('click requires args.selector');
      const timeout = normalizeTimeout(a.timeoutMs);
      await page.click(selector, { timeout });
      return { clicked: true };
    }
    case 'browser.type': {
      const selector = String(a.selector ?? '');
      if (!selector) throw new Error('type requires args.selector');
      const text = String(a.text ?? '');
      const timeout = normalizeTimeout(a.timeoutMs);
      if (a.clear === true) {
        await page.fill(selector, '', { timeout });
      }
      if (a.useFill === true) {
        await page.fill(selector, text, { timeout });
      } else {
        const delay = normalizeDelay(a.delayMs);
        await page.type(selector, text, { timeout, delay });
      }
      return { typed: true, length: text.length };
    }
    case 'browser.hover': {
      const selector = String(a.selector ?? '');
      if (!selector) throw new Error('hover requires args.selector');
      const timeout = normalizeTimeout(a.timeoutMs);
      await page.hover(selector, { timeout });
      return { hovered: true };
    }
    case 'browser.selectOption': {
      const selector = String(a.selector ?? '');
      if (!selector) throw new Error('selectOption requires args.selector');
      const rawValues: unknown[] = Array.isArray(a.values)
        ? a.values
        : [a.value ?? a.values].filter((value: unknown) => value != null);
      const values = rawValues.map((value: unknown) => String(value)).filter((value: string) => value.trim() !== '');
      if (values.length === 0) throw new Error('selectOption requires args.value or args.values');
      const timeout = normalizeTimeout(a.timeoutMs);
      const selected = await page.selectOption(selector, values.length === 1 ? values[0] : values, { timeout });
      return { selected, count: selected.length };
    }
    case 'browser.setInputFiles': {
      const selector = String(a.selector ?? '');
      if (!selector) throw new Error('setInputFiles requires args.selector');
      const rawPaths: unknown[] = Array.isArray(a.paths)
        ? a.paths
        : [a.path ?? a.paths].filter((path: unknown) => path != null);
      const paths = rawPaths.map((path: unknown) => String(path)).filter((path: string) => path.trim() !== '');
      if (paths.length === 0) throw new Error('setInputFiles requires args.path or args.paths');
      const timeout = normalizeTimeout(a.timeoutMs);
      await page.setInputFiles(selector, paths.length === 1 ? paths[0] : paths, { timeout });
      return { uploaded: true, count: paths.length };
    }
    case 'browser.download': {
      const selector = String(a.selector ?? '');
      const timeout = normalizeTimeout(a.timeoutMs);
      const explicitPath = typeof a.path === 'string' && a.path.trim() !== '' ? a.path.trim() : '';
      const downloadDir = typeof a.dir === 'string' && a.dir.trim() !== '' ? a.dir.trim() : process.cwd();
      const waitForDownload = page.waitForEvent('download', { timeout });

      const download = selector
        ? await Promise.all([waitForDownload, page.click(selector, { timeout })]).then(([download]) => download)
        : await waitForDownload;

      const suggestedFilename = download.suggestedFilename();
      const targetPath = explicitPath || (await uniqueDownloadPath(downloadDir, suggestedFilename));
      await fs.mkdir(path.dirname(targetPath), { recursive: true });
      await download.saveAs(targetPath);

      const stat = await fs.stat(targetPath).catch(() => null);

      return {
        downloaded: true,
        path: targetPath,
        suggestedFilename,
        bytes: stat?.size ?? null,
      };
    }
    case 'browser.press': {
      const key = String(a.key ?? '');
      if (!key) throw new Error('press requires args.key');
      const selector = String(a.selector ?? '');
      const timeout = normalizeTimeout(a.timeoutMs);
      if (selector) {
        await page.press(selector, key, { timeout });
      } else {
        await page.keyboard.press(key);
      }
      return { pressed: true, key };
    }
    case 'browser.scroll': {
      const selector = String(a.selector ?? '');
      const x = normalizeNumber(a.x, normalizeNumber(a.deltaX, 0));
      const y = normalizeNumber(a.y, normalizeNumber(a.deltaY, 600));

      if (selector) {
        const timeout = normalizeTimeout(a.timeoutMs);
        const locator = page.locator(selector).first();
        await locator.waitFor({ timeout, state: 'visible' });
        await locator.evaluate((el: any) => {
          el.scrollIntoView({ block: 'center', inline: 'center' });
        });
      } else if (a.absolute === true || a.to === true) {
        await page.evaluate(
          ({ x, y }) => {
            (globalThis as any).window?.scrollTo(x, y);
          },
          { x, y },
        );
      } else {
        await page.evaluate(
          ({ x, y }) => {
            (globalThis as any).window?.scrollBy(x, y);
          },
          { x, y },
        );
      }

      const position = await page.evaluate(() => {
        const win = (globalThis as any).window;
        return {
          x: Number(win?.scrollX ?? 0),
          y: Number(win?.scrollY ?? 0),
        };
      });

      return { scrolled: true, position };
    }
    case 'browser.back': {
      const resp = await page.goBack({ waitUntil: 'domcontentloaded' });
      return {
        url: page.url(),
        status: resp?.status() ?? null,
        title: await page.title().catch(() => null),
      };
    }
    case 'browser.evaluate': {
      const expression = String(a.expression ?? a.script ?? '');
      if (!expression) throw new Error('evaluate requires args.expression');
      // Evaluate as an expression (not a function body).
      // Caller can pass e.g. "document.title" or "(() => window.location.href)()".
      const result = await page.evaluate(expression);
      return { result };
    }
    case 'browser.waitForSelector': {
      const selector = String(a.selector ?? '');
      if (!selector) throw new Error('waitForSelector requires args.selector');
      const timeout = normalizeTimeout(a.timeoutMs);
      await page.waitForSelector(selector, { timeout });
      return { found: true };
    }
    case 'browser.getContent': {
      const includeHtml = a.includeHtml !== false;
      const includeText = a.includeText !== false;
      if (!includeHtml && !includeText) {
        throw new Error('getContent requires includeHtml or includeText');
      }

      const maxChars = normalizePositiveInt(a.maxChars, 20_000);
      const textMaxChars = normalizePositiveInt(a.textMaxChars, 12_000);

      const result: Record<string, unknown> = {
        url: page.url(),
        title: await page.title().catch(() => null),
      };

      if (includeHtml) {
        const rawHtml = await page.content();
        const html = stripNoisyHtml(rawHtml);
        const htmlSlice = truncateText(html, maxChars);

        result.html = htmlSlice.text;
        result.truncated = htmlSlice.truncated;
        result.originalChars = htmlSlice.originalChars;
      }

      if (includeText) {
        const pageText = await page.evaluate(() => {
          const doc = (globalThis as any).document;
          const body = doc?.body;
          const value = body?.innerText ?? body?.textContent ?? '';
          return typeof value === 'string' ? value : String(value);
        });

        const textSlice = truncateText(normalizeWhitespace(pageText), textMaxChars);
        result.text = textSlice.text;
        result.textTruncated = textSlice.truncated;
        result.originalTextChars = textSlice.originalChars;
      }

      return result;
    }
    case 'browser.snapshot': {
      const maxChars = normalizePositiveInt(a.maxChars, 12_000);
      const maxNodes = normalizePositiveInt(a.maxNodes, 350);
      const includeText = a.includeText !== false;
      const interactiveOnly = a.interactiveOnly === true;
      const selector =
        typeof a.selector === 'string' && a.selector.trim() !== '' ? a.selector.trim() : undefined;

      const data = await page.evaluate(
        (input: {
          maxNodes: number;
          includeText: boolean;
          interactiveOnly: boolean;
          selector?: string;
        }) => {
          const doc = (globalThis as any).document;
          const win = (globalThis as any).window;

          if (!doc || !win) {
            return { title: '', url: '', lines: [], totalNodes: 0 };
          }

          const root =
            (input.selector ? doc.querySelector(input.selector) : null) ||
            doc.body ||
            doc.documentElement;

          if (!root) {
            return { title: doc.title ?? '', url: String(win.location?.href ?? ''), lines: [], totalNodes: 0 };
          }

          const normalize = (value: unknown, limit: number) => {
            const raw = typeof value === 'string' ? value : String(value ?? '');
            const compact = raw.replace(/\s+/g, ' ').trim();
            if (compact.length <= limit) return compact;
            return `${compact.slice(0, limit)}...`;
          };

          const isVisible = (el: any) => {
            if (!el || typeof el !== 'object') return false;
            const style = win.getComputedStyle ? win.getComputedStyle(el) : null;
            if (style && (style.display === 'none' || style.visibility === 'hidden')) return false;
            if (style && Number(style.opacity ?? '1') === 0) return false;

            const rect = el.getBoundingClientRect ? el.getBoundingClientRect() : null;
            if (!rect) return false;
            return rect.width > 0 && rect.height > 0;
          };

          const implicitRole = (tag: string, typeAttr: string) => {
            if (tag === 'a') return 'link';
            if (tag === 'button') return 'button';
            if (tag === 'select') return 'combobox';
            if (tag === 'textarea') return 'textbox';
            if (tag === 'summary') return 'button';
            if (tag === 'input') {
              if (typeAttr === 'submit' || typeAttr === 'button' || typeAttr === 'reset') {
                return 'button';
              }
              if (typeAttr === 'checkbox') return 'checkbox';
              if (typeAttr === 'radio') return 'radio';
              return 'textbox';
            }
            return '';
          };

          const isInteractive = (el: any, role: string, tag: string) => {
            if (el?.disabled === true) return false;
            if (typeof role === 'string' && role !== '') {
              if (
                ['button', 'link', 'textbox', 'combobox', 'checkbox', 'radio', 'tab', 'menuitem'].includes(role)
              ) {
                return true;
              }
            }
            if (['button', 'a', 'input', 'select', 'textarea', 'summary', 'label'].includes(tag)) {
              return true;
            }
            if (typeof el?.onclick === 'function') return true;
            if (el?.hasAttribute?.('contenteditable')) return true;
            const tabIndex = Number(el?.getAttribute?.('tabindex') ?? NaN);
            return Number.isFinite(tabIndex) && tabIndex >= 0;
          };

          const lines: string[] = [];
          const queue: any[] = [root];
          let totalNodes = 0;

          while (queue.length > 0 && totalNodes < input.maxNodes) {
            const el = queue.shift();
            if (!el || typeof el.tagName !== 'string') {
              continue;
            }

            const children = Array.from(el.children ?? []);
            for (const child of children) {
              queue.push(child);
            }

            totalNodes += 1;
            if (!isVisible(el)) continue;

            const tag = String(el.tagName || '').toLowerCase();
            if (!tag) continue;

            const roleAttr = normalize(el.getAttribute?.('role') ?? '', 40);
            const typeAttr = normalize(el.getAttribute?.('type') ?? '', 30).toLowerCase();
            const role = roleAttr || implicitRole(tag, typeAttr);
            const interactive = isInteractive(el, role, tag);

            if (input.interactiveOnly && !interactive) {
              continue;
            }

            const nameCandidate =
              el.getAttribute?.('aria-label') ??
              el.getAttribute?.('aria-labelledby') ??
              el.getAttribute?.('placeholder') ??
              el.getAttribute?.('alt') ??
              el.getAttribute?.('title') ??
              el.textContent ??
              '';

            const name = normalize(nameCandidate, 100);
            const text = input.includeText ? normalize(el.textContent ?? '', 120) : '';

            const attrs: string[] = [];
            if (interactive) attrs.push('interactive');
            if (role) attrs.push(`role=${role}`);
            if (el.id) attrs.push(`id=${normalize(el.id, 40)}`);

            const lineParts = [`[${lines.length + 1}] <${tag}>`];
            if (name) lineParts.push(`"${name}"`);
            if (attrs.length > 0) lineParts.push(`(${attrs.join(', ')})`);
            if (input.includeText && text && text !== name) lineParts.push(`- ${text}`);

            lines.push(lineParts.join(' '));
          }

          return {
            title: String(doc.title ?? ''),
            url: String(win.location?.href ?? ''),
            lines,
            totalNodes,
          };
        },
        { maxNodes, includeText, interactiveOnly, selector },
      );

      const header = [
        `URL: ${data.url || page.url()}`,
        data.title ? `Title: ${data.title}` : null,
        `Mode: dom-snapshot`,
      ]
        .filter(Boolean)
        .join('\n');

      const body = Array.isArray(data.lines) ? data.lines.join('\n') : '';
      const combined = [header, body].filter(Boolean).join('\n\n');
      const snapshotSlice = truncateText(combined, maxChars);

      return {
        mode: 'dom-snapshot',
        url: data.url || page.url(),
        title: data.title || (await page.title().catch(() => null)),
        snapshot: snapshotSlice.text,
        truncated: snapshotSlice.truncated,
        originalChars: snapshotSlice.originalChars,
        displayedNodes: Array.isArray(data.lines) ? data.lines.length : 0,
        totalNodes: Number(data.totalNodes ?? 0) || 0,
      };
    }
    case 'browser.getCookies': {
      const ctx = page.context();
      const url = a.url != null ? String(a.url) : undefined;
      const cookies = await ctx.cookies(url ? [url] : undefined);
      return { cookies };
    }
    case 'browser.setCookies': {
      const ctx = page.context();
      const cookies = Array.isArray(a.cookies) ? a.cookies : null;
      if (!cookies) throw new Error('setCookies requires args.cookies[]');
      await ctx.addCookies(cookies);
      return { set: cookies.length };
    }
    case 'browser.clearState': {
      const clearCookies = a.clearCookies !== false;
      const clearStorage = a.clearStorage !== false;
      const clearEvents = a.clearEvents !== false;
      const result: Record<string, unknown> = {
        cookiesCleared: false,
        storageCleared: false,
        eventsCleared: false,
        url: page.url(),
      };

      if (clearCookies) {
        await page.context().clearCookies();
        result.cookiesCleared = true;
      }

      if (clearStorage) {
        try {
          await page.evaluate(() => {
            const win = globalThis as any;
            win.localStorage?.clear?.();
            win.sessionStorage?.clear?.();
          });
          result.storageCleared = true;
        } catch (err) {
          result.storageError = err instanceof Error ? err.message : String(err);
        }
      }

      if (clearEvents) {
        eventBuffer.events.length = 0;
        result.eventsCleared = true;
      }

      return result;
    }
    default:
      throw new Error(`Unsupported browser method: ${m}`);
  }
}

type BufferedBrowserEvent = Record<string, unknown> & {
  type: string;
  timestamp: string;
};

type BrowserEventBuffer = {
  events: BufferedBrowserEvent[];
};

const MAX_BROWSER_EVENTS = 100;
const browserEventBuffers = new WeakMap<Page, BrowserEventBuffer>();

function ensureEventBuffer(page: Page): BrowserEventBuffer {
  const existing = browserEventBuffers.get(page);
  if (existing) return existing;

  const buffer: BrowserEventBuffer = { events: [] };
  browserEventBuffers.set(page, buffer);

  const target = page as any;
  if (typeof target.on !== 'function') return buffer;

  target.on('console', (message: ConsoleMessage) => {
    pushBrowserEvent(buffer, {
      type: 'console',
      level: safeCall(() => message.type(), 'log'),
      text: safeCall(() => message.text(), ''),
      location: safeCall(() => message.location(), null),
    });
  });

  target.on('dialog', (dialog: Dialog) => {
    pushBrowserEvent(buffer, {
      type: 'dialog',
      dialogType: safeCall(() => dialog.type(), ''),
      message: safeCall(() => dialog.message(), ''),
      defaultValue: safeCall(() => dialog.defaultValue(), ''),
    });

    void dialog.dismiss().catch(() => undefined);
  });

  target.on('pageerror', (error: Error) => {
    pushBrowserEvent(buffer, {
      type: 'pageerror',
      name: error?.name ?? 'Error',
      message: error?.message ?? String(error),
      stack: error?.stack ?? null,
    });
  });

  target.on('requestfailed', (request: any) => {
    pushBrowserEvent(buffer, {
      type: 'requestfailed',
      url: safeCall(() => request.url(), ''),
      method: safeCall(() => request.method(), ''),
      errorText: safeCall(() => request.failure()?.errorText ?? '', ''),
    });
  });

  return buffer;
}

function pushBrowserEvent(
  buffer: BrowserEventBuffer,
  event: Record<string, unknown> & { type: string },
): void {
  buffer.events.push({
    ...event,
    timestamp: new Date().toISOString(),
  });

  if (buffer.events.length > MAX_BROWSER_EVENTS) {
    buffer.events.splice(0, buffer.events.length - MAX_BROWSER_EVENTS);
  }
}

function safeCall<T>(fn: () => T, fallback: T): T {
  try {
    return fn();
  } catch {
    return fallback;
  }
}

function normalizeTimeout(v: any): number | undefined {
  if (v == null) return undefined;
  const n = Number(v);
  if (!Number.isFinite(n) || n < 0) return undefined;
  return n;
}

function normalizeDelay(v: any): number | undefined {
  if (v == null) return undefined;
  const n = Number(v);
  if (!Number.isFinite(n) || n < 0) return undefined;
  return n;
}

async function uniqueDownloadPath(dir: string, suggestedFilename: string): Promise<string> {
  const name = sanitizeDownloadFilename(suggestedFilename || 'download');
  const parsed = path.parse(name);
  const root = parsed.name || 'download';
  const ext = parsed.ext || '';

  for (let index = 0; index < 1000; index += 1) {
    const suffix = index === 0 ? '' : `-${index}`;
    const candidate = path.join(dir, `${root}${suffix}${ext}`);

    try {
      await fs.access(candidate);
    } catch {
      return candidate;
    }
  }

  return path.join(dir, `${root}-${Date.now()}${ext}`);
}

function sanitizeDownloadFilename(value: string): string {
  const basename = path.basename(value || 'download');
  const safe = basename.replace(/[^\w.-]+/g, '_').replace(/^_+|_+$/g, '');
  return safe && safe !== '.' && safe !== '..' ? safe.slice(0, 160) : 'download';
}

function normalizeNumber(v: any, fallback: number): number {
  const n = Number(v);
  if (!Number.isFinite(n)) return fallback;
  return n;
}

function normalizePositiveInt(v: any, fallback: number): number {
  const n = Number(v);
  if (!Number.isFinite(n) || n <= 0) return fallback;
  return Math.floor(n);
}

function truncateText(text: string, maxChars: number): {
  text: string;
  truncated: boolean;
  originalChars: number;
} {
  const originalChars = text.length;
  if (maxChars > 0 && originalChars > maxChars) {
    return {
      text: `${text.slice(0, maxChars)}...`,
      truncated: true,
      originalChars,
    };
  }
  return { text, truncated: false, originalChars };
}

function normalizeWhitespace(text: string): string {
  return text.replace(/\s+/g, ' ').trim();
}

function stripNoisyHtml(html: string): string {
  return html
    .replace(/<script[\s\S]*?<\/script>/gi, '')
    .replace(/<style[\s\S]*?<\/style>/gi, '')
    .replace(/<noscript[\s\S]*?<\/noscript>/gi, '')
    .replace(/<template[\s\S]*?<\/template>/gi, '')
    .replace(/<!--[\s\S]*?-->/g, '')
    .trim();
}
