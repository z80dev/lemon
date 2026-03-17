#!/usr/bin/env node

import readline from "node:readline";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { randomUUID } from "node:crypto";

// Baileys imports will be loaded dynamically since they may not be installed
let makeWASocket, useMultiFileAuthState, DisconnectReason, downloadMediaMessage, fetchLatestBaileysVersion, makeCacheableSignalKeyStore;
let pino;

const state = {
  sock: null,
  connected: false,
  credentialsPath: null,
  sessionName: null,
  ownJid: null,
  saveCreds: null,
};

// Filtered JID suffixes (skip broadcast, newsletter, status)
const FILTERED_JID_SUFFIXES = ["@broadcast", "@newsletter"];
const STATUS_JID = "status@broadcast";

function emit(event) {
  process.stdout.write(JSON.stringify(event) + "\n");
}

function emitError(message, extra = {}) {
  emit({ type: "error", message, ...extra });
}

function isFilteredJid(jid) {
  if (!jid || typeof jid !== "string") return true;
  if (jid === STATUS_JID) return true;
  return FILTERED_JID_SUFFIXES.some(s => jid.endsWith(s));
}

function isGroupJid(jid) {
  return typeof jid === "string" && jid.endsWith("@g.us");
}

function extractText(message) {
  if (!message) return null;
  const m = message.message || message;
  return (
    m?.conversation ||
    m?.extendedTextMessage?.text ||
    m?.imageMessage?.caption ||
    m?.videoMessage?.caption ||
    m?.documentMessage?.caption ||
    m?.documentWithCaptionMessage?.message?.documentMessage?.caption ||
    null
  );
}

function extractReplyContext(message) {
  const ctx = message?.message?.extendedTextMessage?.contextInfo ||
              message?.message?.imageMessage?.contextInfo ||
              message?.message?.videoMessage?.contextInfo ||
              message?.message?.documentMessage?.contextInfo;
  if (!ctx) return { reply_to_id: null, reply_to_text: null, mentioned_jids: [] };
  return {
    reply_to_id: ctx.stanzaId || null,
    reply_to_text: ctx.quotedMessage?.conversation || ctx.quotedMessage?.extendedTextMessage?.text || null,
    mentioned_jids: Array.isArray(ctx.mentionedJid) ? ctx.mentionedJid : [],
  };
}

function detectMediaType(message) {
  const m = message?.message || message;
  if (m?.imageMessage) return { type: "image", msg: m.imageMessage, mime: m.imageMessage.mimetype };
  if (m?.videoMessage) return { type: "video", msg: m.videoMessage, mime: m.videoMessage.mimetype };
  if (m?.audioMessage) return { type: "audio", msg: m.audioMessage, mime: m.audioMessage.mimetype };
  if (m?.documentMessage) return { type: "document", msg: m.documentMessage, mime: m.documentMessage.mimetype };
  if (m?.documentWithCaptionMessage?.message?.documentMessage) {
    const doc = m.documentWithCaptionMessage.message.documentMessage;
    return { type: "document", msg: doc, mime: doc.mimetype };
  }
  if (m?.stickerMessage) return { type: "sticker", msg: m.stickerMessage, mime: m.stickerMessage.mimetype };
  return null;
}

async function downloadMedia(message) {
  try {
    const buffer = await downloadMediaMessage(message, "buffer", {});
    const media = detectMediaType(message);
    const ext = (media?.mime || "").split("/")[1] || "bin";
    const tmpFile = path.join(os.tmpdir(), `wa-media-${randomUUID()}.${ext}`);
    fs.writeFileSync(tmpFile, buffer);
    return tmpFile;
  } catch (err) {
    emitError("media download failed", { detail: err?.message || String(err) });
    return null;
  }
}

// --- Connection ---

