import { describe, it, expect } from 'vitest';
import {
  contentTypeFor,
  parseArgs,
  buildRpcArgs,
  decodeBase64Url,
  parseGatewayProbeOutput,
} from './utils.js';

describe('contentTypeFor', () => {
  it('returns text/html for .html', () => {
    expect(contentTypeFor('.html')).toBe('text/html');
  });

  it('returns text/javascript for .js', () => {
    expect(contentTypeFor('.js')).toBe('text/javascript');
  });

  it('returns text/css for .css', () => {
    expect(contentTypeFor('.css')).toBe('text/css');
  });

  it('returns image/svg+xml for .svg', () => {
    expect(contentTypeFor('.svg')).toBe('image/svg+xml');
  });

  it('returns application/json for .json', () => {
    expect(contentTypeFor('.json')).toBe('application/json');
  });

  it('returns image/png for .png', () => {
    expect(contentTypeFor('.png')).toBe('image/png');
  });

  it('returns image/jpeg for .jpg', () => {
    expect(contentTypeFor('.jpg')).toBe('image/jpeg');
  });

  it('returns image/jpeg for .jpeg', () => {
    expect(contentTypeFor('.jpeg')).toBe('image/jpeg');
  });

  it('returns font/woff for .woff', () => {
    expect(contentTypeFor('.woff')).toBe('font/woff');
  });

  it('returns font/woff2 for .woff2', () => {
    expect(contentTypeFor('.woff2')).toBe('font/woff2');
  });

  it('returns null for unknown extension', () => {
    expect(contentTypeFor('.xyz')).toBeNull();
  });

  it('returns null for empty string', () => {
    expect(contentTypeFor('')).toBeNull();
  });
});

describe('parseArgs', () => {
  // Prefix argv with two dummy entries to simulate process.argv (node, script, ...args)
  const argv = (...args: string[]) => ['node', 'script.js', ...args];

  it('returns empty options for no args', () => {
    expect(parseArgs(argv())).toEqual({});
  });

  it('parses --cwd', () => {
    expect(parseArgs(argv('--cwd', '/some/path'))).toMatchObject({ cwd: '/some/path' });
  });

  it('parses --model', () => {
    expect(parseArgs(argv('--model', 'claude-opus-4-6'))).toMatchObject({ model: 'claude-opus-4-6' });
  });

  it('parses --base_url (underscore)', () => {
    expect(parseArgs(argv('--base_url', 'http://localhost:4000'))).toMatchObject({
      baseUrl: 'http://localhost:4000',
    });
  });

  it('parses --base-url (hyphen)', () => {
    expect(parseArgs(argv('--base-url', 'http://localhost:4000'))).toMatchObject({
      baseUrl: 'http://localhost:4000',
    });
  });

  it('parses --system-prompt', () => {
    expect(parseArgs(argv('--system-prompt', 'Be helpful'))).toMatchObject({
      systemPrompt: 'Be helpful',
    });
  });

  it('parses --system_prompt (underscore)', () => {
    expect(parseArgs(argv('--system_prompt', 'Be helpful'))).toMatchObject({
      systemPrompt: 'Be helpful',
    });
  });

  it('parses --session-file', () => {
    expect(parseArgs(argv('--session-file', 'session.json'))).toMatchObject({
      sessionFile: 'session.json',
    });
  });

  it('parses --session_file (underscore)', () => {
    expect(parseArgs(argv('--session_file', 'session.json'))).toMatchObject({
      sessionFile: 'session.json',
    });
  });

  it('parses --debug flag', () => {
    expect(parseArgs(argv('--debug'))).toMatchObject({ debug: true });
  });

  it('parses --no-ui flag', () => {
    expect(parseArgs(argv('--no-ui'))).toMatchObject({ ui: false });
  });

  it('parses --lemon-path', () => {
    expect(parseArgs(argv('--lemon-path', '/home/user/lemon'))).toMatchObject({
      lemonPath: '/home/user/lemon',
    });
  });

  it('parses --port as number', () => {
    expect(parseArgs(argv('--port', '4242'))).toMatchObject({ port: 4242 });
  });

  it('parses --static-dir', () => {
    expect(parseArgs(argv('--static-dir', '/var/www'))).toMatchObject({ staticDir: '/var/www' });
  });

  it('parses multiple args together', () => {
    const result = parseArgs(argv('--cwd', '/proj', '--model', 'gpt-4', '--debug'));
    expect(result).toMatchObject({ cwd: '/proj', model: 'gpt-4', debug: true });
  });

  it('ignores unknown args', () => {
    expect(parseArgs(argv('--unknown', 'value'))).toEqual({});
  });
});

describe('buildRpcArgs', () => {
  it('returns base args for empty options', () => {
    expect(buildRpcArgs({})).toEqual(['run', '--no-start', 'scripts/debug_agent_rpc.exs', '--']);
  });

  it('appends --cwd when set', () => {
    const args = buildRpcArgs({ cwd: '/my/proj' });
    expect(args).toContain('--cwd');
    expect(args).toContain('/my/proj');
  });

  it('appends --model when set', () => {
    const args = buildRpcArgs({ model: 'claude-opus-4-6' });
    expect(args).toContain('--model');
    expect(args).toContain('claude-opus-4-6');
  });

  it('appends --base_url when set', () => {
    const args = buildRpcArgs({ baseUrl: 'http://localhost:4000' });
    expect(args).toContain('--base_url');
    expect(args).toContain('http://localhost:4000');
  });

  it('appends --system_prompt when set', () => {
    const args = buildRpcArgs({ systemPrompt: 'Be concise' });
    expect(args).toContain('--system_prompt');
    expect(args).toContain('Be concise');
  });

  it('appends --session-file when set', () => {
    const args = buildRpcArgs({ sessionFile: 'sess.json' });
    expect(args).toContain('--session-file');
    expect(args).toContain('sess.json');
  });

  it('appends --debug when true', () => {
    expect(buildRpcArgs({ debug: true })).toContain('--debug');
  });

  it('does not append --debug when false', () => {
    expect(buildRpcArgs({ debug: false })).not.toContain('--debug');
  });

  it('appends --no-ui when ui is false', () => {
    expect(buildRpcArgs({ ui: false })).toContain('--no-ui');
  });

  it('does not append --no-ui when ui is true', () => {
    expect(buildRpcArgs({ ui: true })).not.toContain('--no-ui');
  });

  it('does not append --no-ui when ui is undefined', () => {
    expect(buildRpcArgs({})).not.toContain('--no-ui');
  });
});

