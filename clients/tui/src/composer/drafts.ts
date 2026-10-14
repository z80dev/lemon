import type { ImageContent } from "../protocol/types.ts";
import { MAX_IMAGE_BYTES, MAX_IMAGES, type PendingImage } from "./images.ts";

export type SubmissionDisposition = "accepted" | "queued" | "rejected" | "uncertain";

export interface ComposerSubmission {
	readonly sessionKey: string;
	readonly text: string;
	readonly images: readonly ImageContent[];
	/** Keep these objects on an editable queue item to restore its draft later. */
	readonly attachments: readonly PendingImage[];
}

const EMPTY: readonly PendingImage[] = Object.freeze([]);

/** Attachment identities are session-bound and never depend on the editor's text. */
export class ComposerDrafts {
	readonly #sessions = new Map<string, readonly PendingImage[]>();
	readonly #generations = new Map<string, number>();

	/** Deletion/discard invalidates asynchronous reads started for the old draft. */
	generation(sessionKey: string): number {
		return this.#generations.get(sessionKey) ?? 0;
	}

	items(sessionKey: string): readonly PendingImage[] {
		return this.#sessions.get(sessionKey) ?? EMPTY;
	}

	/** Atomic: a failed batch leaves every previously pending attachment intact. */
	add(sessionKey: string, images: readonly PendingImage[]): void {
		const existing = this.items(sessionKey);
		const ids = new Set(existing.map((image) => image.id));
		const next = [...existing];
		let bytes = existing.reduce((total, image) => total + image.byteLength, 0);
		for (const image of images) {
			if (ids.has(image.id)) continue;
			ids.add(image.id);
			bytes += image.byteLength;
			next.push(image);
		}
		if (next.length > MAX_IMAGES || bytes > MAX_IMAGE_BYTES) {
			throw new Error("Attach at most 5 images, totaling at most 10 MiB.");
		}
		this.#sessions.set(sessionKey, Object.freeze(next));
	}

	remove(sessionKey: string, id: string): void {
		const next = this.items(sessionKey).filter((image) => image.id !== id);
		if (next.length === 0) this.#sessions.delete(sessionKey);
		else this.#sessions.set(sessionKey, Object.freeze(next));
	}

	/** Only after verified deletion/reset, or an explicit user discard. */
	clear(sessionKey: string): void {
		this.#sessions.delete(sessionKey);
		this.#generations.set(sessionKey, this.generation(sessionKey) + 1);
	}

	/** Taking a snapshot does not transfer ownership or clear the draft. */
	prepare(sessionKey: string, text: string): ComposerSubmission | undefined {
		const attachments = this.items(sessionKey);
		if (text.trim().length === 0 && attachments.length === 0) return undefined;
		return Object.freeze({
			sessionKey,
			text: text.trim(),
			attachments,
			images: Object.freeze(attachments.map((image) => image.content)),
		});
	}

	/** Call only after a run receipt or an actual queue has taken the payload. */
	complete(submission: ComposerSubmission, disposition: SubmissionDisposition): void {
		if (disposition !== "accepted" && disposition !== "queued") return;
		const transferred = new Set(submission.attachments.map((image) => image.id));
		const remaining = this.items(submission.sessionKey).filter(
			(image) => !transferred.has(image.id),
		);
		if (remaining.length === 0) this.#sessions.delete(submission.sessionKey);
		else this.#sessions.set(submission.sessionKey, Object.freeze(remaining));
	}
}
