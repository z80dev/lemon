/**
 * Client-side chatter: reconnects, aborts, send failures. One styled line,
 * finalized from birth.
 */

import { runTranscriptAction } from "@oh-my-pi/pi-tui/chat/transcript-actions";
import { node, span, text } from "@oh-my-pi/pi-tui/native/describe";
import type { NativeNode, NativeUiEvent } from "@oh-my-pi/pi-tui/native/node";
import { Container } from "@oh-my-pi/pi-tui/tui";
import { formatNumber } from "@oh-my-pi/pi-utils";
import { displayText } from "../../formatters/base.ts";
import type { CompactionDetails, NoticeLevel } from "../../store/transcript-model.ts";
import { getTheme } from "../theme/theme.ts";
import { describeErrorFrame } from "./native-chrome.ts";
import { ClampedText } from "./width-safe.ts";

const SLOT: Record<NoticeLevel, "noticeText" | "warning" | "error"> = {
	info: "noticeText",
	warning: "warning",
	error: "error",
};

export class NoticeComponent extends Container {
	/** As received; Copy error hands this out. */
	readonly #text: string;
	/** What is drawn: {@link displayText}. */
	readonly #shown: string;
	readonly #level: NoticeLevel;
	readonly #compaction: CompactionDetails | undefined;
	#native: NativeNode | undefined;

	constructor(text: string, level: NoticeLevel = "info", compaction?: CompactionDetails) {
		super();
		this.#text = text;
		this.#shown = displayText(text);
		this.#level = level;
		this.#compaction = compaction;
		const theme = getTheme();
		// Word-wraps at the render width, and clamps the rows that pi-tui's fixed
		// padding would otherwise push past it at very narrow widths.
		this.addChild(new ClampedText(theme.fg(SLOT[level], `· ${this.#shown}`), 1, 0));
	}

	/**
	 * A compaction is omp's divider section (`omp.compaction`, the amounts in
	 * its head, the notice as its caption: Lemon has no summary text to fold
	 * under it); an error is omp's error frame with Copy error; anything else
	 * is a quiet `omp.notice` line in its tone.
	 */
	override describe(): NativeNode {
		if (this.#native) return this.#native;
		if (this.#compaction) {
			const { tokensBefore, tokensAfter } = this.#compaction;
			const head = [span("Compacted", "muted")];
			if (tokensBefore !== undefined && tokensAfter !== undefined) {
				head.push(
					span(` · ${formatNumber(tokensBefore)}`, "muted mono"),
					span(" → ", "dim"),
					span(`${formatNumber(tokensAfter)} tokens`, "muted mono"),
				);
			}
			this.#native = node("section", { role: "omp.compaction", head }, [
				text([span(this.#shown, "dim")], { role: "omp.compaction.caption", key: "caption" }),
			]);
		} else if (this.#level === "error") {
			this.#native = describeErrorFrame("Error", this.#shown, [
				{ act: "copy-error", label: "Copy error", title: "Copy the error message" },
			]);
		} else {
			this.#native = text([span(this.#shown, this.#level === "warning" ? "warning" : "muted")], {
				wrap: "word",
				role: "omp.notice",
				tone: this.#level === "warning" ? "warning" : "muted",
			});
		}
		return this.#native;
	}

	/** The error frame's Copy runs the host's clipboard path. */
	handleNativeEvent(event: NativeUiEvent): void {
		if (event.type === "action" && event.act === "copy-error") {
			runTranscriptAction({ act: "copy", text: this.#text });
		}
	}
}
