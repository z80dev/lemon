// Lemon factory OMP extension.
//
// Console role (default): one discoverable `factory` tool and a `/factory` slash
// command for starting, feeding, inspecting and controlling the factory.
// Coordinator role (FACTORY_ROLE=coordinator, set only by the supervisor): ledger
// tools for the single managed coordinator. Loading the extension is inert: it
// registers tools and commands, runs nothing, and makes no model requests.
//
// Every operation shells out to tools/factory/cli.py, the single implementation
// of ledger rules, so consoles, the coordinator and plain shells cannot diverge.
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CLI = path.resolve(HERE, "../../tools/factory/cli.py");
const PYTHON = process.env.FACTORY_PYTHON ?? "python3";
const ROLE = process.env.FACTORY_ROLE === "coordinator" ? "coordinator" : "console";
const CLI_TIMEOUT_MS = 180_000;

const CONSOLE_OPS = ["start", "add", "status", "show", "list", "prioritize", "edit", "pause", "resume", "drain", "stop"];
const PRIORITIES = ["urgent", "high", "normal", "low"];

/** The subset of cli.py's JSON output contract that consoles render. */
interface TaskView {
	id: string;
	revision: number;
	status: string;
	priority: string;
	title: string;
}
interface CliPayload {
	ok: boolean;
	error?: string;
	message?: string;
	runtime?: { state: string; desired_mode: string; epoch: number; model?: string | null; session_id?: string | null };
	work?: Record<string, number>;
	next?: TaskView[];
	task?: TaskView;
	tasks?: TaskView[];
	replayed?: boolean;
	note?: string | null;
}
interface CliResult {
	code: number;
	payload: CliPayload;
}
interface ConsoleParams {
	op: string;
	request?: string;
	title?: string;
	acceptance?: string[];
	priority?: string;
	task_id?: string;
	expected_revision?: number;
	changes_json?: string;
	status?: string;
	abort?: boolean;
	project?: string;
}

async function runCli(pi: ExtensionAPI, args: string[], cwd: string, signal?: AbortSignal): Promise<CliResult> {
	const result = await pi.exec(PYTHON, [CLI, ...args], { cwd, signal, timeout: CLI_TIMEOUT_MS });
	try {
		// cli.py always prints exactly one JSON object in this shape.
		return { code: result.code, payload: JSON.parse(result.stdout) as CliPayload };
	} catch {
		const message = (result.stderr || result.stdout).slice(-2000);
		return { code: result.code || 1, payload: { ok: false, error: "cli_failure", message } };
	}
}

async function runTool(pi: ExtensionAPI, args: string[], cwd: string, signal?: AbortSignal) {
	const { code, payload } = await runCli(pi, args, cwd, signal);
	return { content: [{ type: "text" as const, text: JSON.stringify(payload, null, 2) }], details: payload, isError: code !== 0 };
}

/** Map a console operation onto CLI arguments; `requestKey` makes mutations idempotent. */
function consoleArgs(params: ConsoleParams, requestKey: string): string[] {
	const { op } = params;
	if (!CONSOLE_OPS.includes(op)) throw new Error(`unknown factory op ${op}; use ${CONSOLE_OPS.join(" | ")}`);
	const project = params.project ? ["--project", params.project] : [];
	const taskId = (): string => {
		if (!params.task_id) throw new Error(`factory ${op} needs task_id`);
		return params.task_id;
	};
	switch (op) {
		case "add": {
			if (!params.request?.trim()) throw new Error("factory add needs the request text");
			const args = [...project, "add", params.request, "--request-key", requestKey];
			if (params.priority) args.push("--priority", params.priority);
			if (params.title) args.push("--title", params.title);
			for (const item of params.acceptance ?? []) args.push("--acceptance", item);
			return args;
		}
		case "show":
			return [...project, "show", taskId()];
		case "list":
			return params.status ? [...project, "list", "--status", params.status] : [...project, "list"];
		case "prioritize":
			if (!params.priority || !PRIORITIES.includes(params.priority)) {
				throw new Error(`priority must be one of ${PRIORITIES.join(", ")}`);
			}
			return [...project, "prioritize", taskId(), params.priority, "--request-key", requestKey];
		case "edit":
			if (params.expected_revision === undefined || !params.changes_json) {
				throw new Error("factory edit needs expected_revision and changes_json");
			}
			return [...project, "edit", taskId(), "--expected-revision", String(params.expected_revision),
				"--set-json", params.changes_json, "--request-key", requestKey];
		case "stop":
			return params.abort ? [...project, "stop", "--abort"] : [...project, "stop"];
		default:
			return [...project, op];
	}
}

