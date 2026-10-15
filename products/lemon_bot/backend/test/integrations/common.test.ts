import { describe, expect, test } from 'bun:test';
import { boundedBytes, isPublicAddress, pinnedUrl, providerRequest, secureEqual, scrub } from '../../src/integrations/common';
import type { HttpClient } from '../../src/core/services';
describe('provider security boundary', () => {
  test('origin pinning rejects redirects credentials schemes and lookalike hosts', () => {
    for (const url of ['http://api.example/x', 'https://api.example.evil/x', 'https://user:password@api.example/x', 'https://api.example/x#secret']) expect(() => pinnedUrl(url, ['https://api.example'])).toThrow();
    expect(pinnedUrl('https://api.example/x', ['https://api.example']).pathname).toBe('/x');
  });
  test('private and reserved addresses cannot become public provider targets', () => {
    for (const ip of ['127.0.0.1', '10.0.0.1', '169.254.169.254', '172.16.0.1', '192.168.1.1', '100.64.0.1', '::1', 'fd00::1', 'fe80::1', '::ffff:127.0.0.1']) expect(isPublicAddress(ip)).toBe(false);
    expect(isPublicAddress('8.8.8.8')).toBe(true); expect(isPublicAddress('2606:4700:4700::1111')).toBe(true);
  });
  test('ACL revocation at dispatch sends no request and preserves the reason', async () => {
    let calls = 0;
    const transport: HttpClient = async () => { calls++; return new Response('{}'); };
    await expect(providerRequest('https://api.example/x', {}, { allowedOrigins: ['https://api.example'], allowPrivate: true, fetch: transport, beforeDispatch() { throw new Error('consent revoked'); } })).rejects.toThrow('consent revoked');
    expect(calls).toBe(0);
  });
  test('caller cancellation is combined with provider timeout and is not ignored', async () => {
    const controller = new AbortController(); controller.abort(new Error('revoked'));
    let calls = 0;
    const transport: HttpClient = async () => { calls++; return new Response('{}'); };
    await expect(providerRequest('https://api.example/x', { signal: controller.signal }, { allowedOrigins: ['https://api.example'], allowPrivate: true, fetch: transport })).rejects.toThrow('revoked');
    expect(calls).toBe(0);
  });
  test('streaming provider bytes are bounded even without content length', async () => {
    const response = new Response(new ReadableStream({ start(controller) { controller.enqueue(new Uint8Array(4)); controller.enqueue(new Uint8Array(4)); controller.close(); } }));
    await expect(boundedBytes(response, 5)).rejects.toThrow('size limit');
  });
  test('secret-shaped payload fields and unequal signature lengths fail safely', () => {
    expect(scrub({ authorization: 'token', nested: { refresh_token: 'secret', message: 'Bearer leaked-value' } })).toEqual({ authorization: '[redacted]', nested: { refresh_token: '[redacted]', message: '[redacted]' } });
    expect(secureEqual('valid', 'valid')).toBe(true); expect(secureEqual('valid', 'valid-with-extra')).toBe(false);
  });
});
