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
import { parseSessionsContext } from "./context-usage.ts";
import { MethodUnavailableError } from "./errors.ts";
import {
	type OmpCancelResult,
	type OmpConfigureParams,
	type OmpModel,
	type OmpModelsParams,
	type OmpSendResult,
	type OmpSessionResult,
	type OmpSessionsDiscoverResult,
	type OmpSessionsGetResult,
	type OmpSessionsListParams,
	type OmpSessionsListResult,
	type OmpSessionsResumeParams,
	type OmpSessionsSendParams,
	type OmpSessionsStartParams,
	type OmpStartManyParams,
	type OmpStartManyResult,
	type OmpStatus,
	type OmpSubagentResult,
	parseOmpDiscoveredList,
	parseOmpModels,
	parseOmpSession,
	parseOmpSessions,
	parseOmpStatus,
	parseOmpSubagent,
} from "./omp.ts";
import type {
	SessionLabelParams,
	SessionLabelResult,
	SessionNavigateParams,
	SessionNavigateResult,
	SessionRewindPreview,
	SessionRewindResult,
	SessionRewindTarget,
	SessionTreeParams,
	SessionTreeResult,
} from "./session-tree.ts";
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
	RunsRecentListResult,
	SessionDetailResult,
	SessionExportFormat,
	SessionSummary,
	SessionsCompactParams,
	SessionsContextParams,
	SessionsContextResult,
	SessionsDeleteResult,
	SessionsExportResult,
	SessionsForkParams,
	SessionsForkResult,
	SessionsListParams,
	SessionsListResult,
	SessionsMetadataPatchParams,
	SessionsMetadataPatchResult,
	SessionsPatchParams,
	SessionsPlanParams,
	SessionsPlanResult,
	SessionsPreviewResult,
	SessionsPruneParams,
	SessionsPruneResult,
	SessionsSnapshotParams,
	SessionsSnapshotResult,
	UsageStatusResult,
} from "./types.ts";
import type { UserPromptResolveParams } from "./user-prompt.ts";

export interface SetupStatusResult {
	ready: boolean;
	pendingSteps: Array<{
		id: "config" | "secrets" | "provider";
		label: string;
		command: string;
	}>;
}

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
	sessionsGet: "sessions.get",
	sessionsCreate: "sessions.create",
	userPromptBind: "sessions.prompt.bind",
	userPromptResolve: "sessions.prompt.resolve",
	sessionsFork: "sessions.fork",
	sessionsPreview: "sessions.preview",
	sessionsActive: "sessions.active",
	sessionsActiveList: "sessions.active.list",
	sessionsSnapshot: "sessions.snapshot",
	sessionsPatch: "sessions.patch",
	sessionsMetadataPatch: "sessions.metadata.patch",
	sessionsExport: "sessions.export",
	sessionsPrune: "sessions.prune",
	sessionsReset: "sessions.reset",
	sessionsDelete: "sessions.delete",
	sessionsCompact: "sessions.compact",
	sessionsPlan: "sessions.plan",
	sessionsContext: "sessions.context",
	sessionsTree: "sessions.tree",
	sessionsRewind: "sessions.rewind",
	sessionsNavigate: "sessions.navigate",
	sessionsLabel: "sessions.label",
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
	setupStatus: "setup.status",
	usageStatus: "usage.status",
	usageCost: "usage.cost",
	runsActiveList: "runs.active.list",
	runsRecentList: "runs.recent.list",
	runsTimelineGet: "runs.timeline.get",
	tasksActiveList: "tasks.active.list",
	tasksRecentList: "tasks.recent.list",
	goalSet: "goal.set",
	goalStatus: "goal.status",
	goalPause: "goal.pause",
	goalResume: "goal.resume",
	goalClear: "goal.clear",
	cronList: "cron.list",
	cronAdd: "cron.add",
	cronUpdate: "cron.update",
	cronPause: "cron.pause",
	cronResume: "cron.resume",
	cronRemove: "cron.remove",
	cronRun: "cron.run",
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
	ompStatus: "omp.status",
	ompSessionsList: "omp.sessions.list",
	ompSessionsGet: "omp.sessions.get",
	ompSessionsDiscover: "omp.sessions.discover",
	ompSessionsStart: "omp.sessions.start",
	ompSessionsResume: "omp.sessions.resume",
	ompSessionsSend: "omp.sessions.send",
	ompSessionsCancel: "omp.sessions.cancel",
	ompSessionsClose: "omp.sessions.close",
	ompSessionsStartMany: "omp.sessions.startMany",
	ompModels: "omp.models",
	ompSessionsSubagent: "omp.sessions.subagent",
	ompSessionsConfigure: "omp.sessions.configure",
} as const;

