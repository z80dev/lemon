import { expect, test } from "bun:test";
import { truncateToWidth, visibleWidth } from "@oh-my-pi/pi-tui";

test("pi-natives text measurement works", () => {
	expect(visibleWidth("日本語")).toBe(6);
	expect(visibleWidth("hello")).toBe(5);
});

test("truncateToWidth respects display width", () => {
	expect(visibleWidth(truncateToWidth("hello world", 5))).toBeLessThanOrEqual(5);
});
