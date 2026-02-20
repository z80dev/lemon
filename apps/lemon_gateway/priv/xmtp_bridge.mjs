#!/usr/bin/env node

import readline from "node:readline";

const state = {
  connected: false,
  mock: true,
  sdkName: null,
  client: null,
  identity: { wallet_address: null, inbox_id: null },
  connectConfig: {},
  seenMessageKeys: new Set(),
  conversationCache: new Map(),
};

function emit(event) {
  const line = JSON.stringify(event);
  process.stdout.write(line + "\n");
}

function emitError(message, extra = {}) {
  emit({ type: "error", message, ...extra });
}

function normalizeWallet(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim().toLowerCase();
  if (trimmed === "") return null;

  const withPrefix = trimmed.startsWith("0x") ? trimmed : `0x${trimmed}`;
  if (!/^0x[0-9a-f]{40}$/.test(withPrefix)) return null;

  return withPrefix;
}

function normalizeInboxId(value) {
  const text = normalizeText(value);
  return text ? text.toLowerCase() : null;
}

function normalizeText(value) {
  if (typeof value === "string") {
    const trimmed = value.trim();
    return trimmed === "" ? null : trimmed;
  }

  if (value == null) return null;

  if (typeof value === "number" || typeof value === "boolean") {
    return String(value);
  }

  return null;
}

function normalizeConversationId(value) {
  const text = normalizeText(value);
  return text || "unknown";
}

function inferContentType(message, content) {
  const candidates = [
    message?.content_type,
    message?.contentType,
    message?.kind,
    message?.type,
    content?.type,
    content?.kind,
  ];

  const found = candidates.find((v) => typeof v === "string" && v.trim() !== "");
  const normalized = (found || "text").toLowerCase();

  if (normalized.includes("reply")) return "reply";
  if (normalized.includes("reaction")) return "reaction";
  if (normalized.includes("text")) return "text";
  return normalized;
}

function decodeMessageContent(content, contentType, message) {
  if (contentType === "reaction") {
    const emoji =
      normalizeText(content?.emoji) ||
      normalizeText(content?.reaction) ||
      normalizeText(message?.emoji);

    const reference =
      normalizeText(content?.reference) ||
      normalizeText(content?.target_message_id) ||
      normalizeText(message?.reply_to_message_id);

    return {
      emoji,
      reference,
      text:
        normalizeText(content?.text) ||
        normalizeText(content?.body) ||
        normalizeText(message?.text) ||
        normalizeText(message?.body),
    };
  }

  if (contentType === "reply") {
    const text =
      normalizeText(content?.text) ||
      normalizeText(content?.body) ||
      normalizeText(content?.content) ||
      normalizeText(message?.text) ||
      normalizeText(message?.body);

    const replyToMessageId =
      normalizeText(content?.reply_to_message_id) ||
      normalizeText(content?.reference) ||
      normalizeText(message?.reply_to_message_id);

    return { text, reply_to_message_id: replyToMessageId };
  }

  if (typeof content === "string") {
    return content;
  }

  if (content && typeof content === "object") {
    const text =
      normalizeText(content.text) ||
      normalizeText(content.body) ||
      normalizeText(content.content) ||
      normalizeText(message?.text) ||
      normalizeText(message?.body);

    if (text) return text;

    return safeJsonClone(content) || { unsupported_content_type: contentType };
  }

  return normalizeText(message?.text) || normalizeText(message?.body) || null;
}

function isGroupConversation(conversation) {
  const values = [conversation?.is_group, conversation?.isGroup, conversation?.type];

  return values.some((value) => {
    if (typeof value === "boolean") return value;
    if (typeof value === "number") return value !== 0;
    if (typeof value === "string") {
      const normalized = value.trim().toLowerCase();
      return normalized === "group" || normalized === "true" || normalized === "1";
    }

    return false;
  });
}

function conversationGroupId(conversation, fallbackConversationId) {
  return (
    normalizeText(conversation?.group_id) ||
    normalizeText(conversation?.groupId) ||
    (isGroupConversation(conversation) ? fallbackConversationId : null)
  );
}

function conversationId(conversation) {
  return normalizeConversationId(conversation?.id || conversation?.conversation_id || conversation?.topic);
}

function messageId(message) {
  return normalizeText(message?.id) || normalizeText(message?.message_id) || null;
}

