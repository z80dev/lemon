/**
 * The single protocol -> store -> UI writer.
 *
 * Everything the daemon says arrives here, is written to the stores, and is
 * mirrored into transcript components. Nothing else in the client mutates a
 * store, and nothing else creates a transcript block — that is what keeps the
 * block model (what tests assert on) and the rendered tree in step.
 *
 * Render discipline:
 *   - streaming ticks go through {@link StreamingRevealController}, which
 *     renders the assistant component alone (`requestComponentRender`);
 *   - structural changes (a new block, a finalize, a tool phase flip) request
 *     at most one full render per macrotask.
 */

import type { Component, TUI } from "@oh-my-pi/pi-tui/tui";
import type { ControlPlaneClient } from "../../protocol/client.ts";
import type {
	AgentCompletedEvent,
	AgentEvent,
	AgentStartedEvent,
	AgentToolUseEvent,
	ApprovalRequestedEvent,
	ApprovalResolvedEvent,
	ChatDeltaEvent,
	ChatEvent,
	ConnectionState,
} from "../../protocol/types.ts";
import type { AppStore } from "../../store/app-store.ts";
import type { SessionStore } from "../../store/session-store.ts";
import {
	type AssistantBlock,
	type Block,
	type CompactionDetails,
	type NoticeLevel,
	type ToolBlock,
	toToolPhase,
	type UserDetails,
} from "../../store/transcript-model.ts";
import {
	type AccordionState,
	accordionSettings,
	resolveAccordionState,
} from "../components/accordion.ts";
import { ApprovalRecordComponent } from "../components/approval-panel.ts";
import { AssistantMessageComponent } from "../components/assistant-message.ts";
import { NoticeComponent } from "../components/notice-message.ts";
import { ReasoningComponent } from "../components/reasoning-block.ts";
import { ToolShelfComponent } from "../components/tool-shelf.ts";
import type { TranscriptContainer } from "../components/transcript-container.ts";
import { UserMessageComponent } from "../components/user-message.ts";
import { taskProgressEvent } from "../task-progress.ts";
import { StreamingRevealController } from "./streaming-reveal.ts";

export interface EventControllerOptions {
	client: ControlPlaneClient;
	store: AppStore;
	tui: TUI;
	transcript: TranscriptContainer;
	/** Called whenever the status line's inputs changed. */
	onStatusChanged?: () => void;
	/** Disables the 30fps reveal (tests, `--no-smooth-streaming` later). */
	smoothStreaming?: () => boolean;
}

export class EventController {
	readonly #client: ControlPlaneClient;
	readonly #store: AppStore;
	readonly #tui: TUI;
	readonly #transcript: TranscriptContainer;
	readonly #onStatusChanged: (() => void) | undefined;
	readonly #reveal: StreamingRevealController;

	/** Block id -> its component, for the focused session only. */
	readonly #components = new Map<string, Component>();
	/** Tool block id -> the shelf that owns its card (the transcript child). */
	readonly #shelves = new Map<string, ToolShelfComponent>();
	/** The shelf tool blocks currently append to, until a barrier closes it. */
	#openShelf: ToolShelfComponent | undefined;
	readonly #disposers: Array<() => void> = [];

	#renderScheduled = false;
	#attached = false;
	#recoveryScheduled = false;

