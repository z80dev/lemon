/**
 * Typed method wrappers.
 *
 * Every call is gated on `hello-ok.features.methods`: a daemon that does not
 * advertise a method gets a {@link MethodUnavailableError} locally instead of a
 * round-trip that would come back METHOD_NOT_FOUND. Before the handshake
 * completes nothing is known about the server's method set, so the gate is open
 * — which is what lets `chat.send` be typed into the editor and parked by the
 * client's offline queue before the daemon is up.
 *
 * Names are verbatim from `LemonControlPlane.Methods.*.name/0`.
 */

import type { ControlPlaneClient, RequestOptions } from "./client.ts";
import { MethodUnavailableError } from "./errors.ts";
import type {
	ApprovalResolveParams,
	BlueprintActivationResult,
	BlueprintInspectResult,
	BlueprintPreviewResult,
	BlueprintsListResult,
	ChatAbortParams,
	ChatAbortResult,
	ChatHistoryParams,
	ChatHistoryResult,
	ChatSendParams,
	ChatSendResult,
	ConfigGetParams,
	ConfigSetParams,
	GoalSetParams,
	HealthResult,
	LogsTailParams,
	ModelsListResult,
	ProfileChatParams,
	ProfileChatResult,
	ProfileCloneParams,
	ProfileCreateParams,
	ProfileDeleteResult,
	ProfileExportResult,
	ProfileResult,
	ProfilesListResult,
	ProfilesRosterResult,
	SessionDetailResult,
	SessionExportFormat,
	SessionSummary,
	SessionsDeleteResult,
	SessionsExportResult,
	SessionsListParams,
	SessionsListResult,
	SessionsMetadataPatchParams,
	SessionsMetadataPatchResult,
	SessionsPatchParams,
	SessionsPreviewResult,
	SessionsPruneParams,
	SessionsPruneResult,
	UsageStatusResult,
} from "./types.ts";

export const METHOD = {
	chatSend: "chat.send",
	chatAbort: "chat.abort",
	chatHistory: "chat.history",
	profilesList: "profiles.list",
	profilesGet: "profiles.get",
	profilesCreate: "profiles.create",
	profilesClone: "profiles.clone",
	profilesRename: "profiles.rename",
	profilesExport: "profiles.export",
	profilesDelete: "profiles.delete",
	profilesRoster: "profiles.roster",
	profileChat: "profile.chat",
	sessionsList: "sessions.list",
	sessionsPreview: "sessions.preview",
	sessionsActive: "sessions.active",
	sessionsActiveList: "sessions.active.list",
	sessionsPatch: "sessions.patch",
	sessionsMetadataPatch: "sessions.metadata.patch",
	sessionsExport: "sessions.export",
	sessionsPrune: "sessions.prune",
	sessionsReset: "sessions.reset",
	sessionsDelete: "sessions.delete",
	sessionsCompact: "sessions.compact",
	sessionHeartbeat: "sessions.heartbeat",
	sessionDetail: "session.detail",
	commandsCatalog: "commands.catalog",
	agentsList: "agents.list",
	backgroundStart: "background.start",
	backgroundList: "background.list",
	backgroundStatus: "background.status",
	backgroundResult: "background.result",
	backgroundCancel: "background.cancel",
	sessionBtw: "session.btw",
	modelsList: "models.list",
	approvalResolve: "exec.approval.resolve",
	approvalsGet: "exec.approvals.get",
	health: "health",
	status: "status",
	usageStatus: "usage.status",
	usageCost: "usage.cost",
	runsActiveList: "runs.active.list",
	runsRecentList: "runs.recent.list",
	tasksActiveList: "tasks.active.list",
	tasksRecentList: "tasks.recent.list",
	goalSet: "goal.set",
	goalStatus: "goal.status",
	goalPause: "goal.pause",
	goalResume: "goal.resume",
	goalClear: "goal.clear",
	logsTail: "logs.tail",
	configGet: "config.get",
	configSet: "config.set",
	skillsHermesCatalog: "skills.hermes.catalog",
	skillsInstall: "skills.install",
	blueprintsList: "blueprints.list",
	blueprintsInspect: "blueprints.inspect",
	blueprintsValidate: "blueprints.validate",
	blueprintsPreview: "blueprints.preview",
	blueprintsActivate: "blueprints.activate",
} as const;

export type MethodName = (typeof METHOD)[keyof typeof METHOD];

/** Skill mutations may wait for a human approval and then fetch from Git. */
export const SKILL_MUTATION_REQUEST_TIMEOUT_MS = 360_000;

export class ControlPlaneMethods {
	readonly #client: ControlPlaneClient;

