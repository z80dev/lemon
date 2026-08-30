/**
 * Content-free portable blueprint catalog and activation UX.
 *
 * The daemon owns catalog resolution, validation, profile boundaries, preview
 * digests, and create-once activation. This module retains only bounded IDs,
 * counts, actions, booleans, and digests. Manifest prose, prompts, skill text,
 * schedules, paths, commands, environment values, and server error details are
 * deliberately discarded before anything reaches TUI state or rendering.
 */

import { ControlPlaneError } from "../protocol/errors.ts";
import { METHOD } from "../protocol/methods.ts";
import type {
	BlueprintActivationResult,
	BlueprintInspectResult,
	BlueprintPreviewResult,
	BlueprintsListResult,
} from "../protocol/types.ts";
import type { CommandContext, PickerChoice, SlashCommand } from "./registry.ts";

const ID_RE = /^[a-z0-9][a-z0-9_-]{0,63}$/;
const DIGEST_RE = /^[a-f0-9]{64}$/;
const MAX_BUNDLES = 64;
const MAX_SKILLS = 16;
const SKILL_ACTIONS = new Set(["create", "create_enable", "enable", "unchanged", "collision"]);
const AUTOMATION_ACTIONS = new Set(["create", "unchanged", "collision"]);
const ACTIVATION_SKILL_STATUSES = new Set(["created", "enabled", "unchanged"]);
const ACTIVATION_STATUSES = new Set(["created", "unchanged"]);

interface SafeCatalogEntry {
	id: string;
	skillCount: number;
	automationCount: number;
}

interface SafeInspection extends SafeCatalogEntry {
	valid?: boolean;
	auditStatus?: "pass";
	trustLevel?: "untrusted";
}

interface SafeSkillPlan {
	key: string;
	action: string;
	fileCount: number;
	bytes: number;
}

interface SafePreview {
	bundleId: string;
	profileId: string;
	confirmationDigest: string;
	canActivate: boolean;
	skills: SafeSkillPlan[];
	automation: { id: string; action: string; enabled: boolean };
}

interface BlueprintCommandState {
	selectedBundleId?: string;
	profileDraft?: string;
	preview?: SafePreview;
}

interface TargetArgs {
	bundleId: string;
	profileId: string;
	confirmationDigest?: string;
}

class UnsafeBlueprintReply extends Error {
	readonly code = "UNSAFE_RESPONSE";
}

const stateByClient = new WeakMap<object, BlueprintCommandState>();

export const blueprintsCommand: SlashCommand = {
	name: "blueprints",
	summary: "browse portable automation blueprints",
	usage: "[bundle-id filter]",
	group: "configuration",
	methods: [METHOD.blueprintsList],
	async run(ctx, argv) {
		await safely(ctx, "list", async () => openBlueprintPicker(ctx, argv.join(" ").trim()));
	},
};

export const blueprintCommand: SlashCommand = {
	name: "blueprint",
	summary: "inspect, validate, preview, or activate a portable blueprint",
	usage: "[help|list|inspect|validate|preview|activate] …",
	group: "configuration",
	methods: [METHOD.blueprintsList],
	async run(ctx, argv) {
		const action = (argv[0] ?? "list").toLowerCase();
		if (action === "help") {
			renderHelp(ctx);
			return;
		}

		await safely(ctx, action, async () => {
			switch (action) {
				case "list":
					await openBlueprintPicker(ctx, argv.slice(1).join(" ").trim());
					return;
				case "inspect":
					await inspectBlueprint(ctx, argv[1]);
					return;
				case "validate":
					await validateBlueprint(ctx, argv[1]);
					return;
				case "preview":
					await previewBlueprint(ctx, argv.slice(1));
					return;
				case "activate":
					await activateBlueprint(ctx, argv.slice(1));
					return;
				default:
					ctx.ui.notice(`usage: /blueprint ${blueprintCommand.usage}`, "error");
			}
		});
	},
};

