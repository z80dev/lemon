import { expect, test } from "bun:test";
import { agentHubCommand } from "../../src/commands/agent-hub.ts";
import { createCommandRegistry } from "../../src/commands/index.ts";
import type { CommandContext } from "../../src/commands/registry.ts";

function context(toggle?: () => void) {
	const notices: string[] = [];
	const ctx = {
		session: { key: "parent" },
		ui: {
			notice: (text: string) => notices.push(text),
			...(toggle ? { toggleTaskTree: toggle } : {}),
		},
	} as unknown as CommandContext;
	return { ctx, notices };
}

test("/hub, /tasktree and /subagents are one command that toggles the docked hub", async () => {
	const registry = createCommandRegistry();
	for (const name of ["hub", "tasktree", "subagents"]) {
		expect(registry.get(name)).toBe(agentHubCommand);
	}
	let toggles = 0;
	const { ctx, notices } = context(() => toggles++);
	expect(agentHubCommand.availableWhen?.(ctx)).toBe(true);
	await agentHubCommand.run(ctx, []);
	expect(toggles).toBe(1);
	await agentHubCommand.run(ctx, ["extra"]);
	expect(toggles).toBe(1);
	expect(notices).toEqual(["usage: /hub (no arguments)"]);
});

test("a client without the hub reports why /hub is unavailable", () => {
	expect(agentHubCommand.availableWhen?.(context().ctx)).toBe("no agent hub in this client");
});
