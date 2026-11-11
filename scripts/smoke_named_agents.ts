// On-demand consumer of the real Lemon Bot WebSocket adapter. No fake RPC server,
// synthetic completion event, or provider call. The external execution fixture is
// an existing real native session. A separate component exercises production
// addressed REST/ACL/provenance with real native execution; managed proof is not claimed.
import { readFile } from 'node:fs/promises';
import { createLemonService, type ConnectedLemonService } from '../products/lemon_bot/backend/src/runtime/lemon';
import { ApiError } from '../products/lemon_bot/backend/src/core/errors';
import type { AgentIdentity, AgentMessageReceipt } from '../products/lemon_bot/contracts/protocol';
import { productAddressedSmoke } from './smoke_named_agents_product';
import { newSessionKey } from '../clients/tui/src/session-key';

interface Manifest { url: string; credentialFile: string; cwd: string; root: string; alice: string; bob: string; carol: string; product: string }
interface ChatReceipt { runId: string; sessionKey: string }
interface Completion { ok: boolean; answer: string | null; cancelled: boolean }
interface RequestEvent { messageId: string; sourceId: string; targetId: string; text: string }
type ObservedEvent = { name: string; payload: unknown };
const configuration = JSON.parse(await readFile(process.argv[2]!, 'utf8')) as Omit<Manifest, 'alice' | 'bob' | 'carol' | 'product'>;
const manifest: Manifest = {
  ...configuration,
  alice: newSessionKey(configuration.cwd),
  bob: newSessionKey(configuration.cwd),
  carol: newSessionKey(configuration.cwd),
  product: newSessionKey(configuration.cwd),
};
const token = (await readFile(manifest.credentialFile, 'utf8')).trim();
const url = new URL(manifest.url);
if (url.protocol !== 'ws:' || url.hostname !== '127.0.0.1' || url.pathname !== '/ws') throw new Error('Smoke requires isolated loopback transport.');
// Product integrations must never reach a real platform/provider during smoke.
const originalFetch = globalThis.fetch;
globalThis.fetch = Object.assign(async (input: RequestInfo | URL, init?: RequestInit) => {
  const destination = new URL(input instanceof Request ? input.url : String(input));
  if (!['127.0.0.1', '[::1]', 'localhost'].includes(destination.hostname)) throw new Error('Offline smoke blocked outbound HTTP.');
  return originalFetch(input, init);
}, originalFetch);
const clients: ConnectedLemonService[] = [];
let phase = 'connect';

function check(value: unknown, message: string): asserts value { if (!value) throw new Error(message); }
async function until<T>(read: () => Promise<T>, ready: (value: T) => boolean, label: string): Promise<T> {
  const deadline = Date.now() + 40_000;
  while (Date.now() < deadline) {
    const value = await read();
    if (ready(value)) return value;
    await Bun.sleep(30);
  }
  throw new Error(`Timed out: ${label}`);
}
async function rejected(action: () => Promise<unknown>, label: string, codes = ['conflict', 'forbidden', 'not_found']): Promise<void> {
  let error: unknown;
  try { await action(); } catch (caught) { error = caught; }
  check(error instanceof ApiError && codes.includes(error.code) && error.retrySafe, label);
}
async function connect(): Promise<{ client: ConnectedLemonService; events: ObservedEvent[] }> {
  const client = createLemonService({ controlUrl: manifest.url, operatorToken: token, trustedOverlay: false }, { requestTimeoutMs: 40_000 });
  clients.push(client);
  const events: ObservedEvent[] = [];
  client.onEvent((name, payload) => events.push({ name, payload }));
  client.start();
  await until(async () => client.connected, Boolean, 'authenticated hello');
  for (const method of ['chat.send', 'agent.wait', 'chat.history', 'sessions.create', 'sessions.snapshot', 'agent.identity.list', 'agent.identity.rename', 'agent.identity.register', 'agent.message.send', 'agent.message.get', 'agent.message.complete']) {
    check(client.methods.includes(method), `Required capability missing: ${method}`);
  }
  return { client, events };
}
async function chat(client: ConnectedLemonService, sessionKey: string, prompt: string): Promise<Completion> {
  const receipt = await client.call<ChatReceipt>('chat.send', { sessionKey, cwd: manifest.cwd, prompt, runId: crypto.randomUUID(), queueMode: 'queue' }, { mutation: true });
  check(receipt.runId && receipt.sessionKey === sessionKey, 'Chat admission did not bind the exact existing session.');
  const result = await client.call<Completion>('agent.wait', { runId: receipt.runId, timeoutMs: 30_000 });
  check(result.ok === true && result.cancelled === false && typeof result.answer === 'string', 'Real native run did not complete.');
  return result;
}
async function receipt(client: ConnectedLemonService, sourceId: string, messageId: string): Promise<AgentMessageReceipt> {
  const value = await until(() => client.call<AgentMessageReceipt>('agent.message.get', { sourceId, messageId }), item => item.status !== 'accepted', 'named message completion');
  check(value.messageId === messageId && value.sourceId === sourceId && value.status === 'completed', 'Named receipt did not complete for the exact sender.');
  return value;
}
async function historyContains(client: ConnectedLemonService, sessionKey: string, expected: string, count = 1): Promise<void> {
  await until(() => client.call('chat.history', { sessionKey, cwd: manifest.cwd, limit: 100 }), value => JSON.stringify(value).split(expected).length - 1 >= count, 'sender visible follow-up');
}