	constructor(client: ControlPlaneClient) {
		this.#client = client;
	}

	get client(): ControlPlaneClient {
		return this.#client;
	}

	/** True when the daemon advertises `method` (or the handshake has not run). */
	supports(method: MethodName | string): boolean {
		return this.#client.supports(method);
	}

	#call<T>(method: MethodName, params?: unknown, options?: RequestOptions): Promise<T> {
		if (!this.#client.supports(method)) {
			return Promise.reject(new MethodUnavailableError(method));
		}
		return this.#client.request<T>(method, params, options);
	}

	// -- chat ---------------------------------------------------------------

	chatSend(params: ChatSendParams, options?: RequestOptions): Promise<ChatSendResult> {
		return this.#call<ChatSendResult>(METHOD.chatSend, params, options);
	}

	chatAbort(params: ChatAbortParams, options?: RequestOptions): Promise<ChatAbortResult> {
		return this.#call<ChatAbortResult>(METHOD.chatAbort, params, options);
	}

	chatHistory(params: ChatHistoryParams, options?: RequestOptions): Promise<ChatHistoryResult> {
		return this.#call<ChatHistoryResult>(
			METHOD.chatHistory,
			{ includeFullText: true, ...params },
			options,
		);
	}

	// -- profiles -----------------------------------------------------------

	profilesList(options?: RequestOptions): Promise<ProfilesListResult> {
		return this.#call<ProfilesListResult>(METHOD.profilesList, {}, options);
	}

	profilesGet(params: { id: string }, options?: RequestOptions): Promise<ProfileResult> {
		return this.#call<ProfileResult>(METHOD.profilesGet, params, options);
	}

	profilesCreate(params: ProfileCreateParams, options?: RequestOptions): Promise<ProfileResult> {
		return this.#call<ProfileResult>(METHOD.profilesCreate, params, options);
	}

	profilesClone(params: ProfileCloneParams, options?: RequestOptions): Promise<ProfileResult> {
		return this.#call<ProfileResult>(METHOD.profilesClone, params, options);
	}

	profilesRename(
		params: { id: string; name: string },
		options?: RequestOptions,
	): Promise<ProfileResult> {
		return this.#call<ProfileResult>(METHOD.profilesRename, params, options);
	}

	profilesExport(
		params: { id: string; path: string; force?: boolean },
		options?: RequestOptions,
	): Promise<ProfileExportResult> {
		return this.#call<ProfileExportResult>(METHOD.profilesExport, params, options);
	}

	profilesDelete(
		params: { id: string; confirm: string },
		options?: RequestOptions,
	): Promise<ProfileDeleteResult> {
		return this.#call<ProfileDeleteResult>(METHOD.profilesDelete, params, options);
	}

	profilesRoster(options?: RequestOptions): Promise<ProfilesRosterResult> {
		return this.#call<ProfilesRosterResult>(METHOD.profilesRoster, {}, options);
	}

	profileChat(params: ProfileChatParams, options?: RequestOptions): Promise<ProfileChatResult> {
		return this.#call<ProfileChatResult>(METHOD.profileChat, params, options);
	}

	// -- sessions -----------------------------------------------------------

	sessionsList(params?: SessionsListParams, options?: RequestOptions): Promise<SessionsListResult> {
		return this.#call<SessionsListResult>(METHOD.sessionsList, params, options);
	}

	sessionsPreview(
		params: { sessionKey: string; limit?: number },
		options?: RequestOptions,
	): Promise<SessionsPreviewResult> {
		return this.#call<SessionsPreviewResult>(METHOD.sessionsPreview, params, options);
	}

	sessionsActive(
		params?: Record<string, unknown>,
		options?: RequestOptions,
	): Promise<SessionSummary> {
		return this.#call<SessionSummary>(METHOD.sessionsActive, params, options);
	}

	sessionsActiveList(
		params?: Record<string, unknown>,
		options?: RequestOptions,
	): Promise<SessionsListResult> {
		return this.#call<SessionsListResult>(METHOD.sessionsActiveList, params, options);
	}

	sessionsPatch(params: SessionsPatchParams, options?: RequestOptions): Promise<unknown> {
		return this.#call(METHOD.sessionsPatch, params, options);
	}

	sessionsMetadataPatch(
		params: SessionsMetadataPatchParams,
		options?: RequestOptions,
	): Promise<SessionsMetadataPatchResult> {
		return this.#call<SessionsMetadataPatchResult>(METHOD.sessionsMetadataPatch, params, {
			...options,
			queueIfOffline: false,
		});
	}

	sessionsExport(
		params: { sessionKey: string; format?: SessionExportFormat },
		options?: RequestOptions,
	): Promise<SessionsExportResult> {
		return this.#call<SessionsExportResult>(METHOD.sessionsExport, params, options);
	}

	sessionsPrune(
		params: SessionsPruneParams,
		options?: RequestOptions,
	): Promise<SessionsPruneResult> {
		return this.#call<SessionsPruneResult>(METHOD.sessionsPrune, params, {
			...options,
			queueIfOffline: false,
		});
	}

	sessionsReset(params: { sessionKey: string }, options?: RequestOptions): Promise<unknown> {
		return this.#call(METHOD.sessionsReset, params, options);
	}

	sessionsDelete(
		params: { sessionKey: string },
		options?: RequestOptions,
	): Promise<SessionsDeleteResult> {
		return this.#call<SessionsDeleteResult>(METHOD.sessionsDelete, params, {
			...options,
			queueIfOffline: false,
		});
	}

	sessionsCompact(
		params: { sessionKey: string },
		options?: RequestOptions,
	): Promise<Record<string, unknown>> {
		return this.#call<Record<string, unknown>>(METHOD.sessionsCompact, params, options);
	}

	sessionHeartbeat(
		params: {
			sessionKey: string;
			action?: "status" | "set" | "pause" | "resume" | "clear";
			prompt?: string;
			intervalSeconds?: number;
		},
		options?: RequestOptions,
	): Promise<Record<string, unknown>> {
		return this.#call<Record<string, unknown>>(METHOD.sessionHeartbeat, params, options);
	}

	sessionDetail(
		params: { sessionKey: string },
		options?: RequestOptions,
	): Promise<SessionDetailResult> {
		return this.#call<SessionDetailResult>(METHOD.sessionDetail, params, options);
	}

	// -- models -------------------------------------------------------------

	modelsList(
		params?: Record<string, unknown>,
		options?: RequestOptions,
	): Promise<ModelsListResult> {
		return this.#call<ModelsListResult>(METHOD.modelsList, params, options);
	}

	// -- command and agent discovery ----------------------------------------

	commandsCatalog(
		params?: Record<string, unknown>,
		options?: RequestOptions,
	): Promise<Record<string, unknown>> {
		return this.#call<Record<string, unknown>>(METHOD.commandsCatalog, params, options);
	}

	agentsList(
		params?: Record<string, unknown>,
		options?: RequestOptions,
	): Promise<Record<string, unknown>> {
		return this.#call<Record<string, unknown>>(METHOD.agentsList, params, options);
	}

	backgroundStart(
		params: {
			prompt: string;
			sessionId?: string;
			sessionKey?: string;
			cwd?: string;
			model?: string;
			thinkingLevel?: string;
		},
		options?: RequestOptions,
	): Promise<Record<string, unknown>> {
		return this.#call<Record<string, unknown>>(METHOD.backgroundStart, params, options);
	}

	backgroundList(
		params?: { status?: string },
		options?: RequestOptions,
	): Promise<Record<string, unknown>> {
		return this.#call<Record<string, unknown>>(METHOD.backgroundList, params, options);
	}

	backgroundStatus(
		params: { id: string },
		options?: RequestOptions,
	): Promise<Record<string, unknown>> {
		return this.#call<Record<string, unknown>>(METHOD.backgroundStatus, params, options);
	}

	backgroundResult(
		params: { id: string },
		options?: RequestOptions,
	): Promise<Record<string, unknown>> {
		return this.#call<Record<string, unknown>>(METHOD.backgroundResult, params, options);
	}

	backgroundCancel(
		params: { id: string },
		options?: RequestOptions,
	): Promise<Record<string, unknown>> {
		return this.#call<Record<string, unknown>>(METHOD.backgroundCancel, params, options);
	}

	sessionBtw(
		params: { question: string; sessionId?: string; sessionKey?: string; timeoutMs?: number },
		options?: RequestOptions,
	): Promise<Record<string, unknown>> {
		return this.#call<Record<string, unknown>>(METHOD.sessionBtw, params, options);
	}

	// -- approvals ----------------------------------------------------------

	approvalResolve(params: ApprovalResolveParams, options?: RequestOptions): Promise<unknown> {
		return this.#call(METHOD.approvalResolve, params, options);
	}

	approvalsGet(params?: Record<string, unknown>, options?: RequestOptions): Promise<unknown> {
		return this.#call(METHOD.approvalsGet, params, options);
	}

	// -- diagnostics --------------------------------------------------------

	health(params?: Record<string, unknown>, options?: RequestOptions): Promise<HealthResult> {
		return this.#call<HealthResult>(METHOD.health, params, options);
	}

	status(
		params?: Record<string, unknown>,
		options?: RequestOptions,
	): Promise<Record<string, unknown>> {
		return this.#call<Record<string, unknown>>(METHOD.status, params, options);
	}

	usageStatus(
		params?: Record<string, unknown>,
		options?: RequestOptions,
	): Promise<UsageStatusResult> {
		return this.#call<UsageStatusResult>(METHOD.usageStatus, params, options);
	}

	usageCost(
		params?: Record<string, unknown>,
		options?: RequestOptions,
	): Promise<UsageStatusResult> {
		return this.#call<UsageStatusResult>(METHOD.usageCost, params, options);
	}

	// -- runs ---------------------------------------------------------------

	runsActiveList(params?: Record<string, unknown>, options?: RequestOptions): Promise<unknown> {
		return this.#call(METHOD.runsActiveList, params, options);
	}

	runsRecentList(params?: Record<string, unknown>, options?: RequestOptions): Promise<unknown> {
		return this.#call(METHOD.runsRecentList, params, options);
	}

	tasksActiveList(params?: Record<string, unknown>, options?: RequestOptions): Promise<unknown> {
		return this.#call(METHOD.tasksActiveList, params, options);
	}

	tasksRecentList(params?: Record<string, unknown>, options?: RequestOptions): Promise<unknown> {
		return this.#call(METHOD.tasksRecentList, params, options);
	}

	// -- goals --------------------------------------------------------------

	goalSet(params: GoalSetParams, options?: RequestOptions): Promise<unknown> {
		return this.#call(METHOD.goalSet, params, options);
	}

	goalStatus(params?: Record<string, unknown>, options?: RequestOptions): Promise<unknown> {
		return this.#call(METHOD.goalStatus, params, options);
	}

	goalPause(params?: Record<string, unknown>, options?: RequestOptions): Promise<unknown> {
		return this.#call(METHOD.goalPause, params, options);
	}

	goalResume(params?: Record<string, unknown>, options?: RequestOptions): Promise<unknown> {
		return this.#call(METHOD.goalResume, params, options);
	}

	goalClear(params?: Record<string, unknown>, options?: RequestOptions): Promise<unknown> {
		return this.#call(METHOD.goalClear, params, options);
	}

	// -- misc ---------------------------------------------------------------

	logsTail(params?: LogsTailParams, options?: RequestOptions): Promise<unknown> {
		return this.#call(METHOD.logsTail, params, options);
	}

	configGet(params?: ConfigGetParams, options?: RequestOptions): Promise<unknown> {
		return this.#call(METHOD.configGet, params, options);
	}

	configSet(params: ConfigSetParams, options?: RequestOptions): Promise<unknown> {
		return this.#call(METHOD.configSet, params, options);
	}

	// -- skills -------------------------------------------------------------

	skillsHermesCatalog(
		params?: Record<string, unknown>,
		options?: RequestOptions,
	): Promise<Record<string, unknown>> {
		return this.#call<Record<string, unknown>>(METHOD.skillsHermesCatalog, params, options);
	}

	skillsInstall(
		params: { skillKey: string; cwd?: string },
		options?: RequestOptions,
	): Promise<Record<string, unknown>> {
		return this.#call<Record<string, unknown>>(METHOD.skillsInstall, params, {
			...options,
			timeoutMs: options?.timeoutMs ?? SKILL_MUTATION_REQUEST_TIMEOUT_MS,
		});
	}

	// -- portable blueprints ------------------------------------------------

	blueprintsList(options?: RequestOptions): Promise<BlueprintsListResult> {
		return this.#call<BlueprintsListResult>(METHOD.blueprintsList, {}, options);
	}

	blueprintsInspect(
		params: { bundleId: string },
		options?: RequestOptions,
	): Promise<BlueprintInspectResult> {
		return this.#call<BlueprintInspectResult>(METHOD.blueprintsInspect, params, options);
	}

	blueprintsValidate(
		params: { bundleId: string },
		options?: RequestOptions,
	): Promise<BlueprintInspectResult> {
		return this.#call<BlueprintInspectResult>(METHOD.blueprintsValidate, params, options);
	}

	blueprintsPreview(
		params: { bundleId: string; profileId: string },
		options?: RequestOptions,
	): Promise<BlueprintPreviewResult> {
		return this.#call<BlueprintPreviewResult>(METHOD.blueprintsPreview, params, options);
	}

	blueprintsActivate(
		params: { bundleId: string; profileId: string; confirmationDigest: string },
		options?: RequestOptions,
	): Promise<BlueprintActivationResult> {
		return this.#call<BlueprintActivationResult>(METHOD.blueprintsActivate, params, {
			...options,
			queueIfOffline: false,
		});
	}
}
