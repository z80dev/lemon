#!/usr/bin/env node

import { createHash } from "node:crypto";
import { createInterface } from "node:readline";
import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

const proofPath =
  process.env.LEMON_ACP_STDIO_EXTERNAL_PROOF_PATH ||
  join(process.cwd(), ".lemon", "proofs", "acp-stdio-external-client-latest.json");

const child = spawnACP();
const checks = [];
const pending = new Map();
const updates = [];
const clientRequests = [];
let parseErrorResolver;
let nextId = 1;

createInterface({ input: child.stdout }).on("line", (line) => {
  const message = parseJsonLine(line);
  if (!message) return;

  if (message.method === "session/request_permission") {
    clientRequests.push(summarizeClientRequest(message));
    respond(message.id, {
      outcome: { outcome: "selected", optionId: "allow-once" },
    });
    return;
  }

  if (message.method === "fs/read_text_file") {
    clientRequests.push(summarizeClientRequest(message));
    respond(message.id, { content: "unsaved editor buffer\nline two\n" });
    return;
  }

  if (message.method === "fs/write_text_file") {
    clientRequests.push(summarizeClientRequest(message));
    respond(message.id, null);
    return;
  }

  if (message.method === "fs/delete_file") {
    clientRequests.push(summarizeClientRequest(message));
    respond(message.id, null);
    return;
  }

  if (message.method === "fs/rename_file") {
    clientRequests.push(summarizeClientRequest(message));
    respond(message.id, null);
    return;
  }

  if (message.method === "session/update") {
    updates.push(message);
    return;
  }

  if (message.id === null && message.error?.code === -32700 && parseErrorResolver) {
    parseErrorResolver(message);
    parseErrorResolver = undefined;
    return;
  }

  const resolver = pending.get(message.id);
  if (resolver) {
    pending.delete(message.id);
    resolver(message);
  }
});

let stderr = "";
child.stderr.on("data", (chunk) => {
  stderr += chunk.toString("utf8");
});

