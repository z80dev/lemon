#!/usr/bin/env node

import readline from "node:readline";
import os from "node:os";

const state = {
  connected: false,
  mock: true,
  sdkName: null,
  client: null,
  identity: { wallet_address: null, inbox_id: null },
  connectConfig: {},
  seenMessageKeys: new Set(),
  seenMessageOrder: [],
  conversationCache: new Map(),
  inboxWalletCache: new Map(),
  lastNetworkSyncAtMs: 0,
};

const MAX_SEEN_MESSAGE_KEYS = 5000;
const ETH_IDENTIFIER_KIND = 0;
const CONSENT_UNKNOWN = 0;
const CONSENT_ALLOWED = 1;
const CONSENT_DENIED = 2;
const GROUP_MESSAGE_KIND_APPLICATION = 0;
const ALL_CONSENT_STATES = [CONSENT_UNKNOWN, CONSENT_ALLOWED, CONSENT_DENIED];
const SYNC_ALL_INTERVAL_MS = 15_000;
let viemSignerUtilsPromise = null;

function emit(event) {
  const line = JSON.stringify(event);
  process.stdout.write(line + "\n");
}

function rememberSeenMessageKey(key) {
  if (!key || state.seenMessageKeys.has(key)) {
    return;
  }

  state.seenMessageKeys.add(key);
  state.seenMessageOrder.push(key);

  while (state.seenMessageOrder.length > MAX_SEEN_MESSAGE_KEYS) {
    const oldest = state.seenMessageOrder.shift();
    if (oldest) {
      state.seenMessageKeys.delete(oldest);
    }
  }
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

  if (typeof value === "number" || typeof value === "boolean" || typeof value === "bigint") {
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

function isApplicationMessage(message) {
  const kind = message?.kind;

  if (typeof kind === "number") {
    return kind === GROUP_MESSAGE_KIND_APPLICATION;
  }

  if (typeof kind === "string") {
    const normalized = kind.trim().toLowerCase();
    if (normalized === "") return true;
    if (normalized.includes("membership")) return false;
    if (normalized.includes("system")) return false;
  }

  return true;
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

function walletFromIdentifier(identifier) {
  const value = normalizeText(identifier?.identifier);
  const kind = identifier?.identifierKind;

  if (!value) return null;
  if (kind !== ETH_IDENTIFIER_KIND && kind !== undefined && kind !== null) return null;

  return normalizeWallet(value);
}

async function lookupWalletAddressByInboxId(client, inboxId) {
  if (!client || !inboxId) return null;
  if (state.inboxWalletCache.has(inboxId)) return state.inboxWalletCache.get(inboxId);

  const preferences = client.preferences || client.preference;
  if (!preferences) {
    state.inboxWalletCache.set(inboxId, null);
    return null;
  }

  const tryResolvers = [];
  if (typeof preferences.getInboxStates === "function") {
    tryResolvers.push(() => preferences.getInboxStates([inboxId]));
  }
  if (typeof preferences.fetchInboxStates === "function") {
    tryResolvers.push(() => preferences.fetchInboxStates([inboxId]));
  }

  for (const resolver of tryResolvers) {
    try {
      const states = await resolver();
      const stateEntry = Array.isArray(states) ? states[0] : null;
      const identifiers = Array.isArray(stateEntry?.identifiers) ? stateEntry.identifiers : [];

      const wallet =
        identifiers.map(walletFromIdentifier).find((value) => typeof value === "string") || null;

      if (wallet) {
        state.inboxWalletCache.set(inboxId, wallet);
        return wallet;
      }
    } catch (_error) {
      // Try next resolver.
    }
  }

  state.inboxWalletCache.set(inboxId, null);
  return null;
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

function nowMs() {
  return Date.now();
}

function normalizePrivateKey(value) {
  const text = normalizeText(value);
  if (!text) return null;

  const withoutPrefix = text.startsWith("0x") ? text.slice(2) : text;
  if (!/^[0-9a-fA-F]{64}$/.test(withoutPrefix)) return null;

  return `0x${withoutPrefix}`;
}

function expandHomePath(pathValue) {
  const text = normalizeText(pathValue);
  if (!text) return null;

  if (text === "~") {
    return os.homedir();
  }

  if (text.startsWith("~/")) {
    return `${os.homedir()}${text.slice(1)}`;
  }

  return text;
}

function resolveIdentifierKind(sdkModule) {
  const candidate = sdkModule?.IdentifierKind?.Ethereum;
  return Number.isInteger(candidate) ? candidate : ETH_IDENTIFIER_KIND;
}

async function loadViemSignerUtils() {
  if (!viemSignerUtilsPromise) {
    viemSignerUtilsPromise = Promise.all([import("viem/accounts"), import("viem")]).then(
      ([accountsModule, viemModule]) => ({
        privateKeyToAccount: accountsModule.privateKeyToAccount,
        hexToBytes: viemModule.hexToBytes,
      }),
    );
  }

  return viemSignerUtilsPromise;
}

async function buildNodeSdkSigner(sdkModule, connectCommand) {
  const privateKey = normalizePrivateKey(maybePrivateKey(connectCommand));

  if (!privateKey) {
    throw new Error("wallet_key/private_key must be a valid 32-byte hex private key");
  }

  const { privateKeyToAccount, hexToBytes } = await loadViemSignerUtils();

  if (typeof privateKeyToAccount !== "function" || typeof hexToBytes !== "function") {
    throw new Error("viem signer utilities unavailable");
  }

  const account = privateKeyToAccount(privateKey);
  const configWallet = normalizeWallet(connectCommand.wallet_address);
  const derivedWallet = normalizeWallet(account?.address);
  const walletAddress = configWallet || derivedWallet;

  if (!walletAddress) {
    throw new Error("unable to resolve wallet_address from config or private key");
  }

  if (configWallet && derivedWallet && configWallet !== derivedWallet) {
    throw new Error(
      `wallet_address does not match private key (configured=${configWallet} derived=${derivedWallet})`,
    );
  }

  const identifierKind = resolveIdentifierKind(sdkModule);

  const signer = {
    type: "EOA",
    signMessage: async (message) => {
      const text = typeof message === "string" ? message : String(message ?? "");
      const signatureHex = await account.signMessage({ message: text });
      return hexToBytes(signatureHex);
    },
    getIdentifier: () => ({ identifier: walletAddress, identifierKind }),
  };

  return { signer, walletAddress };
}

async function loadXmtpSdk() {
  const configured = normalizeText(state.connectConfig?.sdk_module);
  const candidates = [configured, "@xmtp/node-sdk"].filter(
    (value, idx, arr) => value && arr.indexOf(value) === idx,
  );
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

  const env = normalizeText(connectCommand.env) || normalizeText(connectCommand.environment);
  if (env) options.env = env;

  const apiUrl = normalizeText(connectCommand.api_url) || normalizeText(connectCommand.apiUrl);
  if (apiUrl) options.apiUrl = apiUrl;

  const dbPath = expandHomePath(connectCommand.db_path);
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
    normalizeWallet(client?.accountIdentifier?.identifier) ||
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
  const normalizedModuleName = moduleName.toLowerCase();

  if (normalizedModuleName === "@xmtp/node-sdk") {
    const { signer } = await buildNodeSdkSigner(sdkModule, connectCommand);
    return createFn(signer, options);
  }

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
    try {
      const result = await api.list({ consentStates: ALL_CONSENT_STATES });
      if (Array.isArray(result)) return result;
    } catch (_error) {
      // Fall through to try list() without options for older SDKs.
    }

    const fallback = await api.list();
    return Array.isArray(fallback) ? fallback : [];
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

  const api = client?.conversations || client;

  if (api && typeof api.getConversationById === "function") {
    try {
      const conversation = await api.getConversationById(id);
      if (conversation) {
        const cid = conversationId(conversation);
        state.conversationCache.set(cid, conversation);
        if (cid !== id) state.conversationCache.set(id, conversation);
        return conversation;
      }
    } catch (_error) {
      // Fall through to full list lookup.
    }
  }

  const conversations = await listConversations(client);

  for (const conversation of conversations) {
    const cid = conversationId(conversation);
    state.conversationCache.set(cid, conversation);
    if (cid !== id && normalizeText(conversation?.id) === normalizeText(id)) {
      state.conversationCache.set(id, conversation);
    }
  }

  return state.conversationCache.get(id) || null;
}

async function sendToConversation(client, conversation, text) {
  if (conversation && typeof conversation.sendText === "function") {
    return conversation.sendText(text);
  }

  if (conversation && typeof conversation.send === "function") {
    return conversation.send(text);
  }

  if (client && typeof client.send === "function") {
    return client.send(conversationId(conversation), text);
  }

  throw new Error("No XMTP send API available on client/conversation");
}

async function syncConversations(client, options = {}) {
  if (!client) return;

  const api = client.conversations || client;
  if (!api) return;

  const forceSyncAll = options.forceSyncAll === true;
  const now = nowMs();
  const shouldSyncAll = forceSyncAll || now - state.lastNetworkSyncAtMs >= SYNC_ALL_INTERVAL_MS;

  if (shouldSyncAll && typeof api.syncAll === "function") {
    await api.syncAll(ALL_CONSENT_STATES);
    state.lastNetworkSyncAtMs = now;
    return;
  }

  if (typeof api.sync === "function") {
    await api.sync();
    return;
  }

  if (typeof api.syncAll === "function") {
    await api.syncAll(ALL_CONSENT_STATES);
    state.lastNetworkSyncAtMs = now;
  }
}

async function handleConnect(command) {
  state.connectConfig = { ...command };
  state.connected = false;
  state.client = null;
  state.seenMessageKeys.clear();
  state.seenMessageOrder = [];
  state.conversationCache.clear();
  state.inboxWalletCache.clear();
  state.lastNetworkSyncAtMs = 0;
  state.identity = resolveIdentity(command, null);

  const walletAddress = state.identity.wallet_address;
  const inboxId = state.identity.inbox_id;
  const forceMock =
    command.mock_mode === true ||
    command.mock_mode === "true" ||
    command.mock_mode === 1 ||
    command.mock_mode === "1";

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
    await syncConversations(client, { forceSyncAll: true });
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
    await syncConversations(state.client);
    const conversations = await listConversations(state.client);

    for (const conversation of conversations) {
      const cid = conversationId(conversation);
      state.conversationCache.set(cid, conversation);

      const messages = await listMessages(conversation);
      const isGroup = isGroupConversation(conversation);
      const groupId = conversationGroupId(conversation, cid);

      for (const message of messages) {
        if (!isApplicationMessage(message)) {
          continue;
        }

        const dedupeKey = messageUniqueKey(cid, message);

        if (state.seenMessageKeys.has(dedupeKey)) {
          continue;
        }

        rememberSeenMessageKey(dedupeKey);

        if (isSelfAuthoredMessage(message)) {
          continue;
        }

        const rawContent = message?.content ?? message?.body ?? message?.text ?? null;
        const contentType = inferContentType(message, rawContent);
        const payload = decodeMessageContent(rawContent, contentType, message);
        const sender = senderIdentity(message);
        if (!sender.wallet_address && sender.inbox_id) {
          sender.wallet_address = await lookupWalletAddressByInboxId(state.client, sender.inbox_id);
        }

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
      message_id: normalizeText(sendResult?.id) || normalizeText(sendResult) || null,
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
