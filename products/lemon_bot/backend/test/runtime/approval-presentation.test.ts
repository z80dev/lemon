import { describe, expect, test } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import { createRuntimeService, executionApprovalPresentation, type RuntimeMapping } from '../../src/runtime/runs';
import { fixture } from './fixture';
import { safeSummary } from '../../src/integrations/common';

describe('runtime approval headlines', () => {
  test('commands retain line breaks and tabs while exposing preview truncation', () => {
    expect(executionApprovalPresentation('bash', { command: 'hostname' })).toEqual({ title: 'hostname', titleTruncated: false, hasControls: false, target: 'Terminal', toolGroup: 'terminal' });
    expect(executionApprovalPresentation('shell', { command: 'pwd\n\thostname' })).toMatchObject({ title: 'pwd\n\thostname', titleTruncated: false, hasControls: false });
    const command = 'echo safe; '.repeat(30) + 'rm -rf /important';
    const proposal = executionApprovalPresentation('bash', { command });
    expect(proposal.title).toBe(command.slice(0, 159) + '…');
    expect(proposal.titleTruncated).toBe(true);
    expect(proposal.title).not.toContain('rm -rf /important');
  });
  test('preview bounds count Unicode code points without splitting them', () => {
    expect(executionApprovalPresentation('bash', { command: '😀'.repeat(160) })).toMatchObject({ title: '😀'.repeat(160), titleTruncated: false });
    expect(executionApprovalPresentation('bash', { command: '😀'.repeat(161) })).toMatchObject({ title: '😀'.repeat(159) + '…', titleTruncated: true });
  });
  test('format, invisible and non-line-break controls are visibly escaped', () => {
    const command = 'a\u202Eb\u200Bc\u00ADd\u034Fe\uFE0Ff\u0000g\u001Bh\u007Fi\u0085j\u2028k\u2029l\rm\n\tn';
    expect(executionApprovalPresentation('bash', { command })).toMatchObject({
      title: 'a⟨U+202E⟩b⟨U+200B⟩c⟨U+00AD⟩d⟨U+034F⟩e⟨U+FE0F⟩f⟨U+0000⟩g⟨U+001B⟩h⟨U+007F⟩i⟨U+0085⟩j⟨U+2028⟩k⟨U+2029⟩l⟨U+000D⟩m\n\tn',
      titleTruncated: false, hasControls: true,
    });
    expect(executionApprovalPresentation('bash', { command: 'x'.repeat(200) + '\u202E' })).toMatchObject({ titleTruncated: true, hasControls: true });
  });
  test('file actions retain the proposed path', () => {
    expect(executionApprovalPresentation('read', { path: '/tmp/report.txt' })).toEqual({ title: 'read /tmp/report.txt', titleTruncated: false, hasControls: false, target: 'Files', toolGroup: 'file_reading' });
    expect(executionApprovalPresentation('write', { destination: '/tmp/report.txt' }).title).toBe('write /tmp/report.txt');
  });
  test('browser proposals use only the host, not credentials, query or fragment', () => {
    expect(executionApprovalPresentation('browser', { operation: 'Navigate', url: 'https://user:private@example.com/path?token=secret#private' })).toEqual({ title: 'Navigate example.com', titleTruncated: false, hasControls: false, target: 'Browser', toolGroup: null });
  });
  test('unknown tools fall back to their display name, never arbitrary fields', () => {
    expect(executionApprovalPresentation('custom_tool', { password: 'private', body: 'private', command: 'ignored' })).toEqual({ title: 'custom_tool', titleTruncated: false, hasControls: false, target: 'custom_tool', toolGroup: null });
  });
  test('credential-bearing text is redacted before truncation', () => {
    const proposal = executionApprovalPresentation('bash', { command: 'curl -H Bearer private token=hidden password=secret api_key=credential', password: 'omitted' });
    for (const secret of ['private', 'hidden', 'secret', 'credential', 'omitted']) expect(proposal.title).not.toContain(secret);
    expect(proposal.title).toContain('[redacted]');
    expect(executionApprovalPresentation('read', { path: '/tmp/token=hidden' }).title).not.toContain('hidden');
    const multiline = executionApprovalPresentation('bash', { command: 'echo start\nBearer\n\tprivate\ntoken=\n\thidden\nhttps://example.com/private\nrm -rf /important' });
    expect(multiline.title).toBe('echo start\n[redacted]\n\t\n[redacted]\n\t\n[provider URL]\nrm -rf /important');
    expect(multiline.titleTruncated).toBe(false);
    expect(safeSummary('Bearer\n\tprivate token=\n\thidden')).toBe('[redacted] [redacted]');
    expect(safeSummary('Bearer\n\tprivate token=\n\thidden', 4096, { preserveLayout: true })).toBe('[redacted]\n\t [redacted]\n\t');
  });
  test('auxiliary terminal and rewriting tools use their exact approval groups', () => {
    for (const tool of ['bash_output', 'kill_process']) expect(executionApprovalPresentation(tool, {}).toolGroup).toBe('terminal');
    for (const tool of ['ast_grep', 'checkpoint']) expect(executionApprovalPresentation(tool, {}).toolGroup).toBe('file_changes');
    expect(executionApprovalPresentation('browser_click', {}).toolGroup).toBeNull();
  });
});

