import { describe, expect, it } from 'vitest';

import { asBool, asInt, asString, parseCliArgs } from './cli-args.js';

describe('cli-args', () => {
  it('parses keyed values and boolean flags', () => {
    expect(parseCliArgs([
      '--ws-url', 'ws://localhost:4040/ws',
      '--headless',
      '--cdp-port', '19999',
    ])).toEqual({
      'ws-url': 'ws://localhost:4040/ws',
      headless: true,
      'cdp-port': '19999',
    });
  });

  it('ignores non-flag tokens', () => {
    expect(parseCliArgs(['ignored', '--token', 'abc'])).toEqual({
      token: 'abc',
    });
  });

  it('coerces strings', () => {
    expect(asString('  hello ')).toBe('hello');
    expect(asString('   ')).toBeNull();
    expect(asString(123)).toBeNull();
  });

  it('coerces booleans', () => {
    expect(asBool(true)).toBe(true);
    expect(asBool('true')).toBe(true);
    expect(asBool('YES')).toBe(true);
    expect(asBool('off')).toBe(false);
  });

  it('coerces ints with fallback', () => {
    expect(asInt('123', 9)).toBe(123);
    expect(asInt('0', 9)).toBe(9);
    expect(asInt('not-a-number', 9)).toBe(9);
  });
});
