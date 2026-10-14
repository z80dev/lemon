import { describe, expect, test } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import { spendStatus, spendWindow } from '../../src/enterprise/spend';
const at = Date.UTC(2026, 9, 14, 10, 35);
const limit: P.SpendLimit = { id: 'l', revision: 1, createdAtMs: 1, updatedAtMs: 1, scope: 'user', subjectId: 'u', period: 'day', limitUsd: 20, warningPercent: 75, enabled: true, enforcement: 'block_new_runs', providerAccount: null };
describe('authoritative spend semantics', () => {
  test('missing or incomplete price is unknown, never a free zero allowance', () => {
    for (const measurement of [{ costUsd: null, incomplete: false }, { costUsd: 0, incomplete: true }, { costUsd: NaN, incomplete: false }, { costUsd: -1, incomplete: false }]) {
      const status = spendStatus(limit, measurement, at); expect(status.state).toBe('unknown'); expect(status.spentUsd).toBeNull(); expect(status.remainingUsd).toBeNull();
    }
  });
  test('warning and equality exhaustion are exact; admitted overspend is displayed without negative remaining', () => {
    expect(spendStatus(limit, { costUsd: 14.99, incomplete: false }, at).state).toBe('ok');
    expect(spendStatus(limit, { costUsd: 15, incomplete: false }, at).state).toBe('warning');
    expect(spendStatus(limit, { costUsd: 20, incomplete: false }, at).state).toBe('exhausted');
    expect(spendStatus(limit, { costUsd: 22, incomplete: false }, at).remainingUsd).toBe(0);
  });
  test('zero-dollar ceiling admits no new paid or measured-zero work', () => {
    expect(spendStatus({ ...limit, limitUsd: 0 }, { costUsd: 0, incomplete: false }, at).state).toBe('exhausted');
  });
  test('UTC day and ISO week do not depend on user timezone or DST', () => {
    expect(spendWindow('day', at)).toEqual({ fromAtMs: Date.UTC(2026, 9, 14), toAtMs: Date.UTC(2026, 9, 15) });
    expect(spendWindow('week', Date.UTC(2026, 9, 18, 23, 59))).toEqual({ fromAtMs: Date.UTC(2026, 9, 12), toAtMs: Date.UTC(2026, 9, 19) });
  });
  test('calendar month handles leap-year February and year rollover', () => {
    expect(spendWindow('month', Date.UTC(2028, 1, 29))).toEqual({ fromAtMs: Date.UTC(2028, 1, 1), toAtMs: Date.UTC(2028, 2, 1) });
    expect(spendWindow('month', Date.UTC(2026, 11, 31))).toEqual({ fromAtMs: Date.UTC(2026, 11, 1), toAtMs: Date.UTC(2027, 0, 1) });
  });
});