async function openBlueprintPicker(ctx: CommandContext, query: string): Promise<void> {
	requireMethod(ctx, METHOD.blueprintsList);
	const catalog = sanitizeCatalog(await ctx.methods.blueprintsList());
	const needle = query.toLowerCase();
	const matches = needle ? catalog.filter((entry) => entry.id.includes(needle)) : catalog;
	if (matches.length === 0) {
		ctx.ui.notice(
			needle ? "no blueprint IDs match that filter" : "no portable blueprints available",
		);
		return;
	}

	const items: PickerChoice[] = matches.map((entry) => ({
		value: entry.id,
		label: entry.id,
		description: `${entry.skillCount} skill${entry.skillCount === 1 ? "" : "s"} · ${entry.automationCount} automation${entry.automationCount === 1 ? "" : "s"}`,
	}));

	ctx.ui.openPicker({
		title: `automation blueprints · ${items.length}`,
		items,
		footer: "type to filter IDs · enter inspects content-free metadata · esc cancels",
		onSelect: async (choice) => {
			await safely(ctx, "inspect", async () => inspectBlueprint(ctx, choice.value));
		},
	});
}

async function inspectBlueprint(
	ctx: CommandContext,
	requestedId: string | undefined,
): Promise<void> {
	requireMethod(ctx, METHOD.blueprintsInspect);
	const state = commandState(ctx);
	const bundleId = requireId(requestedId ?? state.selectedBundleId, "bundle");
	const inspected = sanitizeInspection(await ctx.methods.blueprintsInspect({ bundleId }), bundleId);
	state.selectedBundleId = bundleId;
	state.preview = undefined;
	renderInspection(ctx, inspected, "inspected");
}

async function validateBlueprint(
	ctx: CommandContext,
	requestedId: string | undefined,
): Promise<void> {
	requireMethod(ctx, METHOD.blueprintsValidate);
	const state = commandState(ctx);
	const bundleId = requireId(requestedId ?? state.selectedBundleId, "bundle");
	const validated = sanitizeInspection(
		await ctx.methods.blueprintsValidate({ bundleId }),
		bundleId,
		true,
	);
	state.selectedBundleId = bundleId;
	state.preview = undefined;
	renderInspection(ctx, validated, "validated");
}

async function previewBlueprint(ctx: CommandContext, argv: string[]): Promise<void> {
	requireMethod(ctx, METHOD.blueprintsPreview);
	const state = commandState(ctx);
	const target = parseTargetArgs(argv, state, false);
	state.selectedBundleId = target.bundleId;
	state.profileDraft = target.profileId;
	state.preview = undefined;

	const preview = sanitizePreview(
		await ctx.methods.blueprintsPreview({
			bundleId: target.bundleId,
			profileId: target.profileId,
		}),
		target.bundleId,
		target.profileId,
	);
	state.preview = preview;
	renderPreview(ctx, preview);
}

