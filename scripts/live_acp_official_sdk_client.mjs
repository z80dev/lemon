#!/usr/bin/env node

import { createHash } from "node:crypto";
import { spawn, spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { Readable, Writable } from "node:stream";

const sdkVersion = process.env.LEMON_ACP_SDK_VERSION || "0.4.5";
const proofPath =
  process.env.LEMON_ACP_OFFICIAL_SDK_PROOF_PATH ||
  join(process.cwd(), ".lemon", "proofs", "acp-official-sdk-client-latest.json");
const sdkRoot =
  process.env.LEMON_ACP_SDK_ROOT || join(process.cwd(), "tmp", "acp-official-sdk-client");

const checks = [];
const updates = [];
const clientRequests = [];

try {
  const acp = await loadSdk();
  compileBeam();
  const child = spawnACP();
  let stderr = "";

  child.stderr.on("data", (chunk) => {
    stderr += chunk.toString("utf8");
  });

  const stream = acp.ndJsonStream(
    Writable.toWeb(child.stdin),
    Readable.toWeb(child.stdout),
  );

  const connection = new acp.ClientSideConnection(
    () => ({
      async requestPermission(params) {
        clientRequests.push(summarizeClientRequest("session/request_permission", params));

        return {
          outcome: {
            outcome: "selected",
            optionId: "allow-once",
          },
        };
      },
      async sessionUpdate(params) {
        updates.push(summarizeUpdate(params));
      },
      async readTextFile(params) {
        clientRequests.push(summarizeClientRequest("fs/read_text_file", params));

        return {
          content: "official sdk editor buffer\nline two\n",
        };
      },
      async writeTextFile(params) {
        clientRequests.push(summarizeClientRequest("fs/write_text_file", params));
        return {};
      },
    }),
    stream,
  );

  let sessionId;

  await check("initialize", async () => {
    const result = await connection.initialize({
      protocolVersion: acp.PROTOCOL_VERSION,
      clientCapabilities: {
        fs: {
          readTextFile: true,
          writeTextFile: true,
        },
      },
    });

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

    return {
      sdk_version: sdkVersion,
      protocol_version: result.protocolVersion,
    };
  });

  await check("session_new", async () => {
    const result = await connection.newSession({
      cwd: process.cwd(),
      mcpServers: [],
      _meta: { lemon: { agentId: "default" } },
    });

    sessionId = result.sessionId;
    if (!sessionId) throw new Error("missing session id");
    requireValue(
      result._meta?.lemon?.clientCapabilities?.fs?.readTextFile,
      true,
      "session read text file capability",
    );
    requireValue(
      result._meta?.lemon?.clientCapabilities?.fs?.writeTextFile,
      true,
      "session write text file capability",
    );

    return { session_id_hash: hash(sessionId) };
  });

  await check("queued_prompt", async () => {
    const result = await connection.prompt({
      sessionId,
      prompt: [{ type: "text", text: "queued official sdk smoke" }],
      _meta: { lemon: { wait: false } },
    });

    requireValue(result._meta?.lemon?.status, "queued", "queued status");
    requireValue(result._meta?.lemon?.queued, true, "queued flag");

    return { run_id_hash: hash(result._meta?.lemon?.runId || "") };
  });

  await check("wait_prompt_updates", async () => {
    const result = await connection.prompt({
      sessionId,
      prompt: [{ type: "text", text: "stream official sdk smoke" }],
      _meta: { lemon: { timeoutMs: 1000 } },
    });

    requireValue(result._meta?.lemon?.status, "completed", "completed status");
    requireValue(result._meta?.lemon?.runId, "run_acp_external_stream", "stream run id");

    if (!updates.some((update) => update.session_update === "agent_message_chunk")) {
      throw new Error("missing agent update");
    }

    if (!updates.some((update) => update.session_update === "tool_call_update")) {
      throw new Error("missing tool update");
    }

    return { update_count: updates.length, run_id_hash: hash("run_acp_external_stream") };
  });

  await check("client_file_and_permission_requests", async () => {
    const before = clientRequests.length;
    const result = await connection.prompt({
      sessionId,
      prompt: [{ type: "text", text: "sdk request official smoke" }],
      _meta: { lemon: { timeoutMs: 1000 } },
    });

    requireValue(result._meta?.lemon?.status, "completed", "completed status");
    requireValue(
      result._meta?.lemon?.runId,
      "run_acp_official_sdk_client_requests",
      "client request run id",
    );

    const newRequests = clientRequests.slice(before);
    const methods = newRequests.map((request) => request.method);
    requireIncludes(methods, "session/request_permission", "permission request");
    requireIncludes(methods, "fs/read_text_file", "read text file request");
    requireIncludes(methods, "fs/write_text_file", "write text file request");

    const summaries = result._meta?.lemon?.clientRequests || [];
    if (summaries.length !== 3) throw new Error("missing client request summaries");
    const read = summaries.find((summary) => summary.method === "fs/read_text_file");
    if (!read?.contentBytes || !read?.contentHash) {
      throw new Error("missing redacted read summary");
    }

    return {
      client_request_count: newRequests.length,
      methods_hash: hash(methods.join(",")),
      read_content_hash: read.contentHash,
    };
  });

  await check("approval_bus_permission_bridge", async () => {
    const before = clientRequests.length;
    const result = await connection.prompt({
      sessionId,
      prompt: [{ type: "text", text: "approval bridge official sdk smoke" }],
      _meta: { lemon: { timeoutMs: 1000 } },
    });

    requireValue(result._meta?.lemon?.status, "completed", "completed status");
    requireValue(
      result._meta?.lemon?.runId,
      "run_acp_external_approval_bridge",
      "approval bridge run id",
    );

    const newRequests = clientRequests.slice(before);
    requireValue(newRequests.length, 1, "approval request count");
    requireValue(newRequests[0].method, "session/request_permission", "approval request method");

    const permission = (result._meta?.lemon?.clientRequests || []).find(
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

  await check("load_cancel", async () => {
    const resume = await connection.loadSession({
      sessionId,
      cwd: process.cwd(),
      mcpServers: [],
    });
    if (!resume._meta?.lemon?.sessionKey) throw new Error("missing resumed session key");

    await connection.cancel({ sessionId });

    return { session_id_hash: hash(sessionId) };
  });

  await check("unsupported_image_block", async () => {
    const next = await connection.newSession({
      cwd: process.cwd(),
      mcpServers: [],
      _meta: { lemon: { agentId: "default" } },
    });

    try {
      await connection.prompt({
        sessionId: next.sessionId,
        prompt: [{ type: "image", data: "redacted" }],
      });
    } catch (error) {
      if (error?.code !== -32602) throw error;
      return { error_code: error.code };
    }

    throw new Error("image block unexpectedly accepted");
  });

  child.stdin.end();
  await waitForExit(child);

  const proof = {
    object: "lemon.acp_official_sdk_client_smoke",
    generated_at: new Date().toISOString(),
    sdk_package: "@zed-industries/agent-client-protocol",
    sdk_version: sdkVersion,
    completed_count: checks.filter((check) => check.status === "completed").length,
    failed_count: checks.filter((check) => check.status === "failed").length,
    update_count: updates.length,
    client_request_count: clientRequests.length,
    stderr_hash: hash(stderr),
    results: checks,
    cleanup: cleanup(),
  };

  writeProof(proof);
  console.log(JSON.stringify(proof, null, 2));
  process.exitCode = proof.failed_count > 0 ? 1 : 0;
} catch (error) {
  const proof = {
    object: "lemon.acp_official_sdk_client_smoke",
    generated_at: new Date().toISOString(),
    sdk_package: "@zed-industries/agent-client-protocol",
    sdk_version: sdkVersion,
    completed_count: checks.filter((check) => check.status === "completed").length,
    failed_count: checks.filter((check) => check.status === "failed").length + 1,
    results: [
      ...checks,
      {
        name: "harness_error",
        status: "failed",
        reason_kind: error.constructor?.name || "Error",
        reason_hash: hash(error.message || String(error)),
      },
    ],
    cleanup: cleanup(),
  };

  writeProof(proof);
  console.log(JSON.stringify(proof, null, 2));
  process.exitCode = 1;
}

async function loadSdk() {
  const modulePath = join(
    sdkRoot,
    "node_modules",
    "@zed-industries",
    "agent-client-protocol",
    "dist",
    "acp.js",
  );

  const install = spawnSync(
    "npm",
    [
      "install",
      "--silent",
      "--package-lock=false",
      "--prefix",
      sdkRoot,
      `@zed-industries/agent-client-protocol@${sdkVersion}`,
    ],
    { cwd: process.cwd(), encoding: "utf8" },
  );

  if (install.status !== 0) {
    throw new Error(`npm install failed: ${install.stderr || install.stdout}`);
  }

  return import(pathToFileURL(modulePath).href);
}

function spawnACP() {
  const command = process.env.LEMON_ACP_STDIO_COMMAND || "mix";
  const args = process.env.LEMON_ACP_STDIO_COMMAND
    ? []
    : ["run", "--no-compile", "--no-start", "scripts/lemon_acp_stdio.exs"];

  return spawn(command, args, {
    cwd: process.cwd(),
    stdio: ["pipe", "pipe", "pipe"],
    env: {
      ...process.env,
      LEMON_ACP_STDIO_FAKE_RUNTIME: "1",
      MIX_ENV: process.env.MIX_ENV || "test",
      LEMON_CONTROL_PLANE_PORT: "0",
      LEMON_GATEWAY_HEALTH_PORT: "0",
      LEMON_ROUTER_HEALTH_PORT: "0",
      LEMON_WEB_PORT: "0",
      LEMON_SIM_UI_PORT: "0",
    },
  });
}

function compileBeam() {
  if (process.env.LEMON_ACP_SKIP_COMPILE === "1") return;

  const result = spawnSync("mix", ["compile"], {
    cwd: process.cwd(),
    env: {
      ...process.env,
      MIX_ENV: process.env.MIX_ENV || "test",
    },
    stdio: "inherit",
  });

  if (result.status !== 0) {
    throw new Error("mix compile failed");
  }
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

function summarizeUpdate(params) {
  const update = params?.update || {};

  return {
    session_update: update.sessionUpdate,
    kind: update.kind,
    status: update.status,
    text_hash: hash(update.content?.text || ""),
    tool_call_id_hash: hash(update.toolCallId || ""),
  };
}

function summarizeClientRequest(method, params) {
  return {
    method,
    path_hash: hash(params?.path || ""),
    has_content: typeof params?.content === "string",
    title_hash: hash(params?.toolCall?.title || ""),
    option_count: Array.isArray(params?.options) ? params.options.length : 0,
  };
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

function writeProof(proof) {
  mkdirSync(dirname(proofPath), { recursive: true });
  writeFileSync(proofPath, `${JSON.stringify(proof, null, 2)}\n`);

  const archivePath = proofPath.replace(/-latest\.json$/, `-${Date.now()}.json`);
  if (archivePath !== proofPath) {
    writeFileSync(archivePath, `${JSON.stringify(proof, null, 2)}\n`);
  }
}

function cleanup() {
  return {
    includes_raw_api_keys: false,
    includes_raw_prompts: false,
    includes_raw_answers: false,
    includes_raw_events: false,
    includes_raw_session_ids: false,
    includes_child_stderr: false,
    includes_raw_file_contents: false,
    includes_raw_file_paths: false,
  };
}

function waitForExit(child) {
  return new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("exit", (code) => {
      if (code === 0 || code === null) {
        resolve();
      } else {
        reject(new Error(`ACP child exited ${code}`));
      }
    });
  });
}

function hash(value) {
  return createHash("sha256").update(String(value)).digest("hex").slice(0, 16);
}
