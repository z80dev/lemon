import { describe, expect, it } from 'vitest';
import { formatDuration } from './formatDuration';

describe('formatDuration', () => {
  it.each([
    [null, '--'],
    [undefined, '--'],
    [999, '999ms'],
    [1000, '1.0s'],
    [59_999, '60.0s'],
    [60_000, '1m 0s'],
    [65_999, '1m 5s'],
  ])('formats %s milliseconds as %s', (milliseconds, expected) => {
    expect(formatDuration(milliseconds)).toBe(expected);
  });
});
