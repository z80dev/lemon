/**
 * Width-contract safety net.
 *
 * pi-tui's `Text` and `Markdown` keep their horizontal padding at every width:
 * their content width floors at 1, so a component with `paddingX = 2` emits
 * 5-cell rows when asked for 4. The renderer's rule is absolute — a row may
 * never exceed the requested width — so every transcript component funnels its
 * final rows through {@link WidthClamp}, which truncates only the rows that
 * actually overflow.
 *
 * The clamp is memoized on (source array reference, width) so it keeps the
 * render contract's other half: an unchanged component must return the very
 * same array reference it returned last time, or the transcript container
 * treats every frame as a change.
 */

import { Text } from "@oh-my-pi/pi-tui/components/text";
import type { Component } from "@oh-my-pi/pi-tui/tui";
import { truncateToWidth, visibleWidth } from "@oh-my-pi/pi-tui/utils";

export class WidthClamp {
	#source: readonly string[] | undefined;
	#width = -1;
	#clamped: readonly string[] | undefined;

	/**
	 * `lines` with every over-wide row truncated to `width`. Returns `lines`
	 * itself when nothing overflows — the common case, and the one where
	 * reference identity matters.
	 */
	apply(lines: readonly string[], width: number): readonly string[] {
		if (this.#clamped !== undefined && this.#source === lines && this.#width === width) {
			return this.#clamped;
		}
		let result = lines;
		if (width > 0) {
			let overflow = -1;
			for (let i = 0; i < lines.length; i++) {
				if (visibleWidth(lines[i]!) > width) {
					overflow = i;
					break;
				}
			}
			if (overflow >= 0) {
				const clamped = lines.slice();
				for (let i = overflow; i < clamped.length; i++) {
					// `""` selects the omit-ellipsis mode: a truncated row must not
					// grow a marker glyph that costs another cell.
					if (visibleWidth(clamped[i]!) > width)
						clamped[i] = truncateToWidth(clamped[i]!, width, "");
				}
				result = clamped;
			}
		}
		this.#source = lines;
		this.#width = width;
		this.#clamped = result;
		return result;
	}

	reset(): void {
		this.#source = undefined;
		this.#width = -1;
		this.#clamped = undefined;
	}
}

/** A pi-tui {@link Text} whose rows are guaranteed to fit the render width. */
export class ClampedText implements Component {
	readonly #text: Text;
	readonly #clamp = new WidthClamp();

	constructor(text = "", paddingX = 1, paddingY = 0) {
		this.#text = new Text(text, paddingX, paddingY);
	}

	setText(value: string): boolean {
		return this.#text.setText(value);
	}

	render(width: number): readonly string[] {
		return this.#clamp.apply(this.#text.render(width), width);
	}

	invalidate(): void {
		this.#text.invalidate?.();
		this.#clamp.reset();
	}
}
