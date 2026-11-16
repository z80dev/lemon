import type { SessionEventBatch, SessionEventCursor, SessionsEventsResult } from "./types.ts";

/** An unsupported cursor cannot be interpreted as an older sequence scope. */
export class SessionEventCursorError extends Error {}

export function parseSessionEventCursor(value: unknown): SessionEventCursor {
	if (!value || typeof value !== "object" || !("version" in value) || value.version !== 1) {
		throw new SessionEventCursorError("unsupported session event cursor version");
	}
	const cursor = value as Partial<SessionEventCursor>;
	if (
		typeof cursor.sessionId !== "string" ||
		!cursor.sessionId ||
		typeof cursor.streamId !== "string" ||
		!cursor.streamId ||
		typeof cursor.seq !== "number" ||
		!Number.isSafeInteger(cursor.seq) ||
		cursor.seq < 0
	) {
		throw new SessionEventCursorError("invalid session event cursor");
	}
	return cursor as SessionEventCursor;
}

export function sameSessionEventStream(a: SessionEventCursor, b: SessionEventCursor): boolean {
	return a.version === b.version && a.sessionId === b.sessionId && a.streamId === b.streamId;
}

export function parseSessionEventBatch(value: unknown, sessionKey: string): SessionEventBatch {
	if (!value || typeof value !== "object") throw new Error("invalid session event batch");
	const batch = value as Partial<SessionEventBatch>;
	parseSessionEventCursor(batch.cursor);
	if (
		!Array.isArray(batch.events) ||
		!batch.events.every((entry) => {
			if (
				!entry ||
				typeof entry.event !== "string" ||
				!entry.payload ||
				typeof entry.payload !== "object" ||
				Array.isArray(entry.payload)
			)
				return false;
			const key = entry.payload.sessionKey;
			return key == null || key === sessionKey;
		})
	)
		throw new Error("invalid session event projection");
	return batch as SessionEventBatch;
}

export function parseSessionsEvents(value: unknown): SessionsEventsResult {
	if (!value || typeof value !== "object") throw new Error("invalid sessions.events response");
	const result = value as Partial<SessionsEventsResult>;
	if (typeof result.sessionKey !== "string") throw new Error("invalid sessions.events session key");
	if (result.status === "cursor_expired")
		return { status: "cursor_expired", sessionKey: result.sessionKey };
	if (
		result.status !== "ok" ||
		!Array.isArray(result.events) ||
		typeof result.hasMore !== "boolean"
	) {
		throw new Error("invalid sessions.events response");
	}
	parseSessionEventCursor(result.cursor);
	for (const entry of result.events) parseSessionEventBatch(entry, result.sessionKey);
	return result as SessionsEventsResult;
}
