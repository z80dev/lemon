/**
 * Fullscreen plan review for a `propose_plan` approval.
 *
 * The scrolling, the Contents sidebar, the annotations and the decision row are
 * omp's {@link PlanReviewOverlay}, verbatim. This file is only the seam to
 * Lemon's approval path:
 *
 * - its two choices are the panel's own pair ({@link PLAN_OPTIONS}), so a pick
 *   resolves with exactly the decision the panel's key or button would send;
 * - Esc is not a decision: the overlay closes and the compact panel, still
 *   pending, takes the keyboard back;
 * - omp's Refine loop feeds annotations to the next prompt. Lemon's `deny`
 *   carries no text, so the feedback is staged in the composer instead — the
 *   same place the panel's "send your feedback as a normal prompt" points;
 * - omp writes in-overlay section removals back to the plan file. The plan file
 *   belongs to the daemon, so Lemon cannot, and an approval that silently
 *   ignored a removal would execute a plan the user cut. Approve is therefore
 *   refused while removals are pending (the review reopens on Refine, where the
 *   removals travel as feedback).
 */

import {
	type PlanReviewAnnotationState,
	PlanReviewOverlay,
} from "@oh-my-pi/pi-tui/overlays/plan-review-overlay";
import { parsePlanSections } from "@oh-my-pi/pi-tui/overlays/plan-toc";
import { ensureThemeSync } from "@oh-my-pi/pi-tui/theme/theme";
import type { Component } from "@oh-my-pi/pi-tui/tui";
import type { OverlayHost } from "../commands/registry.ts";
import type { NoticeLevel } from "../store/transcript-model.ts";
import { PLAN_OPTIONS } from "./components/approval-panel.ts";

/** The overlay's feedback preamble, which {@link composeRefineFeedback} re-emits. */
const FEEDBACK_HEADER = "Refinement feedback on the plan:\n";
/** The overlay's own list of sections deleted inside it; replaced by the full diff. */
const REMOVED_BLOCK = /\nRemove these sections:\n(?:- .*\n)*/;

export interface PlanReviewHooks {
	/** Mount `build`'s component as the one overlay, replacing any other. */
	present(build: (host: OverlayHost) => Component): void;
	/** A decision made in the review; the overlay is already closed. */
	decide(decision: string, feedback: string): void;
	/** Esc: the review closed without deciding. */
	dismiss(): void;
	copy?(text: string): void;
	notice(text: string, level?: NoticeLevel): void;
}

/**
 * The Refine feedback: the overlay's annotations plus every section removed
 * from `original`, as one markdown note. Empty when there is nothing to say.
 */
export function composeRefineFeedback(overlayFeedback: string, removed: readonly string[]): string {
	let rest = overlayFeedback.replace(REMOVED_BLOCK, "\n");
	if (rest.startsWith(FEEDBACK_HEADER)) rest = rest.slice(FEEDBACK_HEADER.length);
	rest = rest.replace(/^\n+/, "");
	if (removed.length === 0 && rest.trim() === "") return "";
	const removal =
		removed.length > 0
			? `\nRemove these sections:\n${removed.map((t) => `- ${t}\n`).join("")}`
			: "";
	return `${FEEDBACK_HEADER}${removal}${rest ? `\n${rest}` : ""}`;
}

/** Headings present in `original` but not in `current`, in document order. */
export function removedSections(original: string, current: string): string[] {
	const remaining = new Map<string, number>();
	const key = (level: number, title: string) => `${level}\u0000${title}`;
	for (const section of parsePlanSections(current)) {
		if (section.level === 0) continue;
		const k = key(section.level, section.title);
		remaining.set(k, (remaining.get(k) ?? 0) + 1);
	}
	const removed: string[] = [];
	for (const section of parsePlanSections(original)) {
		if (section.level === 0) continue;
		const k = key(section.level, section.title);
		const left = remaining.get(k) ?? 0;
		if (left > 0) remaining.set(k, left - 1);
		else removed.push(section.title);
	}
	return removed;
}

/** One plan's review: survives the overlay being rebuilt after a refused Approve. */
export class PlanReviewFlow {
	readonly #original: string;
	readonly #title: string;
	readonly #hooks: PlanReviewHooks;
	#current: string;
	#annotations: PlanReviewAnnotationState | undefined;
	#overlayFeedback = "";
	#close: (() => void) | undefined;

	constructor(plan: string, title: string, hooks: PlanReviewHooks) {
		this.#original = plan;
		this.#current = plan;
		this.#title = title;
		this.#hooks = hooks;
	}

	/** Show the review, with `initialIndex` of {@link PLAN_OPTIONS} highlighted. */
	open(initialIndex = 0): void {
		// The overlay reads pi-tui's module-level theme, which omp initializes at startup.
		ensureThemeSync();
		// A rebuilt overlay re-emits feedback for the annotations it restores; nothing else.
		this.#overlayFeedback = "";
		this.#hooks.present((host) => {
			this.#close = host.close;
			return new PlanReviewOverlay(
				this.#current,
				{
					promptTitle: this.#title,
					options: PLAN_OPTIONS.map((option) => option.label),
					initialIndex,
					helpText: "esc back to the compact panel",
					annotationState: this.#annotations,
				},
				{
					onPick: (label) => this.#pick(label, host),
					onCancel: () => {
						host.close();
						this.#hooks.dismiss();
					},
					onCopyPlan: this.#hooks.copy ? (text) => this.#hooks.copy?.(text) : undefined,
					onPlanEdited: (content) => {
						this.#current = content;
					},
					onFeedbackChange: (feedback) => {
						this.#overlayFeedback = feedback;
					},
					onAnnotationStateChange: (state) => {
						this.#annotations = state;
					},
				},
			);
		});
	}

	/** Close the overlay without reporting a dismissal (the request went away). */
	close(): void {
		this.#close?.();
		this.#close = undefined;
	}

	#pick(label: string, host: OverlayHost): void {
		const option = PLAN_OPTIONS.find((candidate) => candidate.label === label);
		if (!option) return;
		const removed = removedSections(this.#original, this.#current);
		if (option.decision === "deny") {
			host.close();
			this.#hooks.decide(option.decision, composeRefineFeedback(this.#overlayFeedback, removed));
			return;
		}
		if (removed.length > 0) {
			this.#hooks.notice(
				"removed sections cannot be written back to the plan file — choose Refine plan to send them as feedback",
				"warning",
			);
			this.open(PLAN_OPTIONS.findIndex((candidate) => candidate.decision === "deny"));
			return;
		}
		host.close();
		this.#hooks.decide(option.decision, "");
	}
}
