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
      const html = await page.content();
      return { html };
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

