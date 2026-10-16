// Deterministic scripted model provider for factory seam tests.
//
// Never used by the live factory. Each scripted prompt embeds
//   FIXTURE<<{"steps":[...]}>>FIXTURE
// and the provider replays step N, where N counts assistant turns since that
// prompt. Any later non-script message (follow-up, async result, wake-up) gets a
// short "ack:" reply. Every request is appended to $FACTORY_FIXTURE_LOG.
import { appendFileSync } from "node:fs";
import {
	type Api,
	type AssistantMessage,
	type Context,
	createAssistantMessageEventStream,
	type Message,
	type Model,
	type SimpleStreamOptions,
	type ToolCall,
} from "@oh-my-pi/pi-ai";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

const PROVIDER = "factory-fixture";
const API = "factory-fixture-api";
// Greedy: a parent script may embed a child's script inside a task string.
const MARKER = /FIXTURE<<([\s\S]*)>>FIXTURE/;

interface Step {
	text?: string;
	tool?: string;
	args?: Record<string, unknown>;
	delay_ms?: number;
}

function textOf(message: Message | undefined): string {
	if (!message || !("content" in message)) return "";
	const content: unknown = message.content;
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	const parts: string[] = [];
	for (const part of content) {
		if (part && typeof part === "object" && "type" in part && part.type === "text" && "text" in part) {
			if (typeof part.text === "string") parts.push(part.text);
		}
	}
	return parts.join("\n");
}

function parseSteps(raw: string): Step[] {
	const parsed: unknown = JSON.parse(raw);
	if (parsed && typeof parsed === "object" && "steps" in parsed && Array.isArray(parsed.steps)) {
		return parsed.steps as Step[]; // fixture scripts are authored by the seam tests themselves
	}
	throw new Error("fixture script must be {\"steps\": [...]}");
}

// With FACTORY_FIXTURE_COORDINATOR=1 a supervisor notice is answered like a minimal
// coordinator: read the snapshot, checkpoint through the announced seq, go idle.
const SUPERVISOR_NOTICE = /\[factory supervisor[\s\S]*?through (\d+)/;

function coordinatorScript(text: string): Step[] | undefined {
	const match = process.env.FACTORY_FIXTURE_COORDINATOR ? SUPERVISOR_NOTICE.exec(text) : null;
	if (!match) return undefined;
	return [
		{ tool: "factory_snapshot", args: {} },
		{ tool: "factory_checkpoint", args: { seq: Number(match[1]) } },
		{ text: "idle" },
	];
}

function choose(messages: Message[]): Step {
	for (let i = messages.length - 1; i >= 0; i--) {
		const m = messages[i];
		if (m.role === "assistant" || m.role === "toolResult") continue;
		const text = textOf(m);
		const match = MARKER.exec(text);
		const script = match ? parseSteps(match[1]) : coordinatorScript(text);
		if (!script) return { text: `ack: ${text.slice(0, 200)}` };
		const turns = messages.slice(i + 1).filter(later => later.role === "assistant").length;
		return script[turns] ?? { text: "fixture script complete" };
	}
	return { text: "ack: (empty)" };
}

function sleep(ms: number, signal: AbortSignal | undefined): Promise<boolean> {
	const { promise, resolve } = Promise.withResolvers<boolean>();
	if (signal?.aborted) {
		resolve(false);
		return promise;
	}
	const timer = setTimeout(() => resolve(true), ms);
	signal?.addEventListener("abort", () => {
		clearTimeout(timer);
		resolve(false);
	});
	return promise;
}

function emptyMessage(modelId: string): AssistantMessage {
	return {
		role: "assistant",
		content: [],
		api: API,
		provider: PROVIDER,
		model: modelId,
		usage: {
			input: 0,
			output: 0,
			cacheRead: 0,
			cacheWrite: 0,
			totalTokens: 0,
			cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
		},
		stopReason: "stop",
		timestamp: Date.now(),
	};
}

let callCounter = 0;

export default function fixtureProvider(pi: ExtensionAPI): void {
	pi.registerProvider(PROVIDER, {
		baseUrl: "https://fixture.invalid/v1",
		apiKey: "FIXTURE_KEY",
		api: API,
		models: ["fixture-main", "fixture-worker"].map(id => ({
			id,
			name: id,
			reasoning: false,
			input: ["text" as const],
			cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
			contextWindow: 128000,
			maxTokens: 8192,
		})),
		streamSimple: (model: Model<Api>, context: Context, options?: SimpleStreamOptions) => {
			const stream = createAssistantMessageEventStream();
			const messages = context.messages ?? [];
			const last = messages[messages.length - 1];
			const step = choose(messages);
			const log = process.env.FACTORY_FIXTURE_LOG;
			if (log) {
				const entry = {
					t: Date.now(),
					model: model.id,
					lastRole: last?.role,
					lastText: textOf(last).slice(0, 400),
					step,
					tools: (context.tools ?? []).map(tool => tool.name),
				};
				appendFileSync(log, `${JSON.stringify(entry)}\n`);
			}
			void (async () => {
				const message = emptyMessage(model.id);
				stream.push({ type: "start", partial: message });
				if (!(await sleep(step.delay_ms ?? 0, options?.signal))) {
					stream.push({ type: "error", reason: "aborted", error: { ...message, stopReason: "aborted" } });
					return;
				}
				if (step.tool) {
					const toolCall: ToolCall = {
						type: "toolCall",
						id: `fx-${process.pid}-${++callCounter}`,
						name: step.tool,
						arguments: step.args ?? {},
					};
					const final: AssistantMessage = { ...message, content: [toolCall], stopReason: "toolUse" };
					stream.push({ type: "toolcall_start", contentIndex: 0, partial: final });
					stream.push({ type: "toolcall_end", contentIndex: 0, toolCall, partial: final });
					stream.push({ type: "done", reason: "toolUse", message: final });
				} else {
					const final: AssistantMessage = { ...message, content: [{ type: "text", text: step.text ?? "" }] };
					stream.push({ type: "done", reason: "stop", message: final });
				}
			})();
			return stream;
		},
	});
}
