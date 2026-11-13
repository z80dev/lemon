import type { ControlPlaneMethods } from "../../protocol/methods.ts";
import { METHOD } from "../../protocol/methods.ts";
import {
	SUBAGENT_MESSAGE_MAX_BYTES,
	type Subagent,
	type SubagentStatus,
} from "../../protocol/subagents.ts";
import type { AgentEvent, SnapshotItems } from "../../protocol/types.ts";
import {
	isTaskActive,
	type TaskStatus,
	TaskStore,
	type TaskUpdate,
} from "../../store/task-store.ts";
import type { NoticeLevel } from "../../store/transcript-model.ts";
import { AgentHubComponent } from "../components/agent-hub.ts";
import { taskDisplayText, taskUpdatesFromEvent } from "../task-progress.ts";

export interface TaskTreeControllerOptions {
	requestRender: () => void;
	/** Host restores editor focus; Escape also hides the panel. */
	onBlur?: () => void;
	/** The daemon's `subagents.*` surface; without it the hub shows streamed task events only. */
	methods?: ControlPlaneMethods;
	/** Mutations are only attempted while connected. */
	online?: () => boolean;
	/** Transcript notice for what was asked and what happened. */
	notice?: (text: string, level?: NoticeLevel) => void;
	store?: TaskStore;
	now?: () => number;
	tickMs?: number;
	/** Roster/transcript refresh period while the hub is open. */
	pollMs?: number;
}

const HUB_STATUS: Record<SubagentStatus, TaskStatus> = {
	queued: "queued",
	running: "running",
	idle: "idle",
	parked: "parked",
	completed: "completed",
	failed: "error",
	cancelled: "aborted",
};

/**
 * The Agent Hub's data: raw client agent events (not the transcript's
 * synthetic child ToolBlocks) feed {@link ingest}; while the hub is open the
 * daemon's `subagents.list` roster is authoritative for lifecycle, lineage,
 * model and usage, and the open agent's transcript is re-read. Messages and
 * cancellation go through `subagents.send`/`subagents.cancel` and report their
 * real outcome. The host owns mounting, focus and the toggle keybinding.
 */
export class TaskTreeController {
	readonly panel: AgentHubComponent;
	readonly store: TaskStore;
	readonly #options: TaskTreeControllerOptions;
	readonly #unsubscribe: () => void;
	#sessionKey: string | null = null;
	#ticker: NodeJS.Timeout | undefined;
	#poller: NodeJS.Timeout | undefined;
	#generation = 0;
	#disposed = false;