async function handleConnect(command) {
  const credentialsPath = command.credentials_path || path.join(os.homedir(), ".lemon", "whatsapp-auth");
  const sessionName = command.session_name || "lemon-wa";
  const pairingPhone = command.pairing_phone || null;

  state.credentialsPath = credentialsPath;
  state.sessionName = sessionName;

  try {
    // Ensure credentials directory exists
    fs.mkdirSync(credentialsPath, { recursive: true });

    const { state: authState, saveCreds } = await useMultiFileAuthState(credentialsPath);
    state.saveCreds = saveCreds;

    const { version } = await fetchLatestBaileysVersion();

    const logger = pino({ level: "silent" });

    const sock = makeWASocket({
      version,
      auth: {
        creds: authState.creds,
        keys: makeCacheableSignalKeyStore(authState.keys, logger),
      },
      printQRInTerminal: false,
      logger,
      generateHighQualityLinkPreview: false,
      syncFullHistory: false,
    });

    state.sock = sock;

    // Connection update events
    sock.ev.on("connection.update", async (update) => {
      const { connection, lastDisconnect, qr } = update;

      if (qr) {
        emit({ type: "qr", data: qr });
      }

      if (connection === "close") {
        const statusCode = lastDisconnect?.error?.output?.statusCode;
        const isLoggedOut = statusCode === DisconnectReason.loggedOut;
        const reason = lastDisconnect?.error?.message || "unknown";

        state.connected = false;
        emit({
          type: "disconnected",
          status_code: statusCode || 0,
          is_logged_out: isLoggedOut,
          reason
        });
      } else if (connection === "open") {
        state.connected = true;
        state.ownJid = sock.user?.id || null;
        emit({
          type: "connected",
          jid: state.ownJid,
          phone_number: state.ownJid?.split(":")[0]?.split("@")[0] || null
        });
      } else if (connection === "connecting") {
        emit({ type: "connecting" });
      }
    });

    // Credentials update
    sock.ev.on("creds.update", saveCreds);

    // Message events (event-driven, not polling!)
    sock.ev.on("messages.upsert", async ({ messages, type }) => {
      if (type !== "notify") return;

      for (const msg of messages) {
        try {
          const jid = msg.key?.remoteJid;
          if (!jid || isFilteredJid(jid)) continue;

          const text = extractText(msg);
          const mediaInfo = detectMediaType(msg);

          // Skip messages with no content
          if (!text && !mediaInfo && !msg.message?.reactionMessage) continue;

          // Handle reactions separately
          if (msg.message?.reactionMessage) {
            const reaction = msg.message.reactionMessage;
            emit({
              type: "reaction",
              jid,
              sender_jid: msg.key.participant || jid,
              message_id: reaction.key?.id || null,
              emoji: reaction.text || "",
            });
            continue;
          }

          const isGroup = isGroupJid(jid);
          const senderJid = isGroup ? (msg.key.participant || jid) : jid;
          const replyCtx = extractReplyContext(msg);

          // Download media if present
          let mediaPath = null;
          if (mediaInfo) {
            mediaPath = await downloadMedia(msg);
          }

          emit({
            type: "message",
            jid,
            sender_jid: senderJid,
            sender_name: msg.pushName || null,
            message_id: msg.key.id || null,
            timestamp: msg.messageTimestamp ? Number(msg.messageTimestamp) : Math.floor(Date.now() / 1000),
            is_group: isGroup,
            text: text || "",
            reply_to_id: replyCtx.reply_to_id,
            reply_to_text: replyCtx.reply_to_text,
            mentioned_jids: replyCtx.mentioned_jids,
            media_type: mediaInfo?.type || null,
            media_path: mediaPath,
            media_mime: mediaInfo?.mime || null,
            from_me: msg.key.fromMe || false,
          });
        } catch (err) {
          emitError("message processing failed", { detail: err?.message || String(err) });
        }
      }
    });

    // Request pairing code if phone provided
    if (pairingPhone && !authState.creds.registered) {
      const cleanPhone = pairingPhone.replace(/[^0-9]/g, "");
      try {
        const code = await sock.requestPairingCode(cleanPhone);
        emit({ type: "pairing_code", code });
      } catch (err) {
        emitError("pairing code request failed", { detail: err?.message || String(err) });
      }
    }
  } catch (err) {
    emitError("connect failed", { code: "connect_failed", detail: err?.message || String(err) });
  }
}

// --- Send commands ---

async function handleSendText(command) {
  if (!state.sock || !state.connected) {
    emit({ type: "command_error", id: command.id, error: "not connected" });
    return;
  }
  try {
    const opts = {};
    if (command.reply_to) {
      opts.quoted = { key: { remoteJid: command.jid, id: command.reply_to, fromMe: false } };
    }
    const result = await state.sock.sendMessage(command.jid, { text: command.text }, opts);
    emit({ type: "command_result", id: command.id, ok: true, data: { message_id: result?.key?.id || null } });
  } catch (err) {
    emit({ type: "command_error", id: command.id, error: err?.message || String(err) });
  }
}

