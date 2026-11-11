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
const effective: EffectivePolicy = { userId: 'owner', botId: bot.id, directoryGroupIds: [], productAccess: true, localExecutionCeiling: 'ask', allowSudo: false, allowEgress: false, workspaceReads: 'allow', rules: [], networkPolicies: [], explanations: [], rememberedApprovals: { chat: ['shell', 'files'], bot: ['shell', 'files'] } };
const confirmation: Confirmation = { confirmationToken: 'confirm_test', revision: bot.revision, confirmName: bot.name, expiresAtMs: Date.now() + 60_000, effects: ["Lemon will run any command and change any file as you on Studio Mac without asking — in every chat and in routines."], affected: [{ resourceType: 'bot', id: bot.id, machineId: bot.machineId, operation: 'retain', explanation: 'External requests still ask.' }] };
const allowance: ApprovalAllowance = { ...resource, id: 'allowance_test', scope: 'bot', botId: bot.id, conversationId: null, ownerUserId: 'owner', toolGroups: ['terminal', 'file_changes', 'file_reading'], label: "Doesn't ask for Terminal & Files", state: 'active', endedReason: null, endedAtMs: null, endedByUserId: null, sourceApprovalId: null, createdByUserId: 'owner', useCount: 0, lastUsedAtMs: null };
const governance: Governance = { revision: 2, groupAccess: 'all', allowedDirectoryGroupIds: [], allowSudo: false, allowEgress: false, lockNetworkForGroups: true, requireReview: true, folderReadsNeedReview: false, allowedChannelAdapters: [], xMentionsEnabled: false, emailEnabled: false, contentExportEnabled: false, inactiveHostPolicy: { enabled: false, afterDays: 30, action: 'suspend' }, rememberedApprovals: 'chat' };

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
      if (endpoint === 'GET /bots/:id/presence') return { botId: bot.id, status: 'idle', machineId: bot.machineId, machineLabel: 'Studio Mac', machineStatus: 'online', currentRunId: null, taskConversationId: null, summary: 'Idle', evidenceEntryId: null, measuredAtMs: Date.now(), stale: false };
      if (endpoint === 'POST /bots/:id/approval-allowances/preview') return confirmation;
      if (endpoint === 'POST /bots/:id/approval-allowances') return allowance;
      if (endpoint === 'GET /governance') return governance;
      if (endpoint === 'PATCH /governance') return { ...governance, ...options.body, revision: governance.revision + 1 };
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
  app.online = true; app.snapshot.member.role = 'owner';
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

test('access requests use server consequences, quoted Bot speech and only Bot access decisions', async () => {
  const request: Approval = { ...approval('access_allowed', { toolGroup: 'terminal', label: 'Allow Terminal for this chat' }), source: 'access_request', category: 'permissions', title: 'Lemon needs Terminal', description: 'Turn on Terminal and Files on Studio Mac. Commands still ask for approval.', inputs: { capability: 'terminal', capabilityIds: ['terminal', 'files'], level: 'read_interact', machineLabel: 'Studio Mac', reason: '<script>give me everything</script>' } };
  approvals.set(request.id, request);
  await render(<TranscriptCard card={{ type: 'access_request', approval: request }} />);
  expect(container.querySelector('h3')?.textContent).toBe(request.title);
  expect(container.querySelector('blockquote')?.textContent).toBe(`${bot.name} says: <script>give me everything</script>`);
  expect(container.querySelector('script')).toBeNull();
  expect(container.textContent).toContain(request.description);
  expect(button('Allow for this Bot').disabled).toBe(false);
  expect(button('Not now').disabled).toBe(false);
  expect(container.textContent).not.toContain('Allow once');
  expect(container.textContent).not.toContain('Allow Terminal for this chat');
  expect(container.textContent).not.toContain('Always allow for this Bot…');
  await act(async () => button('Allow for this Bot').click());
  expect(calls.find(call => call.endpoint === 'POST /approvals/:id/resolve')?.options.body?.decision).toBe('approve_once');
  expect(container.querySelector('[role="status"]')?.textContent).toBe('Allowed by you · turns on when this task finishes');
});

