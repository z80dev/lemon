import { handleBrowserMethod } from './browser-methods.js';
import { blockedDestination } from './destination-guard.js';
import type { ChromeSession } from './chrome.js';

// Raw CDP is limited to read-only methods that cannot start network traffic
// (no navigation, script evaluation, target creation, fetch interception,
// emulation or input). Everything else is refused.
const ALLOWED_CDP_METHODS: Record<string, true> = {
  'Accessibility.getFullAXTree': true,
  'Accessibility.getPartialAXTree': true,
  'Browser.getVersion': true,
  'DOM.describeNode': true,
  'DOM.getBoxModel': true,
  'DOM.getDocument': true,
  'DOM.getOuterHTML': true,
  'DOM.querySelector': true,
  'DOM.querySelectorAll': true,
  'DOMSnapshot.captureSnapshot': true,
  'Page.getFrameTree': true,
  'Page.getLayoutMetrics': true,
  'Page.getNavigationHistory': true,
  'Performance.getMetrics': true,
  'Target.getTargets': true,
};

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
    case 'browser.tabOpen': {
      const url = optionalString(input.url) ?? 'about:blank';
      const reason = await blockedDestination(url);
      if (reason) throw new Error(`browser navigation blocked ${reason}`);
      return chrome.openTab(url);
    }
    case 'browser.tabActivate':
      return chrome.activateTab(requiredTargetId(input));
    case 'browser.tabClose':
      return chrome.closeTab(requiredTargetId(input));
    case 'browser.cdp': {
      const command = optionalString(input.method);
      if (!command) throw new Error('CDP method is required');
      if (!Object.hasOwn(ALLOWED_CDP_METHODS, command)) {
        throw new Error(`CDP method ${command} is not allowed: raw CDP is limited to read-only, non-network methods`);
      }
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
