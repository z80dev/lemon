/**
 * The Ctrl+O model picker: providers first, then that provider's models.
 *
 * Two stages because a daemon with several providers configured lists a few
 * hundred models, and "which provider" is the question the user actually has
 * first. Backspace on an empty filter (and Esc) steps back a stage rather than
 * closing, so the picker behaves like a directory listing.
 *
 * Enter applies the model to the focused session (`sessions.patch`). Ctrl+G
 * toggles "also make it the default", which sets `[defaults] provider` and
 * `model` in the daemon's `config.toml` — the keys `lemon setup provider
 * --set-default` writes — editing those keys in place. The daemon's
 * `config.set` is a free-form key/value store its router never reads, so
 * persisting there would look like it worked and change nothing.
 *
 * On a native (TSP) surface the picker is one stage: every model, grouped by
 * provider under the sheet's group headings, with the provider's mark, the
 * current model marked and the global toggle as an action-bar button.
 */

import { matchesKey } from "@oh-my-pi/pi-tui/keys";
import { CLOSE_ACTION, pickerAction } from "@oh-my-pi/pi-tui/native/picker";
import { isNativeRendering } from "@oh-my-pi/pi-tui/native/state";
import { describeModel, ensureModels, type ModelEntry } from "../../commands/model.ts";
import { saveDefaultModel } from "../../config.ts";
import type { ControlPlaneMethods } from "../../protocol/methods.ts";
import type { AppStore } from "../../store/app-store.ts";
import type { SessionStore } from "../../store/session-store.ts";
import type { NoticeLevel } from "../../store/transcript-model.ts";
import {
	confirmAction,
	type NativePickerItem,
	type PickerItem,
	PickerOverlay,
	type PickerSheet,
} from "./pickers.ts";

/** The context window as a sheet fact column, like omp's model picker. */
const MODEL_COLUMNS: PickerSheet["columns"] = [{ id: "ctx", head: "Ctx", format: "num" }];

/**
 * A provider's avatar on the sheet: Tern's logo for `provider:<id>`, else its
 * initials (`amazon-bedrock` → `AB`, `anthropic` → `An`). Same shape as omp's
 * `providerMark`, which lives in a module bound to omp's model catalogue.
 */
function providerMark(provider: string): NativePickerItem["mark"] {
	const words = provider.split(/[-_\s.]+/).filter((word) => word.length > 0);
	const first = words[0] ?? provider;
	const text =
		words.length >= 2
			? `${first.charAt(0)}${words[1]!.charAt(0)}`.toUpperCase()
			: `${first.charAt(0).toUpperCase()}${first.charAt(1)}`;
	return { text, seed: provider, icon: `provider:${provider}` };
}