/** Every `omp.*` method; a daemon advertising none of them has no omp integration. */
export const OMP_METHODS: readonly string[] = [
	METHOD.ompStatus,
	METHOD.ompSessionsList,
	METHOD.ompSessionsGet,
	METHOD.ompSessionsDiscover,
	METHOD.ompSessionsStart,
	METHOD.ompSessionsResume,
	METHOD.ompSessionsSend,
	METHOD.ompSessionsCancel,
	METHOD.ompSessionsClose,
	METHOD.ompSessionsStartMany,
	METHOD.ompModels,
	METHOD.ompSessionsSubagent,
	METHOD.ompSessionsConfigure,
];

/** Spawning (or resuming) an omp process waits for its RPC handshake. */
export const OMP_START_REQUEST_TIMEOUT_MS = 60_000;
/** A send is acknowledged only after omp itself accepted it. */
export const OMP_SEND_REQUEST_TIMEOUT_MS = 30_000;

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

	async userPromptBind(
		sessionKey: string,
		enabled = true,
	): Promise<{ sessionKey: string; bound: boolean }> {
		const result = await this.#call<{ sessionKey: string; bound: boolean }>(
			METHOD.userPromptBind,
			{ sessionKey, enabled },
			{ queueIfOffline: false },
		);
		if (result?.sessionKey !== sessionKey || result.bound !== enabled)
			throw new Error("The daemon did not confirm the session prompt surface.");
		return result;
	}

	async userPromptResolve(
		params: UserPromptResolveParams,
	): Promise<{ resolved: boolean; promptId: string }> {
		const result = await this.#call<{ resolved: boolean; promptId: string }>(
			METHOD.userPromptResolve,
			params,
			{ queueIfOffline: false },
		);
		if (result?.resolved !== true || result.promptId !== params.promptId)
			throw new Error("The daemon did not confirm the question answer.");
		return result;
	}

	sessionsList(params?: SessionsListParams, options?: RequestOptions): Promise<SessionsListResult> {
		return this.#call<SessionsListResult>(METHOD.sessionsList, params, options);
	}

	/** Exact durable lifecycle lookup; never a substring/history search. */
	sessionsGet(
		params: { sessionKey: string },
		options?: RequestOptions,
	): Promise<{ session: SessionSummary }> {
		return this.#call(METHOD.sessionsGet, params, { ...options, queueIfOffline: false });
	}

	sessionsFork(params: SessionsForkParams, options?: RequestOptions): Promise<SessionsForkResult> {
		return this.#call<SessionsForkResult>(METHOD.sessionsFork, params, {
			...options,
			queueIfOffline: false,
		});
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

	sessionsSnapshot(
		params: SessionsSnapshotParams,
		options?: RequestOptions,
	): Promise<SessionsSnapshotResult> {
		return this.#call<SessionsSnapshotResult>(METHOD.sessionsSnapshot, params, {
			...options,
			queueIfOffline: false,
		});
	}

	sessionsPatch(params: SessionsPatchParams, options?: RequestOptions): Promise<unknown> {
		return this.#call(METHOD.sessionsPatch, params, options);
	}

	sessionsTree(params: SessionTreeParams, options?: RequestOptions): Promise<SessionTreeResult> {
		return this.#call<SessionTreeResult>(METHOD.sessionsTree, params, {
			...options,
			queueIfOffline: false,
		});
	}

	sessionsRewindPreview(
		params: SessionRewindTarget,
		options?: RequestOptions,
	): Promise<SessionRewindPreview> {
		return this.#call<SessionRewindPreview>(
			METHOD.sessionsRewind,
			{ ...params, dryRun: true },
			{
				...options,
				queueIfOffline: false,
			},
		);
	}

	sessionsRewindConfirm(
		params: SessionRewindTarget & { confirmationToken: string },
		options?: RequestOptions,
	): Promise<SessionRewindResult> {
		return this.#call<SessionRewindResult>(
			METHOD.sessionsRewind,
			{ ...params, dryRun: false },
			{
				...options,
				queueIfOffline: false,
			},
		);
	}

	sessionsNavigate(
		params: SessionNavigateParams,
		options?: RequestOptions,
	): Promise<SessionNavigateResult> {
		return this.#call<SessionNavigateResult>(METHOD.sessionsNavigate, params, {
			...options,
			queueIfOffline: false,
		});
	}

	sessionsLabel(params: SessionLabelParams, options?: RequestOptions): Promise<SessionLabelResult> {
		return this.#call<SessionLabelResult>(METHOD.sessionsLabel, params, {
			...options,
			queueIfOffline: false,
		});
	}

	sessionsCreate(
		params: { sessionKey: string; cwd: string },
		options?: RequestOptions,
	): Promise<{ sessionKey: string; sessionId: string; created: boolean }> {
		return this.#call(METHOD.sessionsCreate, params, { ...options, queueIfOffline: false });
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

	sessionsPlan(params: SessionsPlanParams, options?: RequestOptions): Promise<SessionsPlanResult> {
		return this.#call<SessionsPlanResult>(METHOD.sessionsPlan, params, {
			...options,
			queueIfOffline: false,
		});
	}

	/** Read-only, but never parked offline: a stale queued measurement is worthless. */
	async sessionsContext(
		params: SessionsContextParams,
		options?: RequestOptions,
	): Promise<SessionsContextResult> {
		const raw = await this.#call<unknown>(METHOD.sessionsContext, params, {
			...options,
			queueIfOffline: false,
		});
		return parseSessionsContext(raw);
	}

	sessionsCompact(
		params: SessionsCompactParams,
		options?: RequestOptions,
	): Promise<Record<string, unknown>> {
		return this.#call<Record<string, unknown>>(METHOD.sessionsCompact, params, {
			...options,
			queueIfOffline: false,
			timeoutMs: options?.timeoutMs ?? 360_000,
		});
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

	setupStatus(options?: RequestOptions): Promise<SetupStatusResult> {
		return this.#call<SetupStatusResult>(METHOD.setupStatus, {}, options);
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

	runsRecentList(
		params?: Record<string, unknown>,
		options?: RequestOptions,
	): Promise<RunsRecentListResult> {
		return this.#call<RunsRecentListResult>(METHOD.runsRecentList, params, options);
	}

	runsTimelineGet(
		params: { runId: string },
		options?: RequestOptions,
	): Promise<Record<string, unknown>> {
		return this.#call<Record<string, unknown>>(METHOD.runsTimelineGet, params, options);
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

	// -- cron ---------------------------------------------------------------

	cronList(
		params?: { agentId?: string; includeTargetText?: boolean },
		options?: RequestOptions,
	): Promise<Record<string, unknown>> {
		return this.#call<Record<string, unknown>>(METHOD.cronList, params, options);
	}

	cronAdd(
		params: {
			name: string;
			schedule: string;
			agentId: string;
			sessionKey: string;
			prompt: string;
			timezone?: string;
			enabled?: boolean;
			meta?: Record<string, unknown>;
		},
		options?: RequestOptions,
	): Promise<Record<string, unknown>> {
		return this.#call<Record<string, unknown>>(METHOD.cronAdd, params, options);
	}

	cronUpdate(
		params: {
			id: string;
			name?: string;
			schedule?: string;
			prompt?: string;
			timezone?: string;
			enabled?: boolean;
		},
		options?: RequestOptions,
	): Promise<Record<string, unknown>> {
		return this.#call<Record<string, unknown>>(METHOD.cronUpdate, params, options);
	}

	cronPause(params: { id: string }, options?: RequestOptions): Promise<Record<string, unknown>> {
		return this.#call<Record<string, unknown>>(METHOD.cronPause, params, options);
	}

	cronResume(params: { id: string }, options?: RequestOptions): Promise<Record<string, unknown>> {
		return this.#call<Record<string, unknown>>(METHOD.cronResume, params, options);
	}

	cronRemove(params: { id: string }, options?: RequestOptions): Promise<Record<string, unknown>> {
		return this.#call<Record<string, unknown>>(METHOD.cronRemove, params, options);
	}

	cronRun(params: { id: string }, options?: RequestOptions): Promise<Record<string, unknown>> {
		return this.#call<Record<string, unknown>>(METHOD.cronRun, params, options);
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

	// -- omp delegates --------------------------------------------------------
	// Replies carry untrusted omp output; they are parsed defensively here and
	// sanitized by whatever renders them. Mutations are never parked offline.

	async ompStatus(options?: RequestOptions): Promise<OmpStatus> {
		return parseOmpStatus(await this.#call(METHOD.ompStatus, {}, options));
	}

	async ompSessionsList(
		params: OmpSessionsListParams = {},
		options?: RequestOptions,
	): Promise<OmpSessionsListResult> {
		const result = await this.#call<{ sessions?: unknown }>(
			METHOD.ompSessionsList,
			params,
			options,
		);
		return { sessions: parseOmpSessions(result?.sessions) };
	}

	async ompSessionsGet(
		params: { id: string },
		options?: RequestOptions,
	): Promise<OmpSessionsGetResult> {
		const result = await this.#call<{ session?: unknown; summary?: unknown }>(
			METHOD.ompSessionsGet,
			params,
			options,
		);
		return {
			session: requireSession(result?.session, METHOD.ompSessionsGet),
			summary: typeof result?.summary === "string" ? result.summary : null,
		};
	}

	async ompSessionsDiscover(
		params: { cwd: string; limit?: number },
		options?: RequestOptions,
	): Promise<OmpSessionsDiscoverResult> {
		const result = await this.#call<{ sessions?: unknown }>(
			METHOD.ompSessionsDiscover,
			params,
			options,
		);
		return { sessions: parseOmpDiscoveredList(result?.sessions) };
	}

	async ompSessionsStart(
		params: OmpSessionsStartParams,
		options?: RequestOptions,
	): Promise<OmpSessionResult> {
		const result = await this.#call<{ session?: unknown }>(METHOD.ompSessionsStart, params, {
			timeoutMs: OMP_START_REQUEST_TIMEOUT_MS,
			...options,
			queueIfOffline: false,
		});
		return { session: requireSession(result?.session, METHOD.ompSessionsStart) };
	}

	async ompSessionsResume(
		params: OmpSessionsResumeParams,
		options?: RequestOptions,
	): Promise<OmpSessionResult> {
		const result = await this.#call<{ session?: unknown }>(METHOD.ompSessionsResume, params, {
			timeoutMs: OMP_START_REQUEST_TIMEOUT_MS,
			...options,
			queueIfOffline: false,
		});
		return { session: requireSession(result?.session, METHOD.ompSessionsResume) };
	}

	async ompSessionsSend(
		params: OmpSessionsSendParams,
		options?: RequestOptions,
	): Promise<OmpSendResult> {
		const result = await this.#call<{ accepted?: unknown; delivery?: unknown }>(
			METHOD.ompSessionsSend,
			params,
			{ timeoutMs: OMP_SEND_REQUEST_TIMEOUT_MS, ...options, queueIfOffline: false },
		);
		if (result?.accepted !== true) {
			throw new Error(`${METHOD.ompSessionsSend} returned no acceptance receipt`);
		}
		return {
			accepted: true,
			delivery: typeof result.delivery === "string" ? result.delivery : null,
		};
	}

	async ompSessionsCancel(
		params: { id: string },
		options?: RequestOptions,
	): Promise<OmpCancelResult> {
		const result = await this.#call<{ cancelled?: unknown }>(METHOD.ompSessionsCancel, params, {
			...options,
			queueIfOffline: false,
		});
		return { cancelled: result?.cancelled === true };
	}

	async ompSessionsClose(
		params: { id: string },
		options?: RequestOptions,
	): Promise<OmpSessionResult> {
		const result = await this.#call<{ session?: unknown }>(METHOD.ompSessionsClose, params, {
			...options,
			queueIfOffline: false,
		});
		return { session: requireSession(result?.session, METHOD.ompSessionsClose) };
	}

	async ompModels(
		params: OmpModelsParams = {},
		options?: RequestOptions,
	): Promise<{ models: OmpModel[] }> {
		const result = await this.#call<{ models?: unknown }>(METHOD.ompModels, params, options);
		return { models: parseOmpModels(result?.models) };
	}

	async ompSessionsSubagent(
		params: { id: string; subagentId: string; limit?: number },
		options?: RequestOptions,
	): Promise<OmpSubagentResult> {
		return parseOmpSubagent(await this.#call(METHOD.ompSessionsSubagent, params, options));
	}

	async ompSessionsConfigure(
		params: OmpConfigureParams,
		options?: RequestOptions,
	): Promise<OmpSessionResult> {
		const result = await this.#call<{ session?: unknown }>(METHOD.ompSessionsConfigure, params, {
			timeoutMs: OMP_SEND_REQUEST_TIMEOUT_MS,
			...options,
			queueIfOffline: false,
		});
		return { session: requireSession(result?.session, METHOD.ompSessionsConfigure) };
	}

	async ompSessionsStartMany(
		params: OmpStartManyParams,
		options?: RequestOptions,
	): Promise<OmpStartManyResult> {
		const result = await this.#call<{
			results?: Array<{
				index: number;
				session?: unknown;
				error?: { code: string; message: string; id?: string };
			}>;
		}>(METHOD.ompSessionsStartMany, params, {
			timeoutMs: OMP_START_REQUEST_TIMEOUT_MS,
			...options,
			queueIfOffline: false,
		});
		if (!Array.isArray(result?.results))
			throw new Error("omp.sessions.startMany returned no results");
		return {
			results: result.results.map((entry) =>
				entry.error
					? { index: entry.index, error: entry.error }
					: {
							index: entry.index,
							session: requireSession(entry.session, METHOD.ompSessionsStartMany),
						},
			),
		};
	}
}

/** A mutation reply without a parseable session is not a receipt of success. */
function requireSession(value: unknown, method: string) {
	const session = parseOmpSession(value);
	if (!session) throw new Error(`${method} returned no session`);
	return session;
}