function summarize(op: string, payload: CliPayload): string {
	if (!payload.ok) return `factory ${op} failed: ${payload.message ?? payload.error ?? "unknown error"}`;
	const lines: string[] = [];
	const { runtime } = payload;
	if (runtime) {
		lines.push(`Factory ${runtime.state} (desired ${runtime.desired_mode}, epoch ${runtime.epoch})`);
		if (runtime.model) lines.push(`Coordinator: ${runtime.model} · session ${runtime.session_id ?? "-"}`);
	}
	if (payload.work) {
		const work = Object.entries(payload.work).map(([status, n]) => `${n} ${status}`);
		lines.push(`Work: ${work.length ? work.join(", ") : "empty"}`);
	}
	if (payload.next?.length) lines.push(`Next: ${payload.next.map(t => `${t.id} ${t.title}`).join("; ")}`);
	const format = (t: TaskView) => `${t.id} r${t.revision} [${t.status}/${t.priority}] ${t.title}`;
	if (payload.task) lines.push(format(payload.task));
	if (payload.replayed) lines.push("(replayed: this request was already recorded)");
	if (payload.note) lines.push(payload.note);
	for (const t of payload.tasks ?? []) lines.push(format(t));
	return lines.length ? lines.join("\n") : JSON.stringify(payload);
}

function registerConsole(pi: ExtensionAPI): void {
	const z = pi.zod;
	pi.registerTool({
		name: "factory",
		label: "Lemon factory",
		description:
			"Control the shared Lemon development factory (durable work queue + one managed OMP coordinator). " +
			`ops: ${CONSOLE_OPS.join(" | ")}. 'Start the Lemon factory' → start. 'Add this to the factory: …' → add ` +
			"with the user's request verbatim (optional title, proposed acceptance, priority urgent|high|normal|low); " +
			"never start your own worker for it. Report the returned state honestly: adding while stopped only queues.",
		approval: "write",
		parameters: z.object({
			op: z.string().describe(CONSOLE_OPS.join(" | ")),
			request: z.string().optional().describe("add: the user's request, verbatim"),
			title: z.string().optional(),
			acceptance: z.array(z.string()).optional().describe("add: proposed acceptance criteria"),
			priority: z.string().optional().describe("urgent | high | normal | low"),
			task_id: z.string().optional().describe("e.g. F-0042"),
			expected_revision: z.number().optional().describe("edit: the revision you read"),
			changes_json: z.string().optional().describe('edit: JSON object, e.g. {"goal": "…"}'),
			status: z.string().optional().describe("list: comma-separated statuses"),
			abort: z.boolean().optional().describe("stop: emergency abort"),
			project: z.string().optional().describe("registered project ID when not inside its checkout"),
		}),
		execute: (toolCallId, params, signal, _onUpdate, ctx: ExtensionContext) =>
			runTool(pi, consoleArgs(params, `omp:${toolCallId}`), ctx.cwd, signal),
	});

	pi.registerCommand("factory", {
		description: "Lemon factory: start | add <request> | status | show <id> | list | prioritize <id> <p> | pause | resume | drain | stop",
		handler: async (rawArgs, ctx) => {
			const [op = "status", ...rest] = rawArgs.trim().split(/\s+/).filter(Boolean);
			const params: ConsoleParams = { op };
			if (op === "add") params.request = rawArgs.trim().slice(op.length).trim();
			if (op === "show" || op === "prioritize") params.task_id = rest[0];
			if (op === "prioritize") params.priority = rest[1];
			if (op === "list") params.status = rest[0];
			if (op === "stop") params.abort = rest[0] === "--abort";
			let text: string;
			try {
				if (op === "edit") throw new Error("use the factory tool for revision-checked edits");
				const key = `omp-command:${ctx.sessionManager.getSessionId()}:${Date.now()}`;
				text = summarize(op, (await runCli(pi, consoleArgs(params, key), ctx.cwd)).payload);
			} catch (error) {
				text = `factory ${op} failed: ${error instanceof Error ? error.message : String(error)}`;
			}
			pi.sendMessage({ customType: "lemon-factory", content: text, display: true, attribution: "user" }, { triggerTurn: false });
		},
	});
}