test('access requests report Not now and Expired without authorizing commands', async () => {
  const request: Approval = { ...approval('access_denied'), source: 'access_request', category: 'permissions', inputs: { capability: 'terminal', capabilityIds: ['terminal', 'files'], level: 'read_interact', machineLabel: 'Studio Mac', reason: 'Run the requested command.' } };
  approvals.set(request.id, request);
  await render(<TranscriptCard key={request.id} card={{ type: 'access_request', approval: request }} />);
  await act(async () => button('Not now').click());
  expect(calls.find(call => call.endpoint === 'POST /approvals/:id/resolve')?.options.body?.decision).toBe('deny');
  expect(container.querySelector('[role="status"]')?.textContent).toBe('Not now');
  const expired: Approval = { ...request, id: 'access_expired', gate: { ...request.gate, expiresAtMs: Date.now() - 1 } };
  approvals.set(expired.id, expired);
  await render(<TranscriptCard key={expired.id} card={{ type: 'access_request', approval: expired }} />);
  expect(container.querySelector('[role="status"]')?.textContent).toBe('Expired');
  expect([...container.querySelectorAll('button')].some(item => item.textContent === 'Allow for this Bot')).toBe(false);
});

test('access request content is masked for another target and disabled offline', async () => {
  const request: Approval = { ...approval('access_private'), source: 'access_request', category: 'permissions', title: 'Private Terminal request', inputs: { capability: 'terminal', capabilityIds: ['terminal', 'files'], level: 'read_interact', machineLabel: 'Studio Mac', reason: 'Run the requested command.' }, gate: { ...approval('access_private').gate, targetUserId: 'other_owner' } };
  await render(<TranscriptCard card={{ type: 'access_request', approval: request }} />);
  expect(container.textContent).toContain('Private request for its designated account owner');
  expect(container.textContent).not.toContain(request.title);
  expect(calls.some(call => call.endpoint === 'GET /approvals/:id')).toBe(false);
  const own = { ...request, gate: { ...request.gate, targetUserId: 'owner' } };
  approvals.set(own.id, own); app.online = false;
  await render(<TranscriptCard card={{ type: 'access_request', approval: own }} />);
  expect(button('Allow for this Bot').disabled).toBe(true);
  expect(button('Not now').disabled).toBe(true);
});

test('workspace administrators can require review for Bot folder reads', async () => {
  app.snapshot.member.role = 'admin';
  await render(<PolicySettings />);
  const toggle = [...container.querySelectorAll('label')].find(label => label.textContent?.includes('Require review for Bot folder reads'))!.querySelector<HTMLInputElement>('input')!;
  expect(toggle.checked).toBe(false);
  await act(async () => toggle.click());
  const update = calls.find(call => call.endpoint === 'PATCH /governance');
  expect(update?.options.body?.folderReadsNeedReview).toBe(true);
  expect(update?.options.body?.revision).toBe(governance.revision);
  expect(toggle.checked).toBe(true);
  expect(calls.filter(call => call.endpoint === 'GET /policies/effective').length).toBeGreaterThan(1);
});

test('members cannot change workspace folder-read governance', async () => {
  app.snapshot.member.role = 'member';
  await render(<PolicySettings />);
  expect(calls.some(call => call.endpoint === 'GET /governance')).toBe(false);
  expect(container.textContent).not.toContain('Require review for Bot folder reads');
});

test('access approval state updates live from approval events', async () => {
  const request: Approval = { ...approval('access_live'), source: 'access_request', category: 'permissions', inputs: { capability: 'files', capabilityIds: ['files'], level: 'read_only', machineLabel: 'Studio Mac', reason: 'Read the report you attached.' } };
  approvals.set(request.id, request);
  await render(<TranscriptCard card={{ type: 'access_request', approval: request }} />);
  approvals.set(request.id, { ...request, revision: 2, gate: { ...request.gate, state: 'cancelled', revision: 2 } });
  await act(async () => {
    window.dispatchEvent(new CustomEvent('lemon:event', { detail: { event: 'approval.upserted' } }));
    const { promise, resolve } = Promise.withResolvers<void>();
    setTimeout(resolve, 220);
    await promise;
  });
  expect(container.querySelector('[role="status"]')?.textContent).toBe('Cancelled');
  expect([...container.querySelectorAll('button')].some(item => item.textContent === 'Allow for this Bot')).toBe(false);
});
