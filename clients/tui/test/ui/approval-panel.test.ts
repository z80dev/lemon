import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import type { NativeNode } from "@oh-my-pi/pi-tui/native/node";
import { visibleWidth } from "@oh-my-pi/pi-tui/utils";
import type { ApprovalRequestedEvent } from "../../src/protocol/types.ts";
import {
	ACTION_PREVIEW_ROWS,
	ApprovalPanelComponent,
	ApprovalRecordComponent,
	countdown,
	describeAction,
	isApprovedDecision,
	PLAN_PREVIEW_ROWS,
	planPreviewRows,
	previewRows,
} from "../../src/ui/components/approval-panel.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { renderPlain } from "../helpers/memory-terminal.ts";

const NOW = 1_000_000;

beforeEach(() => {
	initTheme({ colorLevel: 3 });
});

afterEach(() => {
	resetTheme();
	invalidateThemeAdapters();
});

function request(overrides: Partial<ApprovalRequestedEvent> = {}): ApprovalRequestedEvent {
	return {
		approvalId: "ap-1",
		runId: "run-1",
		sessionKey: "tui-test",
		agentId: null,
		tool: "bash",
		action: { command: "echo p4check" },
		rationale: "the model wants to run a shell command",
		requestedAtMs: NOW,
		expiresAtMs: NOW + 45_000,
		...overrides,
	};
}

function build(event = request()) {
	const decisions: string[] = [];
	const panel = new ApprovalPanelComponent({
		onDecide: (decision) => decisions.push(decision),
		now: () => NOW,
	});
	panel.show(event);
	return { panel, decisions };
}

describe("ApprovalPanelComponent", () => {
	test("shows the tool, the command, the rationale and every option", () => {
		const { panel } = build();
		const text = renderPlain(panel.render(80));
		expect(text).toContain("approval required · bash");
		expect(text).toContain("echo p4check");
		expect(text).toContain("the model wants to run a shell command");
		expect(text).toContain("1  allow once");
		expect(text).toContain("2  allow for this session");
		expect(text).toContain("3  allow always");
		expect(text).toContain("4  deny");
		expect(text).toContain("expires in 45s");
	});

	test("makes a blocked-skill override unmistakable and exact-bundle scoped", () => {
		const { panel } = build(
			request({
				tool: "skills.install.security_override",
				action: {
					description: "Override BLOCKED security audit for 'hermes-agent' bundle abc123",
					security_override: true,
					bundle_hash: "abc123",
					findings: ["[block] remote_exec: curl piped to shell interpreter"],
				},
				rationale: "SECURITY WARNING: remote execution was detected",
			}),
		);
		const text = renderPlain(panel.render(100));
		expect(text).toContain("SECURITY OVERRIDE · skills.install.security_override");
		expect(text).toContain("Override BLOCKED security audit");
		expect(text).toContain("bundle: abc123");
		expect(text).toContain("[block] remote_exec: curl piped to shell interpreter");
		expect(text).toContain("SECURITY WARNING: remote execution was detected");
		expect(text).toContain("accept this blocked bundle once");
		expect(text).toContain("accept this exact bundle always");
	});

	test("a long command is wrapped, not truncated", () => {
		const command = `find . ${"-name '*.ts' ".repeat(20)}`;
		const { panel } = build(request({ action: { command } }));
		const rows = panel.render(60);
		for (const row of rows) expect(visibleWidth(row)).toBeLessThanOrEqual(60);
		const text = renderPlain(rows);
		// Every word of the command survives somewhere in the wrapped body, which
		// is the whole point: a decision is made on what is on screen.
		expect(text).toContain("find .");
		expect(text.split("-name").length - 1).toBe(20);
		expect(text).not.toContain("…");
	});

	test("an enormous command is capped in rows with the rest counted", () => {
		const rows = previewRows(Array.from({ length: 40 }, (_, i) => `line ${i}`).join("\n"), 60);
		expect(rows).toHaveLength(ACTION_PREVIEW_ROWS + 1);
		expect(rows[ACTION_PREVIEW_ROWS]).toBe(`+${40 - ACTION_PREVIEW_ROWS} more`);
	});

	test("number keys pick an option outright", () => {
		const { panel, decisions } = build();
		panel.handleInput("1");
		panel.handleInput("2");
		panel.handleInput("3");
		panel.handleInput("4");
		expect(decisions).toEqual(["approve_once", "approve_session", "approve_global", "deny"]);
	});

	test("arrows move the selection and enter takes it", () => {
		const { panel, decisions } = build();
		panel.handleInput("\x1b[B");
		panel.handleInput("\x1b[B");
		expect(panel.selectedOption.decision).toBe("approve_global");
		panel.handleInput("\r");
		expect(decisions).toEqual(["approve_global"]);
	});

	test("escape denies rather than dismissing", () => {
		const { panel, decisions } = build();
		panel.handleInput("\x1b");
		expect(decisions).toEqual(["deny"]);
	});

	test("hidden panels render nothing and ignore keys", () => {
		const { panel, decisions } = build();
		panel.hide();
		expect(panel.visible).toBe(false);
		expect(panel.render(80)).toEqual([]);
		panel.handleInput("1");
		expect(decisions).toEqual([]);
	});

	test("rows never exceed the width and repeat renders are memoized", () => {
		const { panel } = build();
		for (const width of [100, 80, 40, 20, 10]) {
			for (const row of panel.render(width)) {
				expect(visibleWidth(row)).toBeLessThanOrEqual(width);
			}
		}
		const rows = panel.render(80);
		expect(panel.render(80)).toBe(rows);
		panel.tick();
		expect(panel.render(80)).not.toBe(rows);
	});
});

