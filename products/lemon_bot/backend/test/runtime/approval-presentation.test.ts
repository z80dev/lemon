import { describe, expect, test } from 'bun:test';
import { executionApprovalPresentation } from '../../src/runtime/runs';

describe('runtime approval headlines', () => {
  test('commands remain concrete, single-line and bounded', () => {
    expect(executionApprovalPresentation('bash', { command: 'hostname' })).toEqual({ title: 'hostname', target: 'Terminal' });
    expect(executionApprovalPresentation('shell', { command: 'pwd\n  hostname' }).title).toBe('pwd hostname');
    const title = executionApprovalPresentation('bash', { command: 'x'.repeat(300) }).title;
    expect(title.length).toBe(160);
    expect(title.endsWith('…')).toBe(true);
  });
  test('file actions retain the proposed path', () => {
    expect(executionApprovalPresentation('read', { path: '/tmp/report.txt' })).toEqual({ title: 'read /tmp/report.txt', target: 'Files' });
    expect(executionApprovalPresentation('write', { destination: '/tmp/report.txt' }).title).toBe('write /tmp/report.txt');
  });
  test('browser proposals use only the host, not credentials, query or fragment', () => {
    expect(executionApprovalPresentation('browser', { operation: 'Navigate', url: 'https://user:private@example.com/path?token=secret#private' })).toEqual({ title: 'Navigate example.com', target: 'Browser' });
  });
  test('unknown tools fall back to their display name, never arbitrary fields', () => {
    expect(executionApprovalPresentation('custom_tool', { password: 'private', body: 'private', command: 'ignored' })).toEqual({ title: 'custom_tool', target: 'custom_tool' });
  });
  test('credential-bearing text is redacted before truncation', () => {
    const proposal = executionApprovalPresentation('bash', { command: 'curl -H Bearer private token=hidden password=secret api_key=credential', password: 'omitted' });
    for (const secret of ['private', 'hidden', 'secret', 'credential', 'omitted']) expect(proposal.title).not.toContain(secret);
    expect(proposal.title).toContain('[redacted]');
    expect(executionApprovalPresentation('read', { path: '/tmp/token=hidden' }).title).not.toContain('hidden');
  });
});