async function handleSendMedia(command) {
  if (!state.sock || !state.connected) {
    emit({ type: "command_error", id: command.id, error: "not connected" });
    return;
  }
  try {
    const buffer = fs.readFileSync(command.file_path);
    let msg = {};
    const mediaType = command.media_type || "document";

    if (mediaType === "image") msg = { image: buffer, caption: command.caption || undefined };
    else if (mediaType === "video") msg = { video: buffer, caption: command.caption || undefined };
    else if (mediaType === "audio") msg = { audio: buffer, ptt: command.ptt || false, mimetype: "audio/ogg; codecs=opus" };
    else msg = { document: buffer, fileName: path.basename(command.file_path), caption: command.caption || undefined, mimetype: command.mime_type || "application/octet-stream" };

    const result = await state.sock.sendMessage(command.jid, msg);
    emit({ type: "command_result", id: command.id, ok: true, data: { message_id: result?.key?.id || null } });
  } catch (err) {
    emit({ type: "command_error", id: command.id, error: err?.message || String(err) });
  }
}

async function handleSendReaction(command) {
  if (!state.sock || !state.connected) {
    emit({ type: "command_error", id: command.id, error: "not connected" });
    return;
  }
  try {
    await state.sock.sendMessage(command.jid, {
      react: {
        text: command.emoji,
        key: { remoteJid: command.jid, id: command.message_id, fromMe: command.from_me || false }
      }
    });
    emit({ type: "command_result", id: command.id, ok: true, data: {} });
  } catch (err) {
    emit({ type: "command_error", id: command.id, error: err?.message || String(err) });
  }
}

async function handleTyping(command) {
  if (!state.sock || !state.connected) return;
  try {
    await state.sock.sendPresenceUpdate(command.composing ? "composing" : "paused", command.jid);
  } catch (_) {}
}

async function handleRead(command) {
  if (!state.sock || !state.connected) return;
  try {
    await state.sock.readMessages(command.keys);
  } catch (_) {}
}

async function handleGroupMetadata(command) {
  if (!state.sock || !state.connected) {
    emit({ type: "command_error", id: command.id, error: "not connected" });
    return;
  }
  try {
    const metadata = await state.sock.groupMetadata(command.jid);
    emit({ type: "command_result", id: command.id, ok: true, data: metadata });
  } catch (err) {
    emit({ type: "command_error", id: command.id, error: err?.message || String(err) });
  }
}

async function handleDisconnect() {
  if (state.sock) {
    try { state.sock.end(); } catch (_) {}
    state.sock = null;
    state.connected = false;
  }
}

// --- Command dispatch ---

async function handleCommand(command) {
  const op = command?.op;
  if (!op) { emitError("command missing op"); return; }

  switch (op) {
    case "connect": return handleConnect(command);
    case "send_text": return handleSendText(command);
    case "send_media": return handleSendMedia(command);
    case "send_reaction": return handleSendReaction(command);
    case "typing": return handleTyping(command);
    case "read": return handleRead(command);
    case "group_metadata": return handleGroupMetadata(command);
    case "disconnect": return handleDisconnect();
    default: emitError("unknown command op", { op });
  }
}

// --- Main: load deps and start stdin listener ---

async function main() {
  try {
    const baileys = await import("@whiskeysockets/baileys");
    makeWASocket = baileys.default || baileys.makeWASocket;
    useMultiFileAuthState = baileys.useMultiFileAuthState;
    DisconnectReason = baileys.DisconnectReason;
    downloadMediaMessage = baileys.downloadMediaMessage;
    fetchLatestBaileysVersion = baileys.fetchLatestBaileysVersion;
    makeCacheableSignalKeyStore = baileys.makeCacheableSignalKeyStore;
  } catch (err) {
    emitError("Failed to load @whiskeysockets/baileys", { code: "baileys_unavailable", detail: err?.message || String(err) });
  }

  try {
    pino = (await import("pino")).default;
  } catch (_) {
    pino = () => ({ level: "silent", child: () => pino(), info: () => {}, error: () => {}, warn: () => {}, debug: () => {}, trace: () => {}, fatal: () => {} });
  }

  const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity, terminal: false });

  rl.on("line", async (line) => {
    const trimmed = line.trim();
    if (!trimmed) return;

    let command;
    try { command = JSON.parse(trimmed); }
    catch (_) { emitError("invalid JSON command", { line: trimmed }); return; }

    if (!command || typeof command !== "object") {
      emitError("command must be a JSON object");
      return;
    }

    try { await handleCommand(command); }
    catch (err) { emitError("command handling failed", { detail: err?.message || String(err) }); }
  });

  rl.on("close", () => process.exit(0));
}

main().catch((err) => {
  emitError("bridge startup failed", { detail: err?.message || String(err) });
  process.exit(1);
});
