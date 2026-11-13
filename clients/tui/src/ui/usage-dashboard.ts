/**
 * `/usage` dashboard: omp's fullscreen usage overlay fed by Lemon's own data.
 *
 * Nothing here invents numbers. The provider cards come from what the daemon
 * reports in `usage.status` (today's per-provider spend and requests, plus any
 * operator-configured daily limits) and the heatmap from the `dailyUsage`
 * series of `usage.cost`, which is the daily ledger. When the daemon reports
 * neither, the dashboard says so instead of drawing placeholders.
 *
 * The ledger keys days by UTC date; the heatmap lays days out on the local
 * calendar, so activity near midnight can land one cell off for users far from
 * UTC.
 */

import {
	type DailyActivityPoint,
	UsageDashboardComponent,
	type UsageDashboardOptions,
} from "@oh-my-pi/pi-tui/overlays/usage-dashboard";
import { wrapTextWithAnsi } from "@oh-my-pi/pi-tui/utils";
import {
	asArray,
	asRecord,
	humanCost,
	humanNumber,
	keyValueLines,
	pickNumber,
	pickString,
} from "../commands/format.ts";

type UsageReport = UsageDashboardOptions["reports"][number];
type UsageLimit = UsageReport["limits"][number];

const DAY_MS = 24 * 60 * 60 * 1000;
/** The ledger answers at most 366 days per `usage.cost` call; the heatmap shows a year. */
const ACTIVITY_DAYS = 365;
/** Rows listed per section of the detail view. */
const DETAIL_ROWS = 10;
/** Fraction of a configured limit at which its card turns to a warning. */
const WARNING_FRACTION = 0.8;
/** Provider id of the card carrying the daemon's configured limits. */
const LIMITS_PROVIDER = "lemon-limits";

export interface UsageDashboardSource {
	/** Fetch the current `usage.status` payload. */
	status(): Promise<Record<string, unknown>>;
	/** Fetch the daily ledger projection (`usage.cost`), or undefined when the daemon has none. */
	cost: ((params: Record<string, unknown>) => Promise<Record<string, unknown>>) | undefined;
	/** Called with every fresh `usage.status`, so callers can keep their own caches current. */
	onStatus?(usage: Record<string, unknown>): void;
	requestRender(): void;
	onClose(): void;
}

function isoDay(ms: number): string {
	return new Date(ms).toISOString().slice(0, 10);
}

/** The `usage.cost` parameters the dashboard asks for: a year of per-day rows. */
export function activityCostParams(nowMs: number): Record<string, unknown> {
	return {
		startDate: isoDay(nowMs - (ACTIVITY_DAYS - 1) * DAY_MS),
		endDate: isoDay(nowMs),
		groupBy: "day",
	};
}

/**
 * Heatmap points from the ledger's `dailyUsage` rows. Unknown costs count as
 * zero (the heatmap falls back to request counts when nothing is priced), and a
 * row without a valid date is dropped.
 */
export function activityFromCost(result: unknown): DailyActivityPoint[] {
	const points: DailyActivityPoint[] = [];
	for (const row of asArray(asRecord(result)?.dailyUsage)) {
		const day = pickString(row, "date");
		if (!day || !/^\d{4}-\d{2}-\d{2}$/.test(day)) continue;
		const cost = pickNumber(row, "cost");
		points.push({
			day,
			cost: cost !== undefined && cost > 0 ? cost : 0,
			requests: pickNumber(row, "requests") ?? 0,
		});
	}
	return points;
}

function limitStatus(used: number | undefined, limit: number): UsageLimit["status"] {
	if (used === undefined) return "unknown";
	if (used > limit) return "exhausted";
	return used >= limit * WARNING_FRACTION ? "warning" : "ok";
}

/**
 * Provider cards from `usage.status`: one `Lemon Limits` card for the daily
 * limits the operator configured, and one card per provider that ran today with
 * its known spend and request count. An absent figure is omitted, not zeroed,
 * and a payload with neither yields no reports.
 */