describe("plan proposals", () => {
	const plan = (markdown: string, title = "Fix the API") =>
		request({
			approvalId: "ap-plan",
			tool: "propose_plan",
			action: { title, path: "/plans/fix-api-plan.md", plan: markdown },
			rationale: `Approve plan "${title}" and start implementation?`,
			expiresAtMs: null,
		});

	test("heads with the title and shows the plan file and Markdown", () => {
		const { panel } = build(plan("# Fix the API\n\n- keep the public surface\n- add a test"));
		const text = renderPlain(panel.render(80));
		expect(text).toContain("Plan proposal · Fix the API");
		expect(text).toContain("plan file: /plans/fix-api-plan.md");
		expect(text).toContain("# Fix the API");
		expect(text).toContain("- add a test");
		expect(text).toContain('Approve plan "Fix the API" and start implementation?');
		expect(text).toContain("1  Approve and execute");
		expect(text).toContain("2  Refine plan");
		expect(text).toContain("1-2 picks · ↑↓ then enter · esc refines");
		for (const scoped of ["allow once", "allow for this session", "allow always", "3  ", "4  "]) {
			expect(text).not.toContain(scoped);
		}
	});

	test("offers exactly approve_once and deny; scope keys do nothing", () => {
		const { panel, decisions } = build(plan("step"));
		panel.handleInput("3");
		panel.handleInput("4");
		expect(decisions).toEqual([]);
		panel.handleInput("1");
		panel.handleInput("2");
		expect(decisions).toEqual(["approve_once", "deny"]);
	});

	test("arrows stop at Refine plan and escape refines", () => {
		const { panel, decisions } = build(plan("step"));
		for (let i = 0; i < 5; i++) panel.handleInput("\x1b[B");
		expect(panel.selectedOption).toMatchObject({ label: "Refine plan", decision: "deny" });
		panel.handleInput("\r");
		panel.handleInput("\x1b");
		expect(decisions).toEqual(["deny", "deny"]);
	});

	test("a long plan is bounded and the rest counted in source lines", () => {
		const markdown = Array.from({ length: 40 }, (_, i) => `line ${i + 1}`).join("\n");
		const rows = planPreviewRows(markdown, 60);
		expect(rows).toHaveLength(PLAN_PREVIEW_ROWS + 1);
		expect(rows[0]).toBe("line 1");
		expect(rows.at(-1)).toBe(`… ${40 - PLAN_PREVIEW_ROWS} more lines (40 total)`);
		const { panel } = build(plan(markdown));
		for (const width of [80, 40, 12]) {
			for (const row of panel.render(width)) expect(visibleWidth(row)).toBeLessThanOrEqual(width);
		}
	});

	test("a short plan is shown whole; an empty one says so; control bytes never reach the terminal", () => {
		expect(planPreviewRows("a\nb\n\n", 40)).toEqual(["a", "b"]);
		expect(planPreviewRows("  \n", 40)).toEqual(["(empty plan)"]);
		expect(planPreviewRows("x\x1b]52;c;evil\x07y", 40)).toEqual(["x]52;c;evily"]);
	});

	test("the transcript record reads as a plan decision", () => {
		const pending = new ApprovalRecordComponent("ap-plan", "propose_plan");
		expect(renderPlain(pending.render(80))).toContain("plan proposed — awaiting your decision");
		pending.annotate("approve_once");
		expect(renderPlain(pending.render(80))).toContain("plan approved — executing");
		const refined = new ApprovalRecordComponent("ap-plan", "propose_plan", "deny");
		expect(renderPlain(refined.render(80))).toContain("plan sent back for refinement");
		// Another client's resolution arrives in the event vocabulary.
		expect(
			renderPlain(new ApprovalRecordComponent("a", "propose_plan", "once").render(80)),
		).toContain("plan approved — executing");
	});

	test("approval decisions are recognised in both vocabularies", () => {
		for (const decision of ["approve_once", "approve_session", "once", "global"]) {
			expect(isApprovedDecision(decision)).toBe(true);
		}
		for (const decision of ["deny", "expired", undefined]) {
			expect(isApprovedDecision(decision)).toBe(false);
		}
	});
});

