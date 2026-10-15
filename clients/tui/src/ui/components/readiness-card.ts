import { node, span, text } from "@oh-my-pi/pi-tui/native/describe";
import type { NativeNode } from "@oh-my-pi/pi-tui/native/node";
import type { Component } from "@oh-my-pi/pi-tui/tui";
import { wrapTextWithAnsi } from "@oh-my-pi/pi-tui/utils";
import type { AppStore } from "../../store/app-store.ts";
import { getTheme } from "../theme/theme.ts";

/** Mutable dock content, never a transcript notice that survives completed setup. */
export class ReadinessCard implements Component {
	constructor(private readonly store: AppStore) {}

	#lines(): string[] {
		const status = this.store.setupStatus;
		if (!status || status.ready || status.pendingSteps.length === 0) return [];
		return [
			"Finish setup before chatting",
			...status.pendingSteps.map((step) => `${step.label} — run \`${step.command}\``),
		];
	}

	render(width: number): string[] {
		if (width <= 0) return [];
		const theme = getTheme();
		return this.#lines().flatMap((line, index) =>
			wrapTextWithAnsi(line, width).map((part) => theme.fg(index === 0 ? "warning" : "dim", part)),
		);
	}

	describe(): NativeNode {
		const lines = this.#lines();
		return node(
			lines.length ? "card" : "col",
			{ role: "lemon.setup" },
			lines.map((line, index) => text([span(line, index === 0 ? "strong" : "muted")])),
		);
	}

	invalidate(): void {}
}
