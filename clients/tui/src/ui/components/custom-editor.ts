/**
 * The prompt editor.
 *
 * Everything pi-tui's {@link Editor} already does well (wrapping, undo, paste
 * markers, autocomplete popups, IME) is inherited untouched. What this subclass
 * adds is the key policy the client needs *before* the base editor sees a
 * keystroke:
 *
 *   Ctrl+C   a non-empty draft is cleared; an empty one aborts the live run;
 *            with nothing running, twice in a row quits.
 *   Ctrl+D   quits on an empty draft, deletes forward otherwise.
 *   Ctrl+G   hands the draft to $EDITOR.
 *   Esc      aborts the live run without discarding the draft; while idle,
 *            Esc Esc discards the draft (recoverable with ↑).
 *   ↑ / ↓    recall sent prompts while the draft is empty.
 *   Alt+↵    cycle the submission mode for the next submission only.
 *
 * Submission funnels through one callback, {@link CustomEditorOptions.onSubmit}.
 * That single seam is where the shell layers queue / steer / redirect / interrupt; nothing
 * else in the client sends a prompt.
 *
 * On a TSP terminal the editor describes omp's composer (`omp.editor`): the
 * context meter, attachment chips, the input line, and a bar of model and
 * effort chips, the status facts, usage, and Send (Stop while a run is live).
 */

import { CombinedAutocompleteProvider } from "@oh-my-pi/pi-tui/autocomplete";
import { BracketedPasteHandler } from "@oh-my-pi/pi-tui/bracketed-paste";
import {
	Editor,
	type EditorTheme,
	type NativeEditorLayout,
} from "@oh-my-pi/pi-tui/components/editor";
import { formatTooltipKey, type KeyName } from "@oh-my-pi/pi-tui/key-hint-format";
import { matchesKey } from "@oh-my-pi/pi-tui/keys";
import { base64ImageNode } from "@oh-my-pi/pi-tui/native/blobs";
import { compact, keyed, node, row, span } from "@oh-my-pi/pi-tui/native/describe";
import type {
	DescribeContext,
	NativeNode,
	NativeUiEvent,
	TspSpan,
} from "@oh-my-pi/pi-tui/native/node";
import { AttachmentList } from "../../composer/attachment-list.ts";
import type {
	ComposerDrafts,
	ComposerSubmission,
	SubmissionDisposition,
} from "../../composer/drafts.ts";
import type { PendingImage } from "../../composer/images.ts";
import { type ComposerIO, ComposerMedia } from "../../composer/media.ts";
import { IMAGE_PATH, parsePastedPaths } from "../../composer/paths.ts";
import type { NoticeLevel } from "../../store/transcript-model.ts";
import type { ComposerFacts, ComposerFactsSource } from "./status-bar.ts";

/** Window in which a second Ctrl+C quits. */
export const EXIT_CONFIRM_MS = 2000;
/** Window in which a second Esc discards the draft. */
export const ESC_DISCARD_MS = 800;
/** How many sent prompts ↑ can walk back through. */
export const HISTORY_LIMIT = 100;

export interface ComposerEditorOptions {
	drafts: ComposerDrafts;
	sessionKey: () => string;
	cwd?: () => string;
	/** Return queued only after the actual payload has an owning queue item. */
	submit: (
		submission: ComposerSubmission,
	) => SubmissionDisposition | Promise<SubmissionDisposition>;
	io?: ComposerIO;
}

/** Live state the TSP composer shows; the host wires {@link CustomEditorOptions.composerState}. */
export interface ComposerNativeState {
	/** The focused session's run is live: the composer turns `pending` and Send becomes Stop. */
	readonly running: boolean;
	/** The session's thinking level; undefined is the daemon default. */
	readonly thinking?: string;
	/** The session's confirmed title, quoted as the empty composer's placeholder. */
	readonly title?: string;
}

const IDLE_COMPOSER: ComposerNativeState = { running: false };

/** Filled steps (of four) of the effort chip's meter on terminals without the `effort` kind. */
const EFFORT_STEPS: Partial<Record<string, number>> = {
	off: 0,
	minimal: 1,
	low: 1,
	medium: 2,
	high: 3,
	xhigh: 4,
};

