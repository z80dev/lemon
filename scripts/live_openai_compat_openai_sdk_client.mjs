#!/usr/bin/env node

import { createHash } from "node:crypto";
import { createRequire } from "node:module";
import path from "node:path";

const requireFromCwd = createRequire(path.join(process.cwd(), "package.json"));
const { default: OpenAI } = await import(requireFromCwd.resolve("openai"));

const rootURL = requiredEnv("LEMON_OPENAI_COMPAT_BASE_URL").replace(/\/+$/, "");
const baseURL = rootURL.endsWith("/v1") ? rootURL : `${rootURL}/v1`;
const apiKey = requiredEnv("LEMON_OPENAI_COMPAT_API_TOKEN");
const model = process.env.LEMON_OPENAI_COMPAT_MODEL || "zai:glm-5-turbo";
const checkMode = process.env.LEMON_OPENAI_COMPAT_CHECKS || "default";
const previousResponseId =
  process.env.LEMON_OPENAI_COMPAT_PREVIOUS_RESPONSE_ID || "resp_run_stored_smoke";

const client = new OpenAI({ apiKey, baseURL });
const checks = [];

if (checkMode === "vision") {
  await check("responses_vision", async () => {
    const imageBase64 = requiredEnv("LEMON_OPENAI_COMPAT_IMAGE_BASE64");
    const response = await client.responses.create({
      model,
      wait: true,
      timeout_ms: 120000,
      metadata: { session_key: "agent:default:openai-vision-sdk-smoke" },
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
  await check("model_retrieve", async () => {
    const list = await client.models.list();
    const first = list.data?.[0];

    if (!first?.id) {
      throw new Error("model list returned no id");
    }

    const modelObject = await client.models.retrieve(first.id);
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

  await check("chat_completions_wait", async () => {
    const response = await client.chat.completions.create({
      model,
      messages: [{ role: "user", content: "sdk client hello" }],
      wait: true,
      timeout_ms: 1000,
    });

    requireValue(response.choices?.[0]?.finish_reason, "stop", "finish_reason");
    requireValue(response.lemon?.status, "completed", "lemon.status");
    return { answer_hash: hash(response.choices?.[0]?.message?.content || "") };
  });

  await check("chat_completions_stream", async () => {
    const stream = await client.chat.completions.create({
      model,
      messages: [{ role: "user", content: "sdk client stream" }],
      stream: true,
    });

    let text = "";
    let chunkCount = 0;

    for await (const chunk of stream) {
      chunkCount += 1;
      text += chunk.choices?.[0]?.delta?.content || "";
    }

    if (!text.includes("stream hello")) {
      throw new Error("missing streamed delta");
    }

    return { chunk_count: chunkCount, text_hash: hash(text) };
  });

  await check("responses_continuation", async () => {
    const response = await client.responses.create({
      model,
      input: "sdk client continue",
      previous_response_id: previousResponseId,
    });

    requireValue(response.previous_response_id, previousResponseId, "previous_response_id");
    requireValue(response.lemon?.previousResponseId, previousResponseId, "lemon.previousResponseId");
  });

  await check("responses_stream", async () => {
    const stream = await client.responses.create({
      model,
      input: "sdk client response stream",
      stream: true,
    });

    let text = "";
    let eventCount = 0;

    for await (const event of stream) {
      eventCount += 1;

      if (event?.type === "response.output_text.delta") {
        text += event.delta || "";
      }
    }

    if (!text.includes("stream hello")) {
      throw new Error("missing streamed response delta");
    }

    return { event_count: eventCount, text_hash: hash(text) };
  });

  await check("responses_retrieve", async () => {
    const response = await client.responses.retrieve(previousResponseId);
    requireValue(response.status, "completed", "stored.status");
    return { output_hash: hash(JSON.stringify(response.output || [])) };
  });
}

const proof = {
  object: "lemon.openai_compat.openai_sdk_client_smoke",
  generated_at: new Date().toISOString(),
  sdk: "openai",
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
