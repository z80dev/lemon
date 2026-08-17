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
	SessionSummary,
	SessionsListResult,
	SessionsPatchParams,
	UsageStatusResult,
} from "./types.ts";

export const METHOD = {
	chatSend: "chat.send",
	chatAbort: "chat.abort",
	chatHistory: "chat.history",
	sessionsList: "sessions.list",
	sessionsActive: "sessions.active",
	sessionsActiveList: "sessions.active.list",
	sessionsPatch: "sessions.patch",
	sessionsReset: "sessions.reset",
	sessionsDelete: "sessions.delete",
	sessionDetail: "session.detail",
	modelsList: "models.list",
	approvalResolve: "exec.approval.resolve",
	approvalsGet: "exec.approvals.get",
	health: "health",
	status: "status",
	usageStatus: "usage.status",
	usageCost: "usage.cost",
	runsActiveList: "runs.active.list",
	runsRecentList: "runs.recent.list",
	goalSet: "goal.set",
	goalStatus: "goal.status",
	goalPause: "goal.pause",
	goalResume: "goal.resume",
	goalClear: "goal.clear",
	logsTail: "logs.tail",
	configGet: "config.get",
	configSet: "config.set",
} as const;

export type MethodName = (typeof METHOD)[keyof typeof METHOD];

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

	// -- sessions -----------------------------------------------------------

	sessionsList(
		params?: Record<string, unknown>,
		options?: RequestOptions,
	): Promise<SessionsListResult> {
		return this.#call<SessionsListResult>(METHOD.sessionsList, params, options);
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

	sessionsReset(params: { sessionKey: string }, options?: RequestOptions): Promise<unknown> {
		return this.#call(METHOD.sessionsReset, params, options);
	}

	sessionsDelete(params: { sessionKey: string }, options?: RequestOptions): Promise<unknown> {
		return this.#call(METHOD.sessionsDelete, params, options);
	}

	sessionDetail(params: { sessionKey: string }, options?: RequestOptions): Promise<SessionSummary> {
		return this.#call<SessionSummary>(METHOD.sessionDetail, params, options);
	}

	// -- models -------------------------------------------------------------

	modelsList(
		params?: Record<string, unknown>,
		options?: RequestOptions,
	): Promise<ModelsListResult> {
		return this.#call<ModelsListResult>(METHOD.modelsList, params, options);
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
}
