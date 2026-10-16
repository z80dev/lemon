import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const source = fs.readFileSync(new URL("../../../../priv/whatsapp_bridge.mjs", import.meta.url), "utf8");
const start = source.indexOf("async function handleSendMedia(command)");
const end = source.indexOf("async function handleSendReaction(command)", start);
assert.ok(start >= 0 && end > start);

for (const [mime, filename] of [["audio/ogg", "reply.ogg"], ["audio/mpeg", "reply.mp3"]]) {
  test(`voice bridge sends ${mime} as a push-to-talk message`, async () => {
    const calls = [];
    const events = [];
    const context = vm.createContext({
      Buffer,
      fs: { readFileSync() { throw new Error("inline voice must not read a file"); } },
      state: {
        connected: true,
        sock: { async sendMessage(...args) { calls.push(args); return { key: { id: "voice-id" } }; } }
      },
      emit(event) { events.push(event); }
    });
    vm.runInContext(source.slice(start, end), context);
    const bytes = Buffer.from([0, 255, 1, 2]);
    await context.handleSendMedia({
      id: "correlation", jid: "123@s.whatsapp.net", media_type: "audio",
      audio_base64: bytes.toString("base64"), mime_type: mime, filename,
      ptt: true, reply_to: "original"
    });
    assert.equal(calls.length, 1);
    const [jid, message, options] = calls[0];
    assert.equal(jid, "123@s.whatsapp.net");
    assert.deepEqual(message.audio, bytes);
    assert.equal(message.ptt, true);
    assert.equal(message.mimetype, mime);
    assert.equal(message.fileName, filename);
    assert.equal(options.quoted.key.id, "original");
    assert.equal(events[0].type, "command_result");
    assert.equal(events[0].id, "correlation");
    assert.equal(events[0].data.message_id, "voice-id");
  });
}

for (const dispatched of [false, true]) {
  test(`voice bridge preserves ${dispatched ? "unknown send" : "definite preparation"} failures`, async () => {
    const errors = [];
    const context = vm.createContext({
      Buffer,
      fs: { readFileSync() { throw new Error("unreadable"); } },
      state: {
        connected: true,
        sock: { async sendMessage() { throw new Error("connection lost"); } }
      },
      emitSendError(command, error, unknown) { errors.push({ id: command.id, unknown }); }
    });
    vm.runInContext(source.slice(start, end), context);
    await context.handleSendMedia({
      id: "correlation", jid: "123@s.whatsapp.net", media_type: "audio",
      ...(dispatched ? { audio_base64: Buffer.from("opus").toString("base64") } : { file_path: "missing.ogg" }),
      ptt: true, reply_to: "original"
    });
    assert.deepEqual(errors, [{ id: "correlation", unknown: dispatched }]);
  });
}
