/**
 * Session-scoped routing overrides: model, reasoning effort, and tools.
 *
 * All three are one `sessions.patch` away — the daemon accepts `model`,
 * `thinkingLevel`, and `toolPolicy` on a session and its router reads them per
 * run. The local `SessionStore` mirrors what we set so the status bar can show
 * it without a round-trip.
 */

import { METHOD } from "../protocol/methods.ts";
import type { ModelsListResult } from "../protocol/types.ts";
import { asArray, pickBoolean, pickNumber, pickString } from "./format.ts";
import type { CommandContext, SlashCommand } from "./registry.ts";

/** `LemonCore.Config.parse_thinking_level/1`. */
export const THINKING_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh"] as const;

/** `LemonCore.Config.parse_tool_policy/1` profiles. */
export const TOOL_POLICY_PROFILES = [
	"full_access",
	"minimal_core",
	"read_only",
	"safe_mode",
	"subagent_restricted",
	"no_external",
	"custom",
] as const;

export interface ModelEntry {
	id: string;
	provider: string;
	name: string;
	contextWindow?: number;
	maxOutput?: number;
	supportsThinking: boolean;
	supportsVision: boolean;
}

/** Normalize one `models.list` row; rows without an id are dropped. */
export function toModelEntry(raw: unknown): ModelEntry | undefined {
	const id = pickString(raw, "id");
	if (!id) return undefined;
	return {
		id,
		provider: pickString(raw, "provider") ?? "unknown",
		name: pickString(raw, "name") ?? id,
		contextWindow: pickNumber(raw, "contextWindow"),
		maxOutput: pickNumber(raw, "maxOutput"),
		supportsThinking: pickBoolean(raw, "supportsThinking") ?? false,
		supportsVision: pickBoolean(raw, "supportsVision") ?? false,
	};
}

export function toModelEntries(result: ModelsListResult | undefined): ModelEntry[] {
	return asArray(result?.models)
		.map((row) => toModelEntry(row))
		.filter((entry): entry is ModelEntry => entry !== undefined);
}

/** Model cache age past which the picker refetches. */
export const MODELS_CACHE_TTL_MS = 60_000;

/**
 * The models cache, refreshed when stale. Failures leave whatever was cached
 * in place: a picker with slightly old entries beats no picker.
 */
export async function ensureModels(
	ctx: Pick<CommandContext, "store" | "methods">,
	nowMs = Date.now(),
): Promise<ModelEntry[]> {
	const cached = ctx.store.models ?? [];
	const fresh = nowMs - ctx.store.modelsFetchedAtMs < MODELS_CACHE_TTL_MS;
	if (cached.length > 0 && fresh) return toModelEntries({ models: cached });
	if (!ctx.methods.supports(METHOD.modelsList)) return toModelEntries({ models: cached });
	try {
		const result = await ctx.methods.modelsList();
		const models = asArray(result?.models) as Array<Record<string, unknown>>;
		if (models.length > 0) {
			ctx.store.models = models;
			ctx.store.modelsFetchedAtMs = nowMs;
		}
		return toModelEntries(result);
	} catch {
		return toModelEntries({ models: cached });
	}
}

/**
 * Context window for a model id, out of the cached `models.list` rows.
 *
 * Ids reach us both bare and provider-prefixed, and the catalog only lists them bare, so a
 * `provider:id` is matched on its tail too. Undefined when the catalog has never heard of it —
 * the caller must then draw no gauge rather than invent a denominator.
 */
export function contextWindowFromCache(
	models: ModelsListResult["models"] | undefined,
	model: string | undefined,
): number | undefined {
	if (!model) return undefined;
	const bare = model.includes(":") ? model.slice(model.indexOf(":") + 1) : model;
	for (const entry of models ?? []) {
		const id = pickString(entry, "id");
		if (id === model || id === bare) {
			const window = pickNumber(entry, "contextWindow");
			if (window !== undefined) return window;
		}
	}
	return undefined;
}

/** Apply a model to the focused session and mirror it locally. */
export async function applyModel(ctx: CommandContext, modelId: string): Promise<void> {
	await ctx.methods.sessionsPatch({ sessionKey: ctx.session.key, model: modelId });
	// `local` holds until a run reports what the router actually resolved to — the
	// patch is a request, and the daemon's own precedence may still overrule it.
	ctx.session.setModel(
		{ model: modelId, contextWindow: contextWindowFromCache(ctx.store.models, modelId) },
		"local",
	);
	ctx.ui.refreshStatus();
	ctx.ui.notice(`model: ${modelId} (session ${ctx.session.key})`);
}

