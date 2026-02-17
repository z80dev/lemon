import type { Page } from 'playwright-core';

export async function handleBrowserMethod(page: Page, method: string, args: any): Promise<unknown> {
  const m = method.startsWith('browser.') ? method : `browser.${method}`;
  const a = args ?? {};

  switch (m) {
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
    default:
      throw new Error(`Unsupported browser method: ${m}`);
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
