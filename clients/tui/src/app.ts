/**
 * AppShell — the P1 skeleton of the Lemon terminal client.
 *
 * Flat container order (later phases slot components into the same seams):
 *
 *   banner        welcome + connection state
 *   chat          transcript blocks (plain Container here; P2 swaps in
 *                 TranscriptContainer with native-scrollback commits)
 *   status        one line: connection, session, activity
 *   editor        the prompt
 *
 * Wiring rules this file keeps to, because later phases depend on them:
 *   - controllers own the store and the UI; components stay dumb
 *   - the accumulated delta buffer is the source of truth for a run's final
 *     text (`agent completed.answer` is server-truncated to 500 bytes)
 *   - nothing here calls `process.exit`; `onExit` hands that to main.ts
 */

import { Editor } from "@oh-my-pi/pi-tui/components/editor";
import { Markdown } from "@oh-my-pi/pi-tui/components/markdown";
import { Text } from "@oh-my-pi/pi-tui/components/text";
import { matchesKey } from "@oh-my-pi/pi-tui/keys";
import { ProcessTerminal, type Terminal } from "@oh-my-pi/pi-tui/terminal";
import { Container, TUI } from "@oh-my-pi/pi-tui/tui";
import { acceptDeltaSeq, ControlPlaneClient } from "./protocol/client.ts";
import { ControlPlaneMethods } from "./protocol/methods.ts";
import type {
	AgentCompletedEvent,
	AgentEvent,
	AgentStartedEvent,
	AgentToolUseEvent,
	ApprovalRequestedEvent,
	ChatDeltaEvent,
	ChatEvent,
} from "./protocol/types.ts";
import { getTheme } from "./ui/theme/theme.ts";
import { getEditorTheme, getMarkdownTheme } from "./ui/theme/tui-adapters.ts";

/** Window in which a second Ctrl+C exits. */
const EXIT_CONFIRM_MS = 2000;

export interface AppShellOptions {
	url: string;
	/** Session to talk to. Defaults to a fresh `tui-<timestamp>` key. */
	sessionKey?: string;
	version?: string;
	/** Injection points for tests. */
	client?: ControlPlaneClient;
	terminal?: Terminal;
	tui?: TUI;
	/** Called instead of `process.exit`. */
	onExit?: (code: number) => void;
}

interface RunView {
	runId: string;
	/** Accumulated delta text — the source of truth for the final answer. */
	buffer: string;
	component: Markdown;
	finalized: boolean;
}

export function defaultSessionKey(now: Date = new Date()): string {
	return `tui-${now.toISOString().replace(/[-:.]/g, "").slice(0, 15)}`;
}

export class AppShell {
	readonly tui: TUI;
	readonly client: ControlPlaneClient;
	readonly methods: ControlPlaneMethods;

	readonly bannerContainer = new Container();
	readonly chatContainer = new Container();
	readonly statusContainer = new Container();
	readonly editorContainer = new Container();

	readonly #banner = new Text("", 1, 0);
	readonly #connectionLine = new Text("", 1, 0);
	readonly #statusLine = new Text("", 1, 0);
	readonly #editor: Editor;

	readonly #version: string;
	readonly #onExit: ((code: number) => void) | undefined;

	#sessionKey: string;
	#runs = new Map<string, RunView>();
	#deltaSeqs = new Map<string, number>();
	#activeRunId: string | undefined;
	#activity: string | undefined;
	#exitArmedAt = 0;
	#pendingApprovals = 0;
	#disposers: Array<() => void> = [];
	#started = false;

	constructor(options: AppShellOptions) {
		this.#version = options.version ?? "dev";
		this.#onExit = options.onExit;
		this.#sessionKey = options.sessionKey ?? defaultSessionKey();
		this.client = options.client ?? new ControlPlaneClient({ url: options.url });
		this.methods = new ControlPlaneMethods(this.client);
		this.tui = options.tui ?? new TUI(options.terminal ?? new ProcessTerminal());
		// Editor construction needs a theme: pi-tui ships no defaults.
		this.#editor = new Editor(getEditorTheme());
	}

	get sessionKey(): string {
		return this.#sessionKey;
	}

	get editor(): Editor {
		return this.#editor;
	}

