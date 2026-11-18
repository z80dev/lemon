import type { TranscriptEntryLike } from "@oh-my-pi/pi-tui/chat/transcript-entry";
import type { OutlineTarget } from "@oh-my-pi/pi-tui/chat/transcript-outline";
import { lexDocument } from "@oh-my-pi/pi-tui/components/markdown";
import {
	type CopyPickSource,
	CopySelectorComponent,
	collectBlocks,
	targetCopy,
} from "@oh-my-pi/pi-tui/overlays/copy-selector";
import type { Token } from "@oh-my-pi/pi-utils/marked";
import { displayDeep } from "../formatters/base.ts";
import { describeError } from "../protocol/errors.ts";
import type { Block } from "../store/transcript-model.ts";
import { replayDeps } from "../ui/replay-overlays.ts";
import { blocksToTranscriptEntries } from "../ui/transcript-entries.ts";
import type { CommandContext, SlashCommand } from "./registry.ts";

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

/**
 * Fullscreen `/copy` picker over the replayed transcript: Up/Down move the
 * outline over turns, Right descends into a turn's code, quotes, commands and
 * links, Enter copies, Esc closes.
 *
 * The picker renders previews (rows and Tern Markdown) from entries passed
 * through the display policy ({@link displayDeep}); what reaches the
 * clipboard is recomputed from the stored, unescaped entry the pick came from.
 */
function openCopySelector(ctx: CommandContext, copyText: (text: string) => Promise<void>): void {
	const raw = blocksToTranscriptEntries(ctx.session.blocks);
	const shown = raw.map((entry) => displayDeep(entry) as TranscriptEntryLike);
	const rawOf = new Map(shown.map((entry, index) => [entry, raw[index]!]));
	ctx.ui.presentOverlay!((host) => {
		const selector: CopySelectorComponent = new CopySelectorComponent(shown, {
			...replayDeps(host, ctx.cwd ?? process.cwd()),
			onPick: (_shownContent, label, source) => {
				host.close();
				const content = rawPick(source, rawOf.get(source.entry));
				if (content === undefined) {
					ctx.ui.notice("copy failed: the picked text no longer matches the transcript", "error");
					return;
				}
				copyText(content).then(
					() => ctx.ui.notice(`copied ${label}`),
					(error) => ctx.ui.notice(`copy failed: ${describeError(error)}`, "error"),
				);
			},
			onCancel: () => host.close(),
		});
		return selector;
	});
}

/**
 * The unescaped text of a pick: the stored entry's block with the same ordinal
 * (carried by the picker, never recovered by comparing escaped content), or
 * the stored entry's turn. A block whose kind no longer lines up fails closed.
 */
function rawPick(source: CopyPickSource, raw: TranscriptEntryLike | undefined): string | undefined {
	if (!raw) return undefined;
	const rawBlocks = collectBlocks([raw]);
	if (source.block) {
		const { ordinal, kind } = source.block;
		if (ordinal === undefined) return undefined;
		const match = rawBlocks[ordinal];
		return match && match.kind === kind ? match.content : undefined;
	}
	return targetCopy({ entries: [raw] } as unknown as OutlineTarget, rawBlocks).content;
}

export const copyCommand: SlashCommand = {
	name: "copy",
	summary:
		"Pick a turn or block to copy, or copy the last reply, a fenced code block, or the last user prompt",
	usage: "[prompt | code [n]]",
	group: "general",
	async run(ctx, argv) {
		if (
			argv.length === 0 &&
			ctx.ui.presentOverlay &&
			ctx.ui.copyText &&
			ctx.session.blocks.length > 0
		) {
			openCopySelector(ctx, (text) => ctx.ui.copyText!(text));
			return;
		}
		const text = selectCopyText(ctx.session.blocks, argv);
		if (!ctx.ui.copyText) throw new Error("Clipboard is unavailable in this client.");
		await ctx.ui.copyText(text);
	},
};