try {
  await check("initialize", async () => {
    const response = await request("initialize", {
      protocolVersion: "1",
      clientCapabilities: {
        fs: {
          readTextFile: true,
          writeTextFile: true,
          deleteFile: true,
          renameFile: true,
        },
      },
    });
    const result = response.result;
    requireValue(result.agentInfo?.name, "Lemon", "agent name");
    requireValue(result.agentCapabilities?.promptCapabilities?.image, false, "image capability");
    requireValue(result._meta?.lemon?.beamSupervisedRuns, true, "beam supervised runs");
    requireValue(
      result._meta?.lemon?.clientCapabilities?.fs?.readTextFile,
      true,
      "read text file capability",
    );
    requireValue(
      result._meta?.lemon?.clientCapabilities?.fs?.writeTextFile,
      true,
      "write text file capability",
    );
    requireValue(
      result._meta?.lemon?.clientCapabilities?.fs?.deleteFile,
      true,
      "delete file capability",
    );
    requireValue(
      result._meta?.lemon?.clientCapabilities?.fs?.renameFile,
      true,
      "rename file capability",
    );
    return { protocol_version: result.protocolVersion };
  });

  let sessionId;

  await check("session_new", async () => {
    const response = await request("session/new", {
      cwd: process.cwd(),
      mcpServers: [],
      _meta: { lemon: { agentId: "default" } },
    });
    sessionId = response.result.sessionId;
    if (!sessionId) throw new Error("missing session id");
    requireValue(
      response.result._meta?.lemon?.clientCapabilities?.fs?.readTextFile,
      true,
      "session read text file capability",
    );
    requireValue(
      response.result._meta?.lemon?.clientCapabilities?.fs?.writeTextFile,
      true,
      "session write text file capability",
    );
    requireValue(
      response.result._meta?.lemon?.clientCapabilities?.fs?.deleteFile,
      true,
      "session delete file capability",
    );
    requireValue(
      response.result._meta?.lemon?.clientCapabilities?.fs?.renameFile,
      true,
      "session rename file capability",
    );
    return { session_id_hash: hash(sessionId) };
  });

  await check("queued_prompt", async () => {
    const response = await request("session/prompt", {
      sessionId,
      prompt: [{ type: "text", text: "queued external smoke" }],
      _meta: { lemon: { wait: false } },
    });
    requireValue(response.result._meta?.lemon?.status, "queued", "queued status");
    requireValue(response.result._meta?.lemon?.queued, true, "queued flag");
    return { run_id_hash: hash(response.result._meta?.lemon?.runId || "") };
  });

  await check("wait_prompt_updates", async () => {
    const response = await request("session/prompt", {
      sessionId,
      prompt: [{ type: "text", text: "stream external smoke" }],
      _meta: { lemon: { timeoutMs: 1000 } },
    });
    requireValue(response.result._meta?.lemon?.status, "completed", "completed status");
    requireValue(response.result._meta?.lemon?.runId, "run_acp_external_stream", "stream run id");

    const agentUpdate = updates.some(
      (message) => message.params?.update?.sessionUpdate === "agent_message_chunk",
    );
    const toolUpdate = updates.some(
      (message) =>
        message.params?.update?.sessionUpdate === "tool_call_update" &&
        message.params?.update?.kind === "execute",
    );

    if (!agentUpdate) throw new Error("missing agent update");
    if (!toolUpdate) throw new Error("missing tool update");

    return { update_count: updates.length, run_id_hash: hash("run_acp_external_stream") };
  });

  await check("client_file_and_permission_requests", async () => {
    const response = await request("session/prompt", {
      sessionId,
      prompt: [{ type: "text", text: "client request external smoke" }],
      _meta: { lemon: { timeoutMs: 1000 } },
    });

    requireValue(response.result._meta?.lemon?.status, "completed", "completed status");
    requireValue(
      response.result._meta?.lemon?.runId,
      "run_acp_external_client_requests",
      "client request run id",
    );

    const methods = clientRequests.map((request) => request.method);
    requireIncludes(methods, "session/request_permission", "permission request");
    requireIncludes(methods, "fs/read_text_file", "read text file request");
    requireIncludes(methods, "fs/write_text_file", "write text file request");
    requireIncludes(methods, "fs/delete_file", "delete file request");
    requireIncludes(methods, "fs/rename_file", "rename file request");

    const summaries = response.result._meta?.lemon?.clientRequests || [];
    if (summaries.length !== 5) throw new Error("missing client request summaries");
    const read = summaries.find((summary) => summary.method === "fs/read_text_file");
    if (!read?.contentBytes || !read?.contentHash) {
      throw new Error("missing redacted read summary");
    }

    return {
      client_request_count: clientRequests.length,
      methods_hash: hash(methods.join(",")),
      read_content_hash: read.contentHash,
    };
  });

  await check("approval_bus_permission_bridge", async () => {
    const before = clientRequests.length;
    const response = await request("session/prompt", {
      sessionId,
      prompt: [{ type: "text", text: "approval bridge external smoke" }],
      _meta: { lemon: { timeoutMs: 1000 } },
    });

    requireValue(response.result._meta?.lemon?.status, "completed", "completed status");
    requireValue(
      response.result._meta?.lemon?.runId,
      "run_acp_external_approval_bridge",
      "approval bridge run id",
    );

    const newRequests = clientRequests.slice(before);
    requireValue(newRequests.length, 1, "approval request count");
    requireValue(newRequests[0].method, "session/request_permission", "approval request method");

    const summaries = response.result._meta?.lemon?.clientRequests || [];
    const permission = summaries.find(
      (summary) => summary.method === "session/request_permission",
    );
    if (!permission) throw new Error("missing permission summary");
    requireValue(permission.outcome, "selected", "approval outcome");
    requireValue(permission.optionId, "allow-once", "approval option");

    return {
      client_request_count: newRequests.length,
      approval_method_hash: hash(newRequests[0].method),
    };
  });

  await check("list_resume_close", async () => {
    const list = await request("session/list", { cwd: process.cwd() });
    if (!list.result.sessions?.some((session) => session.sessionId === sessionId)) {
      throw new Error("missing listed session");
    }

    const resume = await request("session/resume", {
      sessionId,
      cwd: process.cwd(),
      mcpServers: [],
    });
    if (!resume.result._meta?.lemon?.sessionKey) throw new Error("missing resumed session key");

    const close = await request("session/close", { sessionId });
    requireValue(JSON.stringify(close.result), "{}", "close result");
    return { session_id_hash: hash(sessionId) };
  });

  await check("unsupported_image_block", async () => {
    const next = await request("session/new", {
      cwd: process.cwd(),
      mcpServers: [],
      _meta: { lemon: { agentId: "default" } },
    });
    const response = await request("session/prompt", {
      sessionId: next.result.sessionId,
      prompt: [{ type: "image", data: "redacted" }],
    });
    requireValue(response.error?.code, -32602, "image rejection code");
  });

  await check("parse_error", async () => {
    const response = await parseError();
    requireValue(response.error?.code, -32700, "parse error code");
  });
} finally {
  child.stdin.end();
}

