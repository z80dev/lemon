import { hostname } from "node:os";
import { pathToFileURL } from "node:url";
import type { Terminal } from "@oh-my-pi/pi-tui/terminal";
import { TERMINAL } from "@oh-my-pi/pi-tui/terminal-capabilities";
import type { ControlPlaneClient } from "../protocol/client.ts";
import type { AppStore } from "../store/app-store.ts";
import { detectTerminalCapabilities, oscText, type TerminalCapabilities } from "./capabilities.ts";

/** Interactive-only side channels. Never sends prompts, answers, or tool arguments. */
export class TerminalIntegration {
	readonly capabilities: TerminalCapabilities;
	readonly #terminal: Terminal;
	readonly #store: AppStore;
	readonly #client: ControlPlaneClient;
	readonly #disposers: Array<() => void> = [];
	readonly #runs = new Set<string>();
	readonly #approvals = new Set<string>();
	readonly #questions = new Set<string>();
	readonly #outcomes = new Map<string, "done" | "error" | "idle">();
	readonly #cwd: string;
	readonly #beforeStatusChange: (() => void) | undefined;
	#updateQueued = false;
	#programStatus = "";
	#active = false;
	#title = "";
	#session = "";
	#status = "";
	#progress = false;
	#previousHyperlinks: boolean;

	constructor(
		terminal: Terminal,
		store: AppStore,
		client: ControlPlaneClient,
		cwd = process.cwd(),
		capabilities = detectTerminalCapabilities(),
		beforeStatusChange?: () => void,
	) {
		this.#terminal = terminal;
		this.#store = store;
		this.#client = client;
		this.capabilities = capabilities;
		this.#beforeStatusChange = beforeStatusChange;
		const directory = pathToFileURL(cwd);
		directory.hostname = hostname();
		this.#cwd = directory.href;
		this.#previousHyperlinks = TERMINAL.hyperlinks;
		if (this.capabilities.enabled) TERMINAL.hyperlinks = this.capabilities.hyperlinks;
	}

