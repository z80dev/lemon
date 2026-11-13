import type { SlashCommand } from "./registry.ts";

export const paletteCommand: SlashCommand = {
	name: "palette",
	summary: "search commands, local skills and prompt templates",
	usage: "[query]",
	group: "interface",
	availableWhen: (ctx) => (ctx.ui.openCommandPalette ? true : "no command palette in this client"),
	run: (ctx) => ctx.ui.openCommandPalette!(ctx.rest.trim() || undefined),
};

export const outputCommand: SlashCommand = {
	name: "output",
	summary: "browse complete tool output receipts",
	group: "interface",
	availableWhen: (ctx) => (ctx.ui.openToolOutput ? true : "no tool inspector in this client"),
	run: (ctx) => ctx.ui.openToolOutput!("output"),
};

export const diffCommand: SlashCommand = {
	name: "diff",
	summary: "inspect the latest edit diff without card truncation",
	group: "interface",
	availableWhen: (ctx) => (ctx.ui.openToolOutput ? true : "no tool inspector in this client"),
	run: (ctx) => ctx.ui.openToolOutput!("diff"),
};