function senderWalletAddress(message) {
  return (
    normalizeWallet(message?.sender_address) ||
    normalizeWallet(message?.senderAddress) ||
    normalizeWallet(message?.sender_wallet) ||
    normalizeWallet(message?.senderWallet) ||
    normalizeWallet(message?.sender?.address) ||
    normalizeWallet(message?.sender?.walletAddress) ||
    normalizeWallet(message?.sender?.wallet_address) ||
    null
  );
}

function senderInboxId(message) {
  return (
    normalizeInboxId(message?.sender_inbox_id) ||
    normalizeInboxId(message?.senderInboxId) ||
    normalizeInboxId(message?.sender?.inbox_id) ||
    normalizeInboxId(message?.sender?.inboxId) ||
    null
  );
}

function senderIdentity(message) {
  return {
    wallet_address: senderWalletAddress(message),
    inbox_id: senderInboxId(message),
  };
}

function messageUniqueKey(conversationIdValue, message) {
  const id = messageId(message);
  if (id) {
    return `${conversationIdValue}:${id}`;
  }

  const createdAt = normalizeText(message?.sent_at_ns) || normalizeText(message?.sentAtNs) || "unknown_ts";
  const content = normalizeText(message?.text) || normalizeText(message?.body) || "unknown_content";
  return `${conversationIdValue}:${createdAt}:${content}`;
}

function safeJsonClone(value) {
  try {
    return JSON.parse(JSON.stringify(value));
  } catch (_error) {
    return null;
  }
}

async function loadXmtpSdk() {
  const candidates = ["@xmtp/node-sdk", "@xmtp/xmtp-js"];
  const failures = [];

  for (const name of candidates) {
    try {
      const module = await import(name);
      return { ok: true, name, module };
    } catch (error) {
      failures.push({ name, message: error?.message || String(error) });
    }
  }

  return { ok: false, failures };
}

function buildClientOptions(connectCommand) {
  const options = {};

  const env = normalizeText(connectCommand.env);
  if (env) options.env = env;

  const dbPath = normalizeText(connectCommand.db_path);
  if (dbPath) options.dbPath = dbPath;

  const inboxId = normalizeText(connectCommand.inbox_id);
  if (inboxId) options.inboxId = inboxId;

  return options;
}

function walletIdentityFromClient(client) {
  return (
    normalizeWallet(client?.walletAddress) ||
    normalizeWallet(client?.wallet_address) ||
    normalizeWallet(client?.address) ||
    normalizeWallet(client?.account?.address) ||
    normalizeWallet(client?.accountAddress) ||
    null
  );
}

function inboxIdentityFromClient(client) {
  return (
    normalizeInboxId(client?.inboxId) ||
    normalizeInboxId(client?.inbox_id) ||
    normalizeInboxId(client?.account?.inboxId) ||
    normalizeInboxId(client?.account?.inbox_id) ||
    null
  );
}

function resolveIdentity(connectCommand, client = null) {
  return {
    wallet_address: normalizeWallet(connectCommand?.wallet_address) || walletIdentityFromClient(client),
    inbox_id: normalizeInboxId(connectCommand?.inbox_id) || inboxIdentityFromClient(client),
  };
}

function isSelfAuthoredMessage(message) {
  const own = state.identity || {};
  const sender = senderIdentity(message);

  if (own.wallet_address && sender.wallet_address && own.wallet_address === sender.wallet_address) {
    return true;
  }

  if (own.inbox_id && sender.inbox_id && own.inbox_id === sender.inbox_id) {
    return true;
  }

  return false;
}

function maybePrivateKey(connectCommand) {
  return (
    normalizeText(connectCommand.wallet_key) ||
    normalizeText(connectCommand.private_key) ||
    normalizeText(connectCommand.signer_private_key)
  );
}

async function createClient(moduleName, sdkModule, connectCommand) {
  const clientApi = sdkModule?.Client || sdkModule?.client || sdkModule;

  if (!clientApi) {
    throw new Error(`XMTP SDK (${moduleName}) does not expose a Client API`);
  }

  const createFn = clientApi.create;
  if (typeof createFn !== "function") {
    throw new Error(`XMTP SDK (${moduleName}) Client.create is not available`);
  }

  const options = buildClientOptions(connectCommand);
  const privateKey = maybePrivateKey(connectCommand);

  const attempts = [];

  if (privateKey) {
    attempts.push([privateKey, options]);
    attempts.push([privateKey]);
  }

  attempts.push([options]);
  attempts.push([]);

  let lastError = null;

  for (const args of attempts) {
    try {
      const client = await createFn(...args);
      if (client) return client;
    } catch (error) {
      lastError = error;
    }
  }

  throw new Error(
    `XMTP client initialization failed${lastError ? `: ${lastError.message || String(lastError)}` : ""}`,
  );
}

