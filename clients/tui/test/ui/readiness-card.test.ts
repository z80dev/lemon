import { afterEach, beforeEach, expect, test } from "bun:test";
import { visibleWidth } from "@oh-my-pi/pi-tui/utils";
import { AppStore } from "../../src/store/app-store.ts";
import { ReadinessCard } from "../../src/ui/components/readiness-card.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { renderPlain } from "../helpers/memory-terminal.ts";

beforeEach(() => initTheme({ colorLevel: 3 }));
afterEach(() => {
	resetTheme();
	invalidateThemeAdapters();
});

function pendingStore(): AppStore {
	const store = new AppStore("tui-test");
	store.setupStatus = {
		ready: false,
		pendingSteps: [{ id: "provider", label: "Choose a provider", command: "lemon setup provider" }],
	};
	return store;
}

test("pending readiness has matching native and row guidance", () => {
	const card = new ReadinessCard(pendingStore());
	expect(renderPlain(card.render(100))).toContain("Choose a provider — run `lemon setup provider`");
	const native = JSON.stringify(card.describe());
	expect(native).toContain("Finish setup before chatting");
	expect(native).toContain("lemon setup provider");
});

test("narrow terminals wrap rather than lose the recovery command", () => {
	const card = new ReadinessCard(pendingStore());
	const rows = card.render(12);
	expect(rows.every((line) => visibleWidth(line) <= 12)).toBe(true);
	expect(renderPlain(rows).replace(/\s+/g, "")).toContain("lemonsetupprovider");
	expect(card.render(0)).toEqual([]);
});

test("the same card hides after readiness changes or becomes unavailable", () => {
	const store = pendingStore();
	const card = new ReadinessCard(store);
	expect(card.render(100).length).toBeGreaterThan(0);
	store.setupStatus = { ready: true, pendingSteps: [] };
	expect(card.render(100)).toEqual([]);
	expect(JSON.stringify(card.describe())).not.toContain("Finish setup");
	store.setupStatus = undefined;
	expect(card.render(100)).toEqual([]);
});
