import { Input } from "@oh-my-pi/pi-tui/components/input";
import { HtmlFormDialog, type HtmlFormHost } from "@oh-my-pi/pi-tui/html-form/dialog";
import { type HtmlForm, parseHtmlForm } from "@oh-my-pi/pi-tui/html-form/parse";
import { matchesKey } from "@oh-my-pi/pi-tui/keys";
import { col, EMPTY_NODE, text } from "@oh-my-pi/pi-tui/native/describe";
import type { DescribeContext, NativeNode, NativeUiEvent } from "@oh-my-pi/pi-tui/native/node";
import { ensureThemeSync } from "@oh-my-pi/pi-tui/theme/theme";
import type { Component } from "@oh-my-pi/pi-tui/tui";
import { truncateToWidth, wrapTextWithAnsi } from "@oh-my-pi/pi-tui/utils";
import { safeText } from "../../formatters/base.ts";
import type { UserPromptAnswer, UserPromptRequested } from "../../protocol/user-prompt.ts";
import type { NoticeLevel } from "../../store/transcript-model.ts";
import { formSubmission } from "./html-form-answer.ts";

/** What the panel needs to draw agent-written HTML forms with pi-tui's dialog. */
export interface UserPromptFormHost {
	tui: HtmlFormHost;
	notice: (text: string, level?: NoticeLevel) => void;
}

/**
 * A modal, explicit-answer form. Escape always declines; no timer picks a choice.
 * A request carrying `html` is drawn by pi-tui's `HtmlFormDialog` instead of the
 * question list; submit accepts with the form data, Escape/Cancel declines.
 */
export class UserPromptPanel implements Component {
	busy = false;
	#focused = false;
	#dialog: HtmlFormDialog | undefined;
	readonly #forms: UserPromptFormHost | undefined;
	readonly #input = new Input();
	readonly #answer: (event: UserPromptRequested, answer: UserPromptAnswer) => void;
	readonly #repaint: () => void;
	#event: UserPromptRequested | undefined;
	#index = 0;
	#cursor = 0;
	#selected = new Set<number>();
	#custom = false;
	#content: Record<string, string | string[]> = {};