async function listConversations(client) {
  if (!client) return [];

  const api = client.conversations || client;

  if (typeof api.list === "function") {
    const result = await api.list();
    return Array.isArray(result) ? result : [];
  }

  if (typeof client.listConversations === "function") {
    const result = await client.listConversations();
    return Array.isArray(result) ? result : [];
  }

  return [];
}

async function listMessages(conversation) {
  if (!conversation) return [];

  if (typeof conversation.messages === "function") {
    const result = await conversation.messages();
    return Array.isArray(result) ? result : [];
  }

  if (typeof conversation.listMessages === "function") {
    const result = await conversation.listMessages();
    return Array.isArray(result) ? result : [];
  }

  if (Array.isArray(conversation.messages)) {
    return conversation.messages;
  }

  return [];
}

async function resolveConversationById(client, id) {
  if (state.conversationCache.has(id)) {
    return state.conversationCache.get(id);
  }

  const conversations = await listConversations(client);

  for (const conversation of conversations) {
    const cid = conversationId(conversation);
    state.conversationCache.set(cid, conversation);
  }

  return state.conversationCache.get(id) || null;
}

async function sendToConversation(client, conversation, text) {
  if (conversation && typeof conversation.send === "function") {
    return conversation.send(text);
  }

  if (client && typeof client.send === "function") {
    return client.send(conversationId(conversation), text);
  }

  throw new Error("No XMTP send API available on client/conversation");
}

async function handleConnect(command) {
  state.connectConfig = { ...command };
  state.connected = false;
  state.client = null;
  state.conversationCache.clear();
  state.identity = resolveIdentity(command, null);

  const walletAddress = state.identity.wallet_address;
  const inboxId = state.identity.inbox_id;
  const forceMock = command.mock_mode === true || command.mock_mode === "true";

  if (forceMock) {
    state.mock = true;
    state.connected = true;

    emit({
      type: "connected",
      mode: "mock",
      wallet_address: walletAddress,
      inbox_id: inboxId,
      reason: "mock_mode_forced",
    });

    return;
  }

  const sdkResult = await loadXmtpSdk();

  if (!sdkResult.ok) {
    state.mock = true;
    state.connected = true;

    emitError("XMTP SDK unavailable; running in mock mode", {
      code: "sdk_unavailable",
      details: sdkResult.failures,
    });

    emit({
      type: "connected",
      mode: "mock",
      wallet_address: walletAddress,
      inbox_id: inboxId,
      reason: "sdk_unavailable",
    });

    return;
  }

  try {
    const client = await createClient(sdkResult.name, sdkResult.module, command);
    const liveIdentity = resolveIdentity(command, client);

    if (!liveIdentity.wallet_address && !liveIdentity.inbox_id) {
      state.mock = true;
      state.sdkName = sdkResult.name;
      state.client = null;
      state.connected = true;
      state.identity = resolveIdentity(command, null);

      emitError("XMTP live identity unavailable; running in mock mode", {
        code: "identity_unavailable",
        sdk: sdkResult.name,
      });

      emit({
        type: "connected",
        mode: "mock",
        wallet_address: state.identity.wallet_address,
        inbox_id: state.identity.inbox_id,
        reason: "identity_unavailable",
        sdk: sdkResult.name,
      });

      return;
    }

    state.mock = false;
    state.sdkName = sdkResult.name;
    state.client = client;
    state.connected = true;
    state.identity = liveIdentity;

    emit({
      type: "connected",
      mode: "live",
      wallet_address: state.identity.wallet_address,
      inbox_id: state.identity.inbox_id,
      sdk: sdkResult.name,
    });
  } catch (error) {
    state.mock = true;
    state.connected = true;
    state.identity = resolveIdentity(command, null);

    emitError("XMTP client initialization failed; running in mock mode", {
      code: "client_init_failed",
      detail: error?.message || String(error),
      sdk: sdkResult.name,
    });

    emit({
      type: "connected",
      mode: "mock",
      wallet_address: walletAddress,
      inbox_id: inboxId,
      reason: "client_init_failed",
      sdk: sdkResult.name,
    });
  }
}

