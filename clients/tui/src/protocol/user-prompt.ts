export interface UserQuestion {
	id: string;
	question: string;
	header?: string;
	options: Array<{ label: string; description?: string }>;
	multi?: boolean;
	recommended?: number;
}

export interface UserPromptRequested {
	promptId: string;
	sessionKey: string;
	runId?: string | null;
	questions: UserQuestion[];
	expiresAtMs?: number | null;
}

export interface UserPromptResolved {
	promptId: string;
	sessionKey: string;
	runId?: string | null;
	status: string;
}

export interface UserPromptAnswer {
	action: "accept" | "decline" | "cancel";
	content?: Record<string, string | string[]>;
}

export type UserPromptResolveParams = UserPromptAnswer & {
	promptId: string;
	sessionKey: string;
	runId?: string | null;
};

/** Wire data remains untrusted until every question can be rendered. */
export function parseUserPrompt(value: unknown): UserPromptRequested | undefined {
	if (!record(value) || typeof value.promptId !== "string" || typeof value.sessionKey !== "string")
		return undefined;
	if (value.runId != null && typeof value.runId !== "string") return undefined;
	if (value.expiresAtMs != null && typeof value.expiresAtMs !== "number") return undefined;
	if (!Array.isArray(value.questions) || value.questions.length < 1 || value.questions.length > 8)
		return undefined;
	for (const question of value.questions) {
		if (
			!record(question) ||
			typeof question.id !== "string" ||
			typeof question.question !== "string"
		)
			return undefined;
		if (question.header != null && typeof question.header !== "string") return undefined;
		if (question.multi != null && typeof question.multi !== "boolean") return undefined;
		if (question.recommended != null && !Number.isInteger(question.recommended)) return undefined;
		if (!Array.isArray(question.options) || question.options.length > 20) return undefined;
		if (
			question.options.some(
				(option: unknown) =>
					!record(option) ||
					typeof option.label !== "string" ||
					(option.description != null && typeof option.description !== "string"),
			)
		)
			return undefined;
	}
	return value as unknown as UserPromptRequested;
}

function record(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}
