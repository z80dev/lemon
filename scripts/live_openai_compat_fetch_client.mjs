#!/usr/bin/env node

import { createHash } from "node:crypto";

const baseUrl = requiredEnv("LEMON_OPENAI_COMPAT_BASE_URL").replace(/\/+$/, "");
const token = requiredEnv("LEMON_OPENAI_COMPAT_API_TOKEN");
const model = process.env.LEMON_OPENAI_COMPAT_MODEL || "zai:glm-5-turbo";
const checkMode = process.env.LEMON_OPENAI_COMPAT_CHECKS || "default";
const previousResponseId =
  process.env.LEMON_OPENAI_COMPAT_PREVIOUS_RESPONSE_ID || "resp_run_stored_smoke";

const checks = [];

if (checkMode === "vision") {
  await check("responses_vision", async () => {
    const imageBase64 = requiredEnv("LEMON_OPENAI_COMPAT_IMAGE_BASE64");
    const response = await postJson("/v1/responses", {
      model,
      wait: true,
      timeout_ms: 120000,
      metadata: { session_key: "agent:default:openai-vision-external-fetch-smoke" },
      input: [
        {
          type: "message",
          role: "user",
          content: [
            {
              type: "input_text",
              text: "Look at the image. Reply with exactly one lowercase color word.",
            },
            { type: "input_image", image_url: `data:image/png;base64,${imageBase64}` },
          ],
        },
      ],
    });

    requireValue(response.status, "completed", "response.status");
    requireValue(response.lemon?.ok, true, "lemon.ok");
    requireValue(response.lemon?.imageInputCount, 1, "lemon.imageInputCount");

    const answer = outputText(response);

    if (!answer || !answer.toLowerCase().includes("red")) {
      throw new Error("answer did not identify red");
    }

    return {
      response_id_hash: hash(response.id || ""),
      run_id_hash: hash(response.lemon?.runId || ""),
      answer_hash: hash(answer),
      answer_matched_red: true,
    };
  });
} else {
  await check("health_and_capabilities", async () => {
    const health = await getJson("/v1/health");
    requireValue(health.status, "ok", "health.status");

    const capabilities = await getJson("/v1/capabilities");
    requireValue(capabilities.endpoints?.chat_completions, true, "chat_completions");
    requireValue(capabilities.endpoints?.responses, true, "responses");
    requireValue(capabilities.endpoints?.image_input, "data-url-pass-through", "image_input");
  });

  await check("model_retrieve", async () => {
    const list = await getJson("/v1/models");
    const first = list.data?.[0];

    if (!first?.id) {
      throw new Error("model list returned no id");
    }

    const modelObject = await getJson(`/v1/models/${encodeURIComponent(first.id)}`);
    requireValue(modelObject.object, "model", "model.object");
    requireValue(modelObject.id, first.id, "model.id");
    requireBoolean(first.lemon?.supportsVision, "model.list.lemon.supportsVision");
    requireBoolean(modelObject.lemon?.supportsVision, "model.retrieve.lemon.supportsVision");
    requireValue(
      modelObject.lemon.supportsVision,
      first.lemon.supportsVision,
      "model.supportsVision consistency",
    );

    return { model_id_hash: hash(first.id), supports_vision: modelObject.lemon.supportsVision };
  });

  await check("chat_wait", async () => {
    const response = await postJson("/v1/chat/completions", {
      model,
      messages: [{ role: "user", content: "external client hello" }],
      wait: true,
      timeout_ms: 1000,
    });

    requireValue(response.choices?.[0]?.finish_reason, "stop", "finish_reason");
    requireValue(response.lemon?.status, "completed", "lemon.status");
    return { answer_hash: hash(response.choices?.[0]?.message?.content || "") };
  });

  await check("response_continuation", async () => {
    const response = await postJson("/v1/responses", {
      model,
      input: "external client continue",
      previous_response_id: previousResponseId,
    });

    requireValue(response.previous_response_id, previousResponseId, "previous_response_id");
    requireValue(response.lemon?.previousResponseId, previousResponseId, "lemon.previousResponseId");
  });

  await check("stored_response", async () => {
    const response = await getJson(`/v1/responses/${previousResponseId}`);
    requireValue(response.status, "completed", "stored.status");
    return { output_hash: hash(JSON.stringify(response.output || [])) };
  });

  await check("chat_stream", async () => {
    const body = await postText("/v1/chat/completions", {
      model,
      messages: [{ role: "user", content: "external client stream" }],
      stream: true,
    });

    if (!body.includes("event: lemon.tool_progress")) {
      throw new Error("missing tool progress event");
    }

    if (!body.includes("data: [DONE]")) {
      throw new Error("missing done sentinel");
    }

    if (body.includes("raw command output")) {
      throw new Error("raw tool detail leaked");
    }

    return { body_hash: hash(body) };
  });

  await check("response_stream", async () => {
    const body = await postText("/v1/responses", {
      model,
      input: "external client response stream",
      stream: true,
    });

    if (!body.includes("event: response.tool_progress")) {
      throw new Error("missing response tool progress event");
    }

    if (!body.includes("event: response.output_text.delta")) {
      throw new Error("missing response delta event");
    }

    if (!body.includes("stream hello")) {
      throw new Error("missing streamed response text");
    }

    if (!body.includes("event: response.completed")) {
      throw new Error("missing response completed event");
    }

    if (!body.includes("data: [DONE]")) {
      throw new Error("missing done sentinel");
    }

    if (body.includes("raw command output")) {
      throw new Error("raw tool detail leaked");
    }

    return { body_hash: hash(body) };
  });
}