/** The session's model is stored either as `provider:id` or as a bare id. */
function isCurrent(entry: ModelEntry, current: string | undefined): boolean {
	return entry.id === current || `${entry.provider}:${entry.id}` === current;
}

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
	/** One provider-grouped stage on a native sheet instead of provider → model. */
	#grouped = false;

	constructor(host: ModelPickerHost) {
		this.#host = host;
	}

	get stage(): Stage {
		return this.#stage;
	}

	get persistGlobally(): boolean {
		return this.#persistGlobally;
	}

	/** Cycle in models.list order, wrapping to the first entry. Session-only. */
	async cycle(): Promise<void> {
		const session = this.#host.session();
		try {
			const entries = await ensureModels({ store: this.#host.store, methods: this.#host.methods });
			if (entries.length === 0) {
				this.#host.notice("no models to choose from (models.list returned nothing)", "warning");
				return;
			}
			const index = entries.findIndex((entry) => isCurrent(entry, session.model));
			const next = entries[(index + 1) % entries.length]!;
			await this.#apply(`${next.provider}:${next.id}`, session, entries, false);
		} catch (error) {
			this.#host.notice(
				`could not cycle model: ${error instanceof Error ? error.message : String(error)}`,
				"error",
			);
		}
	}

	/** Fetch (or reuse) the model list and open the provider stage. */
	async open(): Promise<void> {
		this.#entries = await ensureModels({ store: this.#host.store, methods: this.#host.methods });
		if (this.#entries.length === 0) {
			this.#host.notice("no models to choose from (models.list returned nothing)", "warning");
			return;
		}
		this.#persistGlobally = false;
		this.#grouped = isNativeRendering();
		// A single provider makes the first stage a formality; the native sheet
		// shows every provider's models at once under group headings.
		const providers = this.#providers();
		if (this.#grouped) {
			this.#provider = undefined;
			this.#stage = "model";
		} else if (providers.length === 1) {
			this.#provider = providers[0].value;
			this.#stage = "model";
		} else {
			this.#provider = undefined;
			this.#stage = "provider";
		}
		this.#present("");
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
		const entries = this.#entries.filter(
			(entry) => provider === undefined || entry.provider === provider,
		);
		// Group headings need each provider's models to be contiguous.
		if (this.#grouped) entries.sort((left, right) => left.provider.localeCompare(right.provider));
		return entries.map((entry) => {
			const badges = [
				...(entry.supportsThinking ? [{ text: "thinking" }] : []),
				...(entry.supportsVision ? [{ text: "vision" }] : []),
			];
			return {
				value: `${entry.provider}:${entry.id}`,
				searchValue: entry.id,
				label: isCurrent(entry, current) ? `${entry.id} (current)` : entry.id,
				description: describeModel(entry),
				group: { id: entry.provider, label: entry.provider },
				native: {
					label: entry.id,
					detail: entry.name !== entry.id ? entry.name : undefined,
					mono: true,
					mark: providerMark(entry.provider),
					...(entry.contextWindow ? { facts: { ctx: entry.contextWindow } } : {}),
					...(badges.length > 0 ? { badges } : {}),
				},
			};
		});
	}

	#title(): string {
		if (this.#grouped) return "Switch model";
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
			this.#togglePersist();
			return true;
		}
		if (
			this.#stage === "model" &&
			!this.#grouped &&
			this.#overlay?.filter === "" &&
			matchesKey(data, "backspace")
		) {
			if (this.#providers().length > 1) {
				this.#stage = "provider";
				this.#provider = undefined;
				this.#rebuild("");
				return true;
			}
		}
		return false;
	}

	/** Ctrl+G and the sheet's "Make default" button. The list and selection stay. */
	#togglePersist(): void {
		this.#persistGlobally = !this.#persistGlobally;
		this.#overlay?.setFooter(this.#footer());
		this.#host.repaint();
	}

	/** Rebuild the overlay in place so title/footer follow the stage. */
	#rebuild(filter = this.#overlay?.filter ?? ""): void {
		if (!this.#overlay) return;
		this.#close?.();
		this.#present(filter);
	}

	#present(filter: string): void {
		const stage = this.#stage;
		this.#overlay = new PickerOverlay({
			title: this.#title(),
			items: stage === "provider" ? this.#providers() : this.#models(this.#provider),
			filter,
			footer: this.#footer(),
			onSelect: (item) => void this.#onSelect(item),
			onCancel: () => this.#onCancel(),
			onKey: (data) => this.#onKey(data),
			sheet: {
				icon: "cpu",
				noun: stage === "provider" ? "providers" : "models",
				placeholder: stage === "provider" ? "Search providers…" : "Search models…",
				...(stage === "model" ? { columns: MODEL_COLUMNS } : {}),
				empty: "No models match",
				current: () => {
					const current = this.#host.session().model;
					return this.#entries
						.filter((entry) => isCurrent(entry, current))
						.map((entry) => `${entry.provider}:${entry.id}`);
				},
				subtitle: () =>
					stage === "provider"
						? "Pick a provider"
						: this.#persistGlobally
							? "Applies to this session and saves it as the default model"
							: "Applies to this session only",
				actions: () =>
					stage === "provider"
						? [confirmAction("Open"), CLOSE_ACTION]
						: [
								confirmAction(this.#persistGlobally ? "Use and make default" : "Use for session"),
								pickerAction("global", "Make default", "ctrl+g", { on: this.#persistGlobally }),
								CLOSE_ACTION,
							],
				onAction: (act) => {
					if (act === "global") this.#togglePersist();
				},
			},
		});
		this.#close = this.#host.present(this.#overlay);
	}

	#onCancel(): void {
		if (this.#stage === "model" && !this.#grouped && this.#providers().length > 1) {
			this.#stage = "provider";
			this.#provider = undefined;
			this.#rebuild("");
			return;
		}
		this.close();
	}

	async #onSelect(item: PickerItem): Promise<void> {
		if (this.#stage === "provider") {
			this.#provider = item.value;
			this.#stage = "model";
			this.#rebuild("");
			return;
		}
		const modelId = item.value;
		this.close();
		await this.#apply(modelId, this.#host.session(), this.#entries, this.#persistGlobally);
	}

	async #apply(
		modelId: string,
		session: SessionStore,
		entries: ModelEntry[],
		persistGlobally: boolean,
	): Promise<void> {
		try {
			await this.#host.methods.sessionsPatch({ sessionKey: session.key, model: modelId });
			const entry = entries.find(
				(candidate) => `${candidate.provider}:${candidate.id}` === modelId,
			);
			session.setModel(
				{ model: modelId, provider: entry?.provider, contextWindow: entry?.contextWindow },
				"local",
			);
			this.#host.refreshStatus();
			this.#host.notice(`model: ${modelId} (session ${session.key})`);
		} catch (error) {
			this.#host.notice(
				`could not set model: ${error instanceof Error ? error.message : String(error)}`,
				"error",
			);
			return;
		}
		if (!persistGlobally) return;
		const entry = entries.find((candidate) => `${candidate.provider}:${candidate.id}` === modelId);
		const provider = entry?.provider ?? modelId.split(":", 1)[0]!;
		try {
			await saveDefaultModel(provider, modelId);
			this.#host.notice(`default model: ${modelId}`);
		} catch (error) {
			this.#host.notice(
				`default not persisted: ${error instanceof Error ? error.message : String(error)}`,
				"warning",
			);
		}
	}
}
