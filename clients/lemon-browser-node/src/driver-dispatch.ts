import { handleBrowserMethod } from './browser-methods.js';
import type { ChromeSession } from './chrome.js';

/**
 * Route one Lemon browser protocol request. Tab lifecycle methods operate on
 * the Chrome session; page methods resolve the explicit target when supplied
 * and otherwise use the session's active target.
 */
export async function dispatchBrowserRequest(
  chrome: ChromeSession,
  method: string,
  args: unknown,
): Promise<unknown> {
  const normalizedMethod = method.startsWith('browser.') ? method : `browser.${method}`;
  const input = asArgs(args);

  switch (normalizedMethod) {
    case 'browser.tabs':
      return chrome.listTabs();
    case 'browser.tabOpen':
      return chrome.openTab(optionalString(input.url) ?? 'about:blank');
    case 'browser.tabActivate':
      return chrome.activateTab(requiredTargetId(input));
    case 'browser.tabClose':
      return chrome.closeTab(requiredTargetId(input));
    case 'browser.cdp': {
      const command = optionalString(input.method);
      if (!command) throw new Error('CDP method is required');
      return chrome.sendCdp(command, asArgs(input.params), optionalString(input.targetId) ?? undefined);
    }
    default: {
      const targetId = optionalString(input.targetId);
      const pageArgs = { ...input };
      delete pageArgs.targetId;
      return chrome.withPage(
        (page) => handleBrowserMethod(page, normalizedMethod, pageArgs),
        targetId ?? undefined,
      );
    }
  }
}

function asArgs(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return {};
  return value as Record<string, unknown>;
}

function requiredTargetId(args: Record<string, unknown>): string {
  const targetId = optionalString(args.targetId);
  if (!targetId) throw new Error('targetId is required');
  return targetId;
}

function optionalString(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const normalized = value.trim();
  return normalized === '' ? null : normalized;
}
