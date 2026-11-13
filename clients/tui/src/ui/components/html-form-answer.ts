import { formAnswers, type HtmlFormData, type OptionNote } from "@oh-my-pi/pi-tui/html-form/data";
import type { HtmlForm } from "@oh-my-pi/pi-tui/html-form/parse";
import type { UserPromptAnswer } from "../../protocol/user-prompt.ts";

/** Bounds the daemon enforces on `sessions.prompt.resolve` content for forms. */
const MAX_FIELDS = 64;
const MAX_KEY_BYTES = 256;
const MAX_VALUE_BYTES = 4_000;
const MAX_LABEL_BYTES = 1_000;

export type FormSubmission =
	| { ok: true; answer: UserPromptAnswer }
	| { ok: false; message: string };

/**
 * Turn a submitted form into a resolve answer: `content` is the form data
 * verbatim (it is the machine-readable answer, so it is refused rather than
 * truncated when it exceeds the wire bounds); `answers`/`notes` are the readable
 * listing the model's tool result echoes, clipped to fit.
 */
export function formSubmission(
	form: HtmlForm,
	data: HtmlFormData,
	notes: readonly OptionNote[],
): FormSubmission {
	const entries = Object.entries(data);
	if (entries.length > MAX_FIELDS) {
		return { ok: false, message: `This form has more than ${MAX_FIELDS} answers.` };
	}
	for (const [name, value] of entries) {
		const items = Array.isArray(value) ? value : [value];
		if (Buffer.byteLength(name, "utf8") > MAX_KEY_BYTES || items.length > MAX_FIELDS) {
			return { ok: false, message: `The answer "${clip(name, 40)}" is too large to send.` };
		}
		for (const item of items) {
			if (typeof item === "number" ? !Number.isFinite(item) : tooLong(item, MAX_VALUE_BYTES)) {
				return {
					ok: false,
					message: `The answer "${clip(name, 40)}" is not valid or exceeds ${MAX_VALUE_BYTES} bytes; shorten it and submit again.`,
				};
			}
		}
	}
	return {
		ok: true,
		answer: {
			action: "accept",
			content: data,
			answers: formAnswers(form, data).map(({ name, question, answer }) => ({
				name: clip(name, MAX_KEY_BYTES),
				question: clip(question, MAX_LABEL_BYTES),
				answer: clip(answer, MAX_VALUE_BYTES),
			})),
			notes: notes.map((note) => ({
				name: clip(note.name, MAX_KEY_BYTES),
				question: clip(note.question, MAX_LABEL_BYTES),
				option: clip(note.option, MAX_LABEL_BYTES),
				value: clip(note.value, MAX_LABEL_BYTES),
				text: clip(note.text, MAX_VALUE_BYTES),
			})),
		},
	};
}

function tooLong(text: string, maxBytes: number): boolean {
	return Buffer.byteLength(text, "utf8") > maxBytes;
}

/** Cut `text` to at most `maxBytes` UTF-8 bytes, marking the cut with an ellipsis. */
export function clip(text: string, maxBytes: number): string {
	if (!tooLong(text, maxBytes)) return text;
	const head = Buffer.from(text, "utf8")
		.subarray(0, Math.max(0, maxBytes - 3))
		.toString("utf8")
		.replace(/\uFFFD+$/, "");
	return `${head}…`;
}
