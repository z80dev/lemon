import { afterEach, beforeEach, expect, mock, test } from 'bun:test';
import { Window } from 'happy-dom';
import { act, type ReactNode } from 'react';
import type { Root } from 'react-dom/client';
import type { Approval, ApprovalAllowance, Bot, Confirmation, EffectivePolicy, Governance } from '@lemon-bot/sdk';
import type { AppContextValue, Route } from '../src/app';

const browser = new Window();
Object.assign(globalThis, { window: browser, document: browser.document, navigator: browser.navigator, Event: browser.Event, InputEvent: browser.InputEvent, HTMLElement: browser.HTMLElement, HTMLInputElement: browser.HTMLInputElement, CustomEvent: browser.CustomEvent, IS_REACT_ACT_ENVIRONMENT: true });
// React DOM performs browser feature detection at import time, after the Happy DOM globals exist.
const { createRoot } = await import('react-dom/client');

const resource = { revision: 1, createdAtMs: 1_800_000_000_000, updatedAtMs: 1_800_000_000_000 };
const bot: Bot = { ...resource, id: 'bot_test', ownerUserId: 'owner', machineId: 'machine_test', profileId: 'profile_test', name: 'Research partner', title: 'Research', job: 'Research carefully.', instructions: '', avatar: { kind: 'character', shape: 'round', color: 'yellow', attachmentId: null }, voice: { voiceId: 'default', speed: 1, language: null }, language: null, skillIds: [], referenceAttachmentIds: [], mainConversationId: 'conversation_test', sidebar: { sectionId: null, rank: 0, hidden: false, pinned: false, unread: false, notificationsEnabled: true }, activity: 'idle', activeRunIds: [], approvalReview: 'per_chat' };
const effective: EffectivePolicy = { userId: 'owner', botId: bot.id, directoryGroupIds: [], productAccess: true, localExecutionCeiling: 'ask', allowSudo: false, allowEgress: false, rules: [], networkPolicies: [], explanations: [], rememberedApprovals: { chat: ['shell', 'files'], bot: ['shell', 'files'] } };
const confirmation: Confirmation = { confirmationToken: 'confirm_test', revision: bot.revision, confirmName: bot.name, expiresAtMs: Date.now() + 60_000, effects: ["Lemon will run any command and change any file as you on Studio Mac without asking — in every chat and in routines."], affected: [{ resourceType: 'bot', id: bot.id, machineId: bot.machineId, operation: 'retain', explanation: 'External requests still ask.' }] };
const allowance: ApprovalAllowance = { ...resource, id: 'allowance_test', scope: 'bot', botId: bot.id, conversationId: null, ownerUserId: 'owner', toolGroups: ['terminal', 'file_changes', 'file_reading'], label: "Doesn't ask for Terminal & Files", state: 'active', endedReason: null, endedAtMs: null, endedByUserId: null, sourceApprovalId: null, createdByUserId: 'owner', useCount: 0, lastUsedAtMs: null };
const governance: Governance = { revision: 2, groupAccess: 'all', allowedDirectoryGroupIds: [], allowSudo: false, allowEgress: false, lockNetworkForGroups: true, requireReview: true, allowedChannelAdapters: [], xMentionsEnabled: false, emailEnabled: false, contentExportEnabled: false, inactiveHostPolicy: { enabled: false, afterDays: 30, action: 'suspend' }, rememberedApprovals: 'chat' };

