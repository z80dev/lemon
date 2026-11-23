import { describe, expect, test } from "bun:test";
import { sessionsSnapshotResult } from "../../src/dev/fake-server.ts";
import {
	parseSessionEventBatch,
	parseSessionEventCursor,
	parseSessionsEvents,
	parseSessionsSnapshot,
	SessionEventCursorError,
	sameSessionEventStream,
} from "../../src/protocol/session-events.ts";
import type { SessionSnapshotIdentity } from "../../src/protocol/types.ts";
import fixture from "../fixtures/session-events.json";

const cursor = { version: 1 as const, sessionId: "native", streamId: "owner:branch", seq: 5 };

describe("versioned session event wire boundaries", () => {
	test("parses the exact server method fixture, asserted by ExUnit", () => {
		for (const wire of [fixture.page, fixture.empty]) {
			const result = parseSessionsEvents(wire);
			expect<unknown>(result).toBe(wire);
			if (result.status !== "ok") throw new Error("expected replay page");
			expect<unknown>(result.entries).toEqual(wire.entries);
			expect(result.hasMore).toBe(wire.hasMore);
			expect<unknown>(result.cursor).toEqual(wire.cursor);
		}
		expect(parseSessionsEvents(fixture.expired)).toEqual({
			status: "cursor_expired",
			sessionKey: fixture.expired.sessionKey,
		});
		expect(() =>
			parseSessionsEvents({ ...fixture.page, entries: undefined, events: [] }),
		).toThrow();
		expect(() =>
			parseSessionsEvents({ ...fixture.page, hasMore: undefined, has_more: true }),
		).toThrow();
	});

	test("keeps cursor and event identity unchanged, including empty projections", () => {
		const batch = { cursor, eventId: "owner:branch:5", events: [] };
		const result = {
			status: "ok" as const,
			sessionKey: "session",
			entries: [batch],
			cursor,
			hasMore: false,
		};
		expect(parseSessionEventCursor(cursor)).toBe(cursor);
		expect(parseSessionEventBatch(batch, "session")).toBe(batch);
		expect(parseSessionsEvents(result)).toBe(result);
		expect(parseSessionsEvents({ status: "cursor_expired", sessionKey: "session" })).toEqual({
			status: "cursor_expired",
			sessionKey: "session",
		});
	});

	test("rejects unsupported versions explicitly instead of interpreting their seq", () => {
		for (const version of [undefined, 0, 2, "1"]) {
			expect(() => parseSessionEventCursor({ ...cursor, version })).toThrow(
				SessionEventCursorError,
			);
			expect(() => parseSessionEventCursor({ ...cursor, version })).toThrow(
				"unsupported session event cursor version",
			);
		}
	});

	test("rejects malformed cursor fields", () => {
		for (const value of [
			{ ...cursor, seq: -1 },
			{ ...cursor, seq: 1.5 },
			{ ...cursor, seq: Number.MAX_SAFE_INTEGER + 1 },
			{ ...cursor, seq: "5" },
			{ ...cursor, sessionId: "" },
			{ ...cursor, streamId: null },
		])
			expect(() => parseSessionEventCursor(value)).toThrow(SessionEventCursorError);
	});

	test("an equal seq never equates owners, native sessions or branch epochs", () => {
		expect(sameSessionEventStream(cursor, { ...cursor, seq: 6 })).toBe(true);
		expect(sameSessionEventStream(cursor, { ...cursor, streamId: "other" })).toBe(false);
		expect(sameSessionEventStream(cursor, { ...cursor, sessionId: "other" })).toBe(false);
	});

	test("rejects a foreign projected session and malformed pages before application", () => {
		expect(() =>
			parseSessionEventBatch(
				{
					cursor,
					events: [{ event: "chat", payload: { sessionKey: "foreign" } }],
				},
				"session",
			),
		).toThrow("invalid session event projection");
		for (const value of [
			{ status: "ok", sessionKey: "session", entries: [], cursor },
			{ status: "unknown", sessionKey: "session" },
			{
				status: "ok",
				sessionKey: "session",
				entries: [{ cursor, events: null }],
				cursor,
				hasMore: false,
			},
		])
			expect(() => parseSessionsEvents(value)).toThrow();
	});
});

describe("sessions.snapshot wire boundary", () => {
	test("the fake server builds the exact ExUnit-asserted production layout", () => {
		const wire = fixture.snapshot;
		expect<unknown>(parseSessionsSnapshot(wire)).toBe(wire);
		const built = sessionsSnapshotResult({
			identity: wire.identity as SessionSnapshotIdentity,
			eventCursor: parseSessionEventCursor(wire.consistency.eventCursor),
		});
		// The fixture's caller lacks `approvals` scope; everything else is identical.
		built.snapshot.approvals = wire.snapshot.approvals as typeof built.snapshot.approvals;
		expect<unknown>(built).toEqual(wire);
		expect("eventCursor" in wire).toBe(false);
	});

	test("fails closed on a missing or unsupported cursor slot, never reading it as absent", () => {
		const wire = structuredClone(fixture.snapshot);
		expect(() => parseSessionsSnapshot({ ...wire, consistency: undefined })).toThrow();
		const { eventCursor: _, ...noSlot } = wire.consistency;
		expect(() => parseSessionsSnapshot({ ...wire, consistency: noSlot })).toThrow();
		expect(() =>
			parseSessionsSnapshot({
				...wire,
				consistency: { ...wire.consistency, eventCursor: { ...cursor, version: 2 } },
			}),
		).toThrow(SessionEventCursorError);
		expect(() =>
			parseSessionsSnapshot({
				...wire,
				consistency: { ...wire.consistency, eventCursor: { ...cursor, sessionId: "other" } },
			}),
		).toThrow(SessionEventCursorError);
		const offline = { ...wire, consistency: { ...wire.consistency, eventCursor: null } };
		expect<unknown>(parseSessionsSnapshot(offline)).toBe(offline);
	});
});