await waitForExit(child);

const proof = {
  object: "lemon.acp_stdio_external_client_smoke",
  generated_at: new Date().toISOString(),
  completed_count: checks.filter((check) => check.status === "completed").length,
  failed_count: checks.filter((check) => check.status === "failed").length,
  update_count: updates.length,
  client_request_count: clientRequests.length,
  stderr_hash: hash(stderr),
  results: checks,
  cleanup: {
    includes_raw_api_keys: false,
    includes_raw_prompts: false,
    includes_raw_answers: false,
    includes_raw_events: false,
    includes_raw_session_ids: false,
    includes_child_stderr: false,
    includes_raw_file_contents: false,
    includes_raw_file_paths: false,
  },
};

writeProof(proof);
console.log(JSON.stringify(proof, null, 2));
process.exitCode = proof.failed_count > 0 ? 1 : 0;

function spawnACP() {
  const command = process.env.LEMON_ACP_STDIO_COMMAND || "mix";
  const args = process.env.LEMON_ACP_STDIO_COMMAND
    ? []
    : ["run", "scripts/lemon_acp_stdio.exs"];

  return spawn(command, args, {
    cwd: process.cwd(),
    stdio: ["pipe", "pipe", "pipe"],
    env: {
      ...process.env,
      LEMON_ACP_STDIO_FAKE_RUNTIME: "1",
      LEMON_CONTROL_PLANE_PORT: "0",
      LEMON_GATEWAY_HEALTH_PORT: "0",
      LEMON_ROUTER_HEALTH_PORT: "0",
      LEMON_WEB_PORT: "0",
      LEMON_SIM_UI_PORT: "0",
    },
  });
}

async function check(name, fn) {
  try {
    const details = (await fn()) || {};
    checks.push({ name, status: "completed", ...details });
  } catch (error) {
    checks.push({
      name,
      status: "failed",
      reason_kind: error.constructor?.name || "Error",
      reason_hash: hash(error.message || String(error)),
    });
  }
}

function request(method, params) {
  const id = `req_${nextId++}`;
  child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);

  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`timeout waiting for ${method}`));
    }, 10_000);

    pending.set(id, (message) => {
      clearTimeout(timer);
      resolve(message);
    });
  });
}

function respond(id, result) {
  child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`);
}

function parseError() {
  child.stdin.write("{not-json}\n");

  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      parseErrorResolver = undefined;
      reject(new Error("timeout waiting for parse error"));
    }, 10_000);

    parseErrorResolver = (message) => {
      clearTimeout(timer);
      resolve(message);
    };
  });
}

function parseJsonLine(line) {
  try {
    return JSON.parse(line);
  } catch {
    return null;
  }
}

function requireValue(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(`${label} mismatch`);
  }
}

function requireIncludes(values, expected, label) {
  if (!values.includes(expected)) {
    throw new Error(`missing ${label}`);
  }
}

function summarizeClientRequest(message) {
  return {
    method: message.method,
    id_hash: hash(message.id || ""),
    session_id_hash: hash(message.params?.sessionId || ""),
    path_hash: hash(message.params?.path || ""),
    has_content: typeof message.params?.content === "string",
    option_count: Array.isArray(message.params?.options) ? message.params.options.length : 0,
  };
}

function waitForExit(process) {
  return new Promise((resolve) => {
    process.on("exit", resolve);
  });
}

function writeProof(proof) {
  mkdirSync(dirname(proofPath), { recursive: true });
  writeFileSync(proofPath, `${JSON.stringify(proof, null, 2)}\n`);

  const archive = join(
    dirname(proofPath),
    `acp-stdio-external-client-${new Date().toISOString().replace(/[-:]/g, "").replace(/\..+/, "Z")}.json`,
  );
  writeFileSync(archive, `${JSON.stringify(proof, null, 2)}\n`);
}

function hash(value) {
  return createHash("sha256").update(String(value)).digest("hex").slice(0, 16);
}
