import { beforeEach, describe, expect, test } from "bun:test";
import { QueueStore, resetQueueIds } from "../../src/store/queue-store.ts";

beforeEach(() => {
	resetQueueIds();
});

describe("QueueStore", () => {
	test("holds prompts per session and pops them head first", () => {
		const queue = new QueueStore();
		queue.push("a", "first");
		queue.push("a", "second");
		queue.push("b", "other session");

		expect(queue.length("a")).toBe(2);
		expect(queue.length("b")).toBe(1);
		expect(queue.total()).toBe(3);
		expect(queue.shift("a")?.text).toBe("first");
		expect(queue.items("a").map((item) => item.text)).toEqual(["second"]);
		// Popping one session must not touch another's backlog.
		expect(queue.items("b").map((item) => item.text)).toEqual(["other session"]);
	});

	test("a blank prompt is not a prompt", () => {
		const queue = new QueueStore();
		expect(queue.push("a", "   \n ")).toBeUndefined();
		expect(queue.length("a")).toBe(0);
	});

	test("items can be edited and deleted in place", () => {
		const queue = new QueueStore();
		const first = queue.push("a", "first")!;
		const second = queue.push("a", "second")!;

		queue.replace("a", first.id, "rewritten");
		expect(queue.items("a").map((item) => item.text)).toEqual(["rewritten", "second"]);

		expect(queue.remove("a", second.id)?.text).toBe("second");
		expect(queue.items("a").map((item) => item.text)).toEqual(["rewritten"]);
		expect(queue.remove("a", "nope")).toBeUndefined();
	});

	test("editing an item to nothing deletes it", () => {
		const queue = new QueueStore();
		const item = queue.push("a", "first")!;
		queue.replace("a", item.id, "  ");
		expect(queue.length("a")).toBe(0);
	});

	test("every mutation announces the session it touched", () => {
		const queue = new QueueStore();
		const seen: Array<{ sessionKey: string; length: number }> = [];
		queue.events.on("changed", (payload) => seen.push(payload));

		const item = queue.push("a", "first")!;
		queue.remove("a", item.id);
		queue.push("a", "second");
		queue.clear("a");
		// A clear with nothing to clear is not a change.
		queue.clear("a");

		expect(seen).toEqual([
			{ sessionKey: "a", length: 1 },
			{ sessionKey: "a", length: 0 },
			{ sessionKey: "a", length: 1 },
			{ sessionKey: "a", length: 0 },
		]);
	});

	test("an untouched session never allocates and reports empty", () => {
		const queue = new QueueStore();
		expect(queue.items("ghost")).toEqual([]);
		expect(queue.shift("ghost")).toBeUndefined();
		expect(queue.sessionKeys()).toEqual([]);
	});
});
