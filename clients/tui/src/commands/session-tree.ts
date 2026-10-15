import { ControlPlaneError, NotConnectedError } from "../protocol/errors.ts";
import { METHOD } from "../protocol/methods.ts";
import type {
	SessionRewindPreview,
	SessionRewindResult,
	SessionRewindTarget,
	SessionTreeEntry,
} from "../protocol/session-tree.ts";
import { forkSession } from "./fork.ts";
import type { CommandContext, PickerChoice, SlashCommand } from "./registry.ts";

const PAGE_SIZE = 100;
const NEXT_PAGE = "page:next";
const PREVIOUS_PAGE = "page:previous";

type TreeMode = "inspect" | "rewind";

export const treeCommand: SlashCommand = {
	name: "tree",
	summary: "browse this session's message tree: switch branch, label entries, fork from one",
	usage: "[label <entryId> <text> | unlabel <entryId>]",
	group: "sessions",
	methods: [METHOD.sessionsTree],
	async run(ctx, argv) {
		if (argv.length === 0) {
			await openTree(ctx, "inspect", false, 0);
			return;
		}
		const label = /^label\s+(\S+)\s+(\S[\s\S]*)$/.exec(ctx.rest);
		const unlabel = /^unlabel\s+(\S+)$/.exec(ctx.rest);
		if (label) await setLabel(ctx, label[1]!, label[2]!.trim());
		else if (unlabel) await setLabel(ctx, unlabel[1]!, null);
		else ctx.ui.notice("usage: /tree [label <entryId> <text> | unlabel <entryId>]", "error");
	},
};

export const rewindCommand: SlashCommand = {
	name: "rewind",
	summary: "rewind before an earlier prompt after an exact preview and confirmation",
	usage: "[--files]",
	group: "sessions",
	methods: [METHOD.sessionsTree, METHOD.sessionsRewind, METHOD.chatHistory],
	availableWhen: (ctx) => (ctx.session.busy ? "stop the current run before rewinding" : true),
	async run(ctx, argv) {
		if (argv.some((arg) => arg !== "--files") || argv.length > 1) {
			ctx.ui.notice("usage: /rewind [--files] · file restoration is opt-in", "error");
			return;
		}
		if (!ctx.ui.reloadSession) {
			ctx.ui.notice("this client cannot reload a rewound session", "error");
			return;
		}
		await openTree(ctx, "rewind", argv.includes("--files"), 0);
	},
};

async function openTree(
	ctx: CommandContext,
	mode: TreeMode,
	restoreFiles: boolean,
	offset: number,
): Promise<void> {
	try {
		const tree = await ctx.methods.sessionsTree({
			sessionKey: ctx.session.key,
			cwd: ctx.cwd ?? process.cwd(),
			limit: PAGE_SIZE,
			offset,
		});
		if (ctx.store.focusedKey !== ctx.session.key) return;
		if (tree.sessionKey !== ctx.session.key || !Array.isArray(tree.entries)) {
			throw new Error("unexpected session tree receipt");
		}
		const entries =
			mode === "rewind"
				? tree.entries.filter(
						(entry) => entry.role === "user" && entry.rewindable && entry.isActive,
					)
				: tree.entries.filter((entry) => entry.type !== "label");
		const byId = new Map(tree.entries.map((entry) => [entry.id, entry]));
		const items: PickerChoice[] = entries.map((entry) => describeEntry(entry, byId));
		if (offset > 0) items.push({ value: PREVIOUS_PAGE, label: "Previous page" });
		if (tree.hasMore) items.push({ value: NEXT_PAGE, label: "Next page" });
		if (items.length === 0) {
			ctx.ui.notice(
				mode === "rewind"
					? "no earlier user prompts can be rewound"
					: "this session has no stored message tree",
			);
			return;
		}
		ctx.ui.openPicker({
			title: `${mode === "rewind" ? "rewind before a prompt" : "session tree"} · ${offset + 1}–${offset + tree.entries.length}/${tree.totalEntries}`,
			items,
			footer:
				mode === "rewind"
					? `enter previews ${restoreFiles ? "history + files" : "history only"} · esc cancels`
					: "active = current branch · enter opens entry actions · /rewind restores files",
			onSelect: async (choice) => {
				if (choice.value === NEXT_PAGE || choice.value === PREVIOUS_PAGE) {
					const next =
						choice.value === NEXT_PAGE ? offset + PAGE_SIZE : Math.max(0, offset - PAGE_SIZE);
					await openTree(ctx, mode, restoreFiles, next);
					return;
				}
				const entry = entries.find((candidate) => candidate.id === choice.value);
				if (!entry) return;
				if (mode === "rewind") {
					await previewRewind(ctx, entry, restoreFiles);
				} else {
					openEntryActions(ctx, entry, tree.leafId);
				}
			},
		});
	} catch (error) {
		failure(ctx, "tree", error);
	}
}