	/** Build the UI, start rendering, and connect. */
	async start(): Promise<void> {
		if (this.#started) return;
		this.#started = true;
		this.#buildUi();
		this.#wireInput();
		this.#wireClient();
		this.tui.start();
		this.#renderStatus();
		try {
			await this.client.connect();
		} catch (error) {
			// The socket keeps retrying in the background; just say so.
			this.#notice(`connection failed: ${describeError(error)}`);
		}
	}

	stop(): void {
		for (const dispose of this.#disposers.splice(0)) dispose();
		this.client.close();
		if (this.#started) this.tui.stop();
		this.#started = false;
	}

	// -- ui -----------------------------------------------------------------

	#buildUi(): void {
		const theme = getTheme();
		this.#banner.setText(
			`${theme.fg("bannerTitle", "lemon")} ${theme.fg("bannerSubtitle", `tui ${this.#version}`)}  ${theme.fg(
				"dim",
				"Ctrl+C abort · Ctrl+C twice quit · Ctrl+D quit",
			)}`,
		);
		this.bannerContainer.addChild(this.#banner);
		this.bannerContainer.addChild(this.#connectionLine);
		this.statusContainer.addChild(this.#statusLine);

		this.#editor.onSubmit = (value) => {
			void this.submit(value);
		};
		this.editorContainer.addChild(this.#editor);

		this.tui.addChild(this.bannerContainer);
		this.tui.addChild(this.chatContainer);
		this.tui.addChild(this.statusContainer);
		this.tui.addChild(this.editorContainer);
		this.tui.setFocus(this.#editor);
		this.#renderConnection();
	}

	#renderConnection(): void {
		const theme = getTheme();
		const state = this.client.state;
		const slot = state === "online" ? "success" : state === "offline" ? "error" : "warning";
		const queued = this.client.queued.length;
		const suffix = queued > 0 ? theme.fg("dim", `  (${queued} queued)`) : "";
		this.#connectionLine.setText(
			`${theme.fg("dim", this.client.url)}  ${theme.fg(slot, state)}${suffix}`,
		);
		this.tui.requestRender();
	}

	#renderStatus(): void {
		const theme = getTheme();
		const parts = [theme.fg("accent", this.#sessionKey)];
		if (this.#activeRunId) {
			parts.push(theme.fg("toolRunning", this.#activity ?? "working…"));
		} else {
			parts.push(theme.fg("dim", "idle"));
		}
		if (this.#pendingApprovals > 0) {
			parts.push(theme.fg("warning", `${this.#pendingApprovals} approval(s) pending`));
		}
		this.#statusLine.setText(parts.join(theme.fg("dim", " · ")));
		this.tui.requestRender();
	}

	#append(component: Markdown | Text): void {
		this.chatContainer.addChild(component);
		this.tui.requestRender();
	}

