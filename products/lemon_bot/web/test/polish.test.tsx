import { expect, test } from 'bun:test';
import { renderToStaticMarkup } from 'react-dom/server';
import { LemonBotError, type ErrorCode } from '@lemon-bot/sdk';
import { errorSummary } from '../src/error-copy';
import { ConfirmDialog, ErrorNotice, Loading, RecoveryNotice } from '../src/ui';
import { draftStateLabels, voiceStateLabels } from '../src/live';
import { isSettingsScreen } from '../src/settings-shell';

test('known errors offer a next step without exposing protocol diagnostics as primary copy', () => {
  for (const code of ['outcome_unknown', 'revision_conflict', 'unauthenticated', 'forbidden', 'invalid_request', 'upstream_unavailable'] satisfies ErrorCode[]) {
    const error = new LemonBotError({ code, message: 'technical nonce reconcile authoritative detail', requestId: 'request_private', retrySafe: false }, { clientNonce: 'reference_private' });
    const primary = renderToStaticMarkup(<ErrorNotice error={error}/>).split('<details>')[0];
    expect(primary).not.toContain('request_private');
    expect(primary).not.toContain('reference_private');
    expect(primary).not.toMatch(/nonce|reconcile|authoritative|outcome_unknown/);
    expect(errorSummary(error).length).toBeGreaterThan(30);
    const full = renderToStaticMarkup(<ErrorNotice error={error}/>);
    expect(full).toContain('Copy details');
    expect(full).toContain('reference_private');
  }
  expect(errorSummary(new TypeError('fetch transport failure'))).not.toContain('fetch transport');
});

test('recovery labels distinguish ordinary errors from uncertain changes and keep offline checks disabled', () => {
  const onCheck = async () => undefined;
  const ordinary = renderToStaticMarkup(<RecoveryNotice error={new Error('validation')} uncertain={false} busy={false} onCheck={onCheck}/>);
  expect(ordinary).toContain('Refresh and check again');
  expect(ordinary).not.toContain('Check status');
  const uncertain = renderToStaticMarkup(<RecoveryNotice error={new Error('lost reply')} uncertain busy={false} available={false} onCheck={onCheck}/>);
  expect(uncertain).toContain('Check status');
  expect(uncertain).toContain('disabled=""');
  expect(uncertain.match(/couldn’t confirm this went through/g)).toHaveLength(1);
});

test('preview confirmation retains typed confirmation and moves opaque references into Details', () => {
  const markup = renderToStaticMarkup(<ConfirmDialog title="Delete Bot?" confirmation={{ confirmationToken: 'private_token', revision: 4, confirmName: 'Helper', expiresAtMs: Date.now() + 60000, effects: ['Delete the Helper Bot.'], affected: [{ resourceType: 'bot', id: 'opaque_bot_reference', machineId: null, operation: 'delete', explanation: 'Its conversations are removed.' }] }} onCancel={() => undefined} onConfirm={async () => undefined}/>);
  expect(markup).toContain('Type “Helper” to confirm');
  expect(markup).toContain('aria-modal="true"');
  expect(markup).not.toContain('private_token');
  expect(markup.indexOf('opaque_bot_reference')).toBeGreaterThan(markup.indexOf('<details>'));
  expect(markup).toContain('disabled=""');
});

test('loading states, draft states, voice states and stale settings routes are humanized', () => {
  expect(renderToStaticMarkup(<Loading label="Loading messages…"/>)).toContain('Loading messages…');
  expect(draftStateLabels.outcome_unknown).toBe('Send status unknown');
  expect(draftStateLabels.sending).toBe('Sending…');
  expect(voiceStateLabels.failed).toBe('Call interrupted');
  expect(isSettingsScreen('settings.old-bookmark')).toBe(true);
  expect(isSettingsScreen('conversation')).toBe(false);
});