async function projectApproval(action: P.JSONObject, tool = 'bash') {
  const f = fixture();
  const runtime = createRuntimeService(f.services); f.services.runtime = runtime;
  const cards: { title: string; inputs: P.JSONObject }[] = [];
  f.services.gates.create = async <T>(_actor: unknown, _kind: unknown, input: unknown) => { cards.push(input as typeof cards[number]); return { id: `card_${cards.length}` } as T; };
  const rpc = f.rpc;
  f.rpc = async (method, params) => method === 'exec.approval.resolve' ? { resolved: true, approvalId: params.approvalId, decision: params.decision, sessionKey: params.expectedSessionKey, runId: params.expectedRunId, approved: false, outcome: 'denied' } : rpc(method, params);
  try {
    const { run } = await runtime.submit(f.alice, f.conversation, f.bot, { clientNonce: 'approval_presentation_001', text: 'work' });
    const bound = f.store.metadata<RuntimeMapping>(`runtimeRun:${run.id}`)!;
    await runtime.project('exec.approval.requested', { approvalId: 'presentation_approval', runId: bound.executionRunId, sessionKey: bound.sessionKey, tool, action, expiresAtMs: f.services.now() + 60_000 });
    return { cards, calls: f.calls, status: f.store.require<P.Run>('runs', run.id).status };
  } finally { runtime.close(); f.store.close(); }
}

describe('runtime approval input projection', () => {
  test('redaction expansion never hides the tail of an accepted 4096-character command', async () => {
    const tail = '\nrm -rf /important';
    const command = ('token=x '.repeat(500) + 'echo ready').padEnd(4096 - tail.length, ' ') + tail;
    const action = { command, password: 'private', body: 'omitted' };
    const original = { ...action };
    const { cards, calls } = await projectApproval(action);
    expect(cards).toHaveLength(1);
    expect(cards[0]!.inputs.command).toBe(command.replaceAll('token=x', '[redacted]'));
    expect((cards[0]!.inputs.command as string).length).toBeGreaterThan(4096);
    expect((cards[0]!.inputs.command as string).endsWith(tail)).toBe(true);
    expect(cards[0]!.inputs).toMatchObject({ redacted: true, omittedInputFields: 2 });
    expect(cards[0]!.inputs).not.toHaveProperty('password');
    expect(cards[0]!.title.endsWith('…')).toBe(true);
    expect(executionApprovalPresentation('bash', cards[0]!.inputs).titleTruncated).toBe(true);
    expect(action).toEqual(original);
    expect(calls.filter(call => call.method === 'exec.approval.resolve')).toHaveLength(0);
  });
  test('line breaks and controls stay in proposal inputs without mutating executable arguments', async () => {
    const action = { command: 'echo safe\n\tprintf "\u202E\u200B"\nrm -rf /important', path: '/tmp/review.txt' };
    const original = { ...action };
    const { cards } = await projectApproval(action);
    expect(cards).toHaveLength(1);
    expect(cards[0]!.inputs).toMatchObject({ command: action.command, path: action.path, redacted: false });
    expect(cards[0]!.title).toBe('echo safe\n\tprintf "⟨U+202E⟩⟨U+200B⟩"\nrm -rf /important');
    expect(executionApprovalPresentation('bash', cards[0]!.inputs).hasControls).toBe(true);
    expect(action).toEqual(original);
  });
  test('credential redaction retains line and tab boundaries in the displayed command', async () => {
    const command = 'echo start\nBearer\n\tprivate\ntoken=\n\thidden\nhttps://example.com/private\nrm -rf /important';
    const action = { command };
    const { cards } = await projectApproval(action);
    expect(cards).toHaveLength(1);
    expect(cards[0]!.inputs.command).toBe('echo start\n[redacted]\n\t\n[redacted]\n\t\n[provider URL]\nrm -rf /important');
    expect(cards[0]!.inputs.redacted).toBe(true);
    expect(action.command).toBe(command);
  });
  test('Terminal proposals without an inspectable command cannot borrow a concrete path or URL', async () => {
    for (const tool of ['bash', 'shell', 'exec', 'terminal', 'bash_output', 'kill_process']) {
      for (const command of [undefined, 'x'.repeat(4097), 'password=private', 'password=\n\tprivate']) {
        const action: P.JSONObject = { path: '/tmp/review.txt', destination: '/tmp/output.txt', url: 'https://example.com' };
        if (command !== undefined) action.command = command;
        const original = { ...action };
        const { cards, calls, status } = await projectApproval(action, tool);
        expect(cards).toHaveLength(0);
        expect(calls.filter(call => call.method === 'exec.approval.resolve')).toMatchObject([{ params: { decision: 'deny' } }]);
        expect(status).not.toBe('awaiting_input');
        expect(action).toEqual(original);
      }
    }
  });
  test('file approvals remain actionable from their concrete path without a command', async () => {
    const { cards } = await projectApproval({ path: '/tmp/review.txt' }, 'read');
    expect(cards).toHaveLength(1);
    expect(cards[0]!.title).toBe('read /tmp/review.txt');
  });
});
