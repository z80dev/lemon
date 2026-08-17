/**
 * Who is asked to approve what, and when.
 *
 * The store is the list of everything pending across every session; this
 * controller decides which single request is on screen, owns the panel's focus
 * and countdown, and is the only place that calls `exec.approval.resolve`.
 *
 * Three things can resolve a request, and all three land here:
 *   - the panel (a key the user pressed);
 *   - `/approve` and `/deny`, including for a *background* session, which is
 *     why the commands route through {@link ApprovalController.resolve} rather
 *     than talking to the protocol themselves;
 *   - an `exec.approval.resolved` event, when another client (or the daemon's
 *     own timeout) answered first.
 *
 * A resolve is optimistic: the panel goes away the moment the user decides,
 * because waiting on a round-trip to acknowledge a keypress feels broken. The
 * request is only *forgotten* once the daemon accepts the decision — a rejected
 * resolve puts the panel back rather than leaving a tool silently blocked.
 */

import type { Container, TUI } from "@oh-my-pi/pi-tui/tui";
import type { ControlPlaneMethods } from "../../protocol/methods.ts";
import type { ApprovalRequestedEvent } from "../../protocol/types.ts";
import type { AppStore, PendingApproval } from "../../store/app-store.ts";
import type { NoticeLevel } from "../../store/transcript-model.ts";
import { ApprovalPanelComponent, humanDecision } from "../components/approval-panel.ts";
import type { EventController } from "./event-controller.ts";

/** How often the countdown is re-read. */
export const APPROVAL_TICK_MS = 1000;

export interface ApprovalControllerOptions {
	store: AppStore;
	methods: ControlPlaneMethods;
	events: EventController;
	tui: TUI;
	/** The slot the panel mounts into, between transcript and status line. */
	container: Container;
	notice: (text: string, level?: NoticeLevel) => void;
	/** Focused again when the panel goes away. */
	focusEditor: () => void;
	refreshStatus: () => void;
	tickMs?: number;
	now?: () => number;
}

export class ApprovalController {
	readonly panel: ApprovalPanelComponent;

	readonly #options: ApprovalControllerOptions;
	/** Requests whose decision is in flight; hidden but not yet forgotten. */
	readonly #resolving = new Set<string>();
	readonly #disposers: Array<() => void> = [];

	#mounted = false;
	#timer: ReturnType<typeof setInterval> | undefined;

	constructor(options: ApprovalControllerOptions) {
		this.#options = options;
		this.panel = new ApprovalPanelComponent({
			onDecide: (decision, event) => {
				void this.resolve(event.approvalId, decision);
			},
			requestRender: () => this.#options.tui.requestRender(),
			now: options.now,
		});
	}

	attach(): void {
		const { store } = this.#options;
		// One subscription covers every arrival and departure: the store emits on
		// requests, on local resolves and on remote ones alike.
		this.#disposers.push(
			store.events.on("approvals-changed", () => this.present()),
			store.events.on("session-changed", () => this.present()),
		);
		this.present();
	}

	dispose(): void {
		for (const dispose of this.#disposers.splice(0)) dispose();
		this.#stopTicker();
		this.#unmount();
	}

	/** Pending requests belonging to the session on screen, oldest first. */
	pendingForFocused(): PendingApproval[] {
		const { store } = this.#options;
		return [...store.approvals.values()].filter((entry) => {
			if (this.#resolving.has(entry.event.approvalId)) return false;
			const key = entry.event.sessionKey;
			// A session-less request (a run started from a channel) belongs to
			// whatever is on screen; there is nowhere else to show it.
			return !key || key === store.focusedKey;
		});
	}

	/** Mount, dismiss or re-target the panel to match the store. */
	present(): void {
		const next = this.pendingForFocused()[0]?.event;
		if (!next) {
			this.#unmount();
			return;
		}
		this.panel.show(next);
		this.#mount();
		this.#syncTicker(next);
		this.#options.tui.requestRender();
	}

	/**
	 * Answer a request. Safe to call for a background session's approval — the
	 * panel only ever shows the focused session's, but the decision is not
	 * scoped to what is visible.
	 */
	async resolve(approvalId: string, decision: string): Promise<void> {
		const { store, methods, events, notice, refreshStatus } = this.#options;
		const pending = store.approvals.get(approvalId);
		if (!pending) {
			notice(`approval ${approvalId} is no longer pending`, "warning");
			return;
		}
		this.#resolving.add(approvalId);
		// Take it off screen first: the keypress is the answer, and the round-trip
		// is bookkeeping.
		this.present();
		try {
			await methods.approvalResolve({ approvalId, decision });
		} catch (error) {
			this.#resolving.delete(approvalId);
			notice(`approval failed: ${describeError(error)}`, "error");
			this.present();
			return;
		}
		this.#resolving.delete(approvalId);
		// Writes the store and annotates the transcript record in one place.
		events.resolveApproval(approvalId, decision);
		notice(
			`${decision === "deny" ? "denied" : "approved"} ${pending.event.tool ?? "tool"} (${humanDecision(decision)})`,
		);
		refreshStatus();
		this.present();
	}

	// -- internals -----------------------------------------------------------

	#mount(): void {
		if (this.#mounted) return;
		this.#mounted = true;
		this.#options.container.addChild(this.panel);
		this.#options.tui.setFocus(this.panel);
	}

	#unmount(): void {
		if (!this.#mounted) return;
		this.#mounted = false;
		const hadFocus = this.#options.tui.getFocused() === this.panel;
		this.#options.container.clear();
		this.panel.hide();
		this.#stopTicker();
		if (hadFocus) this.#options.focusEditor();
		this.#options.tui.requestRender();
	}

	/** The countdown only costs a timer when the request actually expires. */
	#syncTicker(event: ApprovalRequestedEvent): void {
		if (!event.expiresAtMs) {
			this.#stopTicker();
			return;
		}
		if (this.#timer) return;
		this.#timer = setInterval(() => {
			this.panel.tick();
			this.#options.tui.requestComponentRender(this.panel);
		}, this.#options.tickMs ?? APPROVAL_TICK_MS);
		this.#timer.unref?.();
	}

	#stopTicker(): void {
		if (this.#timer) clearInterval(this.#timer);
		this.#timer = undefined;
	}
}

function describeError(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}