	start(): void {
		if (!this.capabilities.enabled || this.#disposers.length > 0) return;
		this.#disposers.push(
			this.#store.events.on("session-changed", () => this.update()),
			this.#store.events.on("conn-changed", () => this.update()),
			this.#store.events.on("blocks-changed", () => this.update()),
			this.#store.events.on("approvals-changed", () => {
				for (const id of this.#approvals) {
					if (!this.#store.approvals.has(id)) this.#approvals.delete(id);
				}
				for (const id of this.#store.approvals.keys()) {
					if (this.#approvals.has(id)) continue;
					this.#approvals.add(id);
					this.#notify("Approval needed", "A tool is waiting for your decision");
				}
				this.update();
			}),
			this.#store.events.on("prompts-changed", () => {
				for (const id of this.#questions) {
					if (!this.#store.userPrompts.has(id)) this.#questions.delete(id);
				}
				for (const id of this.#store.userPrompts.keys()) {
					if (this.#questions.has(id)) continue;
					this.#questions.add(id);
					this.#notify("Question waiting", "Return to Lemon to answer");
				}
				this.update();
			}),
			this.#client.events.on("agent", (event) => {
				const session = event.sessionKey ?? this.#store.focusedKey;
				if (event.type === "started") {
					this.#runs.add(event.runId);
					this.#outcomes.delete(session);
				}
				if (event.type === "completed" && this.#runs.delete(event.runId)) {
					this.#outcomes.set(
						session,
						event.cancelled === true ? "idle" : event.ok === false ? "error" : "done",
					);
					this.#notify(
						event.cancelled === true
							? "Turn interrupted"
							: event.ok === false
								? "Turn failed"
								: "Turn complete",
						"Return to Lemon to continue",
					);
				}
				this.update();
			}),
		);
		this.resume();
	}

	/** Paired with TUI.stop(), including the external-editor handoff. */
	suspend(): void {
		if (!this.#active) return;
		this.#terminal.setProgress(false);
		this.#progress = false;
		this.#setUserVar("lemon_session", "");
		this.#setUserVar("lemon_status", "");
		if (this.capabilities.tern) this.#terminal.write("\x1b]7501;state=clear\x1b\\");
		this.#programStatus = "";
		// Clear stale status even on terminals (including Tern) that ignore the
		// title stack. Supporting terminals then restore the saved parent title.
		this.#terminal.setTitle("");
		this.#terminal.write("\x1b[23;0t");
		this.#active = false;
		this.#title = this.#session = this.#status = "";
	}

	resume(): void {
		if (!this.capabilities.enabled || this.#active) return;
		this.#active = true;
		this.#terminal.write("\x1b[22;0t");
		this.#terminal.write(`\x1b]7;${this.#cwd}\x07`);
		this.update();
	}

	/** Reassert status when a terminal reconnects to the existing PTY. */
	handleInput(data: string): { consume: true } | undefined {
		if (!this.capabilities.tern || (data !== "\x1b]7501;?\x07" && data !== "\x1b]7501;?\x1b\\"))
			return;
		this.#programStatus = "";
		this.update();
		return { consume: true };
	}

	update(): void {
		if (!this.#beforeStatusChange) {
			this.#updateNow();
			return;
		}
		if (!this.#active || this.#updateQueued) return;
		this.#updateQueued = true;
		// Store events may fire midway through finalizing a message. Wait until
		// its component has been sealed, then publish that frame before "idle".
		queueMicrotask(() => {
			this.#updateQueued = false;
			this.#updateNow();
		});
	}

	#updateNow(): void {
		if (!this.#active) return;
		const store = this.#store;
		for (const session of store.sessions.values()) {
			if (session.busy && session.activeRunId) this.#runs.add(session.activeRunId);
		}
		const status =
			store.pendingApprovals > 0
				? "approval needed"
				: store.userPrompts.size > 0
					? "question waiting"
					: store.connection !== "online"
						? store.connection
						: store.busySessions() > 0
							? "working"
							: "ready";
		if (status !== this.#status) this.#beforeStatusChange?.();
		const session = oscText(store.focusedKey);
		const name = oscText(store.focused.title ?? store.focusedKey);
		const title = `Lemon · ${name} · ${status}`;
		if (title !== this.#title) {
			this.#terminal.setTitle(title);
			this.#title = title;
		}
		if (session !== this.#session) {
			this.#setUserVar("lemon_session", session);
			this.#session = session;
		}
		if (status !== this.#status) {
			this.#setUserVar("lemon_status", status);
			this.#status = status;
		}
		if (this.capabilities.tern) {
			const state =
				status === "approval needed"
					? "blocked:kind=permission"
					: status === "question waiting"
						? "blocked:kind=question"
						: status === "working"
							? "working"
							: status === "ready"
								? (this.#outcomes.get(store.focusedKey) ?? "idle")
								: "idle";
			const programStatus = `state=${state}:app=lemon`;
			if (programStatus !== this.#programStatus) {
				this.#terminal.write(`\x1b]7501;${programStatus}\x1b\\`);
				this.#programStatus = programStatus;
			}
		}
		const progress = status === "working";
		if (progress !== this.#progress) {
			// pi-tui owns the keepalive and clears its timer on stop.
			this.#terminal.setProgress(progress);
			this.#progress = progress;
		}
	}

	stop(): void {
		this.suspend();
		for (const dispose of this.#disposers.splice(0)) dispose();
		this.#runs.clear();
		this.#approvals.clear();
		this.#questions.clear();
		this.#outcomes.clear();
		TERMINAL.hyperlinks = this.#previousHyperlinks;
	}

	#setUserVar(name: string, value: string): void {
		const encoded = Buffer.from(value).toString("base64");
		this.#terminal.write(`\x1b]1337;SetUserVar=${name}=${encoded}\x07`);
	}

	#notify(title: string, body: string): void {
		if (!this.#active) return;
		if (this.capabilities.notifications === "bell") {
			this.#terminal.write("\x07");
			return;
		}
		// Tern's program-status protocol already owns the inbox and banners.
		if (this.capabilities.tern) return;
		if (this.capabilities.notifications === "osc9") {
			this.#terminal.write(`\x1b]9;Lemon: ${title} — ${body}\x07`);
		} else if (this.capabilities.notifications === "osc777") {
			this.#terminal.write(`\x1b]777;notify;Lemon: ${title};${body}\x07`);
		}
	}
}