	constructor(options: TaskTreeControllerOptions) {
		this.#options = options;
		this.store = options.store ?? new TaskStore();
		this.panel = new AgentHubComponent({
			requestRender: options.requestRender,
			now: options.now,
			onBlur: () => {
				this.setVisible(false);
				options.onBlur?.();
			},
			onOpen: (taskId) => void this.loadTranscript(taskId),
			onSend: (taskId, message) => this.send(taskId, message),
			onCancel: (taskId) => void this.cancel(taskId),
			onRefresh: () => void this.refresh(true),
		});
		this.#unsubscribe = this.store.events.on("changed", ({ sessionKey }) => {
			if (sessionKey === this.#sessionKey) this.#present();
		});
	}

	get ticking(): boolean {
		return this.#ticker !== undefined;
	}

	/** A session-less event is never assigned to whichever chat is on screen. */
	ingest(event: AgentEvent): boolean {
		if (this.#disposed || event.type !== "tool_use" || !event.sessionKey) return false;
		const updates = taskUpdatesFromEvent(event);
		if (updates.length === 0) return false;
		this.store.upsert(event.sessionKey, updates, this.#now());
		return true;
	}

	reconcile(sessionKey: string, projection: SnapshotItems<Record<string, unknown>>): void {
		if (this.#disposed || projection.status !== "ok") return;
		const updates: TaskUpdate[] = [];
		for (const item of projection.items) {
			if (typeof item.taskId !== "string" || !item.taskId) continue;
			const status = item.status;
			updates.push({
				taskId: item.taskId,
				runId: typeof item.runId === "string" ? item.runId : undefined,
				sessionId: typeof item.sessionId === "string" ? item.sessionId : undefined,
				parentRunId: typeof item.parentRunId === "string" ? item.parentRunId : undefined,
				status:
					status === "completed" ||
					status === "error" ||
					status === "aborted" ||
					status === "queued" ||
					status === "running" ||
					status === "cancelling"
						? status
						: status === "cancelled"
							? "aborted"
							: "unknown",
				progress: typeof item.answer === "string" ? taskDisplayText(item.answer, true) : undefined,
			});
		}
		this.store.clear(sessionKey);
		this.store.upsert(sessionKey, updates, this.#now());
		// The snapshot carries direct children only; the open hub restores the rest.
		if (sessionKey === this.#sessionKey && this.panel.visible) void this.refresh(false);
	}

	setSession(sessionKey: string | null): void {
		if (this.#disposed || this.#sessionKey === sessionKey) return;
		this.#sessionKey = sessionKey;
		this.#generation += 1;
		this.panel.resetView();
		this.panel.update([]);
		this.#present();
		if (this.panel.visible) void this.refresh(false);
	}

	/** Returns the new visibility; the host may focus panel when it opens. */
	toggle(): boolean {
		this.setVisible(!this.panel.visible);
		return this.panel.visible;
	}

	setVisible(visible: boolean): void {
		if (this.#disposed) return;
		const opening = visible && !this.panel.visible;
		this.panel.setVisible(visible);
		if (opening) void this.refresh(false);
		this.#present();
	}

	/**
	 * Re-read the daemon roster (and the open transcript). A failed read is shown
	 * in the hub, and in the transcript only when the user asked; the store keeps
	 * its last known rows rather than pretending the session has no subagents.
	 */
	async refresh(requested: boolean): Promise<void> {
		const methods = this.#options.methods;
		const sessionKey = this.#sessionKey;
		if (this.#disposed || !sessionKey) return;
		if (!methods?.supports(METHOD.subagentsList)) {
			if (requested) {
				this.panel.setFlash({
					text: `daemon does not support ${METHOD.subagentsList}; showing streamed task events`,
					level: "warning",
				});
			}
			return;
		}
		const generation = this.#generation;
		try {
			const agents = await methods.subagentsList({ sessionKey });
			if (this.#disposed || generation !== this.#generation) return;
			this.store.upsert(sessionKey, agents.map(hubUpdate), this.#now(), { authoritative: true });
			if (requested) this.panel.setFlash({ text: "refreshed", level: "info" });
		} catch (error) {
			if (this.#disposed || generation !== this.#generation) return;
			const text = `roster refresh failed: ${describe(error)}`;
			this.panel.setFlash({ text, level: "warning" });
			if (requested) this.#options.notice?.(`agents: ${text}`, "warning");
		}
		const open = this.panel.openTaskId;
		if (open) await this.loadTranscript(open);
	}

	async loadTranscript(taskId: string): Promise<void> {
		const methods = this.#options.methods;
		const sessionKey = this.#sessionKey;
		if (this.#disposed || !sessionKey) return;
		if (!methods?.supports(METHOD.subagentsTranscript)) {
			this.panel.setTranscript({
				taskId,
				loading: false,
				error: `daemon does not support ${METHOD.subagentsTranscript}`,
			});
			return;
		}
		const generation = this.#generation;
		try {
			const transcript = await methods.subagentsTranscript({ sessionKey, taskId });
			if (generation !== this.#generation) return;
			this.panel.setTranscript({
				taskId,
				loading: false,
				text: transcript.text,
				truncated: transcript.truncated,
			});
		} catch (error) {
			if (generation !== this.#generation) return;
			this.panel.setTranscript({ taskId, loading: false, error: describe(error) });
		}
	}

	/** Steer, follow up or revive. Resolves true only when the daemon accepted the message. */
	async send(taskId: string, message: string): Promise<boolean> {
		const sessionKey = this.#sessionKey;
		if (Buffer.byteLength(message, "utf8") > SUBAGENT_MESSAGE_MAX_BYTES) {
			this.#report("message not sent: it exceeds 32 KiB", "warning");
			return false;
		}
		if (!sessionKey || !this.#ready(METHOD.subagentsSend, "message")) return false;
		try {
			const receipt = await this.#options.methods!.subagentsSend({ sessionKey, taskId, message });
			const outcome = DELIVERY_TEXT[receipt.delivery];
			if (receipt.accepted) this.#report(`${outcome} ${taskId}`, "info");
			else if (receipt.delivery === "outcome_unknown")
				this.#report(
					`message to ${taskId} may or may not have been delivered — check its transcript before resending`,
					"warning",
				);
			else this.#report(`message to ${taskId} failed: ${outcome}`, "error");
			void this.refresh(false);
			return receipt.accepted;
		} catch (error) {
			this.#report(`message to ${taskId} not sent: ${describe(error)}`, "error");
			return false;
		}
	}

	async cancel(taskId: string): Promise<void> {
		const sessionKey = this.#sessionKey;
		if (!sessionKey || !this.#ready(METHOD.subagentsCancel, "cancel")) return;
		try {
			const { cancelled } = await this.#options.methods!.subagentsCancel({ sessionKey, taskId });
			if (cancelled) this.#report(`cancelled ${taskId}; its transcript stays readable`, "info");
			else this.#report(`${taskId} did not confirm cancellation; refresh to check`, "warning");
		} catch (error) {
			this.#report(`cancel ${taskId} failed: ${describe(error)}`, "error");
		}
		void this.refresh(false);
	}

	dispose(): void {
		this.#disposed = true;
		this.#unsubscribe();
		this.#stopTimers();
		this.panel.setVisible(false);
	}

	#ready(method: string, verb: string): boolean {
		if (!this.#options.methods?.supports(method)) {
			this.#report(`${verb} unavailable: daemon does not support ${method}`, "warning");
			return false;
		}
		if (this.#options.online && !this.#options.online()) {
			this.#report(`offline — ${verb} not sent; reconnect and retry`, "warning");
			return false;
		}
		return true;
	}

	#report(text: string, level: NoticeLevel): void {
		this.panel.setFlash({ text, level });
		this.#options.notice?.(`agents: ${text}`, level);
	}

	#now(): number {
		return this.#options.now?.() ?? Date.now();
	}

	#present(): void {
		const rows = this.#sessionKey ? this.store.tree(this.#sessionKey) : [];
		this.panel.update(rows);
		const visible = this.panel.visible && !this.#disposed;
		const active = visible && rows.some((row) => isTaskActive(row.task.status));
		if (active && this.#ticker === undefined) {
			this.#ticker = setInterval(this.#options.requestRender, this.#options.tickMs ?? 1000);
			this.#ticker.unref?.();
		} else if (!active && this.#ticker !== undefined) {
			clearInterval(this.#ticker);
			this.#ticker = undefined;
		}
		if (visible && this.#poller === undefined && this.#options.methods) {
			this.#poller = setInterval(() => void this.refresh(false), this.#options.pollMs ?? 3000);
			this.#poller.unref?.();
		} else if (!visible && this.#poller !== undefined) {
			clearInterval(this.#poller);
			this.#poller = undefined;
		}
		this.#options.requestRender();
	}

	#stopTimers(): void {
		clearInterval(this.#ticker);
		clearInterval(this.#poller);
		this.#ticker = undefined;
		this.#poller = undefined;
	}
}

const DELIVERY_TEXT: Record<string, string> = {
	injected: "steered",
	woken: "followed up with",
	revived: "revived",
	failed: "the daemon could not start its turn",
	outcome_unknown: "outcome unknown",
};

function hubUpdate(agent: Subagent): TaskUpdate {
	return {
		taskId: agent.taskId,
		status: HUB_STATUS[agent.status],
		parentTaskId: agent.parentTaskId,
		name: agent.name,
		agent: agent.agent,
		description: agent.description,
		model: agent.model,
		usage: agent.usage,
		contextPercent: agent.contextPercent,
		messaging: agent.messaging,
		cancellable: agent.cancellable,
		startedAt: agent.startedAtMs ?? agent.createdAtMs,
		completedAt: agent.completedAtMs,
		...(agent.activity ? { progress: agent.activity } : {}),
	};
}

function describe(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}
