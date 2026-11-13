/**
 * `/jobs` — the focused session's background processes, live.
 *
 * omp's `JobsSheet` (pi-tui `overlays/jobs-panel`) is reused as is: it lists the
 * session's jobs as a tree beside the selected job's command, cwd, pids, exit
 * code and output tail. The sheet reads its {@link JobsSheetSource} synchronously
 * on every frame, so {@link JobsFeed} answers from a cache that a poll against
 * `process.jobs.list` / `process.jobs.inspect` keeps fresh while the sheet is
 * open. Cancel (X) is `process.jobs.cancel`: bound to the exact session and job,
 * sent once, never queued offline and never retried — an unknown outcome is
 * reported, not repeated.
 */

import {
	type JobsPanelDetail,
	type JobsPanelJob,
	type JobsPanelSnapshot,
	JobsSheet,
	type JobsSheetSource,
} from "@oh-my-pi/pi-tui/overlays/jobs-panel";
import { ensureThemeSync } from "@oh-my-pi/pi-tui/theme/theme";
import { truncateToWidth } from "@oh-my-pi/pi-tui/utils";
import {
	ControlPlaneError,
	MethodUnavailableError,
	NotConnectedError,
	RequestTimeoutError,
} from "../protocol/errors.ts";
import { InvalidJobsReceiptError } from "../protocol/jobs.ts";
import { type ControlPlaneMethods, METHOD } from "../protocol/methods.ts";
import type {
	ProcessJobDetail,
	ProcessJobSummary,
	ProcessJobsListResult,
} from "../protocol/types.ts";
import type { NoticeLevel } from "../store/transcript-model.ts";
import type { SlashCommand } from "./registry.ts";

const POLL_MS = 1_000;
const TAIL_BYTES = 16_384;
const FLASH_MS = 6_000;
const SHORT_ID = 8;

const LIVE_STATUSES: Record<string, true> = {
	queued: true,
	starting: true,
	running: true,
	killing: true,
};

function isLive(status: string): boolean {
	return LIVE_STATUSES[status] === true;
}

type NotifyFn = (text: string, level: NoticeLevel) => void;

export const jobsCommand: SlashCommand = {
	name: "jobs",
	summary: "show the focused session's background processes: inspect output, cancel",
	group: "runs",
	methods: [METHOD.processJobsList, METHOD.processJobsInspect],
	availableWhen: (ctx) => (ctx.ui.presentOverlay ? true : "no overlay host in this client"),
	async run(ctx, argv) {
		if (argv.length > 0) {
			ctx.ui.notice("usage: /jobs (no arguments)", "warning");
			return;
		}
		const sessionKey = ctx.session.key;
		let first: ProcessJobsListResult;
		try {
			first = await ctx.methods.processJobsList({ sessionKey });
			if (first.sessionKey !== sessionKey) throw new InvalidJobsReceiptError("process.jobs.list");
		} catch (error) {
			const [text, level] = jobsFailure("list", error);
			ctx.ui.notice(text, level);
			return;
		}
		// The user may have moved to another session while the list was in flight.
		if (ctx.store.focusedKey !== sessionKey) return;
		const canCancel = ctx.methods.supports(METHOD.processJobsCancel);
		ctx.ui.presentOverlay?.((host) => {
			ensureThemeSync();
			const feed = new JobsFeed({
				methods: ctx.methods,
				sessionKey,
				canCancel,
				notify: (text, level) => ctx.ui.notice(text, level),
				repaint: () => host.repaint(),
				close: () => host.close(),
			});
			feed.prime(first);
			feed.start();
			return new JobsOverlay(feed);
		});
	},
};

interface JobsFeedDeps {
	methods: ControlPlaneMethods;
	sessionKey: string;
	canCancel: boolean;
	notify: NotifyFn;
	repaint(): void;
	close(): void;
	now?: () => number;
}