function describeEntry(
	entry: SessionTreeEntry,
	byId: ReadonlyMap<string, SessionTreeEntry>,
): PickerChoice {
	let depth = 0;
	let parent = entry.parentId;
	const visited = new Set<string>([entry.id]);
	while (parent && byId.has(parent) && !visited.has(parent) && depth < 8) {
		visited.add(parent);
		depth++;
		parent = byId.get(parent)?.parentId ?? null;
	}
	const preview = (entry.text ?? entry.type).replace(/\s+/g, " ").slice(0, 100);
	return {
		value: entry.id,
		label: `${"  ".repeat(depth)}${depth > 0 ? "└─ " : ""}${entry.label ? `[${entry.label}] ` : ""}${entry.role ?? entry.type}: ${preview}`,
		description: `${entry.isActive ? "active" : "branch"}${entry.isLeaf ? " · leaf" : ""} · ${entry.id}`,
	};
}

async function previewRewind(
	ctx: CommandContext,
	entry: SessionTreeEntry,
	restoreFiles: boolean,
	allowPartialRestore = false,
): Promise<void> {
	const target: SessionRewindTarget = {
		sessionKey: ctx.session.key,
		cwd: ctx.cwd ?? process.cwd(),
		entryId: entry.id,
		restoreFiles,
		allowPartialRestore,
	};
	try {
		const preview = await ctx.methods.sessionsRewindPreview(target);
		if (ctx.store.focusedKey !== target.sessionKey) return;
		if (!matchesPreview(preview, target)) throw new Error("unexpected rewind preview");
		const commandCount = preview.unrestorableCommandCount;
		const commands = preview.unrestorableCommands ?? [];
		const hasUnrestorableEffects = preview.unrestorableTools.length > 0 || (commandCount ?? 0) > 0;
		const commandsReviewable = commandCount !== undefined && commandCount === commands.length;
		const blocked =
			restoreFiles &&
			hasUnrestorableEffects &&
			(!allowPartialRestore || !commandsReviewable || preview.canAllowPartialRestore !== true);
		const canAllowPartial =
			restoreFiles &&
			!allowPartialRestore &&
			hasUnrestorableEffects &&
			commandsReviewable &&
			preview.canAllowPartialRestore === true &&
			preview.restoreFiles === true &&
			preview.allowPartialRestore === false;
		const previewLines = [
			`${preview.discardedMessages} message(s) leave the active branch (preserved in /tree)`,
			restoreFiles
				? commandCount === undefined
					? `restore ${preview.restorePaths.length} checkpointed files`
					: `restore ${preview.restorePaths.length} checkpointed files; effects of ${commandCount} shell commands are not reverted`
				: "history only · files stay unchanged",
			...commands.map((command) => `shell effects remain: ${command}`),
			...(restoreFiles ? preview.restorePaths.map((path) => `restore: ${path}`) : []),
			...(preview.unrestorableTools.length
				? [`non-restorable tool effects: ${preview.unrestorableTools.join(", ")}`]
				: []),
			...(blocked
				? [
						canAllowPartial
							? "File restoration is blocked without explicit partial-restoration consent."
							: "File restoration is blocked; the daemon cannot safely restore these effects.",
					]
				: []),
			...(restoreFiles && commandCount !== undefined && !commandsReviewable
				? ["Partial restoration is unavailable: not all shell commands fit in this preview."]
				: []),
			...(restoreFiles && hasUnrestorableEffects && commandCount === undefined
				? ["This daemon does not provide the command details required for partial restoration."]
				: []),
			"The selected prompt returns to the editor; nothing is sent automatically.",
		];
		ctx.ui.noticeBlock(["rewind preview", ...previewLines], "warning");
		const items: PickerChoice[] = [
			{ value: "cancel", label: "Cancel — keep history, files and draft" },
		];
		if (!blocked) {
			items.push({
				value: "confirm",
				label: restoreFiles
					? allowPartialRestore
						? "Rewind and restore only checkpointed files — shell effects remain"
						: "Rewind history and restore previewed files"
					: "Rewind history only",
				description: `${preview.discardedMessages} message(s) · ${entry.id}`,
			});
		}
		if (canAllowPartial) {
			items.push({
				value: "allow-partial",
				label: "Allow partial restoration — get a fresh preview",
				description: "Only checkpointed files can be restored; shell effects are not reverted.",
			});
		}
		if (allowPartialRestore) {
			items.push({
				value: "require-complete",
				label: "Revoke partial consent — get a fresh preview",
			});
		}
		items.push({ value: "inspect", label: "Read full preview in transcript (cancel)" });
		ctx.ui.openPicker({
			title: blocked ? "file rewind is blocked" : "confirm this exact rewind?",
			detail: [
				`Before: ${entry.text ?? entry.id}`,
				...previewLines.slice(0, 6),
				...(previewLines.length > 6
					? ["More preview details in transcript; choose read full preview below."]
					: []),
			],
			items,
			footer:
				canAllowPartial || allowPartialRestore
					? "cancel is selected by default · changing consent only requests a fresh preview"
					: "cancel is selected by default · choose rewind then enter to confirm",
			onSelect: async (choice) => {
				if (!items.some((item) => item.value === choice.value)) return;
				if (choice.value === "cancel" || choice.value === "inspect") return;
				if (ctx.store.focusedKey !== target.sessionKey) {
					ctx.ui.notice("rewind canceled because the focused session changed", "warning");
					return;
				}
				if (choice.value === "allow-partial" || choice.value === "require-complete") {
					await previewRewind(ctx, entry, restoreFiles, choice.value === "allow-partial");
					return;
				}
				try {
					const result = await ctx.methods.sessionsRewindConfirm({
						...target,
						confirmationToken: preview.confirmationToken,
					});
					if (!matchesResult(result, preview, target)) {
						ctx.ui.notice(
							"rewind outcome could not be verified; inspect /tree before doing anything else",
							"error",
						);
						return;
					}
					ctx.ui.resetSession?.(target.sessionKey);
					ctx.store.setDraft(target.sessionKey, result.prompt);
					if (ctx.store.focusedKey === target.sessionKey) ctx.ui.setDraft(result.prompt);
					try {
						await ctx.ui.reloadSession!(target.sessionKey);
						ctx.ui.notice(
							`rewound · ${restoreFiles ? `${result.restoredPaths.length} checkpointed file(s) restored` : "history only · files unchanged"}${result.partialRestore ? `; effects of ${commandCount} shell commands are not reverted` : ""} · edit the recalled prompt to continue`,
						);
					} catch (error) {
						ctx.ui.notice(
							`rewind succeeded; history reload failed (${errorCode(error)}). The recalled prompt is preserved; use /resume to reload.`,
							"warning",
						);
					}
				} catch (error) {
					failure(ctx, "rewind", error, true);
				}
			},
		});
	} catch (error) {
		failure(ctx, "rewind preview", error);
	}
}