const proof = {
  object: "lemon.openai_compat.external_fetch_client_smoke",
  generated_at: new Date().toISOString(),
  check_mode: checkMode,
  endpoint_count: checks.length,
  completed_count: checks.filter((check) => check.status === "completed").length,
  failed_count: checks.filter((check) => check.status === "failed").length,
  results: checks,
  cleanup: {
    includes_raw_api_keys: false,
    includes_raw_prompts: false,
    includes_raw_answers: false,
    includes_raw_events: false,
    includes_raw_image_bytes: false,
  },
};

console.log(JSON.stringify(proof, null, 2));
process.exitCode = proof.failed_count > 0 ? 1 : 0;

async function check(name, fn) {
  try {
    const extra = (await fn()) || {};
    checks.push({ name, status: "completed", ...extra });
  } catch (error) {
    checks.push({ name, status: "failed", reason: error.message });
  }
}

async function getJson(path) {
  return decodeJson(await request(path, { method: "GET" }));
}

async function postJson(path, body) {
  return decodeJson(await postText(path, body));
}

async function postText(path, body) {
  return request(path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function request(path, init) {
  const response = await fetch(`${baseUrl}${path}`, {
    ...init,
    headers: {
      authorization: `Bearer ${token}`,
      ...(init.headers || {}),
    },
  });

  const text = await response.text();

  if (!response.ok) {
    throw new Error(`HTTP ${response.status}: ${text.slice(0, 200)}`);
  }

  return text;
}

function decodeJson(text) {
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new Error(`invalid JSON: ${error.message}`);
  }
}

function requireValue(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(`${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

function requireBoolean(actual, label) {
  if (typeof actual !== "boolean") {
    throw new Error(`${label}: expected boolean, got ${JSON.stringify(actual)}`);
  }
}

function outputText(response) {
  for (const item of response.output || []) {
    for (const content of item.content || []) {
      if (content?.type === "output_text" && typeof content.text === "string") {
        return content.text;
      }
    }
  }
}

function hash(value) {
  return createHash("sha256").update(String(value)).digest("hex").slice(0, 16);
}

function requiredEnv(name) {
  const value = process.env[name];

  if (!value) {
    throw new Error(`${name} is required`);
  }

  return value;
}
