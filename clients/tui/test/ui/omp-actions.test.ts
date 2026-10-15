import { afterEach, expect, test } from "bun:test";
import { ompSessionWire } from "../../src/dev/fixtures/omp-fixtures.ts";
import type { ControlPlaneClient } from "../../src/protocol/client.ts";
import type { ControlPlaneMethods } from "../../src/protocol/methods.ts";
import { parseOmpSession } from "../../src/protocol/omp.ts";
import { OmpStore } from "../../src/store/omp-store.ts";
import { OmpController } from "../../src/ui/controllers/omp-controller.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";

afterEach(resetTheme);

test("operator actions resolve by ID, configure selected model and inspect child transcript", async () => {
	initTheme({ colorLevel: 0 });
	const session = parseOmpSession(ompSessionWire())!;
	const store = new OmpStore();
	store.upsert(session);
	const calls: unknown[] = [];
	const methods = {
		supports: () => true,
		ompModels: async () => ({ models: [{ selector: "provider/free", free: true }] }),
		ompSessionsConfigure: async (params: unknown) => {
			calls.push(params);
			return { session: { ...session, model: "provider/free" } };
		},
		ompSessionsSubagent: async (params: unknown) => {
			calls.push(params);
			return { transcript: { messages: [{ role: "assistant", text: "child tail\u001b[31m" }] } };
		},
		ompStatus: async () => ({ available: true }),
		ompSessionsList: async () => ({ sessions: [session] }),
	} as unknown as ControlPlaneMethods;
	const controller = new OmpController({
		store,
		methods,
		client: { online: true } as ControlPlaneClient,
		cwd: "/work/lemon",
		requestRender() {},
		notice() {},
		resolveApproval: async (id, decision) => {
			calls.push({ id, decision });
		},
	});
	try {
		controller.panel.update([session]);
		controller.panel.setVisible(true);
		await controller.resolveApproval(session, "approval_omp_1", "deny");
		expect(calls).toContainEqual({ id: "approval_omp_1", decision: "deny" });
		await controller.chooseModel(session);
		expect(controller.panel.render(200).join("\n")).toContain("provider/free [free]");
		controller.panel.handleInput("\r");
		await Promise.resolve();
		await Promise.resolve();
		expect(calls).toContainEqual({ id: session.id, model: "provider/free" });
		await controller.subagent(session, "Explore1");
		expect(calls).toContainEqual({ id: session.id, subagentId: "Explore1", limit: 50 });
		expect(controller.panel.render(200).join("\n")).toContain("child tail");
		expect(controller.panel.render(200).join("\n")).not.toContain("\u001b[31m");
		controller.panel.handleInput("\u001b");
		expect(controller.panel.render(200).join("\n")).not.toContain("transcript tail");
	} finally {
		controller.dispose();
	}
});
