import { expect, test } from "bun:test";
import { ompSessionWire } from "../../src/dev/fixtures/omp-fixtures.ts";
import { parseOmpSession } from "../../src/protocol/omp.ts";
import { ompAgentNode, ompDetailNodes } from "../../src/ui/omp-nodes.ts";
import { TERMINAL_CONTROLS } from "../helpers/memory-terminal.ts";

test("semantic nodes prominently show approvals, worktree and child activity", () => {
	const parsed = parseOmpSession(ompSessionWire());
	if (!parsed) throw new Error("fixture");
	const session = {
		...parsed,
		pendingApprovals: [
			{ id: "approval_child", tool: "bash\u001b[31m", details: null, requestedAt: null },
		],
		worktree: { ...parsed.worktree!, branch: "worker", kept: true, dirty: true },
		subagents: [
			{
				...parsed.subagents[0]!,
				id: "child",
				agent: null,
				description: null,
				status: "running",
				activity: "Reading files",
			},
		],
	};
	const header = JSON.stringify(ompAgentNode(session, { now: 0, key: "session" }));
	const body = JSON.stringify(ompDetailNodes(session));
	expect(header).toContain("waiting for approval: bash");
	expect(body).toContain("worktree: worker · kept · dirty");
	expect(body).toContain("Reading files");
	expect(header + body).not.toMatch(TERMINAL_CONTROLS);
	expect(header + body).not.toContain("\\u001b");
});