	constructor(options: EventControllerOptions) {
		this.#client = options.client;
		this.#store = options.store;
		this.#tui = options.tui;
		this.#transcript = options.transcript;
		this.#onStatusChanged = options.onStatusChanged;
		this.#reveal = new StreamingRevealController({
			requestRender: (component) => this.#tui.requestComponentRender(component),
			getSmoothStreaming: options.smoothStreaming,
		});
	}

	// -- lifecycle -----------------------------------------------------------

	attach(): void {
		if (this.#attached) return;
		this.#attached = true;
		const on = <K extends Parameters<ControlPlaneClient["events"]["on"]>[0]>(
			event: K,
			listener: (payload: any) => void,
		) => {
			this.#disposers.push(this.#client.events.on(event, listener));
		};

		on("state", ({ state }: { state: ConnectionState }) => {
			this.#store.setConnection(state);
			this.#onStatusChanged?.();
		});
		on("hello-ok", ({ hello, resumed }: { hello: any; resumed: boolean }) => {
			this.#store.serverVersion = hello?.server?.version;
			this.#store.methods = new Set<string>(hello?.features?.methods ?? []);
			this.notice(
				resumed ? "reconnected" : `connected to lemon ${hello?.server?.version ?? "?"}`,
				resumed ? "warning" : "info",
			);
			this.#onStatusChanged?.();
		});
		on("chat", (event: ChatEvent) => this.#onChat(event));
		on("agent", (event: AgentEvent) => this.#onAgent(event));
		on("exec.approval.requested", (event: ApprovalRequestedEvent) =>
			this.#onApprovalRequested(event),
		);
		on("exec.approval.resolved", (event: ApprovalResolvedEvent) => {
			// Someone else answered: another client, or the daemon's own timeout.
			const pending = this.#store.approvals.get(event.approvalId);
			if (pending?.event.sessionKey && event.sessionKey !== pending.event.sessionKey) return;
			this.#sessionFor(event.sessionKey).recoveryEventVersion += 1;
			this.resolveApproval(event.approvalId, event.decision);
		});
		on("shutdown", () => this.notice("daemon is shutting down", "warning"));
	}

	dispose(): void {
		for (const dispose of this.#disposers.splice(0)) dispose();
		this.#reveal.stop();
		this.#disposeShelves();
		this.#attached = false;
	}

	// -- writes the app drives ----------------------------------------------

	/** Echo the user's prompt. Called by the shell right before `chat.send`. */
	addUserBlock(
		text: string,
		session: SessionStore = this.#store.focused,
		details?: Omit<UserDetails, "sentAt">,
	): void {
		const at = Date.now();
		session.addUser(text, at, { sentAt: at, ...details });
		this.#sync(session);
	}

	notice(
		text: string,
		level: NoticeLevel = "info",
		session = this.#store.focused,
		compaction?: CompactionDetails,
	): void {
		session.addNotice(text, level, undefined, compaction);
		this.#sync(session);
	}

	/** Record the run id `chat.send` returned, before any event arrives. */
	noteRunStarted(runId: string, session: SessionStore = this.#store.focused): void {
		session.activeRunId = runId;
		session.busy = true;
		session.ensureAssistant(runId);
		this.#sync(session);
		this.#onStatusChanged?.();
	}

	/** Mark a run the user aborted: keeps partial text, adds the marker. */
	markInterrupted(runId: string, session: SessionStore = this.#store.focused): void {
		const block = session.assistantFor(runId);
		if (!block || session.activeRunId !== runId || !session.busy) return;
		const component = session === this.#store.focused ? this.#componentFor(block.id) : undefined;
		// Only this run's own reveal may be flushed and torn down; another run's
		// stream keeps revealing.
		const revealing = component !== undefined && this.#reveal.component === component;
		if (revealing) this.#reveal.finish();
		session.markInterrupted(runId);
		if (component instanceof AssistantMessageComponent) this.#sealAssistant(block, component);
		this.#refreshReasoning(session, runId);
		if (revealing) this.#reveal.stop();
		if (session === this.#store.focused) this.#sealOpenShelf();
		this.#scheduleRender();
		this.#onStatusChanged?.();
	}

	/**
	 * The expand key: toggle the most recent tool card or reasoning block in the
	 * focused session. False when the transcript has neither.
	 */
	toggleLatestBlock(): boolean {
		const blocks = this.#store.focused.blocks;
		for (let index = blocks.length - 1; index >= 0; index--) {
			const block = blocks[index];
			if (block?.kind === "tool") {
				const toggled = this.#shelves.get(block.id)?.toggle(block.id);
				if (toggled === undefined) return false;
				this.#scheduleRender();
				return true;
			}
			if (block?.kind === "reasoning") {
				const component = this.#components.get(block.id);
				if (!(component instanceof ReasoningComponent)) return false;
				component.toggleAccordion();
				this.#scheduleRender();
				return true;
			}
		}
		return false;
	}

	/**
	 * The detail key: cycle the global accordion override (collapsed → expanded
	 * → per-kind default) and apply it to every card and reasoning block already
	 * on screen, not just to the ones built afterwards.
	 */
	cycleAccordionOverride(): AccordionState | undefined {
		const override = accordionSettings.cycleOverride();
		this.#applyAccordionOverride();
		return override;
	}

	/** Binary whole-transcript toggle, without disturbing the model-picker key. */
	toggleToolOutputs(): AccordionState {
		const next = accordionSettings.override === "expanded" ? "collapsed" : "expanded";
		accordionSettings.setOverride(next);
		this.#applyAccordionOverride();
		return next;
	}

	#applyAccordionOverride(): void {
		for (const shelf of new Set(this.#shelves.values())) shelf.applyAccordionOverride();
		for (const component of this.#components.values()) {
			if (component instanceof ReasoningComponent) {
				component.setAccordionState(resolveAccordionState("reasoning"));
			}
		}
		this.#scheduleRender();
	}

	/**
	 * Rebuild from the focused session's blocks after selection, reset, or
	 * authoritative snapshot replacement; discarded rows cannot remain native history.
	 */
	rebuildFocused(): void {
		this.#reveal.stop();
		this.#disposeShelves();
		this.#components.clear();
		this.#transcript.disposeChildren();
		this.#sync(this.#store.focused);
	}

	/** Stop every shelf's card animations before the tree is thrown away. */
	#disposeShelves(): void {
		for (const shelf of new Set(this.#shelves.values())) shelf.dispose();
		this.#shelves.clear();
		this.#openShelf = undefined;
	}

	// -- protocol handlers ---------------------------------------------------
	#requestRecovery(session: SessionStore): void {
		if (session !== this.#store.focused || this.#recoveryScheduled) return;
		this.#recoveryScheduled = true;
		queueMicrotask(() => {
			this.#recoveryScheduled = false;
			const hello = this.#client.helloOk;
			if (hello && session === this.#store.focused)
				this.#client.events.emit("resync-needed", { hello, sessionKey: session.key });
		});
	}

	#onChat(event: ChatEvent): void {
		if (event?.type !== "delta") return;
		const delta = event as ChatDeltaEvent;
		const session = this.#sessionFor(delta.sessionKey);
		session.recoveryEventVersion += 1;
		if (
			!session.acceptsEvent(delta.runId, delta.identity) ||
			session.snapshotRunId === delta.runId
		) {
			this.#requestRecovery(session);
			return;
		}
		const result = session.appendDelta(delta.runId, delta.seq, delta.text ?? "");
		if (!result.accepted) return;
		if (session !== this.#store.focused) return;
		this.#sync(session);
		const component = this.#componentFor(result.block.id);
		if (!(component instanceof AssistantMessageComponent)) return;
		if (result.amended) {
			// The tail of a stream that arrived after its own `completed`. The block
			// is history: repaint it in place (updateContent bumps the block version
			// so the container re-renders instead of replaying committed rows) and
			// never reopen a reveal on it.
			this.#sealAssistant(result.block, component);
			this.#scheduleRender();
			return;
		}
		if (this.#reveal.component === component) this.#reveal.setTarget(result.block.text);
		else this.#reveal.begin(component, result.block.text);
	}

	#onAgent(event: AgentEvent): void {
		const owner = this.#sessionFor(event.sessionKey);
		owner.recoveryEventVersion += 1;
		// Spend is session-wide, not a projection: it counts once per run whether or
		// not the event passes the ownership fences below, and whether the session
		// is snapshot-managed (where the event only requests recovery) or not.
		if (event.type === "completed") {
			owner.addRunCost(event.runId, (event as AgentCompletedEvent).usage);
			this.#onStatusChanged?.();
		}
		if (!owner.acceptsEvent(event.runId, event.identity)) {
			this.#requestRecovery(owner);
			return;
		}
		if (owner.snapshotIdentity) {
			// With no event cursor, actions and terminal previews refresh owner truth.
			this.#requestRecovery(owner);
			return;
		}
		switch (event.type) {
			case "started": {
				const started = event as AgentStartedEvent;
				const session = this.#sessionFor(started.sessionKey);
				if (session.isRunTerminal(started.runId)) return;
				session.activeRunId = started.runId;
				session.busy = true;
				session.engine = started.engine ?? undefined;
				// What the run actually resolved to. This is the only place the daemon
				// ever reveals it, so it outranks whatever `/model` set locally.
				session.setModel(
					{
						model: started.model,
						provider: started.provider,
						thinkingLevel: started.thinkingLevel,
					},
					"run",
				);
				this.#sync(session);
				this.#onStatusChanged?.();
				return;
			}
			case "tool_use": {
				const tool = taskProgressEvent(event as AgentToolUseEvent) ?? (event as AgentToolUseEvent);
				const session = this.#sessionFor(tool.sessionKey);
				if (tool.action?.kind === "reasoning") {
					const block = session.upsertReasoning(tool.action, toToolPhase(tool.phase), {
						runId: tool.runId,
					});
					this.#sync(session);
					const component = this.#components.get(block.id);
					if (component instanceof ReasoningComponent) component.update(block);
					this.#scheduleRender();
					return;
				}
				const block = session.upsertTool(tool.action, toToolPhase(tool.phase), {
					runId: tool.runId,
					ok: tool.ok,
					message: tool.message,
				});
				this.#sync(session);
				if (session === this.#store.focused) this.#shelves.get(block.id)?.update(block);
				this.#scheduleRender();
				this.#onStatusChanged?.();
				return;
			}
			case "completed": {
				const completed = event as AgentCompletedEvent;
				const session = this.#sessionFor(completed.sessionKey);
				const focused = session === this.#store.focused;
				// Token counts for the context gauge, which is the only per-session
				// number available — `usage.status` is today-wide across all sessions.
				session.applyUsage(completed.usage);
				session.setModel({ model: completed.model }, "run");
				// Whether the single reveal is driving *this* run's block. A
				// completion for run A must never finish or stop the reveal that is
				// mid-stream on run B — that would flush B's text early and freeze
				// it while its deltas keep arriving.
				const streaming = session.assistantFor(completed.runId);
				const revealing =
					focused &&
					streaming !== undefined &&
					this.#reveal.component === this.#componentFor(streaming.id);
				// The reveal must land the whole buffer before the block seals:
				// finalized bytes are what reaches native scrollback.
				if (revealing) this.#reveal.finish();
				const block = session.finalizeRun(completed.runId, {
					ok: completed.ok,
					answer: completed.answer,
					interrupted: completed.cancelled === true,
					error:
						typeof completed.error === "string"
							? completed.error
							: completed.error == null
								? undefined
								: JSON.stringify(completed.error),
					turn: {
						...(typeof completed.durationMs === "number" && completed.durationMs >= 0
							? { durationMs: completed.durationMs }
							: {}),
						...(completed.usage ? { usage: completed.usage } : {}),
						...(completed.model?.trim() ? { model: completed.model.trim() } : {}),
					},
				});
				// finalizeRun may have created the block (completed outran started),
				// so resolve its component only after the tree is in step.
				this.#sync(session);
				if (focused) this.#refreshReasoning(session, completed.runId);
				if (block && focused) {
					const component = this.#componentFor(block.id);
					if (component instanceof AssistantMessageComponent) this.#sealAssistant(block, component);
					if (revealing) this.#reveal.stop();
				}
				// The run is over, so the trailing run of tool activity is too: seal it
				// and let its rows reach native scrollback.
				if (focused) this.#sealOpenShelf();
				if (completed.ok === false && !completed.cancelled && !block) {
					this.notice(`run ${completed.runId} failed`, "error", session);
				}
				this.#scheduleRender();
				this.#onStatusChanged?.();
				return;
			}
			default:
				return;
		}
	}

	#onApprovalRequested(event: ApprovalRequestedEvent): void {
		const session = this.#sessionFor(event.sessionKey);
		session.recoveryEventVersion += 1;
		if (session.snapshotIdentity || !session.acceptsEvent(event.runId, event.identity)) {
			this.#requestRecovery(session);
			return;
		}
		if (this.#store.approvals.has(event.approvalId)) return;
		const block = session.addApprovalBlock(event.approvalId, event.tool ?? undefined);
		// The block is the transcript's record; the panel (mounted by the approval
		// controller, which watches the store) is where the decision is made.
		this.#store.addApproval(event, block);
		this.#sync(session);
		this.#onStatusChanged?.();
	}

	/**
	 * Forget a resolved approval and annotate its transcript record.
	 *
	 * Every resolve path funnels here — the panel, `/approve`, `/deny`, and the
	 * daemon's own `exec.approval.resolved` — so the store, the block model and
	 * the rendered line can never disagree about what was decided.
	 */
	resolveApproval(approvalId: string, decision: string): void {
		const resolved = this.#store.resolveApproval(approvalId, decision);
		const blockId = resolved?.block?.id;
		if (blockId) {
			const component = this.#components.get(blockId);
			if (component instanceof ApprovalRecordComponent) component.annotate(decision);
		}
		this.#scheduleRender();
		this.#onStatusChanged?.();
	}

	// -- component mirroring -------------------------------------------------

	#sessionFor(sessionKey: string | null | undefined): SessionStore {
		// The bridge omits the key on session-less events (a run started from a
		// channel); those belong to whatever is on screen.
		return sessionKey ? this.#store.session(sessionKey) : this.#store.focused;
	}

	#componentFor(blockId: string): Component | undefined {
		return this.#components.get(blockId);
	}

	/** Repaint a run's reasoning blocks after the store closed them. */
	#refreshReasoning(session: SessionStore, runId: string): void {
		if (session !== this.#store.focused) return;
		for (const block of session.reasoningByActionId.values()) {
			if (block.runId !== runId) continue;
			const component = this.#components.get(block.id);
			if (component instanceof ReasoningComponent) component.update(block);
		}
	}

	/**
	 * Render a finished run's block in its sealed form. The single place that
	 * translates {@link AssistantBlock.status} into component state, so a live
	 * finalize, a late amendment and a session rebuild all produce identical
	 * bytes — which is what makes rebuilt history match what was committed.
	 */
	#sealAssistant(block: AssistantBlock, component: AssistantMessageComponent): void {
		// No explicit transient: an already-sealed component must not be flipped
		// back into streaming-render mode by a repaint.
		component.updateContent(block.text);
		component.finalize({
			ok: block.status !== "error",
			interrupted: block.status === "aborted",
			// A run can fail with neither streamed text nor a message (the daemon
			// reports `ok: false, answer: ""`); without a fallback the block would
			// render as nothing at all and the failure would be invisible.
			error: block.status === "error" ? (block.error ?? "run failed") : undefined,
			turn: block.turn,
		});
	}

	/**
	 * Append components for any focused-session block that does not have one.
	 * Blocks are append-only, so this stays a tail walk; a session switch clears
	 * the map and rebuilds from scratch.
	 */
	#sync(session: SessionStore): void {
		if (session !== this.#store.focused) {
			this.#scheduleStatusOnly();
			return;
		}
		let appended = false;
		for (const block of session.blocks) {
			const existing = this.#components.get(block.id);
			if (
				block.kind === "assistant" &&
				block.status !== "streaming" &&
				existing instanceof AssistantMessageComponent &&
				!existing.isTranscriptBlockFinalized()
			) {
				if (this.#reveal.component === existing) {
					this.#reveal.finish();
					this.#reveal.stop();
				}
				this.#sealAssistant(block, existing);
			}
			if (this.#components.has(block.id) || this.#shelves.has(block.id)) continue;
			if (block.kind === "tool") {
				this.#placeToolBlock(block);
				appended = true;
				continue;
			}
			const component = this.#createComponent(block);
			if (!component) continue;
			// Any non-tool block is a shelf barrier: the run of tool activity above
			// it is over, so its shape can never change again and its rows become
			// commit-eligible.
			this.#sealOpenShelf();
			this.#components.set(block.id, component);
			this.#transcript.addChild(component);
			appended = true;
		}
		if (appended) this.#scheduleRender();
	}

	/**
	 * Route a tool block onto the open shelf, opening one if the previous block
	 * was not a tool. The shelf owns the card; the transcript only ever sees the
	 * shelf, so a card collapsing into a shelf line never adds or removes a
	 * transcript child.
	 */
	#placeToolBlock(block: ToolBlock): void {
		let shelf = this.#openShelf;
		if (!shelf?.open) {
			shelf = new ToolShelfComponent({
				requestRender: (component) => this.#tui.requestComponentRender(component),
			});
			this.#openShelf = shelf;
			this.#transcript.addChild(shelf);
		}
		shelf.add(block);
		this.#shelves.set(block.id, shelf);
	}

	/** Close the current run of tool activity, if any. */
	#sealOpenShelf(): void {
		this.#openShelf?.seal();
		this.#openShelf = undefined;
	}

	#createComponent(block: Block): Component | undefined {
		switch (block.kind) {
			case "user":
				return new UserMessageComponent(block.text, block);
			case "assistant": {
				const component = new AssistantMessageComponent(block.text);
				// A rebuilt session (or a block created straight from `completed`)
				// carries finished runs. Constructing them in the streaming state
				// would leave the transcript reporting a live region that never
				// closes, pinning the native-scrollback commit seam open forever.
				if (block.status !== "streaming") this.#sealAssistant(block, component);
				return component;
			}
			case "tool":
				// Owned by a ToolShelfComponent; see #placeToolBlock.
				return undefined;
			case "notice":
				return new NoticeComponent(block.text, block.level, block.compaction);
			case "reasoning":
				return new ReasoningComponent(block);
			case "approval":
				// The decision itself belongs to the panel below the transcript; this
				// is only the history line, sealed once an answer exists.
				return new ApprovalRecordComponent(
					block.approvalId,
					block.tool,
					block.status === "resolved" ? (block.decision ?? "resolved") : undefined,
				);
			default:
				return undefined;
		}
	}

	#scheduleStatusOnly(): void {
		this.#onStatusChanged?.();
	}

	/** At most one full render per macrotask, however many events landed. */
	#scheduleRender(): void {
		if (this.#renderScheduled) return;
		this.#renderScheduled = true;
		queueMicrotask(() => {
			this.#renderScheduled = false;
			this.#tui.requestRender();
		});
	}
}