function matchesPreview(preview: SessionRewindPreview, target: SessionRewindTarget): boolean {
	return (
		preview.sessionKey === target.sessionKey &&
		preview.entryId === target.entryId &&
		typeof preview.sessionId === "string" &&
		typeof preview.confirmationToken === "string" &&
		preview.confirmationToken.length > 0 &&
		typeof preview.prompt === "string" &&
		(preview.restoreFiles === undefined || preview.restoreFiles === target.restoreFiles) &&
		(preview.allowPartialRestore === undefined ||
			preview.allowPartialRestore === target.allowPartialRestore) &&
		(preview.canAllowPartialRestore === undefined ||
			typeof preview.canAllowPartialRestore === "boolean") &&
		(!target.allowPartialRestore ||
			(preview.restoreFiles === true &&
				preview.allowPartialRestore === true &&
				preview.unrestorableCommands !== undefined &&
				preview.unrestorableCommandCount !== undefined &&
				typeof preview.canAllowPartialRestore === "boolean")) &&
		Number.isInteger(preview.discardedMessages) &&
		preview.discardedMessages >= 0 &&
		Array.isArray(preview.restorePaths) &&
		preview.restorePaths.every((path) => typeof path === "string") &&
		Array.isArray(preview.unrestorableTools) &&
		preview.unrestorableTools.every((tool) => typeof tool === "string") &&
		((preview.unrestorableCommands === undefined &&
			preview.unrestorableCommandCount === undefined) ||
			(Array.isArray(preview.unrestorableCommands) &&
				preview.unrestorableCommands.every((command) => typeof command === "string") &&
				Number.isInteger(preview.unrestorableCommandCount) &&
				preview.unrestorableCommandCount! >= preview.unrestorableCommands.length))
	);
}