export const modelCommand: SlashCommand = {
	name: "model",
	summary: "show, pick or set the session model",
	usage: "[id]",
	group: "routing",
	methods: [METHOD.sessionsPatch],
	async run(ctx, argv) {
		const requested = argv[0];
		if (!requested) {
			if (ctx.ui.openModelPicker) {
				await ctx.ui.openModelPicker();
				return;
			}
			const entries = await ensureModels(ctx);
			if (entries.length === 0) {
				ctx.ui.notice(
					`model: ${ctx.session.model ?? "(daemon default)"} · no model list available`,
				);
				return;
			}
			ctx.ui.openPicker({
				title: "models",
				items: entries.map((entry) => ({
					value: entry.id,
					label: entry.id,
					description: describeModel(entry),
				})),
				footer: "enter applies to this session · esc cancels",
				onSelect: (choice) => applyModel(ctx, choice.value),
			});
			return;
		}
		const entries = await ensureModels(ctx);
		const exact = entries.find((entry) => entry.id === requested);
		const loose = exact ?? entries.find((entry) => entry.id.includes(requested));
		if (entries.length > 0 && !loose) {
			ctx.ui.notice(
				`no model matches "${requested}" — /model with no argument lists them`,
				"error",
			);
			return;
		}
		await applyModel(ctx, loose?.id ?? requested);
	},
};

export function describeModel(entry: ModelEntry): string {
	const parts = [entry.provider];
	if (entry.contextWindow) parts.push(`${Math.round(entry.contextWindow / 1000)}k ctx`);
	if (entry.supportsThinking) parts.push("thinking");
	if (entry.supportsVision) parts.push("vision");
	return parts.join(" · ");
}

export const thinkCommand: SlashCommand = {
	name: "think",
	aliases: ["reasoning"],
	summary: "set the reasoning effort for this session",
	usage: `<${THINKING_LEVELS.join("|")}>`,
	group: "routing",
	methods: [METHOD.sessionsPatch],
	async run(ctx, argv) {
		const requested = argv[0]?.toLowerCase();
		if (!requested) {
			ctx.ui.noticeBlock([
				`thinking: ${ctx.session.thinkingLevel ?? "(daemon default)"}`,
				`levels: ${THINKING_LEVELS.join(", ")}`,
			]);
			return;
		}
		const level = THINKING_LEVELS.find((candidate) => candidate === requested);
		if (!level) {
			ctx.ui.notice(`unknown level "${requested}" (${THINKING_LEVELS.join(", ")})`, "error");
			return;
		}
		await ctx.methods.sessionsPatch({ sessionKey: ctx.session.key, thinkingLevel: level });
		ctx.session.thinkingLevel = level;
		ctx.ui.refreshStatus();
		ctx.ui.notice(`thinking: ${level}`);
	},
};

export const toolPolicyCommand: SlashCommand = {
	name: "toolpolicy",
	aliases: ["tools"],
	summary: "set the tool-policy profile for this session",
	usage: `<${TOOL_POLICY_PROFILES.slice(0, 4).join("|")}|…>`,
	group: "routing",
	methods: [METHOD.sessionsPatch],
	async run(ctx, argv) {
		const requested = argv[0]?.toLowerCase();
		if (!requested) {
			ctx.ui.noticeBlock([
				`tool policy: ${ctx.session.toolPolicy ?? "(daemon default)"}`,
				`profiles: ${TOOL_POLICY_PROFILES.join(", ")}`,
			]);
			return;
		}
		const profile = TOOL_POLICY_PROFILES.find((candidate) => candidate === requested);
		if (!profile) {
			ctx.ui.notice(`unknown profile "${requested}" (${TOOL_POLICY_PROFILES.join(", ")})`, "error");
			return;
		}
		await ctx.methods.sessionsPatch({
			sessionKey: ctx.session.key,
			toolPolicy: { profile },
		});
		ctx.session.toolPolicy = profile;
		ctx.ui.refreshStatus();
		ctx.ui.notice(`tool policy: ${profile}`);
	},
};
