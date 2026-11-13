/**
 * Defensive reading of `process.jobs.*` receipts.
 *
 * A malformed receipt is refused outright instead of rendered as "no jobs": an
 * unreadable list is a failed query, not an idle session. Within a readable job
 * a field of the wrong type degrades to null, and every string and array is
 * bounded before it reaches a terminal.
 */

import { asArray, asRecord } from "../commands/format.ts";
import type {
	ProcessJobAgent,
	ProcessJobDetail,
	ProcessJobSummary,
	ProcessJobsCancelResult,
	ProcessJobsInspectResult,
	ProcessJobsListResult,
} from "./types.ts";

const MAX_JOBS = 100;
const MAX_AGENTS = 100;
const MAX_PIDS = 16;
const ID_LIMIT = 128;
const COMMAND_LIMIT = 2_048;
const PATH_LIMIT = 1_024;
const NAME_LIMIT = 128;
const OUTPUT_LIMIT = 65_536;

export class InvalidJobsReceiptError extends Error {
	constructor(method: string) {
		super(`invalid ${method} receipt`);
		this.name = "InvalidJobsReceiptError";
	}
}

function text(value: unknown, limit: number): string | null {
	return typeof value === "string" ? value.slice(0, limit) : null;
}

function integer(value: unknown): number | null {
	return typeof value === "number" && Number.isFinite(value) ? Math.trunc(value) : null;
}

function parseJob(value: unknown): ProcessJobSummary | undefined {
	const record = asRecord(value);
	const id = text(record?.id, ID_LIMIT);
	if (!record || !id) return undefined;
	return {
		id,
		status: text(record.status, 32) ?? "unknown",
		ownerId: text(record.ownerId, ID_LIMIT),
		command: text(record.command, COMMAND_LIMIT),
		startedAt: integer(record.startedAt),
		endedAt: integer(record.endedAt),
		exitCode: integer(record.exitCode),
		launch: text(record.launch, 32),
	};
}

function parseAgent(value: unknown): ProcessJobAgent | undefined {
	const record = asRecord(value);
	const id = text(record?.id, ID_LIMIT);
	if (!record || !id) return undefined;
	return {
		id,
		parentId: text(record.parentId, ID_LIMIT),
		name: text(record.name, NAME_LIMIT),
	};
}

export function parseProcessJobsList(raw: unknown): ProcessJobsListResult {
	const record = asRecord(raw);
	const sessionKey = text(record?.sessionKey, 1_024);
	if (!record || !sessionKey || !Array.isArray(record.jobs) || typeof record.live !== "boolean") {
		throw new InvalidJobsReceiptError("process.jobs.list");
	}
	const jobs = record.jobs.slice(0, MAX_JOBS).flatMap((job) => parseJob(job) ?? []);
	return {
		sessionKey,
		live: record.live,
		rootId: text(record.rootId, ID_LIMIT),
		at: integer(record.at),
		jobs,
		agents: asArray(record.agents)
			.slice(0, MAX_AGENTS)
			.flatMap((agent) => parseAgent(agent) ?? []),
		total: Math.max(integer(record.total) ?? jobs.length, jobs.length),
		truncated: record.truncated === true,
	};
}

export function parseProcessJobsInspect(raw: unknown): ProcessJobsInspectResult {
	const record = asRecord(raw);
	const sessionKey = text(record?.sessionKey, 1_024);
	const detail = asRecord(record?.job);
	const summary = parseJob(detail);
	if (!sessionKey || !detail || !summary) throw new InvalidJobsReceiptError("process.jobs.inspect");
	const job: ProcessJobDetail = {
		...summary,
		cwd: text(detail.cwd, PATH_LIMIT),
		backend: text(detail.backend, 32),
		pids: asArray(detail.pids)
			.filter((pid): pid is number => typeof pid === "number" && Number.isInteger(pid) && pid > 0)
			.slice(0, MAX_PIDS),
		output: text(detail.output, OUTPUT_LIMIT) ?? "",
		outputTruncated: detail.outputTruncated === true,
		outputBytes: integer(detail.outputBytes),
	};
	return { sessionKey, job };
}

export function parseProcessJobsCancel(raw: unknown): ProcessJobsCancelResult {
	const record = asRecord(raw);
	const sessionKey = text(record?.sessionKey, 1_024);
	const jobId = text(record?.jobId, ID_LIMIT);
	const job = parseJob(record?.job);
	if (!sessionKey || !jobId || !job || typeof record?.cancelled !== "boolean") {
		throw new InvalidJobsReceiptError("process.jobs.cancel");
	}
	return { sessionKey, jobId, cancelled: record.cancelled, job };
}