export function reportsFromStatus(usage: unknown, nowMs: number): UsageReport[] {
	const reports: UsageReport[] = [];
	const periodStart = pickNumber(usage, "periodStart");
	const window =
		periodStart === undefined
			? { id: "1d", label: "Today", durationMs: DAY_MS }
			: { id: "1d", label: "Today", durationMs: DAY_MS, resetsAt: periodStart + DAY_MS };

	const input = pickNumber(usage, "tokens.input");
	const output = pickNumber(usage, "tokens.output");
	const configured: Array<{
		id: string;
		label: string;
		unit: "requests" | "tokens" | "usd";
		used: number | undefined;
		limit: number | undefined;
	}> = [
		{
			id: "runs",
			label: "Runs",
			unit: "requests",
			used: pickNumber(usage, "runs"),
			limit: pickNumber(usage, "quotas.runsLimit"),
		},
		{
			id: "tokens",
			label: "Tokens",
			unit: "tokens",
			used: input !== undefined && output !== undefined ? input + output : undefined,
			limit: pickNumber(usage, "quotas.tokensLimit"),
		},
		{
			id: "cost",
			label: "Spend",
			unit: "usd",
			used: pickNumber(usage, "cost"),
			limit: pickNumber(usage, "quotas.costLimit"),
		},
	];
	const limits: UsageLimit[] = [];
	for (const entry of configured) {
		if (entry.limit === undefined) continue;
		limits.push({
			id: `lemon-${entry.id}`,
			label: entry.label,
			scope: { provider: LIMITS_PROVIDER as never, windowId: window.id },
			window,
			amount: {
				unit: entry.unit,
				limit: entry.limit,
				...(entry.used === undefined ? {} : { used: entry.used }),
			},
			status: limitStatus(entry.used, entry.limit),
		});
	}
	if (limits.length > 0) {
		reports.push({
			provider: LIMITS_PROVIDER as never,
			fetchedAt: nowMs,
			limits,
			notes: ["Daily limits configured on the daemon."],
		});
	}

	for (const row of asArray(asRecord(usage)?.providers)) {
		const provider = pickString(row, "provider");
		if (!provider) continue;
		const cost = pickNumber(row, "cost");
		const requests = pickNumber(row, "requests");
		const rows: UsageLimit[] = [];
		if (cost !== undefined) {
			rows.push({
				id: `${provider}-spend`,
				label: "Spend today",
				scope: { provider: provider as never, windowId: window.id },
				window,
				amount: { unit: "usd", used: cost },
				status: "unknown",
			});
		}
		if (requests !== undefined) {
			rows.push({
				id: `${provider}-requests`,
				label: "Requests today",
				scope: { provider: provider as never, windowId: window.id },
				window,
				amount: { unit: "requests", used: requests },
				status: "unknown",
			});
		}
		if (rows.length === 0) continue;
		reports.push({
			provider: provider as never,
			fetchedAt: nowMs,
			limits: rows,
			notes: ["Lemon-recorded usage; the provider's own quota is not reported."],
		});
	}
	return reports;
}

/** Plain-text `usage.status` summary, the report `/usage text` prints. */
export function usageStatusLines(usage: Record<string, unknown>): string[] {
	const input = pickNumber(usage, "tokens.input") ?? 0;
	const output = pickNumber(usage, "tokens.output") ?? 0;
	const lines = [
		`usage — ${pickString(usage, "period") ?? "today"}`,
		...keyValueLines([
			["runs", pickNumber(usage, "runs")],
			[
				"tokens",
				`${humanNumber(input)} in · ${humanNumber(output)} out · ${humanNumber(input + output)} total`,
			],
			["cost", humanCost(pickNumber(usage, "cost"))],
			["status", pickString(usage, "summary.status")],
			["remaining runs", pickNumber(usage, "summary.remainingRuns")],
			["remaining tokens", pickNumber(usage, "summary.remainingTokens")],
		]),
	];
	const providers = asArray(usage.providers);
	if (providers.length > 0) {
		lines.push("providers:");
		for (const provider of providers) {
			lines.push(
				`  ${pickString(provider, "provider") ?? "?"} · ${pickNumber(provider, "requests") ?? 0} req · ${humanCost(pickNumber(provider, "cost")) ?? "$0"}`,
			);
		}
	}
	return lines;
}