interface TestCallOptions { params?: Record<string, string>; query?: unknown; body?: Record<string, unknown> }
const calls: { endpoint: string; options: TestCallOptions }[] = [];
const approvals = new Map<string, Approval>();
const navigations: Route[] = [];
const page = <T,>(items: T[]) => ({ items, nextCursor: null });
const app = {
  online: true,
  snapshot: {
    user: { id: 'owner', displayName: 'Owner' },
    member: { role: 'owner' },
    workspace: { id: 'workspace_test', ownerUserId: 'owner' },
    bots: [bot],
    machines: [{ ...resource, id: bot.machineId, nodeId: 'node_test', nodeName: 'studio', name: 'Studio Mac', ownerUserId: 'owner', accessUserIds: [], status: 'online', lastSeenAtMs: resource.updatedAtMs, labels: {}, botIds: [bot.id] }],
    capabilities: {},
  },
  client: {
    call: async (endpoint: string, options: TestCallOptions = {}) => {
      calls.push({ endpoint, options });
      if (endpoint === 'GET /approvals/:id') return approvals.get(options.params?.id ?? '')!;
      if (endpoint === 'POST /approvals/:id/resolve') {
        const current = approvals.get(options.params?.id ?? '')!;
        const decision = options.body?.decision;
        const resolved = { ...current, revision: current.revision + 1, resolvedScope: decision === 'approve_chat' ? 'chat' : 'once', gate: { ...current.gate, state: decision === 'deny' ? 'denied' : 'approved', resolvedAtMs: Date.now(), resolvedByUserId: 'owner', revision: current.gate.revision + 1 } } as Approval;
        approvals.set(resolved.id, resolved); return resolved;
      }
      if (endpoint === 'GET /policies/effective') return effective;
      if (endpoint === 'GET /skills' || endpoint === 'GET /attachments' || endpoint === 'GET /bots/:id/grants' || endpoint === 'GET /bots/:id/connectors' || endpoint === 'GET /bots/:id/approval-allowances' || endpoint === 'GET /approvals') return page([]);
      if (endpoint === 'GET /machines/:id/capabilities') return { machineId: bot.machineId, os: 'macOS', measuredAtMs: resource.updatedAtMs, stale: false, items: [] };
      if (endpoint === 'POST /bots/:id/approval-allowances/preview') return confirmation;
      if (endpoint === 'POST /bots/:id/approval-allowances') return allowance;
      if (endpoint === 'GET /governance') return governance;
      if (endpoint === 'PATCH /governance') return { ...governance, revision: governance.revision + 1, rememberedApprovals: options.body?.rememberedApprovals };
      if (endpoint === 'GET /policies') return { revision: 1, publicTemplates: false, allowedMcpOrigins: null, localExecutionCeiling: 'ask', actionRecording: false, auditRetentionDays: 30, rules: [] };
      throw new Error(`Unexpected test endpoint: ${endpoint}`);
    },
  },
  navigate: (route: Route) => { navigations.push(route); },
  refresh: async () => undefined,
  reportError: (error: unknown) => { throw error; },
  realtime: null,
} as unknown as AppContextValue;
function useApp() { return app; }
mock.module('../src/app', () => ({ useApp }));

// These imports must follow mock.module so the components bind to the in-memory App context.
const { TranscriptCard } = await import('../src/features/chat/cards');
const { SettingsPanel } = await import('../src/features/bots/settings');
const { PolicySettings } = await import('../src/features/settings/policies');

let container: HTMLDivElement;
let root: Root;
beforeEach(() => {
  calls.length = 0; approvals.clear(); navigations.length = 0;
  container = document.createElement('div'); document.body.append(container); root = createRoot(container);
});
afterEach(async () => {
  await act(async () => root.unmount());
  container.remove();
  mock.restore();
});
async function render(children: ReactNode) { await act(async () => root.render(children)); }
function button(text: string) {
  const found = [...container.querySelectorAll('button')].find(item => item.textContent === text);
  if (!found) throw new Error(`Button not found: ${text}`);
  return found;
}
function approval(id: string, chatOption: Approval['chatOption'] = undefined): Approval {
  return { ...resource, id, gate: { id: `gate_${id}`, state: 'pending', targetUserId: 'owner', expiresAtMs: Date.now() + 60_000, resolvedAtMs: null, resolvedByUserId: null, revision: 1 }, entryId: `entry_${id}`, conversationId: 'conversation_test', botId: bot.id, runId: 'run_test', source: 'lemon_exec', category: 'shell', title: 'hostname', description: 'Run hostname', target: 'Terminal', inputs: { command: 'hostname' }, policyMode: 'ask_first', review: 'ask', ruleId: null, scope: { kind: 'once', label: 'This command', machineId: bot.machineId, machineLabel: 'Studio Mac', botId: bot.id, runId: 'run_test', origin: 'owner_chat', connectorId: null, consequences: ['Runs a local command'], expiresAtMs: Date.now() + 60_000 }, chatOption, resolvedScope: null };
}

