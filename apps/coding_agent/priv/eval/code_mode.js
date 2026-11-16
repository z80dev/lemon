// Trusted Deno driver. Cells run in a permissionless worker, never this isolate.
const encoder = new TextEncoder();
const send = (frame) => Deno.stdout.writeSync(encoder.encode(JSON.stringify(frame) + "\n"));
const workerSource = `
const pending = new Map();
let sequence = 0;
const call = (tool, args = {}) => new Promise((resolve, reject) => {
  const call = ++sequence;
  pending.set(call, { resolve, reject });
  postMessage({ type: "tool_call", call, tool, args });
});
globalThis.tools = new Proxy(Object.create(null), {
  get: (_, name) => name === "call" ? call : (args) => call(String(name), args)
});
const show = (values) => values.map(v => typeof v === "string" ? v : JSON.stringify(v)).join(" ");
globalThis.console = Object.freeze({
  log: (...values) => postMessage({ type: "output", text: show(values) + "\\n" }),
  error: (...values) => postMessage({ type: "output", text: show(values) + "\\n" }),
  warn: (...values) => postMessage({ type: "output", text: show(values) + "\\n" })
});
onmessage = async ({ data }) => {
  if (data.type === "reply") {
    const waiter = pending.get(data.call);
    if (!waiter) return;
    pending.delete(data.call);
    if (data.error) waiter.reject(new Error(data.error));
    else waiter.resolve(data.result);
    return;
  }
  if (data.type !== "run") return;
  try {
    const AsyncFunction = Object.getPrototypeOf(async function() {}).constructor;
    const value = await new AsyncFunction(data.code)();
    postMessage({ type: "done", status: "ok", value: value === undefined ? null : value });
  } catch (error) {
    postMessage({ type: "done", status: "error", error: String(error) });
  }
};
`;
const url = URL.createObjectURL(new Blob([workerSource], { type: "application/javascript" }));
const worker = new Worker(url, {
  type: "module",
  deno: { permissions: "none" },
});
worker.onmessage = ({ data }) => send(data);
worker.onerror = (event) => {
  event.preventDefault();
  send({ type: "done", status: "error", error: event.message });
};
let buffer = "";
const decoder = new TextDecoder();
for await (const chunk of Deno.stdin.readable) {
  buffer += decoder.decode(chunk, { stream: true });
  let newline;
  while ((newline = buffer.indexOf("\n")) !== -1) {
    const line = buffer.slice(0, newline);
    buffer = buffer.slice(newline + 1);
    worker.postMessage(JSON.parse(line));
  }
}
worker.terminate();