describe("describeAction", () => {
	test("prefers a command, falls back to the map, never to nothing", () => {
		expect(describeAction({ command: "ls -la" })).toBe("ls -la");
		expect(describeAction({ cmd: "ls" })).toBe("ls");
		expect(describeAction({ path: "/etc/hosts" })).toBe("/etc/hosts");
		expect(describeAction({ weird: 3 })).toBe('{"weird":3}');
		expect(describeAction({})).toBe("(no action detail)");
		expect(describeAction(null)).toBe("(no action detail)");
	});
});

describe("countdown", () => {
	test("counts down in seconds, then minutes, then stops", () => {
		expect(countdown(NOW + 42_000, NOW)).toBe("expires in 42s");
		expect(countdown(NOW + 125_000, NOW)).toBe("expires in 2m05s");
		expect(countdown(NOW - 1, NOW)).toBe("expired");
		expect(countdown(null, NOW)).toBe("");
	});
});

describe("ApprovalRecordComponent", () => {
	test("stays unfinalized while pending and seals once answered", () => {
		const record = new ApprovalRecordComponent("ap-1", "bash");
		expect(record.isTranscriptBlockFinalized()).toBe(false);
		expect(renderPlain(record.render(80))).toContain("approval requested for bash (ap-1)");

		const version = record.getTranscriptBlockVersion();
		record.annotate("approve_session");
		expect(record.isTranscriptBlockFinalized()).toBe(true);
		expect(record.getTranscriptBlockVersion()).toBeGreaterThan(version);
		expect(renderPlain(record.render(80))).toContain("approval granted for bash (session)");
	});

	test("a denial reads as a denial, and a second answer cannot rewrite it", () => {
		const record = new ApprovalRecordComponent("ap-2", "write", "deny");
		expect(renderPlain(record.render(80))).toContain("approval denied for write (deny)");
		record.annotate("approve_once");
		expect(record.decision).toBe("deny");
	});

	test("an expired, timed-out or cancelled approval never reads as granted", () => {
		const cases: Array<[string, string]> = [
			["expired", "approval expired for bash — the run ended"],
			["timeout", "approval timed out for bash"],
			["cancelled", "approval withdrawn for bash"],
		];
		for (const [decision, line] of cases) {
			const record = new ApprovalRecordComponent("ap-3", "bash", decision);
			const plain = renderPlain(record.render(80));
			expect(plain).toContain(line);
			expect(plain).not.toContain("granted");
			expect(JSON.stringify(record.describe())).toContain(line.replace(/^a/, "A"));
			expect(record.describe()).toMatchObject({ p: { tone: "warning" } });
		}
	});

	test("a plan proposal that expired never reads as approved", () => {
		const expired = new ApprovalRecordComponent("ap-4", "propose_plan", "expired");
		expect(renderPlain(expired.render(80))).toContain("plan proposal expired — the run ended");
		expect(JSON.stringify(expired.describe())).toContain("Plan proposal expired — the run ended");
		const timedOut = new ApprovalRecordComponent("ap-4", "propose_plan", "timeout");
		expect(renderPlain(timedOut.render(80))).toContain("plan proposal closed (timeout)");
		expect(renderPlain(timedOut.render(80))).not.toContain("plan approved");
	});
});

