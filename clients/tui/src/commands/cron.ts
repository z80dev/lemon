import { METHOD } from "../protocol/methods.ts";
import { asArray, humanTime, pick, pickNumber, pickString } from "./format.ts";
import type { SlashCommand } from "./registry.ts";

export const cronCommand: SlashCommand = {
	name: "cron",
	summary: "list, pause, resume, trigger, or remove scheduled jobs",
	usage: "[list [--failing] [--json] | pause|resume|run <id|name> | remove <id|name>]",
	group: "sessions",
	methods: [METHOD.cronList],
	async run(ctx, argv) {
		const action = argv[0] ?? "list";
		const args = argv.slice(1);
		const list = action === "list";
		if (
			(list && args.some((arg) => !["--failing", "--json"].includes(arg))) ||
			(!list && (!["pause", "resume", "run", "remove"].includes(action) || args.length !== 1))
		) {
			ctx.ui.notice(`usage: /cron ${cronCommand.usage}`, "error");
			return;
		}
		const result = await ctx.methods.cronList({ includeTargetText: false });
		const jobs = asArray(result.jobs);
		if (list) {
			const selected = jobs.filter(
				(job) => !args.includes("--failing") || (pickNumber(job, "failureStreak") ?? 0) > 0,
			);
			if (args.includes("--json")) {
				ctx.ui.notice(JSON.stringify({ jobs: selected, total: selected.length }));
				return;
			}
			ctx.ui.noticeBlock(
				selected.length
					? selected.map(
							(job) =>
								`${pickString(job, "id")} · ${pickString(job, "name") ?? "-"} · ${pickString(job, "schedule")} · ${pick(job, "enabled") === true ? "enabled" : "paused"} · next ${humanTime(pickNumber(job, "nextRunAtMs")) ?? "-"} · failures ${pickNumber(job, "failureStreak") ?? 0} · ${pickString(job, "lastStatus") ?? "-"}`,
						)
					: ["no cron jobs"],
			);
			return;
		}
		const target = args[0]!;
		const exact = jobs.find((job) => pickString(job, "id") === target);
		const matches = exact
			? [exact]
			: jobs.filter((job) => pickString(job, "name")?.toLowerCase() === target.toLowerCase());
		if (matches.length !== 1) {
			ctx.ui.notice(
				matches.length
					? `ambiguous cron name; use an ID: ${matches.map((job) => pickString(job, "id")).join(", ")}`
					: "cron job not found",
				"error",
			);
			return;
		}
		const id = pickString(matches[0], "id");
		if (!id) throw new Error("invalid cron job response");
		const mutate = async () => {
			if (action === "pause") await ctx.methods.cronPause({ id });
			else if (action === "resume") await ctx.methods.cronResume({ id });
			else if (action === "run") {
				const receipt = await ctx.methods.cronRun({ id });
				const runId = pickString(receipt, "runId");
				if (!runId) throw new Error("cron run outcome unknown; check cron runs before retrying");
				ctx.ui.notice(`cron run · ${id} · run ${runId}`);
				return;
			} else await ctx.methods.cronRemove({ id });
			ctx.ui.notice(`cron ${action} · ${id}`);
		};
		if (action === "remove") {
			ctx.ui.openPicker({
				title: `remove cron ${pickString(matches[0], "name") ?? id} (${id})?`,
				items: [
					{ value: "cancel", label: "Cancel" },
					{ value: "remove", label: "Remove this job" },
				],
				onSelect: async (choice) => {
					if (choice.value === "remove") await mutate();
				},
			});
		} else await mutate();
	},
};
