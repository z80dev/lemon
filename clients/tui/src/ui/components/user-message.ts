/**
 * The user's own prompt, echoed into the transcript.
 *
 * Finalized from birth: it never mutates, so it omits the FinalizableBlock
 * methods entirely (the container treats a block without them as final) and its
 * rows commit to native scrollback as soon as they scroll off.
 */

import {
	hasTranscriptActions,
	runTranscriptAction,
} from "@oh-my-pi/pi-tui/chat/transcript-actions";
import { Markdown } from "@oh-my-pi/pi-tui/components/markdown";
import { base64ImageNode } from "@oh-my-pi/pi-tui/native/blobs";
import { card, node, row, span, text } from "@oh-my-pi/pi-tui/native/describe";
import type {
	DescribeContext,
	NativeChild,
	NativeNode,
	NativeUiEvent,
} from "@oh-my-pi/pi-tui/native/node";
import { iconButton } from "@oh-my-pi/pi-tui/native/overlay";
import { Container } from "@oh-my-pi/pi-tui/tui";
import { visibleWidth } from "@oh-my-pi/pi-tui/utils";
import type { UserDelivery, UserDetails } from "../../store/transcript-model.ts";
import { TranscriptMarks } from "../../terminal/marks.ts";
import { getTheme } from "../theme/theme.ts";
import { getMarkdownTheme } from "../theme/tui-adapters.ts";
import { WidthClamp } from "./width-safe.ts";

/** Left gutter reserved for the prompt marker. */
const GUTTER = 2;

const DELIVERY_BADGE: Record<UserDelivery, { text: string; title: string }> = {
	steer: { text: "steered", title: "Delivered into the run that was working" },
	redirect: { text: "redirected", title: "Replaced the working run's pending direction" },
	interrupt: { text: "interrupted", title: "Stopped the working run and started this turn" },
};

export class UserMessageComponent extends Container {
	// Memoized marker overlay keyed on the child render's array reference (same
	// reference ⇒ identical rows ⇒ reuse the wrapped copy). Keeps this component
	// reference-stable for the transcript's incremental assembly, and never
	// mutates the Markdown child's own cached array.
	#source: readonly string[] | undefined;
	#lines: readonly string[] | undefined;
	readonly #clamp = new WidthClamp();
	readonly #marks = new TranscriptMarks();
	readonly #text: string;
	readonly #details: UserDetails;
	#native: NativeNode | undefined;
	#nativeHour12: boolean | undefined;

	constructor(text: string, details: UserDetails = {}) {
		super();
		const theme = getTheme();
		this.#text = text;
		this.#details = details;
		this.addChild(
			new Markdown(text, GUTTER, 0, getMarkdownTheme(), {
				color: (value) => theme.fg("userText", value),
			}),
		);
	}

	/**
	 * omp's user frame: a quiet toolbar (Copy · the time sent), the attached
	 * images, the prompt as markdown, then how it reached a busy run as a badge.
	 * Rows render none of the extras; they are native chrome only.
	 */
	override describe(cx?: DescribeContext): NativeNode {
		// The terminal's clock preference: Bun's default locale ignores the user's.
		const hour12 = cx?.hour12;
		if (this.#native && this.#nativeHour12 === hour12) return this.#native;
		this.#nativeHour12 = hour12;
		const { sentAt, images, delivery } = this.#details;
		const children: NativeChild[] = [];
		const tools: NativeNode[] = [];
		if (hasTranscriptActions()) {
			const copy = iconButton("copy", "copy-message", "Copy message", { key: "copy" });
			copy.p!.role = "omp.user.tool";
			tools.push(copy);
		}
		if (sentAt !== undefined) {
			const at = new Date(sentAt);
			if (tools.length > 0) tools.push(node("text", { text: "·" }, undefined, "dot"));
			tools.push(
				text(
					[
						span(
							at.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12 }),
							"dim mono",
						),
					],
					{ role: "omp.user.time", title: at.toLocaleString([], { hour12 }), key: "time" },
				),
			);
		}
		if (tools.length > 0) {
			children.push(
				node("row", { gap: "xs", align: "center", role: "omp.user.tools" }, tools, "tools"),
			);
		}
		if (images && images.length > 0) {
			const thumbs = images.map((image, index) => {
				const label = `#${index + 1}`;
				return base64ImageNode(image.data, image.mime_type, { alt: label, title: label }, label);
			});
			children.push(
				node(
					"row",
					{ gap: "sm", wrap: true, align: "start", role: "omp.user.images" },
					thumbs,
					"images",
				),
			);
		}
		children.push(...this.children);
		if (delivery) {
			const badge = DELIVERY_BADGE[delivery];
			children.push(
				row([node("badge", { text: badge.text, tone: "accent", title: badge.title })], {
					gap: "xs",
					justify: "end",
					role: "omp.user.badges",
				}),
			);
		}
		this.#native = card({ role: "omp.user", tone: "user" }, children);
		return this.#native;
	}

	/** The toolbar's Copy runs the host's clipboard path. */
	handleNativeEvent(event: NativeUiEvent): void {
		if (event.type === "action" && event.act === "copy-message") {
			runTranscriptAction({ act: "copy", text: this.#text });
		}
	}

	override render(width: number): readonly string[] {
		// Clamp before the overlay: the marker swaps padding cells in place, so it
		// must sit on rows that already fit the requested width.
		const lines = this.#clamp.apply(super.render(width), width);
		if (lines.length === 0) return lines;
		if (this.#source === lines && this.#lines !== undefined) return this.#lines;
		const theme = getTheme();
		const first = lines[0]!;
		// Markdown emits the horizontal padding as literal leading spaces, so the
		// marker replaces them in place: same visible width, never wider than the
		// requested width.
		const markerWidth = visibleWidth(theme.cursor);
		const wrapped = lines.slice();
		wrapped[0] =
			markerWidth > 0 && markerWidth <= GUTTER && first.startsWith(" ".repeat(GUTTER))
				? theme.fg("userPrefix", theme.cursor) +
					" ".repeat(GUTTER - markerWidth) +
					first.slice(GUTTER)
				: first;
		this.#source = lines;
		this.#lines = this.#marks.apply(wrapped, "prompt");
		return this.#lines;
	}

	override invalidate(): void {
		this.#source = undefined;
		this.#lines = undefined;
		this.#clamp.reset();
		super.invalidate();
	}
}