function matchesResult(
	result: SessionRewindResult,
	preview: SessionRewindPreview,
	target: SessionRewindTarget,
): boolean {
	return (
		result.sessionKey === target.sessionKey &&
		result.entryId === target.entryId &&
		result.sessionId === preview.sessionId &&
		result.prompt === preview.prompt &&
		result.restoreFiles === target.restoreFiles &&
		result.confirmationToken === preview.confirmationToken &&
		result.allowPartialRestore === target.allowPartialRestore &&
		result.partialRestore ===
			(target.restoreFiles &&
				target.allowPartialRestore &&
				(preview.unrestorableCommandCount ?? 0) > 0) &&
		sameStrings(result.restoredPaths, target.restoreFiles ? preview.restorePaths : []) &&
		sameStrings(result.unrestorableTools, preview.unrestorableTools) &&
		sameStrings(result.unrestorableCommands, preview.unrestorableCommands ?? []) &&
		result.unrestorableCommandCount === (preview.unrestorableCommandCount ?? 0)
	);
}

function sameStrings(actual: unknown, expected: readonly string[]): boolean {
	return (
		Array.isArray(actual) &&
		actual.length === expected.length &&
		actual.every((value, index) => value === expected[index])
	);
}

function errorCode(error: unknown): string {
	if (error instanceof ControlPlaneError && error.details && typeof error.details === "object") {
		const reason = (error.details as Record<string, unknown>).reason;
		if (typeof reason === "string" && /^[a-z_]{1,64}$/.test(reason))
			return `${error.code}: ${reason}`;
	}
	return error instanceof ControlPlaneError || error instanceof NotConnectedError
		? error.code
		: "INVALID_RESPONSE";
}

function failure(ctx: CommandContext, operation: string, error: unknown, mutation = false): void {
	const unsafe =
		mutation &&
		(!(error instanceof ControlPlaneError || error instanceof NotConnectedError) ||
			(error instanceof ControlPlaneError &&
				error.details &&
				typeof error.details === "object" &&
				(error.details as Record<string, unknown>).retrySafe === false));
	ctx.ui.notice(
		`session ${operation} did not complete (${errorCode(error)}); no local history or draft was discarded${unsafe ? ". The remote outcome is uncertain; inspect /tree and the affected files before retrying." : ""}`,
		"error",
	);
}

/** The per-entry action picker `/tree` opens; every mutation goes through a typed method. */
function openEntryActions(
	ctx: CommandContext,
	entry: SessionTreeEntry,
	leafId: string | null,
): void {
	const canNavigate = ctx.methods.supports(METHOD.sessionsNavigate) && entry.id !== leafId;
	const items: PickerChoice[] = [{ value: "inspect", label: "Inspect" }];
	if (canNavigate) {
		items.push({
			value: "switch",
			label: "Switch active branch here",
			description: "the abandoned branch stays in /tree",
		});
		if (!entry.isActive) {
			items.push({
				value: "switch-summarize",
				label: "Switch here and summarize the abandoned branch",
				description: "summary is generated in the background by a loaded session",
			});
		}
	}
	if (ctx.methods.supports(METHOD.sessionsLabel)) {
		items.push({ value: "label", label: "Set label" });
		if (entry.label)
			items.push({ value: "unlabel", label: "Clear label", description: entry.label });
	}
	if (ctx.methods.supports(METHOD.sessionsFork) && ctx.ui.openFork) {
		items.push({
			value: "fork",
			label: "Fork a new session from here",
			description: "history up to and including this entry",
		});
	}
	const sessionKey = ctx.session.key;
	ctx.ui.openPicker({
		title: `entry ${entry.id} · ${entry.role ?? entry.type}${entry.label ? ` · ${entry.label}` : ""}`,
		detail: [(entry.text ?? "(no text preview)").replace(/\s+/g, " ").slice(0, 200)],
		items,
		footer: "enter selects · esc cancels",
		onSelect: async (choice) => {
			if (!items.some((item) => item.value === choice.value)) return;
			if (choice.value !== "inspect" && ctx.store.focusedKey !== sessionKey) {
				ctx.ui.notice("action canceled because the focused session changed", "warning");
				return;
			}
			switch (choice.value) {
				case "inspect":
					ctx.ui.noticeBlock([
						`entry ${entry.id} · ${entry.role ?? entry.type} · ${entry.isActive ? "active" : "preserved branch"}${entry.label ? ` · label: ${entry.label}` : ""}`,
						`parent: ${entry.parentId ?? "root"}${entry.isLeaf ? " · leaf" : ""}`,
						entry.text ?? "(no text preview)",
					]);
					return;
				case "switch":
				case "switch-summarize":
					await switchBranch(ctx, entry, choice.value === "switch-summarize");
					return;
				case "label":
					if (ctx.ui.getDraft().trim() === "") {
						ctx.ui.setDraft(`/tree label ${entry.id} `);
						ctx.ui.notice(
							"type the label after the entry id and press enter (empty text is refused)",
						);
					} else {
						ctx.ui.notice(`label this entry with: /tree label ${entry.id} <text>`);
					}
					return;
				case "unlabel":
					await setLabel(ctx, entry.id, null);
					return;
				case "fork":
					await forkSession(ctx, entry.id);
					return;
			}
		},
	});
}