function section(
	title: string,
	rows: unknown[],
	label: (row: unknown) => string,
	incomplete: boolean,
): string[] {
	if (rows.length === 0) return [];
	const lines = [`${title}:`];
	for (const row of rows.slice(0, DETAIL_ROWS)) {
		const cost = humanCost(pickNumber(row, "cost"));
		lines.push(
			`  ${label(row)}: ${cost ? `${cost}${incomplete ? "+" : ""}` : "cost unknown"} · ${humanNumber(pickNumber(row, "requests") ?? 0)} req · ${humanNumber(pickNumber(row, "inputTokens") ?? 0)} in · ${humanNumber(pickNumber(row, "outputTokens") ?? 0)} out`,
		);
	}
	if (rows.length > DETAIL_ROWS) lines.push(`  … ${rows.length - DETAIL_ROWS} more`);
	return lines;
}

/** The ledger half of the detail view: a year of `usage.cost` totals, never presenting a known subtotal as the total. */
export function costDetailLines(cost: Record<string, unknown>): string[] {
	const incomplete = cost.incomplete !== false;
	const total = humanCost(pickNumber(cost, "totalCost"));
	const lines = [
		`ledger — ${pickString(cost, "startDate") ?? "?"} → ${pickString(cost, "endDate") ?? "?"}`,
		...keyValueLines([
			[
				"total",
				total === undefined
					? undefined
					: `${total}${incomplete ? " known subtotal (unknown pricing may be present)" : ""}`,
			],
			["requests", pickNumber(cost, "totalRequests")],
			["sessions omitted", pickNumber(cost, "sessionsOmitted")],
		]),
	];
	lines.push(
		...section(
			"providers",
			asArray(cost.providers),
			(row) => pickString(row, "provider") ?? "?",
			incomplete,
		),
		...section(
			"models",
			asArray(cost.models),
			(row) => `${pickString(row, "provider") ?? "?"}:${pickString(row, "model") ?? "?"}`,
			incomplete,
		),
		...section(
			"sessions",
			asArray(cost.sessions),
			(row) => pickString(row, "sessionKey") ?? "?",
			incomplete,
		),
		// Newest days first: the oldest of a year are the least interesting.
		...section(
			"days",
			[...asArray(cost.dailyUsage)].reverse(),
			(row) => pickString(row, "date") ?? "?",
			incomplete,
		),
	);
	return lines;
}

/** The full detail report: today's `usage.status` plus the ledger, wrapped to `width`. */
export function usageDetailText(
	usage: Record<string, unknown>,
	cost: Record<string, unknown> | undefined,
	width: number,
): string {
	const lines = usageStatusLines(usage);
	if (cost) lines.push("", ...costDetailLines(cost));
	return lines.flatMap((line) => wrapTextWithAnsi(line, Math.max(1, width))).join("\n");
}

/** Build the dashboard over `source`'s live data. */
export async function buildUsageDashboard(
	source: UsageDashboardSource,
): Promise<UsageDashboardComponent> {
	let usage = await source.status();
	source.onStatus?.(usage);
	let cost: Record<string, unknown> | undefined;

	const loadCost = async (signal?: AbortSignal): Promise<Record<string, unknown>> => {
		if (!source.cost) throw new Error("this daemon does not serve usage.cost");
		const result = await source.cost(activityCostParams(Date.now()));
		if (signal?.aborted) throw new Error("closed");
		cost = result;
		return result;
	};

	return new UsageDashboardComponent({
		reports: reportsFromStatus(usage, Date.now()),
		renderDetail: (width) => usageDetailText(usage, cost, width),
		loadActivity: async (push, signal) => {
			const result = await loadCost(signal);
			push(activityFromCost(result));
		},
		refresh: async () => {
			usage = await source.status();
			source.onStatus?.(usage);
			// The ledger half of the detail follows the refresh; a failure there
			// leaves the previous ledger in place rather than failing the cards.
			await loadCost().catch(() => undefined);
			return reportsFromStatus(usage, Date.now());
		},
		requestRender: () => source.requestRender(),
		onClose: () => source.onClose(),
	});
}
