/**
 * The Ctrl+O model picker: providers first, then that provider's models.
 *
 * Two stages because a daemon with several providers configured lists a few
 * hundred models, and "which provider" is the question the user actually has
 * first. Backspace on an empty filter (and Esc) steps back a stage rather than
 * closing, so the picker behaves like a directory listing.
 *
 * Enter applies the model to the focused session (`sessions.patch`). Ctrl+G
 * toggles "also make it the default", which is written to the TUI's own config
 * file — the daemon's `config.set` is a free-form key/value store its router
 * never reads, so persisting there would look like it worked and change
 * nothing.
 */

import { matchesKey } from "@oh-my-pi/pi-tui/keys";
import { describeModel, ensureModels, type ModelEntry } from "../../commands/model.ts";
import { saveConfigKey } from "../../config.ts";
import type { ControlPlaneMethods } from "../../protocol/methods.ts";
import type { AppStore } from "../../store/app-store.ts";
import type { SessionStore } from "../../store/session-store.ts";
import type { NoticeLevel } from "../../store/transcript-model.ts";
import { type PickerItem, PickerOverlay } from "./pickers.ts";

export interface ModelPickerHost {
	store: AppStore;
	methods: ControlPlaneMethods;
	session(): SessionStore;
	notice(text: string, level?: NoticeLevel): void;
	refreshStatus(): void;
	/** Shows the overlay and returns a closer. */
	present(overlay: PickerOverlay): () => void;
	/** Requests a repaint of the open overlay. */
	repaint(): void;
}

type Stage = "provider" | "model";

export class ModelPicker {
	readonly #host: ModelPickerHost;
	#overlay: PickerOverlay | undefined;
	#close: (() => void) | undefined;
	#entries: ModelEntry[] = [];
	#provider: string | undefined;
	#stage: Stage = "provider";
	#persistGlobally = false;

	constructor(host: ModelPickerHost) {
		this.#host = host;
	}

	get stage(): Stage {
		return this.#stage;
	}

	get persistGlobally(): boolean {
		return this.#persistGlobally;
	}

	/** Fetch (or reuse) the model list and open the provider stage. */
	async open(): Promise<void> {
		this.#entries = await ensureModels({ store: this.#host.store, methods: this.#host.methods });
		if (this.#entries.length === 0) {
			this.#host.notice("no models to choose from (models.list returned nothing)", "warning");
			return;
		}
		this.#persistGlobally = false;
		// A single provider makes the first stage a formality.
		const providers = this.#providers();
		if (providers.length === 1) {
			this.#provider = providers[0].value;
			this.#stage = "model";
		} else {
			this.#provider = undefined;
			this.#stage = "provider";
		}
		this.#overlay = new PickerOverlay({
			title: this.#title(),
			items: this.#stage === "provider" ? providers : this.#models(this.#provider),
			footer: this.#footer(),
			onSelect: (item) => void this.#onSelect(item),
			onCancel: () => this.#onCancel(),
			onKey: (data) => this.#onKey(data),
		});
		this.#close = this.#host.present(this.#overlay);
	}

	close(): void {
		this.#close?.();
		this.#close = undefined;
		this.#overlay = undefined;
	}

	#providers(): PickerItem[] {
		const counts = new Map<string, number>();
		for (const entry of this.#entries) {
			counts.set(entry.provider, (counts.get(entry.provider) ?? 0) + 1);
		}
		return [...counts.entries()]
			.sort((left, right) => left[0].localeCompare(right[0]))
			.map(([provider, count]) => ({
				value: provider,
				label: provider,
				description: `${count} model(s)`,
			}));
	}

	#models(provider: string | undefined): PickerItem[] {
		const current = this.#host.session().model;
		return this.#entries
			.filter((entry) => provider === undefined || entry.provider === provider)
			.map((entry) => ({
				value: entry.id,
				label: entry.id === current ? `${entry.id} (current)` : entry.id,
				description: describeModel(entry),
			}));
	}

	#title(): string {
		if (this.#stage === "provider") return "model — pick a provider";
		return `model — ${this.#provider ?? "all providers"}`;
	}

	#footer(): string {
		const persist = this.#persistGlobally ? "global+session" : "session only";
		return this.#stage === "provider"
			? "enter opens a provider · esc cancels"
			: `enter applies (${persist}) · ctrl+g toggles global · esc goes back`;
	}

	#onKey(data: string): boolean {
		if (matchesKey(data, "ctrl+g")) {
			this.#persistGlobally = !this.#persistGlobally;
			this.#rebuild();
			return true;
		}
		if (this.#stage === "model" && this.#overlay?.filter === "" && matchesKey(data, "backspace")) {
			if (this.#providers().length > 1) {
				this.#stage = "provider";
				this.#provider = undefined;
				this.#rebuild();
				return true;
			}
		}
		return false;
	}

	/** Rebuild the overlay in place so title/footer follow the stage. */
	#rebuild(): void {
		if (!this.#overlay) return;
		const filter = this.#overlay.filter;
		this.#close?.();
		this.#overlay = new PickerOverlay({
			title: this.#title(),
			items: this.#stage === "provider" ? this.#providers() : this.#models(this.#provider),
			filter,
			footer: this.#footer(),
			onSelect: (item) => void this.#onSelect(item),
			onCancel: () => this.#onCancel(),
			onKey: (data) => this.#onKey(data),
		});
		this.#close = this.#host.present(this.#overlay);
	}

	#onCancel(): void {
		if (this.#stage === "model" && this.#providers().length > 1) {
			this.#stage = "provider";
			this.#provider = undefined;
			this.#rebuild();
			return;
		}
		this.close();
	}

	async #onSelect(item: PickerItem): Promise<void> {
		if (this.#stage === "provider") {
			this.#provider = item.value;
			this.#stage = "model";
			this.#rebuild();
			return;
		}
		const modelId = item.value;
		this.close();
		const session = this.#host.session();
		try {
			await this.#host.methods.sessionsPatch({ sessionKey: session.key, model: modelId });
			session.model = modelId;
			this.#host.refreshStatus();
			this.#host.notice(`model: ${modelId} (session ${session.key})`);
		} catch (error) {
			this.#host.notice(
				`could not set model: ${error instanceof Error ? error.message : String(error)}`,
				"error",
			);
			return;
		}
		if (!this.#persistGlobally) return;
		const entry = this.#entries.find((candidate) => candidate.id === modelId);
		try {
			await saveConfigKey("agent", {
				default_model: modelId,
				default_provider: entry?.provider,
			});
			this.#host.notice(`default model: ${modelId}`);
		} catch (error) {
			this.#host.notice(
				`default not persisted: ${error instanceof Error ? error.message : String(error)}`,
				"warning",
			);
		}
	}
}