	constructor(
		answer: (event: UserPromptRequested, answer: UserPromptAnswer) => void,
		repaint: () => void,
		forms?: UserPromptFormHost,
	) {
		this.#forms = forms;
		this.#answer = answer;
		this.#repaint = repaint;
		this.#input.prompt = "Answer: ";
		this.#input.onSubmit = (value) => {
			if (!this.busy && value.trim() && Buffer.byteLength(value, "utf8") <= 4000) {
				this.#advance(value);
			}
		};
	}

	get focused(): boolean {
		return this.#focused;
	}
	set focused(value: boolean) {
		this.#focused = value;
		if (this.#dialog) this.#dialog.focused = value;
	}

	setUseTerminalCursor(useTerminalCursor: boolean): void {
		this.#dialog?.setUseTerminalCursor(useTerminalCursor);
		this.#input.setUseTerminalCursor(useTerminalCursor);
	}

	get visible(): boolean {
		return this.#event !== undefined;
	}
	get event(): UserPromptRequested | undefined {
		return this.#event;
	}

	show(event: UserPromptRequested): void {
		if (this.#event?.promptId === event.promptId) return;
		this.#closeDialog();
		this.#event = event;
		this.#index = 0;
		this.#content = {};
		this.busy = false;
		if (event.html !== undefined) this.#openDialog(event, event.html);
		else this.#resetQuestion();
	}

	hide(): void {
		this.#closeDialog();
		this.#event = undefined;
		this.busy = false;
	}

	#openDialog(event: UserPromptRequested, html: string): void {
		// The dialog paints with pi-tui's theme singleton, which must exist first.
		ensureThemeSync();
		const form: HtmlForm = parseHtmlForm(html);
		const dialog = new HtmlFormDialog(form, {
			title: "Ask",
			tui: this.#forms?.tui,
			onSubmit: (data, notes) => {
				if (this.busy) return;
				const submission = formSubmission(form, data, notes);
				// Over-bound data keeps the form open: nothing is truncated or guessed.
				if (!submission.ok) this.#forms?.notice(submission.message, "error");
				else this.#answer(event, submission.answer);
			},
			onCancel: () => {
				if (!this.busy) this.#answer(event, { action: "decline" });
			},
		});
		dialog.focused = this.#focused;
		this.#dialog = dialog;
	}

	#closeDialog(): void {
		this.#dialog?.dispose();
		this.#dialog = undefined;
	}

	handleInput(data: string): void {
		const event = this.#event;
		if (!event || this.busy) return;
		if (this.#dialog) {
			this.#dialog.handleInput(data);
			this.#repaint();
			return;
		}
		if (matchesKey(data, "escape") || matchesKey(data, "ctrl+c")) {
			this.#answer(event, { action: "decline" });
			return;
		}
		const question = event.questions[this.#index]!;
		if (this.#custom) {
			this.#input.focused = this.focused;
			this.#input.handleInput(data);
		} else if (data === "o") {
			this.#custom = true;
		} else if (matchesKey(data, "up")) {
			this.#cursor = (this.#cursor - 1 + question.options.length) % question.options.length;
		} else if (matchesKey(data, "down")) {
			this.#cursor = (this.#cursor + 1) % question.options.length;
		} else if (data === " " && question.multi) {
			if (!this.#selected.delete(this.#cursor)) this.#selected.add(this.#cursor);
		} else if (matchesKey(data, "enter")) {
			if (question.multi) {
				if (this.#selected.size) this.#advance();
			} else {
				this.#selected = new Set([this.#cursor]);
				this.#advance();
			}
		}
		this.#repaint();
	}

	handleNativeEvent(event: NativeUiEvent): void {
		if (this.#dialog) {
			if (!this.busy) this.#dialog.handleNativeEvent(event);
			this.#repaint();
			return;
		}
		if (this.#custom && !this.busy) this.#input.handleNativeEvent(event);
		this.#repaint();
	}

	invalidate(): void {
		this.#dialog?.invalidate();
		this.#input.invalidate();
	}

	render(width: number): readonly string[] {
		if (!this.#event) return [];
		if (this.#dialog) return this.#dialog.render(width);
		const rows = this.#lines().flatMap((line) =>
			wrapTextWithAnsi(safeText(line), Math.max(1, width)),
		);
		if (this.#custom) {
			this.#input.focused = this.focused;
			rows.push(...this.#input.render(width));
		}
		return rows.map((line) => truncateToWidth(line, width));
	}

	describe(cx: DescribeContext): NativeNode {
		if (!this.#event) return EMPTY_NODE;
		if (this.#dialog) return this.#dialog.describe(cx);
		this.#input.focused = this.focused && this.#custom;
		return col(
			[
				...this.#lines().map((line) => text(safeText(line))),
				...(this.#custom ? [this.#input.describe(cx)] : []),
			],
			{ role: "lemon.session.prompt" },
		);
	}

	#lines(): string[] {
		const event = this.#event!;
		const question = event.questions[this.#index]!;
		const rows = [
			`Question ${this.#index + 1}/${event.questions.length}${question.header ? ` · ${question.header}` : ""}`,
			question.question,
		];
		if (!this.#custom) {
			for (const [index, option] of question.options.entries()) {
				const selected = question.multi ? (this.#selected.has(index) ? "[x]" : "[ ]") : "";
				rows.push(
					`${index === this.#cursor ? "›" : " "} ${selected} ${option.label}${index === question.recommended ? " (recommended)" : ""}${option.description ? ` — ${option.description}` : ""}`,
				);
			}
		}
		rows.push(
			this.busy
				? "Sending answer…"
				: this.#custom
					? "Enter: submit text · Esc: decline all"
					: `↑↓: choose · ${question.multi ? "Space: toggle · Enter: next" : "Enter: select"} · o: other answer · Esc: decline all`,
		);
		return rows;
	}

	#resetQuestion(): void {
		this.#cursor = 0;
		this.#selected.clear();
		this.#input.setValue("");
		this.#custom = this.#event!.questions[this.#index]!.options.length === 0;
	}

	#advance(custom?: string): void {
		const event = this.#event!;
		const question = event.questions[this.#index]!;
		const key = `q${this.#index}`;
		const selected = [...this.#selected]
			.sort((a, b) => a - b)
			.map((index) => question.options[index]!.label);
		if (selected.length) this.#content[key] = question.multi ? selected : selected[0]!;
		if (custom !== undefined) this.#content[`${key}__other`] = custom;
		if (this.#index + 1 < event.questions.length) {
			this.#index += 1;
			this.#resetQuestion();
			this.#repaint();
		} else {
			this.#answer(event, { action: "accept", content: { ...this.#content } });
		}
	}
}
