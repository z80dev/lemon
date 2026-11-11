import { expect, test } from 'bun:test';
import { LemonBotClient, type MachineSetup } from '../src/index.ts';
import { fetchBoundary } from './fixtures.ts';

test('SSH setup retains nonce and reconciles with a read', async () => {
  const setup: MachineSetup = { id: 'setup-1', revision: 1, createdAtMs: 1, updatedAtMs: 1, machineId: 'machine-1', sshDestination: 'me@studio', state: 'running', step: 'checking_ssh', failure: null, persistence: null, finishedAtMs: null };
  const boundary = fetchBoundary(() => Response.json(setup));
  const client = new LemonBotClient({ baseUrl: 'https://bot.example', fetch: boundary.clientFetch });
  const body = { clientNonce: 'fixed', sshDestination: 'me@studio', machineId: 'machine-1' };
  expect(await client.addMachineOverSsh(body)).toEqual(setup);
  expect(await boundary.requests[0]!.clone().json()).toEqual(body);
  expect(await client.machineSetup('setup-1')).toEqual(setup);
  expect(boundary.requests.map(request => [request.method, new URL(request.url).pathname])).toEqual([
    ['POST', '/v1/machines/ssh'], ['GET', '/v1/machine-setups/setup-1'],
  ]);
});

test('lost SSH setup response is never automatically replayed', async () => {
  const boundary = fetchBoundary(() => { throw new TypeError('Disconnected'); });
  const client = new LemonBotClient({ baseUrl: 'https://bot.example', fetch: boundary.clientFetch });
  await expect(client.addMachineOverSsh({ clientNonce: 'fixed', sshDestination: 'me@studio' })).rejects.toMatchObject({ outcomeUnknown: true, clientNonce: 'fixed' });
  expect(boundary.requests).toHaveLength(1);
});
