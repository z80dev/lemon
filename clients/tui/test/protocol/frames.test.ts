import { describe, expect, test } from "bun:test";
import {
	DEFAULT_POLICY,
	decodeFrame,
	encodeFrame,
	FrameDecodeError,
	isEventFrame,
	isHelloOkFrame,
	isResFrame,
	makeReq,
	tryDecodeFrame,
} from "../../src/protocol/frames.ts";

describe("frames codec", () => {
	test("makeReq builds a req frame with a uuid id", () => {
		const frame = makeReq("chat.send", { sessionKey: "s1", prompt: "hi" });
		expect(frame.type).toBe("req");
		expect(frame.method).toBe("chat.send");
		expect(frame.id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-/);
		expect(frame.params).toEqual({ sessionKey: "s1", prompt: "hi" });
	});

	test("makeReq omits params when not given", () => {
		const frame = makeReq("health");
		expect("params" in frame).toBe(false);
		expect(JSON.parse(encodeFrame(frame))).toEqual({
			type: "req",
			id: frame.id,
			method: "health",
		});
	});

	test("decodes a res frame", () => {
		const frame = decodeFrame('{"type":"res","id":"abc","ok":true,"payload":{"runId":"r1"}}');
		expect(isResFrame(frame)).toBe(true);
		if (!isResFrame(frame)) throw new Error("unreachable");
		expect(frame.ok).toBe(true);
		expect(frame.payload).toEqual({ runId: "r1" });
	});

	test("decodes an error res frame", () => {
		const frame = decodeFrame(
			'{"type":"res","id":"abc","ok":false,"error":{"code":"NOT_FOUND","message":"nope"}}',
		);
		if (!isResFrame(frame)) throw new Error("expected res");
		expect(frame.ok).toBe(false);
		expect(frame.error).toEqual({ code: "NOT_FOUND", message: "nope" });
	});

	test("decodes an event frame with seq and stateVersion", () => {
		const frame = decodeFrame(
			'{"type":"event","event":"chat","seq":7,"payload":{"type":"delta","text":"hi"},"stateVersion":{"health":2}}',
		);
		expect(isEventFrame(frame)).toBe(true);
		if (!isEventFrame(frame)) throw new Error("unreachable");
		expect(frame.event).toBe("chat");
		expect(frame.seq).toBe(7);
		expect(frame.stateVersion).toEqual({ health: 2 });
	});

	test("hello-ok is normalized with policy defaults", () => {
		const frame = decodeFrame('{"type":"hello-ok","server":{"version":"1"},"features":{}}');
		expect(isHelloOkFrame(frame)).toBe(true);
		if (!isHelloOkFrame(frame)) throw new Error("unreachable");
		expect(frame.protocol).toBe(1);
		expect(frame.features.methods).toEqual([]);
		expect(frame.features.events).toEqual([]);
		expect(frame.policy).toEqual(DEFAULT_POLICY);
	});

	test("hello-ok keeps a server-provided tick interval", () => {
		const frame = decodeFrame(
			'{"type":"hello-ok","protocol":1,"server":{},"features":{"methods":["health"],"events":[]},"policy":{"tickIntervalMs":250}}',
		);
		if (!isHelloOkFrame(frame)) throw new Error("unreachable");
		expect(frame.policy.tickIntervalMs).toBe(250);
		expect(frame.policy.maxPayload).toBe(DEFAULT_POLICY.maxPayload);
	});

	test("rejects malformed JSON", () => {
		expect(() => decodeFrame("{not json")).toThrow(FrameDecodeError);
	});

	test("rejects unknown frame types", () => {
		expect(() => decodeFrame('{"type":"nope"}')).toThrow(/unsupported frame type/);
	});

	test("rejects non-object frames", () => {
		expect(() => decodeFrame("[1,2,3]")).toThrow(/must be a JSON object/);
	});

	test("tryDecodeFrame reports instead of throwing", () => {
		const bad = tryDecodeFrame("nope");
		expect(bad.ok).toBe(false);
		if (bad.ok) throw new Error("unreachable");
		expect(bad.error).toBeInstanceOf(FrameDecodeError);
		expect(bad.error.raw).toBe("nope");

		const good = tryDecodeFrame('{"type":"event","event":"tick","seq":1}');
		expect(good.ok).toBe(true);
	});
});