test('approval card renders the chat choice only when eligible and reports the remembered result', async () => {
  const absent = approval('approval_absent'); approvals.set(absent.id, absent);
  await render(<TranscriptCard key={absent.id} card={{ type: 'local_tool_permission', approval: absent }} />);
  expect(container.textContent).not.toContain('Allow Terminal for this chat');

  const ineligible = approval('approval_null', null); approvals.set(ineligible.id, ineligible);
  await render(<TranscriptCard key={ineligible.id} card={{ type: 'local_tool_permission', approval: ineligible }} />);
  expect(container.textContent).not.toContain('Allow Terminal for this chat');

  const eligible = approval('approval_eligible', { toolGroup: 'terminal', label: 'Allow Terminal for this chat' }); approvals.set(eligible.id, eligible);
  await render(<TranscriptCard key={eligible.id} card={{ type: 'local_tool_permission', approval: eligible }} />);
  expect(button('Allow Terminal for this chat').disabled).toBe(false);
  await act(async () => button('Allow Terminal for this chat').click());
  expect(calls.find(call => call.endpoint === 'POST /approvals/:id/resolve')?.options.body?.decision).toBe('approve_chat');
  expect(container.textContent).toContain('Allowed for this chat by you');
});

test('bot-wide review mode requires the server preview and typed-name confirmation', async () => {
  let reloads = 0;
  await render(<SettingsPanel bot={bot} reload={async () => { reloads++; }} />);
  const option = [...container.querySelectorAll('label')].find(label => label.textContent?.includes("Don't ask for Terminal & Files"))?.querySelector<HTMLInputElement>('input');
  if (!option) throw new Error('Bot-wide review option not found');
  await act(async () => { option.click(); await Promise.resolve(); await Promise.resolve(); });
  expect(calls.filter(call => call.endpoint === 'POST /bots/:id/approval-allowances/preview')).toHaveLength(1);
  expect(container.querySelector('[role="dialog"]')?.textContent).toContain(confirmation.effects[0]);

  const name = container.querySelector<HTMLInputElement>('[role="dialog"] input')!;
  await act(async () => {
    Object.getOwnPropertyDescriptor(browser.HTMLInputElement.prototype, 'value')!.set!.call(name, bot.name);
    name.dispatchEvent(new browser.InputEvent('input', { bubbles: true, inputType: 'insertText', data: bot.name }));
    name.dispatchEvent(new browser.Event('change', { bubbles: true }));
    await Promise.resolve();
  });
  const confirmButton = button('Confirm');
  if (confirmButton.disabled) throw new Error(`Confirm stayed disabled: value=${name.value}; online=${navigator.onLine}`);
  await act(async () => { confirmButton.click(); await Promise.resolve(); await Promise.resolve(); });
  const create = calls.find(call => call.endpoint === 'POST /bots/:id/approval-allowances');
  expect(create?.options.body?.confirmationToken).toBe(confirmation.confirmationToken);
  expect(create?.options.body?.confirmName).toBe(bot.name);
  expect(reloads).toBe(1);
});

test('workspace admins can expand remembered approval governance', async () => {
  await render(<PolicySettings />);
  const select = [...container.querySelectorAll('label')].find(label => label.textContent?.includes('Allowed scope'))?.querySelector<HTMLSelectElement>('select');
  if (!select) throw new Error('Remembered approvals select not found');
  await act(async () => { select.value = 'chat_and_bot'; select.dispatchEvent(new browser.Event('change', { bubbles: true })); });
  await act(async () => button('Save remembered approvals').click());
  const update = calls.find(call => call.endpoint === 'PATCH /governance');
  expect(update?.options.body?.rememberedApprovals).toBe('chat_and_bot');
  expect(update?.options.body?.revision).toBe(governance.revision);
});