/** Native action codes on the composer's own controls; `status.*` go to the facts' source. */
const ACTION = {
	model: "status.model",
	thinking: "thinking.select",
	submit: "submit",
	interrupt: "interrupt",
	removeAttachment: "attachment.remove:",
} as const;

export interface CustomEditorOptions {
	theme: EditorTheme;
	/** The one submission seam. Slash/shell handling happens downstream of it. */
	onSubmit: (text: string) => void | Promise<void>;
	/** Native automation cannot submit until the connection and modal state allow it. */
	canSubmit?: () => boolean;
	/** Abort the run in flight. Return true when there was one. */
	onAbort?: () => boolean;
	onQuit?: (code: number) => void;
	/** Ctrl+G / `/editor`. */
	onExternalEdit?: () => void | Promise<void>;
	/**
	 * Alt+Enter: cycle the submission mode for *this* submission only. The base
	 * editor reserves Alt+Enter for exactly this kind of host hook (it inserts a
	 * newline only when none is installed), and Shift+Enter is already the
	 * newline key, so this is the one free chord next to the submit key.
	 */
	onCycleMode?: () => void;
	notice?: (text: string, level?: NoticeLevel) => void;
	/** Called after a key changed something the host may want repainted. */
	requestRender?: () => void;
	/** Clock seam for the double-press windows. */
	now?: () => number;
	/** Opt in only when the host can route real image payloads. */
	composer?: ComposerEditorOptions;
	/** TSP composer state; unset describes an idle composer without a title. */
	composerState?: () => ComposerNativeState;
	/** TSP model chip click: the model picker key's path. */
	onSelectModel?: () => void;
	/** TSP effort chip click: the thinking key's path. Unset leaves the chip out. */
	onSelectThinking?: () => void;
	/** Keys named in the TSP chips' tooltips. */
	controlKeys?: { model?: string; thinking?: string };
}

/** The bar's controls, rebuilt only when what they show changes. */
interface ComposerControls {
	readonly model: NativeNode | undefined;
	readonly effort: NativeNode | undefined;
	readonly submit: NativeNode;
}

export class CustomEditor extends Editor {
	readonly #options: CustomEditorOptions;
	readonly #now: () => number;

	/** Sent prompts, oldest first. */
	readonly #history: string[] = [];
	/** Position while walking history; undefined when not recalling. */
	#historyIndex: number | undefined;
	/** The draft that was on screen when recall started. */
	#stashed = "";
	#exitArmedAt = 0;
	#escapeAt = 0;
	#nativeSubmitting = false;
	readonly #pasteHandler = new BracketedPasteHandler();
	readonly #attachmentList = new AttachmentList();
	readonly #media: ComposerMedia | undefined;
	readonly #submittingSessions = new Set<string>();
	#renderSource: readonly string[] | undefined;
	#renderAttachments: readonly string[] | undefined;
	#renderRows: readonly string[] = [];
	/** The status facts the TSP composer carries (the host's status bar). */
	composerFacts: ComposerFactsSource | undefined;
	#nativeComposer:
		| {
				key: string;
				facts: ComposerFacts | undefined;
				chips: NativeNode;
				input: NativeNode;
				controls: ComposerControls;
				line: NativeNode;
				bar: NativeNode;
				layout: NativeEditorLayout;
		  }
		| undefined;
	#nativeChips:
		| {
				images: readonly PendingImage[];
				busy: boolean;
				node: NativeNode;
				previews: ReadonlyMap<PendingImage, NativeNode>;
		  }
		| undefined;
	#titlePlaceholder: { title: string; text: readonly TspSpan[] } | undefined;