async function activateBlueprint(ctx: CommandContext, argv: string[]): Promise<void> {
	requireMethod(ctx, METHOD.blueprintsPreview);
	requireMethod(ctx, METHOD.blueprintsActivate);
	const state = commandState(ctx);
	const target = parseTargetArgs(argv, state, true);
	state.selectedBundleId = target.bundleId;
	state.profileDraft = target.profileId;
	state.preview = undefined;

	if (!target.confirmationDigest || !DIGEST_RE.test(target.confirmationDigest)) {
		ctx.ui.notice(
			"activation requires the exact 64-character digest from a fresh preview · profile draft kept",
			"warning",
		);
		return;
	}

	// Always re-read destination and catalog state before mutation. The daemon
	// performs the same comparison under its activation lock.
	const fresh = sanitizePreview(
		await ctx.methods.blueprintsPreview({
			bundleId: target.bundleId,
			profileId: target.profileId,
		}),
		target.bundleId,
		target.profileId,
	);

	if (fresh.confirmationDigest !== target.confirmationDigest) {
		ctx.ui.notice(
			"activation refused: the exact plan changed or the digest is incorrect · nothing changed · profile draft kept",
			"warning",
		);
		return;
	}
	if (!fresh.canActivate) {
		ctx.ui.notice(
			"activation refused: the destination has a collision · nothing changed · profile draft kept",
			"warning",
		);
		return;
	}

	try {
		const activated = sanitizeActivation(
			await ctx.methods.blueprintsActivate({
				bundleId: target.bundleId,
				profileId: target.profileId,
				confirmationDigest: target.confirmationDigest,
			}),
			target.bundleId,
			target.profileId,
		);
		state.preview = undefined;
		ctx.ui.noticeBlock([
			`blueprint ${activated.bundleId} · profile ${activated.profileId}`,
			`activation ${activated.automationStatus} · ${activated.skillCount} skill action${activated.skillCount === 1 ? "" : "s"}`,
			activated.automationStatus === "unchanged"
				? "identical blueprint already active · no duplicate created"
				: "activation committed through the profile and scheduler services",
		]);
	} catch (error) {
		state.preview = undefined;
		throw error;
	}
}

function renderInspection(ctx: CommandContext, result: SafeInspection, verb: string): void {
	const lines = [
		`blueprint ${result.id} · ${verb}`,
		`${result.skillCount} skill${result.skillCount === 1 ? "" : "s"} · ${result.automationCount} automation${result.automationCount === 1 ? "" : "s"}`,
	];
	if (result.valid === true) {
		lines.push(`validation pass · audit ${result.auditStatus} · trust ${result.trustLevel}`);
	}
	lines.push("content, schedules, paths, commands, environment values, and secrets omitted");
	ctx.ui.noticeBlock(lines);
}

function renderPreview(ctx: CommandContext, preview: SafePreview): void {
	const skillActions = countActions(preview.skills.map((skill) => skill.action));
	ctx.ui.noticeBlock([
		`blueprint ${preview.bundleId} · profile ${preview.profileId}`,
		`preview only · ${preview.canActivate ? "ready" : "collision"} · nothing changed`,
		`${preview.skills.length} skill action${preview.skills.length === 1 ? "" : "s"}${skillActions ? ` (${skillActions})` : ""}`,
		`automation ${preview.automation.id} · ${preview.automation.action} · ${preview.automation.enabled ? "enabled" : "disabled"}`,
		`confirmation digest: ${preview.confirmationDigest}`,
		`activate with /blueprint activate ${preview.bundleId} --profile ${preview.profileId} --confirm ${preview.confirmationDigest}`,
	]);
}

function renderHelp(ctx: CommandContext): void {
	ctx.ui.noticeBlock([
		"blueprint commands",
		"/blueprints [bundle-id filter] — browse the bounded catalog",
		"/blueprint inspect [bundle-id]",
		"/blueprint validate [bundle-id]",
		"/blueprint preview [bundle-id] --profile <profile-id>",
		"/blueprint activate [bundle-id] [--profile <profile-id>] --confirm <exact-digest>",
		"preview is non-mutating; activation re-previews and requires an exact fresh digest",
		"only bounded IDs, counts, actions, booleans, and digests are retained or rendered",
	]);
}

