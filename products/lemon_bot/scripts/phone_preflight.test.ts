import { expect, test } from 'bun:test';
import { checkOrigin, serveRoutes } from './phone_preflight';

// All descriptors, hosts, IDs and transports below are FAKE, not acceptance evidence.
const fakeOrigin = 'https://fake-machine.fake-tailnet.ts.net:8448';
const fakeSetup = { product: 'lemon_bot', apiVersion: 1, instanceId: 'fake-instance', version: 'fake', publicUrl: fakeOrigin, capabilities: { pairing: true }, setupRequired: false };
const fakeFetch = (body: unknown, type = 'application/json', status = 200) => (async () => new Response(typeof body === 'string' ? body : JSON.stringify(body), { status, headers: { 'Content-Type': type } })) as typeof fetch;
test('fake Serve metadata lists existing route without trusting port 4080', () => {
  expect(serveRoutes({ Web: { 'fake-machine.fake-tailnet.ts.net:8448': { Handlers: { '/': { Proxy: 'http://127.0.0.1:4080' } } } } })).toEqual([{ origin: fakeOrigin, upstreamPort: 4080 }]);
  expect(serveRoutes({ Web: { 'secret@invalid': {} } })).toEqual([]);
  expect(serveRoutes(null)).toEqual([]);
});
test('fake HTML 200, Phoenix JSON, redirect and mismatched identities fail closed', async () => {
  for (const fetcher of [fakeFetch('<html>fake Phoenix</html>', 'text/html'), fakeFetch({ errors: { detail: 'fake Phoenix' } }), fakeFetch('', 'application/json', 302)]) {
    expect((await checkOrigin(fakeOrigin, 'fake-instance', true, 'phone', fetcher)).status).toBe('wrong_service');
  }
  expect((await checkOrigin(fakeOrigin, 'other-fake-instance', true, 'phone', fakeFetch(fakeSetup))).status).toBe('instance_mismatch');
});
test('fake valid product, advertised URL, setup and TLS predicates', async () => {
  expect((await checkOrigin(fakeOrigin, 'fake-instance', true, 'phone', fakeFetch(fakeSetup))).status).toBe('verified_product_api');
  expect((await checkOrigin(fakeOrigin, 'fake-instance', true, 'phone', fakeFetch({ ...fakeSetup, publicUrl: 'https://other.fake-tailnet.ts.net' }))).status).toBe('advertised_origin_mismatch');
  expect((await checkOrigin(fakeOrigin, 'fake-instance', false, 'phone', fakeFetch(fakeSetup))).status).toBe('pairing_unavailable');
  expect((await checkOrigin('http://127.0.0.1:4080', 'fake-instance', true, 'phone', fakeFetch(fakeSetup))).status).toBe('loopback_origin');
});
