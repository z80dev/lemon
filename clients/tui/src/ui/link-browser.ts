/**
 * Fullscreen link browser over the Lemon transcript.
 *
 * omp's `overlays/link-browser` only tags markdown links of schemes an extension registered
 * process-wide, so Lemon's own OSC 8 hyperlinks and bare URLs would not be found, and registering
 * schemes would change what every other markdown component draws while the browser is open (a
 * streaming reply could commit rows in marker form to scrollback). This component keeps the
 * replay, scrolling and drawing of omp's browser (`TranscriptBrowser`, `ChatTranscriptBuilder`)
 * but detects links itself from the rendered rows ({@link ./link-hints.ts LinkHints}) and touches
 * no global state: the rows it returns are the replay's own, plus the tags.
 */

import { ChatTranscriptBuilder } from "@oh-my-pi/pi-tui/chat/chat-transcript-builder";
import {
	TranscriptBrowser,
	type TranscriptBrowserFrame,
} from "@oh-my-pi/pi-tui/chat/transcript-browser";
import type { TranscriptEntryLike } from "@oh-my-pi/pi-tui/chat/transcript-entry";
import { composeOutlineColumn } from "@oh-my-pi/pi-tui/chat/transcript-outline";
import { matchesSelectCancel } from "@oh-my-pi/pi-tui/keybinding-matchers";
import { matchesKey, parseKey } from "@oh-my-pi/pi-tui/keys";
import { routeSgrMouseInput } from "@oh-my-pi/pi-tui/mouse";
import { ensureThemeSync, theme } from "@oh-my-pi/pi-tui/theme/theme";
import type { Component, TUI } from "@oh-my-pi/pi-tui/tui";
import { sliceByColumn } from "@oh-my-pi/pi-tui/utils";
import { LinkHints, linkTargets, rowLinkLabels } from "./link-hints.ts";

export interface LinkBrowserOptions {
	ui: TUI;
	cwd: string;
	requestRender: () => void;
	/** A link was picked (a whole tag typed, or a click on a label). */
	onActivate: (url: string) => void;
	onClose: () => void;
}

/**
 * Fullscreen link browser: the transcript replayed on the alternate screen, every link tagged
 * with a hint. Typing a whole tag or clicking a label activates the link; arrows, Page Up/Down,
 * Home/End and the wheel scroll; Esc closes. It stays open after a pick, showing the opener's
 * result in the footer. The transcript is a snapshot taken at construction.
 */
export class LinkBrowserOverlay implements Component {
	readonly #options: LinkBrowserOptions;
	readonly #builder: ChatTranscriptBuilder;
	readonly #browser: TranscriptBrowser;
	readonly #hints = new LinkHints();
	/** The last frame without tags: what a click is traced back through. */
	#frame: readonly string[] = [];
	#crowded = false;
	/** Width of the last frame without the scrollbar column, which links are detected at. */
	#contentWidth = 0;
	#scrollToEnd = true;
	#disposed = false;
	#status: { text: string; ok: boolean } | undefined;

	constructor(entries: TranscriptEntryLike[], options: LinkBrowserOptions) {
		ensureThemeSync();
		this.#options = options;
		this.#builder = new ChatTranscriptBuilder({
			ui: options.ui,
			cwd: options.cwd,
			requestRender: options.requestRender,
		});
		this.#builder.rebuild(entries);
		this.#browser = new TranscriptBrowser({
			getHeight: () => options.ui.terminal?.rows || process.stdout.rows || 40,
			frame: (context) => this.#compose(context.contentWidth),
		});
	}

	/** Whether the transcript draws any link at frame width `width`. */
	hasLinks(width: number): boolean {
		const contentWidth = Math.max(1, width - 1);
		return linkTargets(this.#body(contentWidth), contentWidth).length > 0;
	}

	/** Show the result of the last activation in the footer. */
	setStatus(text: string, ok: boolean): void {
		this.#status = { text, ok };
		this.#options.requestRender();
	}

	invalidate(): void {
		this.#builder.container.invalidate();
		this.#browser.invalidate();
	}

	dispose(): void {
		if (this.#disposed) return;
		this.#disposed = true;
		this.#builder.dispose();
	}

	handleInput(data: string): void {
		if (data.startsWith("\x1b[<")) {
			routeSgrMouseInput(data, (event) => {
				if (event.wheel !== null) {
					if (this.#browser.scroll(event.wheel * 3)) this.#options.requestRender();
				} else if (event.leftClick) {
					const url = rowLinkLabels(this.#frame[event.row] ?? "", this.#contentWidth).find(
						(label) => event.col >= label.start && event.col < label.end,
					)?.url;
					if (url !== undefined) this.#options.onActivate(url);
				}
				return true;
			});
			return;
		}
		if (matchesKey(data, "escape") || matchesSelectCancel(data)) {
			this.#options.onClose();
			return;
		}
		if (this.#browser.handleScrollKey(data)) {
			this.#options.requestRender();
			return;
		}
		const key = parseKey(data);
		if (this.#crowded || key === undefined || !/^[a-z]$/.test(key)) return;
		const picked = this.#hints.type(key);
		if (typeof picked === "string") this.#options.onActivate(picked);
		this.#options.requestRender();
	}

	render(width: number): readonly string[] {
		if (this.#scrollToEnd) {
			this.#scrollToEnd = false;
			this.#browser.render(width);
			this.#browser.scrollToBottom();
		}
		const contentWidth = Math.max(1, width - 1);
		this.#contentWidth = contentWidth;
		let frame = this.#browser.render(width);
		// Without the scrollbar column: a label wrapped at the row's end must end its row.
		this.#hints.update(
			frame.map((row) => sliceByColumn(row, 0, contentWidth)),
			this.#browser.frameRowOffset,
			contentWidth,
		);
		const crowded = this.#hints.crowded(contentWidth);
		if (crowded !== this.#crowded) {
			// The footer says why no tags are drawn; it takes the same row, so labels stay put.
			this.#crowded = crowded;
			frame = this.#browser.render(width);
		}
		this.#frame = frame;
		return crowded ? frame : this.#hints.paint(frame, contentWidth);
	}

	/** The transcript's rows at `contentWidth`, indented as the other transcript browsers draw it. */
	#body(contentWidth: number): string[] {
		const children = this.#builder.container.children;
		const rows = this.#browser.renderOutlineRows(children, contentWidth);
		return composeOutlineColumn(rows, 0, children.length, [], -1, contentWidth, undefined).lines;
	}

	#compose(contentWidth: number): TranscriptBrowserFrame {
		let hint: string;
		if (this.#crowded) {
			hint = theme.fg(
				"warning",
				"Too many links on one row to tag; widen the terminal · PgUp/PgDn scroll · Esc close",
			);
		} else if (this.#status) {
			hint = theme.fg(this.#status.ok ? "success" : "warning", this.#status.text);
		} else {
			hint = theme.fg("dim", "Type a tag or click a link · PgUp/PgDn scroll · Esc close");
		}
		return {
			header: [
				`${theme.bold("Links")}${theme.sep.dot}${theme.fg("dim", "open one from anywhere in the transcript")}`,
			],
			body: { lines: this.#body(contentWidth) },
			footer: [hint],
		};
	}
}

export interface CreateLinkBrowserOptions extends LinkBrowserOptions {
	entries: TranscriptEntryLike[];
}

/** A link browser over `entries`; the caller presents it and wires `onClose` to the overlay close. */
export function createLinkBrowser({
	entries,
	...options
}: CreateLinkBrowserOptions): LinkBrowserOverlay {
	return new LinkBrowserOverlay(entries, options);
}
