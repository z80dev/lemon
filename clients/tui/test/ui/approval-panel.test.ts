import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { visibleWidth } from "@oh-my-pi/pi-tui/utils";
import type { ApprovalRequestedEvent } from "../../src/protocol/types.ts";
import {
	ACTION_PREVIEW_ROWS,
	ApprovalPanelComponent,
	ApprovalRecordComponent,
	countdown,
	describeAction,
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
});
