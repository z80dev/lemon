import { expect, test } from 'bun:test';
import type { BotGrant, MachineCapability } from '@lemon-bot/sdk';
import { grantControlReason, grantGroup, grantName, grantStatus } from '../src/features/bots/grant-presentation';

const capability: MachineCapability = { id: 'terminal', name: 'Measured terminal', category: 'shell', supported: true, configuredLevel: 'read_interact', osGrant: 'not_required', tools: ['bash'], reason: 'destination_shell_measured', measuredAtMs: 1, stale: false };
const grant: BotGrant = { id: 'grant', botId: 'bot', machineId: 'machine', capabilityId: 'terminal', requestedLevel: 'read_interact', effectiveLevel: 'read_interact', reasons: [capability.reason], revision: 1, createdAtMs: 1, updatedAtMs: 1 };

test('measured names and categories win, connectors use their resource names', () => {
  expect(grantName('terminal', capability)).toBe(capability.name);
  expect(grantName('connector:1', undefined, 'Calendar')).toBe('Calendar');
  expect(grantGroup('custom', capability)).toBe('Everyday');
  expect(grantGroup('connector:1')).toBe('Connections');
  expect(grantGroup('screen_recording')).toBe('Control this Mac');
});

test('shell view-only and unsupported native policy mappings are unavailable', () => {
  expect(grantControlReason('terminal', 'read_only', capability)).toBeDefined();
  expect(grantControlReason('custom', 'read_only', capability)).toBeDefined();
  expect(grantControlReason('terminal', 'read_interact', capability)).toBeUndefined();
  expect(grantControlReason('files', 'read_only')).toBeUndefined();
  expect(grantControlReason('screen_recording', 'read_only', { ...capability, category: 'os_app' })).toBeDefined();
});

test('cutover, policy and stale measurements take precedence over readiness', () => {
  const ready = grantStatus(grant, capability);
  const stale = grantStatus(grant, { ...capability, stale: true });
  expect(stale).not.toBe(ready);
  const policy = { ...grant, reasons: [...grant.reasons, 'Local execution is deny; workspace ceiling is deny.'] };
  expect(grantStatus(policy, { ...capability, stale: true })).toBe(grantStatus(policy, capability));
  expect(grantStatus(policy, capability)).not.toBe(stale);
  const pending = { ...policy, reasons: [...policy.reasons, 'Tool-policy cutover has not been acknowledged.'] };
  expect(grantStatus(pending, capability)).not.toBe(grantStatus(policy, capability));
  expect(grantStatus({ ...grant, effectiveLevel: 'off' }, capability)).not.toBe(ready);
});

test('unknown machine reason codes stay out of status while raw evidence remains intact', () => {
  const unknown = { ...grant, effectiveLevel: 'off' as const, reasons: ['future_machine_code'] };
  expect(grantStatus(unknown)).not.toContain('future_machine_code');
  expect(unknown.reasons).toEqual(['future_machine_code']);
});

test('macOS permission reasons explain checked grants and Worker setup', () => {
  const expected = {
    macos_grant_measured: 'macOS permission checked.',
    macos_grant_denied: "macOS hasn't allowed this — open Permissions on that Mac.",
    macos_grant_probe_unavailable: "macOS permissions can't be checked until this Mac uses Lemon Bot Worker — open Permissions on that Mac.",
  };
  for (const [reason, message] of Object.entries(expected)) {
    const measured = reason === 'macos_grant_measured';
    const desktop: MachineCapability = {
      ...capability, id: 'accessibility', category: 'os_app', reason,
      configuredLevel: measured ? 'read_interact' : 'off',
      osGrant: measured ? 'granted' : reason === 'macos_grant_denied' ? 'denied' : 'unknown',
      stale: reason === 'macos_grant_probe_unavailable',
    };
    const permission: BotGrant = { ...grant, capabilityId: desktop.id, effectiveLevel: desktop.configuredLevel, reasons: [reason] };
    expect(grantStatus(permission, desktop)).toBe(message);
    expect(permission.reasons).toEqual([reason]);
    const policy = { ...permission, reasons: [reason, 'Local execution is deny; workspace ceiling is deny.'] };
    expect(grantStatus(policy, desktop)).toContain('workspace policy');
    expect(grantStatus({ ...policy, reasons: [...policy.reasons, 'Tool-policy cutover has not been acknowledged.'] }, desktop)).toContain('not yet confirmed');
  }
});
