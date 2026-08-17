/**
 * One overlay at a time.
 *
 * pi-tui's overlay stack allows several, but a TUI that can stack a model
 * picker over a session switcher over a confirm dialog is a TUI where Esc means
 * something different every time. Opening a second overlay closes the first.
 *
 * The controller also owns focus: the overlay takes it while it is up, and the
 * editor gets it back on close — with its draft untouched, because overlays
 * never write to the editor.
 */

import type { Component, OverlayHandle, OverlayOptions, TUI } from "@oh-my-pi/pi-tui/tui";

export interface SelectorControllerOptions {
	tui: TUI;
	/** Focused again whenever the last overlay closes. */
	defaultFocus: () => Component | null;
}

const DEFAULT_OVERLAY: OverlayOptions = {
	width: "70%",
	minWidth: 40,
	maxHeight: "70%",
	anchor: "center",
};

export class SelectorController {
	readonly #tui: TUI;
	readonly #defaultFocus: () => Component | null;
	#handle: OverlayHandle | undefined;
	#component: Component | undefined;
	#onClose: (() => void) | undefined;

	constructor(options: SelectorControllerOptions) {
		this.#tui = options.tui;
		this.#defaultFocus = options.defaultFocus;
	}

	get isOpen(): boolean {
		return this.#handle !== undefined;
	}

	/** The overlay currently up, if any. */
	get current(): Component | undefined {
		return this.#component;
	}

	/**
	 * Show `component` as the only overlay. Returns a closer that is safe to call
	 * more than once and after another overlay has replaced this one.
	 */
	open(component: Component, options: OverlayOptions = {}, onClose?: () => void): () => void {
		this.close();
		this.#component = component;
		this.#onClose = onClose;
		this.#handle = this.#tui.showOverlay(component, { ...DEFAULT_OVERLAY, ...options });
		this.#tui.setFocus(component);
		this.#tui.requestRender();
		return () => {
			if (this.#component === component) this.close();
		};
	}

	close(): void {
		if (!this.#handle) return;
		const onClose = this.#onClose;
		this.#handle.hide();
		this.#handle = undefined;
		this.#component = undefined;
		this.#onClose = undefined;
		this.#tui.setFocus(this.#defaultFocus());
		this.#tui.requestRender();
		onClose?.();
	}

	/** Re-render the open overlay after its contents changed. */
	repaint(): void {
		if (!this.#component) return;
		this.#component.invalidate?.();
		this.#tui.requestRender();
	}

	dispose(): void {
		this.close();
	}
}
