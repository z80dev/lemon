import type {
	SessionEventBatch,
	SessionEventCursor,
	SessionsEventsResult,
	SessionsSnapshotResult,
} from "./types.ts";

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
	const cursor = parseSessionEventCursor(batch.cursor);
	if (batch.schemaVersion !== undefined) {
		if (batch.schemaVersion !== 1)
			throw new SessionEventCursorError("unsupported session event schema version");
		if (batch.eventId !== `${cursor.streamId}:${cursor.seq}` || batch.sequence !== cursor.seq)
			throw new SessionEventCursorError("invalid session event identity");
	}
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
		!Array.isArray(result.entries) ||
		typeof result.hasMore !== "boolean"
	) {
		throw new Error("invalid sessions.events response");
	}
	parseSessionEventCursor(result.cursor);
	for (const entry of result.entries) parseSessionEventBatch(entry, result.sessionKey);
	return result as SessionsEventsResult;
}

function isObject(value: unknown): value is Record<string, unknown> {
	return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

/**
 * Validate a `sessions.snapshot` result before any of it is installed. The live
 * cursor lives only at `consistency.eventCursor`; an unsupported cursor throws
 * {@link SessionEventCursorError} so callers keep requiring a snapshot rather
 * than reading it as "no cursor".
 */
export function parseSessionsSnapshot(value: unknown): SessionsSnapshotResult {
	if (!isObject(value)) throw new Error("invalid sessions.snapshot response");
	const { status, sessionKey, identity } = value;
	if (
		typeof sessionKey !== "string" ||
		!isObject(identity) ||
		typeof identity.sessionKey !== "string" ||
		(status !== "ok" && status !== "retry")
	)
		throw new Error("invalid sessions.snapshot response");
	if (status === "retry") return value as SessionsSnapshotResult;
	const { consistency, snapshot } = value;
	if (!isObject(consistency) || !("eventCursor" in consistency) || !isObject(snapshot))
		throw new Error("invalid sessions.snapshot response");
	if (consistency.eventCursor !== null) {
		const cursor = parseSessionEventCursor(consistency.eventCursor);
		if (cursor.sessionId !== identity.sessionId)
			throw new SessionEventCursorError("snapshot event cursor belongs to another session");
	}
	return value as SessionsSnapshotResult;
}
