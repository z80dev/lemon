// Lemon <-> LCU bridge. One JSON object per line on stdin/stdout.
//
// LCU's shared harness client (<lcu-root>/adapters/client.mjs) owns the MCP
// connection to the original computer-use server: request metadata, approval
// deadlines, the agent-host approval guard and the diagnostic log. This bridge
// only relays: Lemon serializes operations, answers approvals and decides when
// a turn ends.
//
// Requests:  {id, type: "connect", command}
//            {id, type: "call", name, arguments, sessionId, turnId, toolCallId}
//            {type: "cancel", target}            (aborts call `target`; no reply)
//            {id, type: "turnEnded", sessionId, turnId, event}
//            {type: "elicitationResponse", id, response}
// Replies:   {id, ok: true, result} | {id, ok: false, error, code?}
// Events:    {type: "elicitation", id, params}
//            {type: "elicitationCancelled", id}
import { createInterface } from 'node:readline';
import { userInfo } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

// LCU, its diagnostic log and the signed Computer Use helper all belong to the
// macOS/Linux account: the helper binds its socket under the account's real
// home folder. A Lemon runtime started with an isolated HOME must not move them.
process.env.HOME = userInfo().homedir;

const root = process.argv[2];
if (!root) {
  console.error('lemon lcu bridge: the LCU release directory argument is required');
  process.exit(64);
}

const { createCuaClient } = await import(pathToFileURL(join(root, 'adapters', 'client.mjs')).href);

let cua;
let elicitationSequence = 0;
const pendingElicitations = new Map();
const inflight = new Map();

function send(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function requestElicitation(params, { signal } = {}) {
  return new Promise(resolve => {
    const id = ++elicitationSequence;
    const settle = response => {
      if (!pendingElicitations.delete(id)) return false;
      resolve(response);
      return true;
    };
    pendingElicitations.set(id, settle);
    signal?.addEventListener('abort', () => {
      if (settle({ action: 'cancel' })) send({ type: 'elicitationCancelled', id });
    }, { once: true });
    send({ type: 'elicitation', id, params });
  });
}

async function handle(request) {
  switch (request?.type) {
    case 'connect': {
      if (!cua) {
        const command = request.command;
        if (!Array.isArray(command) || command.length === 0 ||
            command.some(part => typeof part !== 'string' || !part)) {
          throw new Error('connect requires the LCU MCP server argv');
        }
        const candidate = createCuaClient({ command, adapter: 'lemon', onElicitation: requestElicitation });
        try {
          await candidate.connect();
        } catch (error) {
          await candidate.close().catch(() => {});
          throw error;
        }
        cua = candidate;
      }
      return { instructions: cua.instructions, tools: cua.publicTools() };
    }
    case 'call': {
      if (!cua) throw new Error('LCU is not connected');
      const controller = new AbortController();
      inflight.set(request.id, controller);
      try {
        const result = await cua.call(request.name, request.arguments ?? {}, {
          sessionId: request.sessionId,
          turnId: request.turnId,
          toolCallId: request.toolCallId,
          signal: controller.signal,
        });
        return { content: result.content ?? [], isError: result.isError === true };
      } finally {
        inflight.delete(request.id);
      }
    }
    case 'turnEnded': {
      if (!cua) return { skipped: true };
      await cua.turnEnded({ sessionId: request.sessionId, turnId: request.turnId, event: request.event });
      return { ended: true };
    }
    default:
      throw new Error(`unknown bridge request: ${String(request?.type)}`);
  }
}

const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
const running = new Set();

input.on('line', line => {
  let request;
  try {
    request = JSON.parse(line);
  } catch {
    console.error('lemon lcu bridge: ignored a malformed request line');
    return;
  }
  if (request?.type === 'elicitationResponse') {
    pendingElicitations.get(request.id)?.(request.response ?? { action: 'cancel' });
    return;
  }
  if (request?.type === 'cancel') {
    inflight.get(request.target)?.abort();
    return;
  }
  const task = handle(request).then(
    result => send({ id: request.id, ok: true, result }),
    error => send({
      id: request.id,
      ok: false,
      error: error instanceof Error ? error.message : String(error),
      ...(error?.code ? { code: String(error.code) } : {}),
    }),
  );
  running.add(task);
  task.finally(() => running.delete(task));
});

// Lemon closed stdin (or stopped reading stdout): cancel what is pending, let
// LCU close the original server, and exit.
let shuttingDown = false;
async function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  for (const settle of [...pendingElicitations.values()]) settle({ action: 'cancel' });
  for (const controller of inflight.values()) controller.abort();
  await Promise.allSettled([...running]);
  if (cua) await cua.close().catch(() => {});
  process.exit(0);
}

input.on('close', shutdown);
process.stdout.on('error', shutdown);
