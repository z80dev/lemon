// Stand-in for priv/lcu_bridge.mjs in tests: same line protocol, no LCU.
// Behavior is chosen by the `code` argument of a `js` call:
//   "text:<s>"     -> one text block <s>
//   "image"        -> a text block and a PNG image block
//   "error"        -> isError: true
//   "elicit:<app>" -> a native-app approval request for <app>; returns "approval:<action>"
//   "hang"         -> waits for cancel, then fails with "aborted"
//   "crash"        -> exits with status 3
// LCU_FAKE_LOG names a file that receives every request as a JSON line.
import { appendFileSync } from 'node:fs';
import { createInterface } from 'node:readline';

const log = process.env.LCU_FAKE_LOG;
const pending = new Map();
const hanging = new Map();
let elicitations = 0;

const send = message => process.stdout.write(`${JSON.stringify(message)}\n`);
process.stdout.on('error', () => process.exit(0));
const record = request => { if (log) appendFileSync(log, `${JSON.stringify(request)}\n`); };

function elicit(app, request) {
  return new Promise(resolve => {
    const id = ++elicitations;
    pending.set(id, resolve);
    send({ type: 'elicitation', id, params: {
      mode: 'form',
      message: `Allow Computer Use to use ${app}?`,
      requestedSchema: { type: 'object', properties: {} },
      _meta: {
        codex_approval_kind: 'mcp_tool_call',
        connector_id: 'computer-use',
        persist: ['session', 'always'],
        tool_params: { app },
        'x-codex-turn-metadata': { session_id: request.sessionId, turn_id: request.turnId },
      },
    } });
  });
}

async function call(request) {
  const code = String(request.arguments?.code ?? '');
  if (code.startsWith('text:')) return { content: [{ type: 'text', text: code.slice(5) }], isError: false };
  if (code === 'image') {
    return { content: [{ type: 'text', text: 'shot' }, { type: 'image', data: 'iVBORw0KGgo=', mimeType: 'image/png' }], isError: false };
  }
  if (code === 'error') return { content: [{ type: 'text', text: 'boom' }], isError: true };
  if (code.startsWith('elicit:')) {
    const answer = await elicit(code.slice(7), request);
    return { content: [{ type: 'text', text: `approval:${answer?.action}` }], isError: false };
  }
  if (code === 'hang') {
    await new Promise(resolve => hanging.set(request.id, resolve));
    throw new Error('aborted');
  }
  if (code === 'crash') process.exit(3);
  return { content: [{ type: 'text', text: `ran:${request.name}` }], isError: false };
}

createInterface({ input: process.stdin }).on('line', async line => {
  const request = JSON.parse(line);
  record(request);
  if (request.type === 'elicitationResponse') {
    pending.get(request.id)?.(request.response);
    pending.delete(request.id);
    return;
  }
  if (request.type === 'cancel') {
    hanging.get(request.target)?.();
    return;
  }
  try {
    let result;
    if (request.type === 'connect') {
      if (process.env.LCU_FAKE_CONNECT_FAIL) throw new Error('connect refused');
      result = { instructions: 'Fake computer-use instructions.', tools: [
        { name: 'js', description: 'Fake js tool.', inputSchema: { type: 'object', properties: { code: { type: 'string' } }, required: ['code'] } },
        { name: 'js_reset', description: 'Fake reset tool.', inputSchema: { type: 'object', properties: {} } },
      ] };
    } else if (request.type === 'call') {
      result = await call(request);
    } else if (request.type === 'turnEnded') {
      result = { ended: true };
    } else {
      throw new Error(`unknown ${request.type}`);
    }
    send({ id: request.id, ok: true, result });
  } catch (error) {
    send({ id: request.id, ok: false, error: error.message });
  }
});
