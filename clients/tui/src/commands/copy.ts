import { lexDocument } from "@oh-my-pi/pi-tui/components/markdown";
import type { Token } from "@oh-my-pi/pi-utils/marked";
import type { Block } from "../store/transcript-model.ts";
import type { SlashCommand } from "./registry.ts";

/** Use the assistant renderer's lexer, including nested lists/quotes and tilde fences. */
export function fencedCodeBlocks(text: string): string[] {
	const blocks: string[] = [];
	const walk = (tokens: readonly Token[]): void => {
		for (const token of tokens) {
			if (token.type === "code" && token.codeBlockStyle !== "indented") blocks.push(token.text);
			if (token.type === "list") walk(token.items);
			else if ("tokens" in token && Array.isArray(token.tokens)) walk(token.tokens);
		}
	};
	walk(lexDocument(text));
	return blocks;
}

export function selectCopyText(blocks: readonly Block[], argv: string[]): string {
	const [target, index] = argv;
	if (
		argv.length > 2 ||
		(target !== undefined && target !== "prompt" && target !== "code") ||
		(target === "prompt" && argv.length !== 1) ||
		(index !== undefined && (!/^[1-9]\d*$/.test(index) || !Number.isSafeInteger(Number(index))))
	) {
		throw new Error("Usage: /copy [prompt | code [n]] (code blocks are numbered from 1)");
	}
	let last: Block | undefined;
	const kind = target === "prompt" ? "user" : "assistant";
	for (let i = blocks.length - 1; i >= 0; i--) {
		if (blocks[i]!.kind !== kind) continue;
		last = blocks[i];
		break;
	}
	if (target === "prompt") {
		if (last?.kind !== "user" || !last.text) throw new Error("No user prompt to copy.");
		return last.text;
	}
	if (last?.kind !== "assistant") throw new Error("No assistant reply to copy.");
	const runId = last.runId;
	// A reply can be split into chronological segments around thinking and tools.
	const reply = blocks
		.filter((block) => block.kind === "assistant" && block.runId === runId)
		.map((block) => (block.kind === "assistant" ? block.text : ""))
		.join("\n\n");
	if (!reply) throw new Error("No assistant reply to copy.");
	if (target !== "code") return reply;
	const code = fencedCodeBlocks(reply);
	const selected = Number(index ?? 1);
	if (selected > code.length)
		throw new Error(`No code block ${selected} in the last reply (${code.length} found).`);
	return code[selected - 1]!;
}

export const copyCommand: SlashCommand = {
	name: "copy",
	summary: "Copy the last reply, a fenced code block, or the last user prompt",
	usage: "[prompt | code [n]]",
	group: "general",
	async run(ctx, argv) {
		const text = selectCopyText(ctx.session.blocks, argv);
		if (!ctx.ui.copyText) throw new Error("Clipboard is unavailable in this client.");
		await ctx.ui.copyText(text);
	},
};
