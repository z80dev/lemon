import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import type { Component } from "@oh-my-pi/pi-tui/tui";
import type { CommandHost, OverlayHost } from "../../src/commands/registry.ts";
import { DEFAULT_METHODS } from "../../src/dev/fake-server.ts";
import {
	activityCostParams,
	activityFromCost,
	reportsFromStatus,
	usageDetailText,
} from "../../src/ui/usage-dashboard.ts";
import { createHarness, type Harness, type RecordingHost } from "../helpers/command-harness.ts";

const STATUS = {
	period: "today",
	periodStart: Date.UTC(2026, 10, 13),
	runs: 12,
	tokens: { input: 48_000, output: 12_000 },
	cost: 1.234,
	quotas: { runsLimit: 100, tokensLimit: null, costLimit: 2 },
	providers: [
		{ provider: "anthropic", requests: 12, cost: 1.234 },
		{ provider: "openai", requests: 3, cost: null },
	],
	summary: { status: "within_limits" },
};

describe("usage dashboard data mapping", () => {
	test("activity comes from dailyUsage rows, skipping malformed ones and unknown costs", () => {
		const points = activityFromCost({
			dailyUsage: [
				{ date: "2026-11-11", cost: 0.5, requests: 4 },
				{ date: "2026-11-12", cost: null, requests: 2 },
				{ date: "not-a-day", cost: 9, requests: 9 },
				{ cost: 1, requests: 1 },
			],
		});
		expect(points).toEqual([
			{ day: "2026-11-11", cost: 0.5, requests: 4 },
			{ day: "2026-11-12", cost: 0, requests: 2 },
		]);
		expect(activityFromCost(undefined)).toEqual([]);
	});

	test("a year of days is requested, ending today", () => {
		const params = activityCostParams(Date.UTC(2026, 10, 13, 15));
		expect(params).toEqual({ startDate: "2025-11-14", endDate: "2026-11-13", groupBy: "day" });
	});

	test("cards carry configured limits and per-provider spend, omitting unknown figures", () => {
		const reports = reportsFromStatus(STATUS, 1);
		const limits = reports.find((report) => report.provider === "lemon-limits");
		expect(
			limits?.limits.map((limit) => [limit.label, limit.amount.used, limit.amount.limit]),
		).toEqual([
			["Runs", 12, 100],
			["Spend", 1.234, 2],
		]);
		expect(limits?.limits.map((limit) => limit.status)).toEqual(["ok", "ok"]);
		const anthropic = reports.find((report) => report.provider === "anthropic");
		expect(anthropic?.limits.map((limit) => limit.label)).toEqual([
			"Spend today",
			"Requests today",
		]);
		const openai = reports.find((report) => report.provider === "openai");
		expect(openai?.limits.map((limit) => limit.label)).toEqual(["Requests today"]);
	});

	test("a limit already exceeded reads as exhausted, an unknown usage as unknown", () => {
		const over = reportsFromStatus({ runs: 5, quotas: { runsLimit: 4 } }, 1);
		expect(over[0]?.limits[0]?.status).toBe("exhausted");
		const unknown = reportsFromStatus({ runs: null, quotas: { runsLimit: 4 } }, 1);
		expect(unknown[0]?.limits[0]?.status).toBe("unknown");
	});

	test("no quota or provider data produces no reports, never placeholders", () => {
		expect(reportsFromStatus({ runs: 0, providers: [] }, 1)).toEqual([]);
	});

	test("the detail report shows status and a labelled known subtotal from the ledger", () => {
		const text = usageDetailText(
			STATUS,
			{
				startDate: "2025-11-14",
				endDate: "2026-11-13",
				totalCost: 4.5,
				incomplete: true,
				totalRequests: 20,
				providers: [{ provider: "anthropic", cost: 4.5, requests: 20 }],
				dailyUsage: [{ date: "2026-11-12", cost: 4.5, requests: 20 }],
			},
			80,
		);
		expect(text).toContain("48k in");
		expect(text).toContain("known subtotal");
		expect(text).toContain("2026-11-12");
		expect(usageDetailText(STATUS, undefined, 80)).not.toContain("ledger");
	});
});

/** The recording host with the optional overlay seam a test can install. */
type OverlayTestHost = RecordingHost & Pick<CommandHost, "presentOverlay">;

describe("/usage command", () => {
	let harness: Harness;
	let costServed: () => void;
	let costRequested: Promise<void>;
	beforeEach(async () => {
		costRequested = new Promise((resolve) => {
			costServed = resolve;
		});
		harness = await createHarness({ methods: [...DEFAULT_METHODS] });
		harness.server.respondWith("usage.status", STATUS);
		harness.server.onMethod("usage.cost", () => {
			costServed();
			return {
				startDate: "2025-11-14",
				endDate: "2026-11-13",
				totalCost: 1.234,
				incomplete: false,
				dailyUsage: [{ date: "2026-11-13", cost: 1.234, requests: 12 }],
			};
		});
	});
	afterEach(() => harness.stop());

	test("opens the dashboard overlay and loads a year of ledger days", async () => {
		const mounted: Component[] = [];
		const host: OverlayTestHost = harness.host;
		host.presentOverlay = (build) => {
			const overlayHost: OverlayHost = {
				close: () => {},
				repaint: () => {},
				rows: () => 40,
				columns: () => 120,
				tui: undefined as never,
			};
			mounted.push(build(overlayHost));
		};
		await harness.run("/usage");
		expect(mounted).toHaveLength(1);
		expect(harness.host.notices).toHaveLength(0);
		await costRequested;
		expect(harness.server.requestsFor("usage.cost")[0]?.params).toMatchObject({ groupBy: "day" });
		expect(harness.store.usage?.runs).toBe(12);
		mounted[0]?.dispose?.();
	});

	test("/usage text keeps the inline report, without the overlay", async () => {
		let opened = 0;
		const host: OverlayTestHost = harness.host;
		host.presentOverlay = () => {
			opened += 1;
		};
		await harness.run("/usage text");
		expect(opened).toBe(0);
		expect(harness.host.text).toContain("48k in");
		expect(harness.host.text).toContain("$1.23");
	});

	test("an unknown argument is refused without a request", async () => {
		await harness.run("/usage wat");
		expect(harness.server.requestsFor("usage.status")).toHaveLength(0);
		expect(harness.host.text).toContain("usage: /usage [text]");
	});
});
