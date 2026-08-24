/**
 * Rendering helpers shared by the command implementations.
 *
 * Control-plane payloads are wide, nested and only loosely specified (most
 * handlers return a `summary` map plus whatever the subsystem knows). These
 * helpers read defensively — an absent key renders as nothing rather than
 * "undefined" — so a daemon that grows or drops a field does not turn a command
 * into a wall of noise.
 */

export type Json = Record<string, unknown>;

export function asRecord(value: unknown): Json | undefined {
	if (typeof value !== "object" || value === null || Array.isArray(value)) return undefined;
	return value as Json;
}

export function asArray(value: unknown): unknown[] {
	return Array.isArray(value) ? value : [];
}

/** First present value among `keys`, searched depth-first through `paths`. */
export function pick(source: unknown, ...paths: string[]): unknown {
	const record = asRecord(source);
	if (!record) return undefined;
	for (const path of paths) {
		let current: unknown = record;
		for (const segment of path.split(".")) {
			const next = asRecord(current);
			if (!next) {
				current = undefined;
				break;
			}
			current = next[segment];
		}
		if (current !== undefined && current !== null) return current;
	}
	return undefined;
}

export function pickString(source: unknown, ...paths: string[]): string | undefined {
	const value = pick(source, ...paths);
	if (typeof value === "string") return value;
	if (typeof value === "number" || typeof value === "boolean") return String(value);
	return undefined;
}

export function pickNumber(source: unknown, ...paths: string[]): number | undefined {
	const value = pick(source, ...paths);
	if (typeof value === "number" && Number.isFinite(value)) return value;
	if (typeof value === "string") {
		const parsed = Number.parseFloat(value);
		if (Number.isFinite(parsed)) return parsed;
	}
	return undefined;
}

export function pickBoolean(source: unknown, ...paths: string[]): boolean | undefined {
	const value = pick(source, ...paths);
	if (typeof value === "boolean") return value;
	if (value === "true") return true;
	if (value === "false") return false;
	return undefined;
}

/** 1234 -> "1.2k", 1_200_000 -> "1.2M". Small numbers stay exact. */
export function humanNumber(value: number): string {
	const abs = Math.abs(value);
	if (abs < 1000) return String(Math.round(value));
	if (abs < 1_000_000) return `${trimZero(value / 1000)}k`;
	if (abs < 1_000_000_000) return `${trimZero(value / 1_000_000)}M`;
	return `${trimZero(value / 1_000_000_000)}G`;
}

function trimZero(value: number): string {
	const fixed = value.toFixed(1);
	return fixed.endsWith(".0") ? fixed.slice(0, -2) : fixed;
}

export function humanDuration(ms: number | undefined): string | undefined {
	if (ms === undefined || !Number.isFinite(ms)) return undefined;
	if (ms < 1000) return `${Math.round(ms)}ms`;
	const seconds = ms / 1000;
	if (seconds < 60) return `${trimZero(seconds)}s`;
	const minutes = Math.floor(seconds / 60);
	if (minutes < 60) return `${minutes}m ${Math.round(seconds % 60)}s`;
	const hours = Math.floor(minutes / 60);
	if (hours < 24) return `${hours}h ${minutes % 60}m`;
	return `${Math.floor(hours / 24)}d ${hours % 24}h`;
}

export function humanTime(ms: number | undefined): string | undefined {
	if (ms === undefined || !Number.isFinite(ms) || ms <= 0) return undefined;
	return new Date(ms).toISOString().replace("T", " ").slice(0, 19);
}

export function humanCost(value: number | undefined): string | undefined {
	if (value === undefined || !Number.isFinite(value)) return undefined;
	if (value === 0) return "$0";
	if (value < 0.01) return `$${value.toFixed(4)}`;
	return `$${value.toFixed(2)}`;
}

/** `label: value` lines, skipping every entry whose value is absent. */
export function keyValueLines(entries: Array<[string, unknown]>): string[] {
	const lines: string[] = [];
	for (const [label, value] of entries) {
		if (value === undefined || value === null || value === "") continue;
		lines.push(`${label}: ${scalar(value)}`);
	}
	return lines;
}

function scalar(value: unknown): string {
	if (Array.isArray(value)) return value.map((entry) => scalar(entry)).join(", ");
	if (typeof value === "object" && value !== null) {
		return Object.entries(value as Json)
			.filter(([, entry]) => entry !== undefined && entry !== null)
			.map(([key, entry]) => `${key}=${scalar(entry)}`)
			.join(" ");
	}
	return String(value);
}

/**
 * Last-resort rendering for a payload nothing else knows the shape of: one line
 * per top-level scalar, arrays and objects reduced to a count. Never recurses,
 * so an unexpectedly deep payload cannot produce a page of output.
 */
export function shallowLines(payload: unknown, limit = 20): string[] {
	const record = asRecord(payload);
	if (!record) return [String(payload)];
	const lines: string[] = [];
	for (const [key, value] of Object.entries(record)) {
		if (lines.length >= limit) {
			lines.push("…");
			break;
		}
		if (value === undefined || value === null) continue;
		if (Array.isArray(value)) {
			lines.push(`${key}: ${value.length} item(s)`);
		} else if (typeof value === "object") {
			const nested = Object.entries(value as Json).filter(([, entry]) => entry !== null);
			lines.push(`${key}: ${nested.map(([k, v]) => `${k}=${scalar(v)}`).join(" ")}`);
		} else {
			lines.push(`${key}: ${String(value)}`);
		}
	}
	return lines.length > 0 ? lines : ["(empty)"];
}

/** Indent every line but the first, so a notice block reads as one unit. */
export function indentBlock(lines: string[]): string {
	return lines.map((line, index) => (index === 0 ? line : `  ${line}`)).join("\n");
}