function registerCoordinator(pi: ExtensionAPI): void {
	const z = pi.zod;
	const epoch = process.env.FACTORY_EPOCH ?? "0";
	const project = process.env.FACTORY_PROJECT ? ["--project", process.env.FACTORY_PROJECT] : [];
	const key = (toolCallId: string) => ["--request-key", `coordinator:${toolCallId}`];

	pi.registerTool({
		name: "factory_snapshot",
		label: "Factory snapshot",
		description: "Bounded factory snapshot: runtime, policy, inbox/queued/active/ready/blocked tasks, live attempts, unprocessed events.",
		approval: "read",
		loadMode: "essential",
		parameters: z.object({}),
		execute: (_id, _params, signal, _u, ctx) => runTool(pi, [...project, "snapshot"], ctx.cwd, signal),
	});

	pi.registerTool({
		name: "factory_show",
		label: "Factory task",
		description: "Full task record (raw request, acceptance, scope) and its attempts.",
		approval: "read",
		loadMode: "essential",
		parameters: z.object({ task_id: z.string() }),
		execute: (_id, params, signal, _u, ctx) => runTool(pi, [...project, "show", params.task_id], ctx.cwd, signal),
	});

	pi.registerTool({
		name: "factory_task",
		label: "Factory task update",
		description:
			"Revision-checked task update. op=edit with changes_json (title, goal, acceptance[], non_goals[], risk, " +
			"priority, dependencies[], write_set[], notes) or op=transition with to + reason (+ disposition to cancel). " +
			"A revision_conflict returns the current task: re-read and reconcile, never overwrite.",
		approval: "write",
		loadMode: "essential",
		parameters: z.object({
			op: z.string().describe("edit | transition"),
			task_id: z.string(),
			expected_revision: z.number(),
			changes_json: z.string().optional(),
			to: z.string().optional(),
			reason: z.string().optional(),
			disposition: z.string().optional(),
		}),
		execute: (toolCallId, params, signal, _u, ctx) => {
			const rev = ["--expected-revision", String(params.expected_revision)];
			let args: string[];
			if (params.op === "edit") {
				args = ["edit", params.task_id, ...rev, "--set-json", params.changes_json ?? "{}"];
			} else if (params.op === "transition") {
				args = ["transition", params.task_id, params.to ?? "", ...rev, "--reason", params.reason ?? ""];
				if (params.disposition) args.push("--disposition", params.disposition);
			} else {
				throw new Error(`unknown op ${params.op}`);
			}
			return runTool(pi, [...project, ...args, ...key(toolCallId)], ctx.cwd, signal);
		},
	});

	pi.registerTool({
		name: "factory_add",
		label: "Factory child task",
		description: "Record a child task from bounded decomposition of a broad parent request.",
		approval: "write",
		loadMode: "essential",
		parameters: z.object({
			parent_id: z.string(),
			request: z.string(),
			title: z.string(),
			acceptance: z.array(z.string()).optional(),
			priority: z.string().optional(),
		}),
		execute: (toolCallId, params, signal, _u, ctx) => {
			const source = JSON.stringify({ kind: "decomposition", parent_id: params.parent_id });
			const args = [...project, "add", params.request, "--parent", params.parent_id, "--title", params.title,
				"--source-json", source, ...key(toolCallId)];
			if (params.priority) args.push("--priority", params.priority);
			for (const item of params.acceptance ?? []) args.push("--acceptance", item);
			return runTool(pi, args, ctx.cwd, signal);
		},
	});

	pi.registerTool({
		name: "factory_attempt",
		label: "Factory attempt",
		description:
			"op=reserve: admission-checked reservation BEFORE dispatching a native task worker (refused while paused, " +
			"draining, over capacity, on a stale epoch, with unmet dependencies or a dirty coordinator checkout). " +
			"op=record: record status launched|running|succeeded|failed|cancelled with worker_ref, branch, head_sha, outcome_json.",
		approval: "write",
		loadMode: "essential",
		parameters: z.object({
			op: z.string().describe("reserve | record"),
			task_id: z.string().optional(),
			expected_revision: z.number().optional(),
			stage: z.string().optional().describe("implement | review | repair"),
			attempt_id: z.string().optional(),
			status: z.string().optional(),
			worker_ref: z.string().optional(),
			branch: z.string().optional(),
			head_sha: z.string().optional(),
			outcome_json: z.string().optional(),
		}),
		execute: (toolCallId, params, signal, _u, ctx) => {
			let args: string[];
			if (params.op === "reserve") {
				args = ["reserve", params.task_id ?? "", "--expected-revision", String(params.expected_revision ?? -1),
					"--stage", params.stage ?? "implement", "--epoch", epoch];
			} else if (params.op === "record") {
				args = ["attempt", params.attempt_id ?? "", "--status", params.status ?? "", "--epoch", epoch];
				if (params.worker_ref) args.push("--worker-ref", params.worker_ref);
				if (params.branch) args.push("--branch", params.branch);
				if (params.head_sha) args.push("--head-sha", params.head_sha);
				if (params.outcome_json) args.push("--outcome-json", params.outcome_json);
			} else {
				throw new Error(`unknown op ${params.op}`);
			}
			return runTool(pi, [...project, ...args, ...key(toolCallId)], ctx.cwd, signal);
		},
	});

	pi.registerTool({
		name: "factory_checkpoint",
		label: "Factory checkpoint",
		description: "Mark ledger events processed through seq, after their decisions are durably recorded.",
		approval: "write",
		loadMode: "essential",
		parameters: z.object({ seq: z.number() }),
		execute: (_id, params, signal, _u, ctx) =>
			runTool(pi, [...project, "checkpoint", String(params.seq), "--epoch", epoch], ctx.cwd, signal),
	});
}

export default function lemonFactory(pi: ExtensionAPI): void {
	pi.setLabel("Lemon factory");
	if (ROLE === "coordinator") registerCoordinator(pi);
	else registerConsole(pi);
}