	constructor(options: CustomEditorOptions) {
		super(options.theme);
		this.#options = options;
		this.#now = options.now ?? Date.now;
		// Base Editor exposes submission as a property; ours is the only writer.
		this.onSubmit = (text: string) => this.#submit(text);
		if (options.onCycleMode) {
			// Installing the hook is what stops Alt+Enter inserting a newline.
			this.onAltEnter = () => options.onCycleMode?.();
		}
		if (options.composer) {
			this.#media = new ComposerMedia({
				drafts: options.composer.drafts,
				cwd: options.composer.cwd ?? process.cwd,
				io: options.composer.io,
				insertText: (sessionKey, text) => {
					if (options.composer?.sessionKey() !== sessionKey) {
						options.notice?.(
							"Clipboard text belongs to another session; paste it there again.",
							"warning",
						);
						return;
					}
					const cursor = this.getCursor();
					const before = this.getLines()[cursor.line]?.slice(0, cursor.col) ?? "";
					super.pasteText(before && !/\s$/.test(before) ? ` ${text}` : text);
				},
				notice: (message) => options.notice?.(message, "warning"),
				changed: () => options.requestRender?.(),
			});
		}
	}

	/** Sent prompts, oldest first (the ↑ ring). */
	get history(): readonly string[] {
		return this.#history;
	}

	/** Install slash-command and file-path completion. */
	setCommands(
		commands: Array<{ name: string; description?: string; argumentHint?: string }>,
		basePath = process.cwd(),
	): void {
		this.setAutocompleteProvider(
			new CombinedAutocompleteProvider(
				commands.map((command) => ({
					name: command.name,
					description: command.description,
					argumentHint: command.argumentHint,
					allowArgs: true,
				})),
				basePath,
			),
		);
	}

	/** Reset the double-press arms — used after any state-changing event. */
	disarm(): void {
		this.#exitArmedAt = 0;
		this.#escapeAt = 0;
	}

	/** Push a prompt onto the recall ring without sending it. */
	#rememberPrompt(text: string): void {
		const trimmed = text.trim();
		if (trimmed.length === 0) return;
		if (this.#history[this.#history.length - 1] === text) return;
		this.#history.push(text);
		if (this.#history.length > HISTORY_LIMIT) this.#history.shift();
	}

	protected override get nativeSendable(): boolean {
		return (
			!this.disableSubmit &&
			!this.#nativeSubmitting &&
			!this.mediaBusy &&
			this.pendingAttachments.length === 0 &&
			(this.#options.canSubmit?.() ?? true)
		);
	}

	/** The session's title, quoted in italics, kept while it stands so the editor node is reused. */
	override describePlaceholder = (): string | readonly TspSpan[] => {
		const title = this.#options.composerState?.().title;
		if (!title) return "";
		if (this.#titlePlaceholder?.title !== title) {
			this.#titlePlaceholder = { title, text: [span(`\u201c${title}\u201d`, "em")] };
		}
		return this.#titlePlaceholder.text;
	};

	/**
	 * omp's TSP composer. Tern discovers the delegatable composer by the
	 * `omp.editor` role, not merely by an editable node: ordinary picker/search
	 * fields must never receive prompts. Tone `pending` while the run is live,
	 * over the context meter, the attachment chips, the `line` row holding the
	 * input, and the `bar`: model chip, effort chip, the other status facts,
	 * usage, then Send (Stop while running). Clicks come back as `status.model`,
	 * `thinking.select`, `submit`, `interrupt`, `attachment.remove:<id>` and the
	 * facts' `status.*` actions.
	 */
	override describeLayout = (input: NativeNode, context: DescribeContext): NativeEditorLayout => {
		const state = this.#options.composerState?.() ?? IDLE_COMPOSER;
		const facts = this.composerFacts?.describeComposerFacts();
		const effortGlyph = context.supports("effort");
		const chips = this.#describeChips();
		const key = [state.running, state.thinking, effortGlyph].join("\0");
		const memo = this.#nativeComposer;
		if (
			memo &&
			memo.key === key &&
			memo.facts === facts &&
			memo.input === input &&
			memo.chips === chips
		) {
			return memo.layout;
		}
		const sameControls = memo?.key === key && memo.facts === facts;
		const controls = sameControls
			? memo.controls
			: this.#describeControls(state, facts, effortGlyph);
		const bar = sameControls
			? memo.bar
			: keyed(
					row(
						compact([
							controls.model,
							controls.effort,
							// The facts are the bar's flexible space; without them a spacer keeps Send at the end.
							facts?.extras ?? node("row", { grow: 1 }, [], "gap"),
							facts?.usage,
							controls.submit,
						]),
						{ role: "omp.composer.bar", gap: "sm", align: "center" },
					),
					"bar",
				);
		const line =
			memo?.input === input
				? memo.line
				: keyed(row([input], { role: "omp.composer.line", align: "start", gap: "sm" }), "line");
		const layout: NativeEditorLayout = {
			role: "omp.editor",
			tone: state.running ? "pending" : undefined,
			children: compact([facts?.context, chips, line, bar]),
			caret: "line/input",
		};
		this.#nativeComposer = { key, facts, chips, input, controls, line, bar, layout };
		return layout;
	};

	/**
	 * The attachment band (`omp.composer.chips`): one `omp.composer.chip` card
	 * per pending image with the image itself, its name and size, and a remove
	 * control; a busy line while images attach or send. Hidden while empty.
	 */
	#describeChips(): NativeNode {
		const images = this.pendingAttachments;
		const busy = this.mediaBusy;
		const memo = this.#nativeChips;
		if (memo?.images === images && memo.busy === busy) return memo.node;
		const previews = new Map<PendingImage, NativeNode>();
		const cards = images.map((image, index) => {
			const preview =
				memo?.previews.get(image) ??
				base64ImageNode(image.content.data, image.content.mime_type, {
					alt: image.name,
					max: { w: "12ch", h: "4lines" },
				});
			previews.set(image, preview);
			const size = Math.max(1, Math.ceil(image.byteLength / 1024));
			return node(
				"card",
				{ role: "omp.composer.chip", tone: "accent", head: [span(`#${index + 1}`, "strong")] },
				[
					preview,
					node("text", { text: image.name, wrap: "none" }, undefined, "name"),
					node("text", { spans: [span(`${size} KiB`, "dim")], wrap: "none" }, undefined, "size"),
					node(
						"icon",
						{
							name: "x",
							role: "omp.composer.chipRemove",
							title: "Remove image",
							actions: { click: `${ACTION.removeAttachment}${image.id}` },
						},
						undefined,
						"remove",
					),
				],
				`image:${image.id}`,
			);
		});
		if (busy) {
			cards.push(
				node(
					"text",
					{ spans: [span("Attaching/sending images\u2026", "dim")], wrap: "none" },
					undefined,
					"busy",
				),
			);
		}
		const described = keyed(
			row(cards, {
				gap: "sm",
				wrap: true,
				role: "omp.composer.chips",
				hidden: cards.length === 0,
			}),
			"chips",
		);
		this.#nativeChips = { images, busy, node: described, previews };
		return described;
	}

	/** The model and effort chips, and Send or Stop. */
	#describeControls(
		state: ComposerNativeState,
		facts: ComposerFacts | undefined,
		effortGlyph: boolean,
	): ComposerControls {
		const keys = this.#options.controlKeys;
		const model =
			facts &&
			node(
				"row",
				{
					role: "omp.composer.model",
					gap: "xs",
					align: "center",
					title: `Switch model${tooltipKey(keys?.model)}`,
					actions: { click: ACTION.model },
				},
				[
					node("icon", { name: "model" }, undefined, "icon"),
					node("text", { spans: facts.model, wrap: "none" }, undefined, "name"),
					node("icon", { name: "chev" }, undefined, "chev"),
				],
				"model",
			);
		// Lemon always has a session thinking level: unset is the daemon's default.
		const level = state.thinking ?? "default";
		const steps = EFFORT_STEPS[level];
		const effort =
			this.#options.onSelectThinking &&
			node(
				"row",
				{
					role: "omp.composer.effort",
					gap: "xs",
					align: "center",
					title: `Thinking effort${tooltipKey(keys?.thinking)}`,
					actions: { click: ACTION.thinking },
				},
				[
					effortGlyph
						? node("effort", { level }, undefined, "glyph")
						: node(
								"meter",
								{ value: steps === undefined ? null : steps / 4, style: "blocks", steps: 4 },
								undefined,
								"meter",
							),
					node("text", { text: level, wrap: "none" }, undefined, "level"),
				],
				"effort",
			);
		const submit = state.running
			? node(
					"text",
					{
						role: "omp.composer.stop",
						text: "Stop",
						tone: "error",
						title: `Stop${tooltipKey("escape")}`,
						actions: { click: ACTION.interrupt },
					},
					undefined,
					"stop",
				)
			: node(
					"kbd",
					{
						role: "omp.composer.send",
						keys: ["enter"],
						title: `Send${tooltipKey("enter")}`,
						actions: { click: ACTION.submit },
					},
					undefined,
					"send",
				);
		return { model, effort, submit };
	}

	/**
	 * Clicks on the composer's controls take the same paths as their keys:
	 * the model picker, the thinking picker, Enter, and Esc; the facts' clicks
	 * go to their source. `send` is Carly's atomic prompt.
	 */
	override handleNativeEvent(event: NativeUiEvent): void {
		if (event.type === "send") {
			this.#nativeSend(event.text);
			return;
		}
		if (event.type !== "action") {
			super.handleNativeEvent(event);
			return;
		}
		switch (event.act) {
			case ACTION.model:
				this.#options.onSelectModel?.();
				return;
			case ACTION.thinking:
				this.#options.onSelectThinking?.();
				return;
			case ACTION.submit:
				this.submit();
				return;
			case ACTION.interrupt:
				if (this.#options.onAbort?.()) this.disarm();
				this.#options.requestRender?.();
				return;
			default:
				if (event.act.startsWith(ACTION.removeAttachment)) {
					this.removeAttachment(event.act.slice(ACTION.removeAttachment.length));
				} else {
					this.composerFacts?.handleNativeEvent(event);
				}
		}
	}

	#nativeSend(text: string): void {
		if (!text.trim() || !this.nativeSendable) return;
		// Carly's prompt is atomic: a human's unsent draft belongs in recall,
		// never concatenated with the delegated prompt.
		this.#rememberPrompt(this.getExpandedText());
		this.setText("");
		this.#nativeSubmitting = true;
		this.#options.requestRender?.();
		void this.#submit(text)
			.catch((error: unknown) => {
				this.#options.notice?.(`Prompt failed: ${String(error)}`, "error");
			})
			.finally(() => {
				this.#nativeSubmitting = false;
				this.#options.requestRender?.();
			});
	}

	override handleInput(data: string): void {
		if (this.#media) {
			let next = data;
			while (next.length > 0) {
				const paste = this.#pasteHandler.process(next);
				if (!paste.handled) break;
				if (paste.pasteContent !== undefined) void this.pasteContent(paste.pasteContent);
				next = paste.remaining;
			}
			if (!next) return;
			data = next;
			// Non-bracketed terminal drag/drop arrives as one path-sized burst.
			if (data.length > 1) {
				const paths = parsePastedPaths(data);
				if (paths?.some((path) => IMAGE_PATH.test(path))) {
					void this.#media.pastePaths(this.#options.composer!.sessionKey(), paths);
					return;
				}
			}
		}
		if (this.#intercept(data)) {
			this.#options.requestRender?.();
			return;
		}
		// Any other key ends a history walk: the buffer is the user's again.
		if (this.#historyIndex !== undefined && !isHistoryKey(data)) {
			this.#historyIndex = undefined;
		}
		if (!matchesKey(data, "escape")) this.#escapeAt = 0;
		if (!matchesKey(data, "ctrl+c")) this.#exitArmedAt = 0;
		super.handleInput(data);
	}

	get pendingAttachments(): readonly PendingImage[] {
		const composer = this.#options.composer;
		return composer ? composer.drafts.items(composer.sessionKey()) : NO_ATTACHMENTS;
	}

	/** Native send should remain unavailable while upload/submission owns the input. */
	get mediaBusy(): boolean {
		const sessionKey = this.#options.composer?.sessionKey();
		return (
			sessionKey !== undefined &&
			(Boolean(this.#media?.busy(sessionKey)) || this.#submittingSessions.has(sessionKey))
		);
	}

	/** Also serves a host attachment picker; IDs remain stable through session switches. */
	removeAttachment(id: string): void {
		const composer = this.#options.composer;
		if (!composer) return;
		composer.drafts.remove(composer.sessionKey(), id);
		this.#options.requestRender?.();
	}

	async pasteContent(text: string): Promise<boolean> {
		const paths = this.#media ? parsePastedPaths(text) : undefined;
		if (paths) return this.#media!.pastePaths(this.#options.composer!.sessionKey(), paths);
		// Preserve pi's large-paste markers, sanitization, undo, and prompt history.
		super.pasteText(text);
		this.#options.requestRender?.();
		return true;
	}

	override pasteText(text: string): void {
		void this.pasteContent(text);
	}

	override submit(): void {
		if (this.disableSubmit) return;
		if (this.pendingAttachments.length > 0 || this.mediaBusy) void this.submitComposer();
		else super.submit();
	}

	/** Submit this human draft; external native sends must not inherit its images. */
	async submitComposer(): Promise<void> {
		const composer = this.#options.composer;
		if (!composer || this.disableSubmit) return;
		const sessionKey = composer.sessionKey();
		const generation = composer.drafts.generation(sessionKey);
		if (this.#submittingSessions.has(sessionKey)) return;
		this.#submittingSessions.add(sessionKey);
		this.#options.requestRender?.();
		try {
			if (this.#media?.busy(sessionKey) && !(await this.#media.settled(sessionKey))) return;
			if (
				composer.sessionKey() !== sessionKey ||
				composer.drafts.generation(sessionKey) !== generation
			)
				return;
			const original = this.getExpandedText();
			const submission = composer.drafts.prepare(sessionKey, original);
			if (!submission) return;
			if (submission.images.length === 0) {
				// Ctrl+V may finish as ordinary text or file mentions, not an image.
				this.setText("");
				await this.#submitPlain(submission.text);
				return;
			}
			const disposition = await composer.submit(submission);
			composer.drafts.complete(submission, disposition);
			if (disposition === "accepted" || disposition === "queued") {
				this.#rememberPrompt(submission.text);
				this.addToHistory(submission.text);
				if (
					composer.sessionKey() === sessionKey &&
					composer.drafts.generation(sessionKey) === generation &&
					this.getExpandedText() === original
				) {
					this.setText("");
				}
				this.#historyIndex = undefined;
				this.disarm();
			}
		} catch {
			this.#options.notice?.(
				"Image submission was not accepted; the attachment draft is retained.",
				"error",
			);
		} finally {
			this.#submittingSessions.delete(sessionKey);
			this.#options.requestRender?.();
		}
	}

	override render(width: number): readonly string[] {
		const source = super.render(width);
		const attachments = this.#attachmentList.render(this.pendingAttachments, this.mediaBusy, width);
		if (attachments.length === 0) return source;
		if (source !== this.#renderSource || attachments !== this.#renderAttachments) {
			this.#renderSource = source;
			this.#renderAttachments = attachments;
			this.#renderRows = [...source, ...attachments];
		}
		return this.#renderRows;
	}

	/** Returns true when the key was consumed and must not reach the editor. */
	#intercept(data: string): boolean {
		if (this.#media && matchesKey(data, "ctrl+v")) {
			void this.#media.pasteClipboard(this.#options.composer!.sessionKey());
			return true;
		}
		if (this.#media && matchesKey(data, "ctrl+shift+backspace")) {
			const last = this.pendingAttachments.at(-1);
			if (last) this.removeAttachment(last.id);
			return true;
		}
		if (
			(matchesKey(data, "enter") || data === "\n") &&
			!this.isShowingAutocomplete() &&
			(this.pendingAttachments.length > 0 || this.mediaBusy)
		) {
			void this.submitComposer();
			return true;
		}
		if (matchesKey(data, "ctrl+c")) {
			this.#onCtrlC();
			return true;
		}
		if (matchesKey(data, "ctrl+d")) {
			if (this.getText().length > 0) return false;
			if (this.pendingAttachments.length > 0 || this.mediaBusy) {
				this.#options.notice?.("Remove pending images with ctrl+shift+backspace before quitting.");
				return true;
			}
			this.#options.onQuit?.(0);
			return true;
		}
		if (this.#options.onExternalEdit && matchesKey(data, "ctrl+g")) {
			void this.#options.onExternalEdit();
			return true;
		}
		if (matchesKey(data, "escape")) {
			return this.#onEscape();
		}
		if (matchesKey(data, "up")) {
			return this.#recall(-1);
		}
		if (matchesKey(data, "down")) {
			return this.#recall(1);
		}
		return false;
	}

	#onCtrlC(): void {
		const draft = this.getExpandedText();
		if (draft.length > 0) {
			// Not lost: a cleared draft is still recallable with ↑.
			this.#rememberPrompt(draft);
			this.setText("");
			this.#historyIndex = undefined;
			this.#exitArmedAt = 0;
			return;
		}
		if (this.#options.onAbort?.()) {
			this.#exitArmedAt = 0;
			return;
		}
		if (this.pendingAttachments.length > 0 || this.mediaBusy) {
			this.#options.notice?.(
				"Pending images retained; ctrl+shift+backspace removes the last image.",
			);
			return;
		}
		const now = this.#now();
		if (now - this.#exitArmedAt < EXIT_CONFIRM_MS) {
			this.#options.onQuit?.(0);
			return;
		}
		this.#exitArmedAt = now;
		this.#options.notice?.("press Ctrl+C again to quit");
	}

	#onEscape(): boolean {
		// An open autocomplete popup owns Escape.
		if (this.isShowingAutocomplete()) return false;
		// Interrupt is independent of the draft: an in-flight correction is
		// valuable input, not something the user should clear just to stop a run.
		if (this.#options.onAbort?.()) {
			this.disarm();
			return true;
		}
		const now = this.#now();
		if (now - this.#escapeAt < ESC_DISCARD_MS && this.getText().length > 0) {
			this.#rememberPrompt(this.getExpandedText());
			this.setText("");
			this.#historyIndex = undefined;
			this.#escapeAt = 0;
			this.#options.notice?.("draft discarded (↑ to bring it back)");
			return true;
		}
		this.#escapeAt = now;
		return false;
	}

	/** Walk the recall ring. `-1` is older, `+1` newer. */
	#recall(direction: -1 | 1): boolean {
		if (this.#history.length === 0) return false;
		if (this.#historyIndex === undefined) {
			// Only an empty draft opts into recall; otherwise ↑ moves the cursor.
			if (direction !== -1 || this.getText().length > 0) return false;
			this.#stashed = this.getText();
			this.#historyIndex = this.#history.length - 1;
			this.setText(this.#history[this.#historyIndex]);
			return true;
		}
		const next = this.#historyIndex + direction;
		if (next < 0) return true;
		if (next >= this.#history.length) {
			this.#historyIndex = undefined;
			this.setText(this.#stashed);
			return true;
		}
		this.#historyIndex = next;
		this.setText(this.#history[next]);
		return true;
	}

	/**
	 * The base editor has already expanded paste markers, trimmed, and emptied
	 * the buffer by the time this runs — `text` is the real prompt bytes.
	 */
	async #submit(text: string): Promise<void> {
		if (this.pendingAttachments.length > 0 || this.mediaBusy) {
			// Autocomplete/native callers can reach the base submit callback after it clears.
			this.setText(text);
			await this.submitComposer();
			return;
		}
		await this.#submitPlain(text);
	}

	async #submitPlain(text: string): Promise<void> {
		this.#historyIndex = undefined;
		this.disarm();
		if (text.trim().length === 0) return;
		this.#rememberPrompt(text);
		this.addToHistory(text);
		await this.#options.onSubmit(text);
	}
}

/** `  ⌃O`: the key after a control's tooltip, or nothing when it has none. */
function tooltipKey(key: string | undefined): string {
	return key ? `  ${formatTooltipKey(key as KeyName)}` : "";
}

function isHistoryKey(data: string): boolean {
	return matchesKey(data, "up") || matchesKey(data, "down");
}

const NO_ATTACHMENTS: readonly PendingImage[] = Object.freeze([]);
