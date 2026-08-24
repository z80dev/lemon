import { describe, expect, test } from "bun:test";
import type { ApprovalRequestedEvent } from "../../src/protocol/types.ts";
import { AppStore } from "../../src/store/app-store.ts";

function approval(id: string): ApprovalRequestedEvent {
	return {
		approvalId: id,
		runId: "run-1",
		sessionKey: "main",
		agentId: null,
		tool: "bash",
		action: {},
		rationale: null,
		requestedAtMs: null,
		expiresAtMs: null,
	};
}

describe("AppStore", () => {
	test("materializes sessions lazily and focuses the first one", () => {
		const store = new AppStore("main");
		expect(store.focusedKey).toBe("main");
		expect(store.focused.focused).toBe(true);
		expect(store.sessions.size).toBe(1);
		store.session("other");
		expect(store.sessions.size).toBe(2);
	});

	test("switching focus moves the flag and clears unread", () => {
		const store = new AppStore("main");
		const other = store.session("other");
		other.addNotice("background news");
		expect(store.totalUnread()).toBe(1);

		const changed: string[] = [];
		store.events.on("session-changed", ({ key }) => changed.push(key));
		store.setFocused("other");

		expect(changed).toEqual(["other"]);
		expect(store.focusedKey).toBe("other");
		expect(other.unread).toBe(0);
		expect(store.session("main").focused).toBe(false);
		expect(store.totalUnread()).toBe(0);
	});

	test("connection changes emit once per transition", () => {
		const store = new AppStore("main");
		const states: string[] = [];
		store.events.on("conn-changed", ({ state }) => states.push(state));
		store.setConnection("online");
		store.setConnection("online");
		store.setConnection("reconnecting");
		expect(states).toEqual(["online", "reconnecting"]);
	});

	test("approvals track pending count and resolve their block", () => {
		const store = new AppStore("main");
		const block = store.focused.addApprovalBlock("ap-1", "bash");
		store.addApproval(approval("ap-1"), block);
		expect(store.pendingApprovals).toBe(1);

		store.resolveApproval("ap-1", "once");
		expect(store.pendingApprovals).toBe(0);
		expect(block.status).toBe("resolved");
		expect(block.decision).toBe("once");
		expect(store.resolveApproval("ap-1")).toBeUndefined();
	});
});