	#notice(message: string): void {
		const theme = getTheme();
		this.#append(new Text(theme.fg("noticeText", `· ${message}`), 1, 0));
	}

	// -- input --------------------------------------------------------------

	#wireInput(): void {
		this.#disposers.push(
			this.tui.addInputListener((data) => {
				if (matchesKey(data, "ctrl+c")) {
					this.#onCtrlC();
					return { consume: true };
				}
				if (matchesKey(data, "ctrl+d")) {
					this.requestExit(0);
					return { consume: true };
				}
				return undefined;
			}),
		);
	}

	/** Ctrl+C aborts a live run; pressed twice with nothing running, it quits. */
	#onCtrlC(): void {
		if (this.#activeRunId) {
			const runId = this.#activeRunId;
			this.#notice("aborting…");
			void this.methods
				.chatAbort({ runId, sessionKey: this.#sessionKey })
				.catch((error) => this.#notice(`abort failed: ${describeError(error)}`));
			this.#exitArmedAt = 0;
			return;
		}
		const now = Date.now();
		if (now - this.#exitArmedAt < EXIT_CONFIRM_MS) {
			this.requestExit(0);
			return;
		}
		this.#exitArmedAt = now;
		this.#notice("press Ctrl+C again to quit");
	}

	requestExit(code: number): void {
		this.stop();
		this.#onExit?.(code);
	}

	// -- submit -------------------------------------------------------------

	async submit(value: string): Promise<void> {
		const prompt = value.trim();
		if (prompt.length === 0) return;
		const theme = getTheme();
		this.#append(new Text(`${theme.fg("userPrefix", `${theme.cursor} `)}${prompt}`, 1, 0));
		this.#exitArmedAt = 0;

		try {
			const result = await this.methods.chatSend({ sessionKey: this.#sessionKey, prompt });
			if (result?.runId) {
				this.#activeRunId = result.runId;
				this.#ensureRun(result.runId);
				this.#renderStatus();
			}
		} catch (error) {
			this.#notice(`send failed: ${describeError(error)}`);
		}
	}

	// -- client events ------------------------------------------------------

	#wireClient(): void {
		const on = <K extends Parameters<typeof this.client.events.on>[0]>(
			event: K,
			listener: (payload: any) => void,
		) => {
			this.#disposers.push(this.client.events.on(event, listener));
		};

		on("state", () => {
			this.#renderConnection();
		});
		on("queued", () => {
			this.#renderConnection();
		});
		on("queue-flushed", () => {
			this.#renderConnection();
		});
		on(
			"hello-ok",
			({ hello, resumed }: { hello: { server: { version?: string } }; resumed: boolean }) => {
				if (resumed) this.#notice("reconnected");
				else this.#notice(`connected to lemon ${hello.server?.version ?? "?"}`);
			},
		);
		on("chat", (event: ChatEvent) => this.#onChatEvent(event));
		on("agent", (event: AgentEvent) => this.#onAgentEvent(event));
		on("exec.approval.requested", (event: ApprovalRequestedEvent) => {
			if (!this.#belongsToSession(event.sessionKey)) return;
			this.#pendingApprovals += 1;
			this.#notice(
				`approval requested for ${event.tool ?? "a tool"} (${event.approvalId}) — approvals arrive in P4`,
			);
			this.#renderStatus();
		});
		on("exec.approval.resolved", () => {
			this.#pendingApprovals = Math.max(0, this.#pendingApprovals - 1);
			this.#renderStatus();
		});
		on("shutdown", () => {
			this.#notice("daemon is shutting down");
		});
	}

	#belongsToSession(sessionKey: string | null | undefined): boolean {
		return !sessionKey || sessionKey === this.#sessionKey;
	}

	#onChatEvent(event: ChatEvent): void {
		if (event?.type !== "delta") return;
		const delta = event as ChatDeltaEvent;
		if (!this.#belongsToSession(delta.sessionKey)) return;
		if (!acceptDeltaSeq(this.#deltaSeqs, delta.runId, delta.seq)) return;
		const run = this.#ensureRun(delta.runId);
		if (run.finalized) return;
		run.buffer += delta.text ?? "";
		run.component.setText(run.buffer);
		this.tui.requestRender();
	}

	#onAgentEvent(event: AgentEvent): void {
		if (!this.#belongsToSession(event.sessionKey)) return;
		switch (event.type) {
			case "started": {
				const started = event as AgentStartedEvent;
				this.#activeRunId = started.runId;
				this.#activity = started.engine ? `${started.engine} working…` : "working…";
				this.#ensureRun(started.runId);
				this.#renderStatus();
				return;
			}
			case "tool_use": {
				const tool = event as AgentToolUseEvent;
				if (tool.phase === "completed") this.#activity = "working…";
				else this.#activity = tool.action?.title ?? "working…";
				this.#renderStatus();
				return;
			}
			case "completed": {
				this.#finalizeRun(event as AgentCompletedEvent);
				return;
			}
			default:
				return;
		}
	}

	#ensureRun(runId: string): RunView {
		let run = this.#runs.get(runId);
		if (!run) {
			const component = new Markdown("", 1, 0, getMarkdownTheme());
			run = { runId, buffer: "", component, finalized: false };
			this.#runs.set(runId, run);
			this.#append(component);
		}
		return run;
	}

	#finalizeRun(event: AgentCompletedEvent): void {
		const run = this.#runs.get(event.runId);
		if (run && !run.finalized) {
			// The delta buffer wins: `answer` is truncated to 500 bytes server-side.
			const finalText = run.buffer.length > 0 ? run.buffer : (event.answer ?? "");
			run.buffer = finalText;
			run.component.setText(finalText);
			run.finalized = true;
			if (event.ok === false) {
				this.#notice(`run ${event.runId} failed${event.answer ? `: ${event.answer}` : ""}`);
			}
		}
		if (this.#activeRunId === event.runId) {
			this.#activeRunId = undefined;
			this.#activity = undefined;
		}
		this.#renderStatus();
	}
}

function describeError(error: unknown): string {
	if (error instanceof Error) return error.message;
	return String(error);
}