describe('decodeBase64Url', () => {
  it('decodes standard base64url without padding', () => {
    // "hello" in base64url is "aGVsbG8" (no padding needed, length 7)
    // Actually: "hello" -> base64 is "aGVsbG8=" but base64url without pad is "aGVsbG8"
    const encoded = Buffer.from('hello').toString('base64url');
    expect(decodeBase64Url(encoded)).toBe('hello');
  });

  it('handles base64url with dashes and underscores', () => {
    // base64url uses - instead of + and _ instead of /
    const original = 'test/value+here';
    const encoded = Buffer.from(original).toString('base64url');
    expect(decodeBase64Url(encoded)).toBe(original);
  });

  it('decodes a path-like string', () => {
    const path = '/home/user/dev/lemon';
    const encoded = Buffer.from(path).toString('base64url');
    expect(decodeBase64Url(encoded)).toBe(path);
  });

  it('decodes a session id with mixed characters', () => {
    const sessionId = 'my-session_123';
    const encoded = Buffer.from(sessionId).toString('base64url');
    expect(decodeBase64Url(encoded)).toBe(sessionId);
  });
});

describe('parseGatewayProbeOutput', () => {
  it('returns error from processError', () => {
    const err = new Error('spawn failed');
    const result = parseGatewayProbeOutput('', '', null, err);
    expect(result).toEqual({ sessions: [], error: 'spawn failed' });
  });

  it('returns error when status is non-zero with stderr', () => {
    const result = parseGatewayProbeOutput('', 'something failed', 1);
    expect(result).toEqual({ sessions: [], error: 'something failed' });
  });

  it('returns error when status is non-zero with stdout fallback', () => {
    const result = parseGatewayProbeOutput('stdout error', '', 2);
    expect(result).toEqual({ sessions: [], error: 'stdout error' });
  });

  it('returns generic error when status non-zero and no stderr/stdout', () => {
    const result = parseGatewayProbeOutput('', '', 3);
    expect(result).toEqual({ sessions: [], error: 'probe exited with status 3' });
  });

  it('returns empty sessions for empty stdout on success', () => {
    const result = parseGatewayProbeOutput('', '', 0);
    expect(result).toEqual({ sessions: [], error: null });
  });

  it('returns error from __ERROR__ line', () => {
    const result = parseGatewayProbeOutput('__ERROR__|connect_failed|lemon_gateway@host', '', 0);
    expect(result).toEqual({ sessions: [], error: 'connect_failed|lemon_gateway@host' });
  });

  it('returns generic gateway probe error when __ERROR__ line has no detail', () => {
    const result = parseGatewayProbeOutput('__ERROR__|', '', 0);
    expect(result).toEqual({ sessions: [], error: 'gateway probe error' });
  });

  it('skips malformed lines (not 3 pipe-separated parts)', () => {
    const result = parseGatewayProbeOutput('bad\nalso-bad|only-two', '', 0);
    expect(result).toEqual({ sessions: [], error: null });
  });

  it('parses a valid session line', () => {
    const sessionId = 'my-session-1';
    const cwd = '/home/user/project';
    const sid64 = Buffer.from(sessionId).toString('base64url');
    const cwd64 = Buffer.from(cwd).toString('base64url');
    const stdout = `${sid64}|${cwd64}|0\n`;

    const result = parseGatewayProbeOutput(stdout, '', 0);
    expect(result.error).toBeNull();
    expect(result.sessions).toHaveLength(1);
    expect(result.sessions[0]).toEqual({
      session_id: sessionId,
      cwd,
      is_streaming: false,
    });
  });

  it('parses a streaming session line', () => {
    const sessionId = 'stream-session';
    const cwd = '/work/dir';
    const sid64 = Buffer.from(sessionId).toString('base64url');
    const cwd64 = Buffer.from(cwd).toString('base64url');
    const stdout = `${sid64}|${cwd64}|1\n`;

    const result = parseGatewayProbeOutput(stdout, '', 0);
    expect(result.sessions[0].is_streaming).toBe(true);
  });

  it('parses multiple session lines', () => {
    const s1 = Buffer.from('sess1').toString('base64url');
    const c1 = Buffer.from('/a').toString('base64url');
    const s2 = Buffer.from('sess2').toString('base64url');
    const c2 = Buffer.from('/b').toString('base64url');
    const stdout = `${s1}|${c1}|0\n${s2}|${c2}|1\n`;

    const result = parseGatewayProbeOutput(stdout, '', 0);
    expect(result.sessions).toHaveLength(2);
    expect(result.sessions[0].session_id).toBe('sess1');
    expect(result.sessions[1].session_id).toBe('sess2');
    expect(result.sessions[1].is_streaming).toBe(true);
  });
});