try {
  const operator = await connect();
  const external = await connect();
  const observer = await connect();
  const aliceId = `session://${manifest.alice}`;
  const bobId = `session://${manifest.bob}`;
  const botId = 'bot://named-agent-smoke/carol';

  phase = 'name a fresh conversation before inference';
  const created = await operator.client.call<{ sessionKey: string; sessionId: string }>('sessions.create', { sessionKey: manifest.bob, cwd: manifest.cwd }, { mutation: true });
  check(created.sessionKey === manifest.bob && Boolean(created.sessionId), 'Fresh conversation persistence changed its identity.');
  const named = await operator.client.call<{ agent: AgentIdentity }>('agent.identity.rename', { id: bobId, name: '@Bob' }, { mutation: true });
  check(named.agent.id === bobId && named.agent.name === 'bob', 'Handle normalization changed stable identity.');
  phase = 'seed native contexts';
  await chat(operator.client, manifest.alice, 'SMOKE_SEED_ALICE ALICE_PRIVATE=amber');
  await chat(operator.client, manifest.bob, 'SMOKE_SEED_BOB BOB_PRIVATE=violet');
  await chat(operator.client, manifest.carol, 'SMOKE_SEED_CAROL CAROL_PRIVATE=teal');
  const listed = await operator.client.call<{ agents: AgentIdentity[] }>('agent.identity.list', { query: 'bob' });
  check(listed.agents.some(agent => agent.id === bobId && agent.name === 'bob'), 'Addressable Bob was absent from discovery.');
  await rejected(() => operator.client.call('agent.identity.rename', { id: aliceId, name: 'BOB' }, { mutation: true }), 'Collision unexpectedly reassigned Bob.');

  phase = 'native addressed message and replay';
  const firstIntent = { sourceId: aliceId, target: '@bob', text: 'SMOKE_BOB_QUERY_ONE: answer from your prior private context.', messageId: crypto.randomUUID() };
  const accepted = await operator.client.call<AgentMessageReceipt>('agent.message.send', firstIntent, { mutation: true });
  check(['accepted', 'completed'].includes(accepted.status) && accepted.targetId === bobId, 'Send did not acknowledge the intended Bob.');
  if (accepted.status === 'accepted') check(!accepted.response, 'Acceptance falsely claimed an answer.');
  phase = 'native message completion';
  const first = await receipt(operator.client, aliceId, firstIntent.messageId);
  check(first.response === 'BOB_REPLY_ONE=violet', 'Bob did not retain existing private context.');
  phase = 'native replay and sender isolation';
  const replay = await operator.client.call<AgentMessageReceipt>('agent.message.send', firstIntent, { mutation: true });
  check(replay.messageId === first.messageId && replay.runId === first.runId, 'Identical replay started another run.');
  await rejected(() => operator.client.call('agent.message.send', { ...firstIntent, text: 'changed intent' }, { mutation: true }), 'Changed replay intent was accepted.');
  await rejected(() => operator.client.call('agent.message.get', { sourceId: bobId, messageId: first.messageId }), 'Another sender could read the receipt.');
  phase = 'native original-source continuation';
  await historyContains(operator.client, manifest.alice, "Alice observed Bob's first answer in her original context.");
  phase = 'rename preserves stable context';
  const renamed = await operator.client.call<{ agent: AgentIdentity }>('agent.identity.rename', { id: bobId, name: 'robert' }, { mutation: true });
  check(renamed.agent.id === bobId && renamed.agent.name === 'robert', 'Rename changed stable ID.');
  await rejected(() => operator.client.call('agent.message.send', { sourceId: aliceId, target: '@bob', text: 'old handle must not dispatch', messageId: crypto.randomUUID() }, { mutation: true }), 'Old handle still resolved.');
  const secondId = crypto.randomUUID();
  await operator.client.call('agent.message.send', { sourceId: aliceId, target: bobId, text: 'SMOKE_BOB_QUERY_TWO: recall your prior answer.', messageId: secondId }, { mutation: true });
  const second = await receipt(operator.client, aliceId, secondId);
  check(second.response === 'BOB_REPLY_TWO=violet; prior answer retained', 'Stable ID failed to resume the same Bob context.');

  await historyContains(operator.client, manifest.alice, "Alice observed Bob's second answer in her original context.");
  phase = 'actual native agent_message tool loop';
  const toolRun = await chat(operator.client, manifest.alice, 'SMOKE_ASK_BOB_WITH_TOOL: ask @robert to explain using his existing context.');
  check(toolRun.answer === 'Alice submitted the named tool request.', 'Native agent_message did not complete its actual tool loop.');
  await historyContains(operator.client, manifest.alice, 'Alice observed tool-mediated Bob in original context.');
  await historyContains(operator.client, manifest.bob, 'TOOL_BOB_ANSWER=violet');
  await until(
    () => operator.client.call<{ snapshot: { phase: string; terminal: boolean; answer: { text: string; canonical: boolean } } }>('sessions.snapshot', { sessionKey: manifest.alice, cwd: manifest.cwd }),
    value => value.snapshot.phase === 'completed' && value.snapshot.terminal && value.snapshot.answer.canonical && value.snapshot.answer.text === 'Alice observed tool-mediated Bob in original context.',
    'canonical named-tool source completion',
  );
  phase = 'external identity binding';
  const registration = { scope: 'operator', id: botId, name: 'carol', label: 'Offline transport fixture Carol', metadata: { backendInstanceId: 'named-agent-smoke', botId: 'carol' } };
  const registered = await external.client.call<{ agent: AgentIdentity }>('agent.identity.register', registration, { mutation: true });
  check(registered.agent.id === botId, 'External identity was not bound.');
  await rejected(() => operator.client.call('agent.message.send', { sourceId: botId, target: bobId, text: 'spoofed source', messageId: crypto.randomUUID() }, { mutation: true }), 'Another socket could send as the registered Bot.');

  phase = 'native to external request and real response';
  const externalId = crypto.randomUUID();
  await operator.client.call('agent.message.send', { sourceId: aliceId, target: '@carol', text: 'SMOKE_CAROL_QUERY: answer from existing context.', messageId: externalId }, { mutation: true });
  const request = await until(async () => external.events.find(event => event.name === 'agent.message.request' && (event.payload as RequestEvent)?.messageId === externalId), Boolean, 'targeted external request');
  const payload = request!.payload as RequestEvent;
  check(payload.targetId === botId && payload.sourceId === aliceId, 'External request lost exact provenance.');
  check(!operator.events.some(event => event.name === 'agent.message.request'), 'External request was globally broadcast.');
  check(!observer.events.some(event => event.name === 'agent.message.request'), 'Unrelated socket received external request.');
  await rejected(() => observer.client.call('agent.message.complete', { messageId: externalId, status: 'completed', response: 'forged' }, { mutation: true }), 'Unrelated connection completed external message.');

  // This is an execution fixture, not a fake method acknowledgement: the request
  // actually resumes Carol's saved native context and waits for native completion.
  const externalRun = await external.client.call<ChatReceipt>('chat.send', { sessionKey: manifest.carol, cwd: manifest.cwd, prompt: `[Untrusted peer ${payload.sourceId}]\n${payload.text}`, runId: crypto.randomUUID(), queueMode: 'queue' }, { mutation: true });
  await external.client.call('agent.message.complete', { messageId: externalId, status: 'accepted', runId: externalRun.runId }, { mutation: true });
  const externalAnswer = await external.client.call<Completion>('agent.wait', { runId: externalRun.runId, timeoutMs: 30_000 });
  check(externalAnswer.ok && externalAnswer.answer === 'CAROL_REPLY=teal', 'External execution did not use existing Carol context.');
  await external.client.call('agent.message.complete', { messageId: externalId, status: 'completed', runId: externalRun.runId, response: externalAnswer.answer }, { mutation: true });
  const externalResult = await receipt(operator.client, aliceId, externalId);
  check(externalResult.response === 'CAROL_REPLY=teal', 'External response was not correlated.');
  await historyContains(operator.client, manifest.alice, "Alice observed Carol's answer in her original context.");

  phase = 'external source to native result';
  const outwardId = crypto.randomUUID();
  await external.client.call('agent.message.send', { sourceId: botId, target: '@robert', text: 'SMOKE_BOT_TO_BOB: use your existing context.', messageId: outwardId }, { mutation: true });
  const resultEvent = await until(async () => external.events.find(event => event.name === 'agent.message.result' && (event.payload as AgentMessageReceipt)?.messageId === outwardId && (event.payload as AgentMessageReceipt).status === 'completed'), Boolean, 'targeted Bot result');
  const result = resultEvent!.payload as AgentMessageReceipt;
  check(result.sourceId === botId && result.targetId === bobId && result.response === 'BOB_EXTERNAL_REPLY=violet', 'Bot result did not retain original identities/context.');
  check(!observer.events.some(event => event.name === 'agent.message.result'), 'Unrelated socket received external result.');

  phase = 'disconnect remains offline';
  external.client.close();
  await until(() => operator.client.call<{ agents: AgentIdentity[] }>('agent.identity.list', { query: 'carol' }), value => value.agents.some(agent => agent.id === botId && agent.status === 'offline'), 'external offline identity');
  const offlineId = crypto.randomUUID();
  await rejected(() => operator.client.call('agent.message.send', { sourceId: aliceId, target: botId, text: 'must not fall back to native', messageId: offlineId }, { mutation: true }), 'Disconnected Bot silently accepted or fell back.', ['upstream_unavailable']);
  const offlineReceipt = await operator.client.call<AgentMessageReceipt>('agent.message.get', { sourceId: aliceId, messageId: offlineId });
  check(offlineReceipt.status === 'failed' && offlineReceipt.response === null, 'Disconnected Bot acquired a completed/native receipt.');
  console.log(JSON.stringify({ transportSmoke: 'passed', productAdapter: 'createLemonService', productRuntimeAndACL: false, nativeExistingContext: true, externalRequestReply: true, targetedEvents: true, replayNoDuplicate: true, disconnectOffline: true }));

  phase = 'real product addressed REST, native execution and privacy';
  await productAddressedSmoke(manifest, token, bobId);
} catch {
  console.error(`Named-agent transport smoke failed during ${phase}; no passing evidence claimed.`);
  process.exitCode = 1;
} finally {
  for (const client of clients) client.close();
}