/** What the sheet reads each frame, kept current by polling the daemon. */
export class JobsFeed implements JobsSheetSource {
	/** Absent when the daemon cannot cancel: the sheet then renders read-only. */
	cancel?: (id: string) => void;
	#snapshot: JobsPanelSnapshot = { running: [], recent: [] };
	#details = new Map<string, JobsPanelDetail>();
	#seen = new Map<string, { firstSeen: number; settledAt?: number }>();
	#cancelling = new Set<string>();
	#deps: JobsFeedDeps;
	#wanted: string | undefined;
	#stale: string | undefined;
	#flash: { text: string; until: number } | undefined;
	#banner: string | undefined;
	#timer: NodeJS.Timeout | undefined;
	#inFlight = false;
	#again = false;
	#closed = false;
	/** Repaints requested since the sheet last rendered; more than one means it is no longer on screen. */
	#unrendered = 0;

	constructor(deps: JobsFeedDeps) {
		this.#deps = deps;
		if (deps.canCancel) this.cancel = (id) => void this.#cancel(id);
		else this.#banner = "read-only: this daemon does not expose process.jobs.cancel";
	}

	/** Seed the cache with the listing fetched before the sheet opened. */
	prime(list: ProcessJobsListResult): void {
		this.#apply(list);
	}

	start(): void {
		this.#schedule(POLL_MS);
	}

	load(): JobsPanelSnapshot {
		return this.#snapshot;
	}

	inspect(id: string): JobsPanelDetail | undefined {
		if (this.#wanted !== id) {
			this.#wanted = id;
			this.#poke();
		}
		return this.#details.get(id);
	}

