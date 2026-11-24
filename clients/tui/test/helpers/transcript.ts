import type { Component } from "@oh-my-pi/pi-tui/tui";
import type { SessionStore } from "../../src/store/session-store.ts";
import type { TranscriptContainer } from "../../src/ui/components/transcript-container.ts";

/** Lifecycle assertions do not offer/acknowledge the renderer's history batches. */
export function unfinalizedBlocks(transcript: TranscriptContainer): readonly Component[] {
	return transcript.children.filter(
		(child) =>
			(
				child as Component & { isTranscriptBlockFinalized?(): boolean }
			).isTranscriptBlockFinalized?.() === false,
	);
}

/** A run's assistant text as the transcript holds it, across tool-boundary segments. */
export function runText(session: SessionStore, runId: string): string {
	return session.blocks
		.filter((block) => block.kind === "assistant" && block.runId === runId)
		.map((block) => (block.kind === "assistant" ? block.text : ""))
		.join("");
}