async function handlePoll() {
  if (!state.connected) {
    emitError("poll requested before connect", { code: "not_connected" });
    return;
  }

  if (state.mock || !state.client) {
    return;
  }

  try {
    const conversations = await listConversations(state.client);

    for (const conversation of conversations) {
      const cid = conversationId(conversation);
      state.conversationCache.set(cid, conversation);

      const messages = await listMessages(conversation);
      const isGroup = isGroupConversation(conversation);
      const groupId = conversationGroupId(conversation, cid);

      for (const message of messages) {
        const dedupeKey = messageUniqueKey(cid, message);

        if (state.seenMessageKeys.has(dedupeKey)) {
          continue;
        }

        state.seenMessageKeys.add(dedupeKey);

        if (isSelfAuthoredMessage(message)) {
          continue;
        }

        const rawContent = message?.content ?? message?.body ?? message?.text ?? null;
        const contentType = inferContentType(message, rawContent);
        const payload = decodeMessageContent(rawContent, contentType, message);
        const sender = senderIdentity(message);

        emit({
          type: "message",
          conversation_id: cid,
          message_id: messageId(message),
          sender_address: sender.wallet_address,
          sender_inbox_id: sender.inbox_id,
          content_type: contentType,
          content: payload,
          is_group: isGroup,
          group_id: groupId,
        });
      }
    }
  } catch (error) {
    emitError("XMTP poll failed", {
      code: "poll_failed",
      detail: error?.message || String(error),
    });
  }
}

async function handleSend(command) {
  const conversationIdValue = normalizeConversationId(command.conversation_id);
  const content = normalizeText(command.content) || normalizeText(command.text) || "";

  if (!state.connected) {
    emitError("send requested before connect", {
      code: "not_connected",
      conversation_id: conversationIdValue,
    });
    return;
  }

  if (state.mock || !state.client) {
    emitError("XMTP SDK unavailable; mock send no-op", {
      code: "mock_send",
      conversation_id: conversationIdValue,
    });

    emit({
      type: "sent",
      mock: true,
      conversation_id: conversationIdValue,
      request_id: command.request_id || null,
    });

    return;
  }

  try {
    const conversation = await resolveConversationById(state.client, conversationIdValue);

    if (!conversation) {
      emitError("XMTP conversation not found", {
        code: "conversation_not_found",
        conversation_id: conversationIdValue,
      });
      return;
    }

    const sendResult = await sendToConversation(state.client, conversation, content);

    emit({
      type: "sent",
      mock: false,
      conversation_id: conversationIdValue,
      request_id: command.request_id || null,
      message_id: normalizeText(sendResult?.id) || null,
    });
  } catch (error) {
    emitError("XMTP send failed", {
      code: "send_failed",
      conversation_id: conversationIdValue,
      detail: error?.message || String(error),
    });
  }
}

async function handleCommand(command) {
  const op = normalizeText(command?.op);

  if (!op) {
    emitError("command missing op", { code: "invalid_command" });
    return;
  }

  if (op === "connect") {
    await handleConnect(command);
    return;
  }

  if (op === "poll") {
    await handlePoll();
    return;
  }

  if (op === "send") {
    await handleSend(command);
    return;
  }

  emitError("unknown command op", { code: "unknown_op", op });
}

async function handleLine(line) {
  const trimmed = line.trim();
  if (trimmed === "") return;

  let command;

  try {
    command = JSON.parse(trimmed);
  } catch (_error) {
    emitError("invalid JSON command", { code: "invalid_json", line: trimmed });
    return;
  }

  if (!command || typeof command !== "object" || Array.isArray(command)) {
    emitError("command must be a JSON object", { code: "invalid_command" });
    return;
  }

  try {
    await handleCommand(command);
  } catch (error) {
    emitError("bridge command handling failed", {
      code: "command_failed",
      detail: error?.message || String(error),
    });
  }
}

const rl = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
  terminal: false,
});

rl.on("line", (line) => {
  handleLine(line).catch((error) => {
    emitError("bridge runtime error", {
      code: "runtime_error",
      detail: error?.message || String(error),
    });
  });
});

rl.on("close", () => {
  process.exit(0);
});