	close(): void {
		if (this.#closed) return;
		this.dispose();
		this.#deps.close();
	}

	/** Stop polling; safe to call repeatedly. */
	dispose(): void {
		this.#closed = true;
		clearTimeout(this.#timer);
		this.#timer = undefined;
	}

	/** The sheet calls this from `render`: it is still on screen. */
	markRendered(): void {
		this.#unrendered = 0;
	}

	/** One line the sheet shows above the list: a recent cancel result, stale data, or read-only. */
	note(): string | undefined {
		const flash = this.#flash;
		if (flash && flash.until > this.#now()) return flash.text;
		return this.#stale ? `stale: ${this.#stale}; retrying` : this.#banner;
	}

	/** Poll once. Never overlaps itself; a failure keeps the last listing and marks it stale. */
	async refresh(): Promise<void> {
		if (this.#inFlight || this.#closed) return;
		this.#inFlight = true;
		const { methods, sessionKey } = this.#deps;
		try {
			const list = await methods.processJobsList({ sessionKey });
			if (this.#closed) return;
			if (list.sessionKey !== sessionKey) throw new InvalidJobsReceiptError("process.jobs.list");
			this.#apply(list);
			const id = this.#wanted;
			if (id && list.jobs.some((job) => job.id === id)) await this.#fetchDetail(id);
			this.#stale = undefined;
		} catch (error) {
			if (!this.#closed) this.#stale = jobsFailure("list", error)[0];
		} finally {
			this.#inFlight = false;
		}
	}

	async #fetchDetail(id: string): Promise<void> {
		const { methods, sessionKey } = this.#deps;
		try {
			const { job } = await methods.processJobsInspect({
				sessionKey,
				jobId: id,
				tailBytes: TAIL_BYTES,
			});
			if (!this.#closed && job.id === id) this.#details.set(id, panelDetail(job));
		} catch (error) {
			// A job the daemon no longer holds simply has no detail; anything else is a stale poll.
			if (ControlPlaneError.is(error, "NOT_FOUND")) this.#details.delete(id);
			else throw error;
		}
	}

	async #cancel(id: string): Promise<void> {
		if (this.#closed || this.#cancelling.has(id)) return;
		this.#cancelling.add(id);
		const { methods, sessionKey, notify } = this.#deps;
		try {
			await methods.processJobsCancel({ sessionKey, jobId: id });
			this.#flashNote(`cancel requested for ${shortId(id)}`);
		} catch (error) {
			const [text, level] = jobsFailure("cancel", error);
			this.#flashNote(text);
			notify(text, level);
		} finally {
			this.#cancelling.delete(id);
			this.#poke();
		}
	}

	#flashNote(text: string): void {
		this.#flash = { text, until: this.#now() + FLASH_MS };
	}

	#apply(list: ProcessJobsListResult): void {
		const now = this.#now();
		const skew = list.at === null ? 0 : list.at - now;
		const ids = agentLabels(list);
		const running: JobsPanelJob[] = [];
		const recent: JobsPanelJob[] = [];
		for (const job of list.jobs) {
			const mapped = panelJob(job, ids, skew, this.#track(job, now));
			(mapped.status === "running" ? running : recent).push(mapped);
		}
		const live = new Set(list.jobs.map((job) => job.id));
		for (const id of this.#seen.keys()) if (!live.has(id)) this.#seen.delete(id);
		for (const id of this.#details.keys()) if (!live.has(id)) this.#details.delete(id);
		this.#banner = bannerFor(list, this.#deps.canCancel);
		this.#snapshot = {
			running,
			recent,
			rootId: list.rootId ?? undefined,
			agents: list.agents.map((agent) => ({
				id: ids.get(agent.id) ?? agent.id,
				parentId: agent.parentId ? (ids.get(agent.parentId) ?? agent.parentId) : undefined,
			})),
		};
	}

	/** First time a job was seen, and when it was first seen settled: fallbacks for missing daemon times. */
	#track(job: ProcessJobSummary, now: number): { firstSeen: number; settledAt?: number } {
		const entry = this.#seen.get(job.id) ?? { firstSeen: now };
		if (!isLive(job.status) && entry.settledAt === undefined) entry.settledAt = now;
		this.#seen.set(job.id, entry);
		return entry;
	}

	/** Fetch again now (selection or a cancel changed what is wanted) instead of waiting out the interval. */
	#poke(): void {
		if (this.#closed) return;
		if (this.#inFlight) this.#again = true;
		else if (this.#timer) this.#schedule(0);
	}

	#schedule(delay: number): void {
		clearTimeout(this.#timer);
		this.#timer = setTimeout(() => void this.#tick(), delay);
	}

	async #tick(): Promise<void> {
		this.#timer = undefined;
		if (this.#closed) return;
		await this.refresh();
		if (this.#closed) return;
		// Another overlay replaced the sheet without telling it: stop polling for nobody.
		if (this.#unrendered >= 2) {
			this.dispose();
			return;
		}
		this.#unrendered += 1;
		this.#deps.repaint();
		const delay = this.#again ? 0 : POLL_MS;
		this.#again = false;
		this.#schedule(delay);
	}

	#now(): number {
		return this.#deps.now?.() ?? Date.now();
	}
}

/** The omp sheet plus a one-line note (cancel result, stale data) above its rows. */
export class JobsOverlay extends JobsSheet {
	readonly #feed: JobsFeed;

	constructor(feed: JobsFeed) {
		super(feed);
		this.#feed = feed;
	}

	override render(width: number): readonly string[] {
		this.#feed.markRendered();
		const rows = super.render(width);
		const note = this.#feed.note();
		return note ? [truncateToWidth(` ⚠ ${note}`, width), ...rows] : rows;
	}
}

function bannerFor(list: ProcessJobsListResult, canCancel: boolean): string | undefined {
	if (!list.live) return "this session has no live runtime yet, so it owns no jobs";
	if (list.truncated) return `showing the newest ${list.jobs.length} of ${list.total} jobs`;
	return canCancel ? undefined : "read-only: this daemon does not expose process.jobs.cancel";
}

function shortId(id: string): string {
	return id.slice(0, SHORT_ID);
}

/**
 * Display ids for subagents: the sheet names an agent by its id, so a readable
 * label replaces the uuid in the agent list and in every job's `ownerId`. The
 * root keeps its real id, which the sheet compares against `rootId`.
 */
function agentLabels(list: ProcessJobsListResult): Map<string, string> {
	const labels = new Map<string, string>();
	for (const agent of list.agents) {
		if (agent.id === list.rootId) continue;
		labels.set(agent.id, `${agent.name ?? "subagent"} ${shortId(agent.id)}`);
	}
	return labels;
}

/** Store lifecycle label to the sheet's four states. */
export function panelStatus(job: ProcessJobSummary): JobsPanelJob["status"] {
	if (isLive(job.status)) return "running";
	switch (job.status) {
		case "completed":
			return job.exitCode !== null && job.exitCode !== 0 ? "failed" : "completed";
		case "killed":
		case "canceled":
			return "cancelled";
		default:
			return "failed";
	}
}

/** One plain sentence for states the four sheet statuses cannot tell apart. */
export function statusCaption(job: ProcessJobSummary): string | undefined {
	if (job.launch === "outcome_unknown") return "launch outcome unknown: do not rerun this command";
	switch (job.status) {
		case "queued":
			return "queued: waiting for background capacity";
		case "starting":
			return "starting";
		case "killing":
			return "stopping";
		case "lost":
			return "lost: termination was never confirmed, and the daemon will not retry it";
		case "error":
			return "failed to run";
		case "rejected":
			return "launch rejected: it never started";
		case "expired":
			return "launch expired before it could start";
		case "completed":
			return job.exitCode !== null && job.exitCode !== 0
				? `exited with code ${job.exitCode}`
				: undefined;
		default:
			return undefined;
	}
}

export function panelJob(
	job: ProcessJobSummary,
	labels: ReadonlyMap<string, string>,
	skewMs: number,
	seen: { firstSeen: number; settledAt?: number },
): JobsPanelJob {
	const status = panelStatus(job);
	const start = job.startedAt === null ? seen.firstSeen : job.startedAt - skewMs;
	const end = job.endedAt === null ? seen.settledAt : job.endedAt - skewMs;
	return {
		id: job.id,
		type: "bash",
		status,
		label: job.command ?? job.id,
		caption: statusCaption(job),
		startTime: start,
		endTime: status === "running" ? undefined : end,
		ownerId: job.ownerId === null ? undefined : (labels.get(job.ownerId) ?? job.ownerId),
	};
}

export function panelDetail(job: ProcessJobDetail): JobsPanelDetail {
	const output = job.outputTruncated ? `[earlier output not shown]\n${job.output}` : job.output;
	return {
		command: job.command ?? undefined,
		cwd: job.cwd ?? undefined,
		pids: job.pids,
		exitCode: job.exitCode ?? undefined,
		output,
	};
}

/** A fixed message per failure class; raw server messages and details are never shown. */
export function jobsFailure(action: "list" | "cancel", error: unknown): [string, NoticeLevel] {
	const noun = action === "list" ? "Background jobs" : "Cancel";
	if (error instanceof MethodUnavailableError) {
		return [`This daemon does not support ${error.method}.`, "warning"];
	}
	if (error instanceof NotConnectedError) {
		return [`${noun}: no live daemon connection; nothing was sent.`, "warning"];
	}
	if (error instanceof RequestTimeoutError) {
		return action === "cancel"
			? [
					"Cancel did not answer in time. The job may already be stopping; the request was not retried — check /jobs before trying again.",
					"warning",
				]
			: ["Background jobs did not answer in time", "warning"];
	}
	if (error instanceof ControlPlaneError) {
		const details = error.details as { reason?: unknown } | null | undefined;
		if (action === "cancel") {
			if (details?.reason === "outcome_unknown") {
				return [
					"Cancel outcome unknown: the daemon could not confirm the job stopped. It was not retried — check the job before trying again.",
					"warning",
				];
			}
			if (error.code === "NOT_FOUND") return ["That job is no longer listed.", "info"];
			if (error.code === "CONFLICT") return ["That job already finished.", "info"];
		}
		if (error.code === "UNAVAILABLE") return [`${noun} runtime is unavailable.`, "warning"];
		return [`${noun} request failed (${error.code}).`, "error"];
	}
	return [`The daemon returned an unreadable ${noun.toLowerCase()} receipt.`, "error"];
}