async function switchBranch(
	ctx: CommandContext,
	entry: SessionTreeEntry,
	summarize: boolean,
): Promise<void> {
	if (ctx.session.busy) {
		ctx.ui.notice("stop the current run before switching branches", "warning");
		return;
	}
	if (!ctx.ui.reloadSession) {
		ctx.ui.notice("this client cannot reload a switched session", "error");
		return;
	}
	const sessionKey = ctx.session.key;
	try {
		const result = await ctx.methods.sessionsNavigate({
			sessionKey,
			cwd: ctx.cwd ?? process.cwd(),
			entryId: entry.id,
			summarize,
		});
		if (result.sessionKey !== sessionKey || result.entryId !== entry.id) {
			ctx.ui.notice(
				"branch switch outcome could not be verified; inspect /tree before doing anything else",
				"error",
			);
			return;
		}
		ctx.ui.resetSession?.(sessionKey);
		const recalled = typeof result.prompt === "string" && result.prompt.length > 0;
		const draftFree = ctx.store.focusedKey !== sessionKey || ctx.ui.getDraft().trim() === "";
		if (recalled && draftFree) {
			ctx.store.setDraft(sessionKey, result.prompt!);
			if (ctx.store.focusedKey === sessionKey) ctx.ui.setDraft(result.prompt!);
		}
		try {
			await ctx.ui.reloadSession(sessionKey);
			const lines = [
				`switched active branch to ${entry.id}${recalled && draftFree ? " · edit the recalled prompt to continue" : ""}`,
			];
			if (summarize) {
				lines.push(
					result.summarizing
						? "the abandoned branch is being summarized in the background"
						: "abandoned-branch summary skipped: the session is not loaded",
				);
			}
			if (recalled && !draftFree) {
				lines.push("your draft was kept; the selected prompt was:", result.prompt!);
			}
			ctx.ui.noticeBlock(lines);
		} catch (error) {
			ctx.ui.notice(
				`branch switched; history reload failed (${errorCode(error)}). Use /resume to reload.`,
				"warning",
			);
		}
	} catch (error) {
		failure(ctx, "switch", error, true);
	}
}

async function setLabel(ctx: CommandContext, entryId: string, label: string | null): Promise<void> {
	if (!ctx.methods.supports(METHOD.sessionsLabel)) {
		ctx.ui.notice("this daemon does not support entry labels", "warning");
		return;
	}
	const sessionKey = ctx.session.key;
	try {
		const result = await ctx.methods.sessionsLabel({
			sessionKey,
			cwd: ctx.cwd ?? process.cwd(),
			entryId,
			label,
		});
		if (result.sessionKey !== sessionKey || result.entryId !== entryId) {
			throw new Error("unexpected label receipt");
		}
		ctx.ui.notice(
			result.label ? `labelled ${entryId}: ${result.label}` : `cleared the label of ${entryId}`,
		);
	} catch (error) {
		failure(ctx, "label", error);
	}
}
