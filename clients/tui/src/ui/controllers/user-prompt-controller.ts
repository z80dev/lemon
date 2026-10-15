import type { Container, TUI } from "@oh-my-pi/pi-tui/tui";
import type { ControlPlaneClient } from "../../protocol/client.ts";
import type { ControlPlaneMethods } from "../../protocol/methods.ts";
import {
	parseUserPrompt,
	type UserPromptAnswer,
	type UserPromptRequested,
} from "../../protocol/user-prompt.ts";
import type { AppStore } from "../../store/app-store.ts";
import type { NoticeLevel } from "../../store/transcript-model.ts";
import { UserPromptPanel } from "../components/user-prompt-panel.ts";

export interface UserPromptControllerOptions {
	client: ControlPlaneClient;
	methods: ControlPlaneMethods;
	store: AppStore;
	tui: TUI;
	container: Container;
	focusEditor: () => void;
	notice: (text: string, level?: NoticeLevel) => void;
}

/** Mirrors approval request/resolve ownership, but never installs approval grants. */
export class UserPromptController {
	readonly panel: UserPromptPanel;
	readonly #options: UserPromptControllerOptions;
	readonly #pending = new Map<string, UserPromptRequested>();
	readonly #disposers: Array<() => void> = [];
	#mounted = false;

	constructor(options: UserPromptControllerOptions) {
		this.#options = options;
		this.panel = new UserPromptPanel(
			(event, answer) => {
				void this.resolve(event, answer);
			},
			() => options.tui.requestRender(),
		);
	}

	attach(): void {
		const { client, store } = this.#options;
		this.#disposers.push(
			client.events.on("session.prompt.requested", (raw) => {
				const event = parseUserPrompt(raw);
				if (!event) {
					this.#options.notice(
						"The daemon sent an invalid user question; no answer was selected.",
						"error",
					);
					return;
				}
				this.#pending.set(event.promptId, event);
				this.present();
			}),
			client.events.on("session.prompt.resolved", (event) => {
				const pending = this.#pending.get(event.promptId);
				if (!pending || pending.sessionKey !== event.sessionKey || pending.runId !== event.runId)
					return;
				this.#pending.delete(event.promptId);
				this.present();
			}),
			client.events.on("state", ({ state }) => {
				if (state === "online") return;
				this.#pending.clear();
				this.present();
			}),
			store.events.on("session-changed", () => this.present()),
		);
	}

	dispose(): void {
		for (const dispose of this.#disposers.splice(0)) dispose();
		this.#pending.clear();
		this.present();
	}

	present(): void {
		const { store, container, tui, focusEditor } = this.#options;
		const next = [...this.#pending.values()].find((event) => event.sessionKey === store.focusedKey);
		if (next) {
			this.panel.show(next);
			if (!this.#mounted) {
				this.#mounted = true;
				container.addChild(this.panel);
			}
			tui.setFocus(this.panel);
		} else if (this.#mounted) {
			const hadFocus = tui.getFocused() === this.panel;
			this.#mounted = false;
			container.clear();
			this.panel.hide();
			if (hadFocus) focusEditor();
		}
		tui.requestRender();
	}

	async resolve(event: UserPromptRequested, answer: UserPromptAnswer): Promise<void> {
		if (!this.#pending.has(event.promptId) || this.panel.busy) return;
		this.panel.busy = true;
		this.#options.tui.requestRender();
		try {
			await this.#options.methods.userPromptResolve({
				promptId: event.promptId,
				sessionKey: event.sessionKey,
				runId: event.runId,
				...answer,
			});
			this.#pending.delete(event.promptId);
		} catch (error) {
			this.#options.notice(
				`Question answer failed: ${error instanceof Error ? error.message : String(error)}. No answer was selected locally.`,
				"error",
			);
		} finally {
			this.panel.busy = false;
			this.present();
		}
	}
}
