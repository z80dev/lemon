import { afterEach, beforeEach, expect, test } from "bun:test";
import { createHarness, type Harness } from "../helpers/command-harness.ts";

let h: Harness;
let jobs: Record<string, unknown>[];
beforeEach(async () => {
	h = await createHarness({
		methods: ["cron.list", "cron.pause", "cron.resume", "cron.run", "cron.remove"],
	});
	jobs = [
		{
			id: "j1",
			name: "Morning",
			schedule: "daily",
			enabled: true,
			failureStreak: 2,
			lastStatus: "failed",
		},
	];
	h.server.onMethod("cron.list", () => ({ jobs }));
	for (const method of ["cron.pause", "cron.resume", "cron.remove"])
		h.server.onMethod(method, () => ({}));
	h.server.onMethod("cron.run", () => ({ runId: "r1" }));
});
afterEach(() => h.stop());

test("default list shows health and supports failing JSON", async () => {
	await h.run("/cron");
	expect(h.host.last?.text).toContain("failures 2");
	await h.run("/cron list --failing --json");
	expect(JSON.parse(h.host.last!.text).total).toBe(1);
});
test("mutations resolve names case insensitively", async () => {
	for (const action of ["pause", "resume", "run"]) {
		await h.run(`/cron ${action} MORNING`);
		expect(h.server.requestsFor(`cron.${action}`)[0]?.params).toEqual({ id: "j1" });
	}
});
test("ambiguous names refuse with candidates", async () => {
	jobs.push({ id: "j2", name: "MORNING" });
	await h.run("/cron pause morning");
	expect(h.host.last?.text).toContain("j1, j2");
	expect(h.server.requestsFor("cron.pause")).toHaveLength(0);
});
test("remove binds confirmation to the resolved ID and defaults to cancel", async () => {
	await h.run("/cron remove Morning");
	expect(h.server.requestsFor("cron.remove")).toHaveLength(0);
	const picker = h.host.pickers.at(-1)!;
	expect(picker.items[0]?.value).toBe("cancel");
	await picker.onSelect(picker.items[0]!);
	expect(h.server.requestsFor("cron.remove")).toHaveLength(0);
	await picker.onSelect(picker.items[1]!);
	expect(h.server.requestsFor("cron.remove")[0]?.params).toEqual({ id: "j1" });
});