function parseTargetArgs(
	argv: string[],
	state: BlueprintCommandState,
	withConfirmation: boolean,
): TargetArgs {
	let bundleId: string | undefined;
	let profileId: string | undefined;
	let confirmationDigest: string | undefined;

	for (let index = 0; index < argv.length; index += 1) {
		const value = argv[index]!;
		if (!value.startsWith("--") && bundleId === undefined) {
			bundleId = value;
			continue;
		}
		if (value.startsWith("--profile=")) {
			profileId = value.slice("--profile=".length);
			continue;
		}
		if (value === "--profile") {
			profileId = argv[++index];
			continue;
		}
		if (withConfirmation && value.startsWith("--confirm=")) {
			confirmationDigest = value.slice("--confirm=".length).toLowerCase();
			continue;
		}
		if (withConfirmation && value === "--confirm") {
			confirmationDigest = argv[++index]?.toLowerCase();
			continue;
		}
		throw new UnsafeBlueprintReply();
	}

	return {
		bundleId: requireId(bundleId ?? state.selectedBundleId, "bundle"),
		profileId: requireId(profileId ?? state.profileDraft, "profile"),
		...(confirmationDigest ? { confirmationDigest } : {}),
	};
}

function sanitizeCatalog(payload: BlueprintsListResult): SafeCatalogEntry[] {
	if (!Array.isArray(payload.bundles)) throw new UnsafeBlueprintReply();
	const safe: SafeCatalogEntry[] = [];
	for (const raw of payload.bundles.slice(0, MAX_BUNDLES)) {
		try {
			safe.push(sanitizeCatalogEntry(raw));
		} catch {
			// Invalid entries are unavailable, not renderable error content.
		}
	}
	return safe;
}

function sanitizeCatalogEntry(payload: BlueprintInspectResult): SafeCatalogEntry {
	const id = requireId(payload.id, "bundle");
	const skills = requireArray(payload.skills, MAX_SKILLS);
	const automations = requireArray(payload.automations, 1);
	for (const skill of skills) requireId(asRecord(skill)?.key, "skill");
	for (const automation of automations) requireId(asRecord(automation)?.id, "automation");
	return { id, skillCount: skills.length, automationCount: automations.length };
}

function sanitizeInspection(
	payload: BlueprintInspectResult,
	expectedId: string,
	validated = false,
): SafeInspection {
	const result = sanitizeCatalogEntry(payload);
	if (result.id !== expectedId) throw new UnsafeBlueprintReply();
	if (!validated) return result;
	const validation = asRecord(payload.validation);
	if (
		validation?.valid !== true ||
		validation.auditStatus !== "pass" ||
		validation.trustLevel !== "untrusted"
	) {
		throw new UnsafeBlueprintReply();
	}
	return { ...result, valid: true, auditStatus: "pass", trustLevel: "untrusted" };
}

function sanitizePreview(
	payload: BlueprintPreviewResult,
	expectedBundleId: string,
	expectedProfileId: string,
): SafePreview {
	if (payload.bundleId !== expectedBundleId || payload.profile?.id !== expectedProfileId) {
		throw new UnsafeBlueprintReply();
	}
	const digest = requireDigest(payload.confirmationDigest);
	const skills = requireArray(payload.skills, MAX_SKILLS).map((raw) => {
		const skill = asRecord(raw);
		const key = requireId(skill?.key, "skill");
		const action = requireEnum(skill?.action, SKILL_ACTIONS);
		return {
			key,
			action,
			fileCount: safeCount(skill?.fileCount),
			bytes: safeCount(skill?.bytes),
		};
	});
	const automation = asRecord(payload.automation);
	if (!automation) throw new UnsafeBlueprintReply();
	return {
		bundleId: expectedBundleId,
		profileId: expectedProfileId,
		confirmationDigest: digest,
		canActivate: payload.canActivate === true,
		skills,
		automation: {
			id: requireId(automation.id, "automation"),
			action: requireEnum(automation.action, AUTOMATION_ACTIONS),
			enabled: automation.enabled === true,
		},
	};
}

