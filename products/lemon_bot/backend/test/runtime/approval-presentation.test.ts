import { describe, expect, test } from 'bun:test';
import { executionApprovalPresentation } from '../../src/runtime/runs';

describe('runtime approval headlines', () => {
  test('commands remain concrete, single-line and bounded', () => {
    expect(executionApprovalPresentation('bash', { command: 'hostname' })).toEqual({ title: 'hostname', target: 'Terminal', toolGroup: 'terminal' });
    expect(executionApprovalPresentation('shell', { command: 'pwd\n  hostname' }).title).toBe('pwd hostname');
    const title = executionApprovalPresentation('bash', { command: 'x'.repeat(300) }).title;
    expect(title.length).toBe(160);
    expect(title.endsWith('…')).toBe(true);
  });
  test('file actions retain the proposed path', () => {
    expect(executionApprovalPresentation('read', { path: '/tmp/report.txt' })).toEqual({ title: 'read /tmp/report.txt', target: 'Files', toolGroup: 'file_reading' });
    expect(executionApprovalPresentation('write', { destination: '/tmp/report.txt' }).title).toBe('write /tmp/report.txt');
  });
  test('browser proposals use only the host, not credentials, query or fragment', () => {
    expect(executionApprovalPresentation('browser', { operation: 'Navigate', url: 'https://user:private@example.com/path?token=secret#private' })).toEqual({ title: 'Navigate example.com', target: 'Browser', toolGroup: null });
  });
  test('unknown tools fall back to their display name, never arbitrary fields', () => {
    expect(executionApprovalPresentation('custom_tool', { password: 'private', body: 'private', command: 'ignored' })).toEqual({ title: 'custom_tool', target: 'custom_tool', toolGroup: null });
  });
  test('credential-bearing text is redacted before truncation', () => {
    const proposal = executionApprovalPresentation('bash', { command: 'curl -H Bearer private token=hidden password=secret api_key=credential', password: 'omitted' });
    for (const secret of ['private', 'hidden', 'secret', 'credential', 'omitted']) expect(proposal.title).not.toContain(secret);
    expect(proposal.title).toContain('[redacted]');
    expect(executionApprovalPresentation('read', { path: '/tmp/token=hidden' }).title).not.toContain('hidden');
  });
  test('auxiliary terminal and rewriting tools use their exact approval groups', () => {
    for (const tool of ['bash_output', 'kill_process']) expect(executionApprovalPresentation(tool, {}).toolGroup).toBe('terminal');
    for (const tool of ['ast_grep', 'checkpoint']) expect(executionApprovalPresentation(tool, {}).toolGroup).toBe('file_changes');
    expect(executionApprovalPresentation('browser_click', {}).toolGroup).toBeNull();
  });
});