describe("ApprovalPanelComponent native buttons", () => {
	test("a button click takes its quick-pick decision path", () => {
		const { panel, decisions } = build();
		const described = panel.describe();
		expect(panel.describe()).toBe(described);
		panel.handleNativeEvent({
			type: "action",
			key: "actions/approve_session",
			act: "approve_session",
			mods: [],
		});
		panel.handleNativeEvent({ type: "action", key: "actions/bogus", act: "bogus", mods: [] });
		expect(decisions).toEqual(["approve_session"]);
	});

	/** Every node in a described tree, depth first. */
	function nodes(root: NativeNode): NativeNode[] {
		const children = (root.c ?? []).filter((child): child is NativeNode => "k" in child);
		return [root, ...children.flatMap(nodes)];
	}

	function buttons(root: NativeNode) {
		return nodes(root)
			.filter((entry) => entry.p && "role" in entry.p && entry.p.role === "omp.btn")
			.map((entry) => ({
				act: entry.p && "actions" in entry.p ? entry.p.actions?.click : undefined,
				tone: entry.p && "tone" in entry.p ? entry.p.tone : undefined,
				label: JSON.stringify(entry.c),
			}));
	}

	test("a plan proposal offers exactly two clickable decisions", () => {
		const markdown = Array.from({ length: 30 }, (_, i) => `- step ${i + 1}`).join("\n");
		const { panel, decisions } = build(
			request({
				tool: "propose_plan",
				action: { title: "Fix  the\nAPI", path: "/plans/fix-api-plan.md", plan: markdown },
				rationale: 'Approve plan "Fix the API" and start implementation?',
			}),
		);
		const described = panel.describe();
		const json = JSON.stringify(described);
		expect(json).toContain("Plan proposal · Fix the API");
		expect(json).toContain("plan file: /plans/fix-api-plan.md");
		expect(json).toContain("- step 1");
		expect(json).toContain(`- step ${PLAN_PREVIEW_ROWS}"`);
		expect(json).not.toContain(`- step ${PLAN_PREVIEW_ROWS + 1}"`);
		expect(json).toContain(`… ${30 - PLAN_PREVIEW_ROWS} more lines (30 total)`);

		const offered = buttons(described);
		expect(offered.map((button) => button.act)).toEqual(["approve_once", "deny"]);
		expect(offered[0]!.label).toContain("Approve and execute");
		expect(offered[0]!.tone).toBe("accent");
		expect(offered[1]!.label).toContain("Refine plan");
		expect(offered[1]!.tone).toBeUndefined();

		for (const act of ["approve_session", "approve_global", "deny", "approve_once"]) {
			panel.handleNativeEvent({ type: "action", key: `actions/${act}`, act, mods: [] });
		}
		expect(decisions).toEqual(["deny", "approve_once"]);
	});

	test("other tools keep the four scoped buttons", () => {
		const { panel } = build();
		expect(buttons(panel.describe()).map((button) => button.act)).toEqual([
			"approve_once",
			"approve_session",
			"approve_global",
			"deny",
		]);
	});

	test("the native transcript record reads as a plan decision", () => {
		const record = new ApprovalRecordComponent("ap-plan", "propose_plan");
		expect(JSON.stringify(record.describe())).toContain("Plan proposed — awaiting your decision");
		record.annotate("deny");
		expect(record.describe()).toMatchObject({ p: { tone: "muted" } });
		expect(JSON.stringify(record.describe())).toContain("Plan sent back for refinement");
		const approved = new ApprovalRecordComponent("ap-plan", "propose_plan", "approve_once");
		expect(JSON.stringify(approved.describe())).toContain("Plan approved — executing");
	});
});