function sanitizeActivation(
	payload: BlueprintActivationResult,
	expectedBundleId: string,
	expectedProfileId: string,
): { bundleId: string; profileId: string; automationStatus: string; skillCount: number } {
	if (
		payload.activated !== true ||
		payload.bundleId !== expectedBundleId ||
		payload.profileId !== expectedProfileId
	) {
		throw new UnsafeBlueprintReply();
	}
	const skills = requireArray(payload.skills, MAX_SKILLS);
	for (const raw of skills) {
		const skill = asRecord(raw);
		requireId(skill?.key, "skill");
		requireEnum(skill?.status, ACTIVATION_SKILL_STATUSES);
	}
	const automation = asRecord(payload.automation);
	if (!automation) throw new UnsafeBlueprintReply();
	return {
		bundleId: expectedBundleId,
		profileId: expectedProfileId,
		automationStatus: requireEnum(automation.status, ACTIVATION_STATUSES),
		skillCount: skills.length,
	};
}

function commandState(ctx: CommandContext): BlueprintCommandState {
	let state = stateByClient.get(ctx.client);
	if (!state) {
		state = {};
		stateByClient.set(ctx.client, state);
	}
	return state;
}

function requireMethod(ctx: CommandContext, method: string): void {
	if (!ctx.methods.supports(method)) throw new UnsafeBlueprintReply();
}

function requireId(value: unknown, _kind: string): string {
	if (typeof value !== "string" || !ID_RE.test(value)) throw new UnsafeBlueprintReply();
	return value;
}

function requireDigest(value: unknown): string {
	if (typeof value !== "string" || !DIGEST_RE.test(value)) throw new UnsafeBlueprintReply();
	return value;
}

function requireEnum(value: unknown, allowed: Set<string>): string {
	if (typeof value !== "string" || !allowed.has(value)) throw new UnsafeBlueprintReply();
	return value;
}

function requireArray(value: unknown, max: number): unknown[] {
	if (!Array.isArray(value) || value.length > max) throw new UnsafeBlueprintReply();
	return value;
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
	return typeof value === "object" && value !== null && !Array.isArray(value)
		? (value as Record<string, unknown>)
		: undefined;
}

function safeCount(value: unknown): number {
	return Number.isSafeInteger(value) && (value as number) >= 0
		? Math.min(value as number, 1_000_000)
		: 0;
}

function countActions(actions: string[]): string {
	const counts = new Map<string, number>();
	for (const action of actions) counts.set(action, (counts.get(action) ?? 0) + 1);
	return [...counts.entries()]
		.sort(([left], [right]) => left.localeCompare(right))
		.map(([action, count]) => `${count} ${action}`)
		.join(" · ");
}

async function safely(
	ctx: CommandContext,
	operation: string,
	work: () => Promise<void>,
): Promise<void> {
	try {
		await work();
	} catch (error) {
		if (operation === "activate") commandState(ctx).preview = undefined;
		ctx.ui.notice(safeFailure(operation, error), "error");
	}
}

function safeFailure(operation: string, error: unknown): string {
	const code =
		error instanceof ControlPlaneError
			? error.code
			: typeof error === "object" && error !== null && "code" in error
				? String((error as { code?: unknown }).code ?? "")
				: "";
	if (code === "NOT_FOUND") return "blueprint is no longer available";
	if (code === "CONFLICT" && operation === "activate") {
		return "activation refused: the exact plan changed or collided · nothing changed · profile draft kept";
	}
	if (code === "INVALID_REQUEST" || code === "INVALID_PARAMS" || code === "UNSAFE_RESPONSE") {
		return operation === "activate"
			? "activation request was refused · nothing changed · profile draft kept"
			: "blueprint request was refused; use bounded bundle and profile IDs";
	}
	if (
		code === "NOT_CONNECTED" ||
		code === "METHOD_UNAVAILABLE" ||
		code === "REQUEST_TIMEOUT" ||
		code === "TIMEOUT" ||
		code === "UNAVAILABLE"
	) {
		return operation === "activate"
			? "blueprint service is unavailable · nothing changed · profile draft kept"
			: "blueprint service is unavailable";
	}
	return operation === "activate"
		? "activation was refused · nothing changed · profile draft kept"
		: "blueprint operation failed safely";
}
