/**
 * omp delegate sessions as Tern semantic nodes, shared by the `/omp` panel and
 * the `omp` tool card so both describe a session the same way: an `agent` node
 * (status, title, model, the running tool, turns/tools/tokens/context/cost,
 * terminal-clocked age) with the session's detail as its body.
 *
 * Every string is omp output and untrusted, so it reaches a node only through
 * {@link safeLine}/{@link safeText}: plain text, no escapes, never markdown.
 */

import { basename } from "node:path";
import { node, span, text } from "@oh-my-pi/pi-tui/native/describe";
import type { NativeChild, NativeNode } from "@oh-my-pi/pi-tui/native/node";
import { type TodoItem, type TodoStatus, todoChecklistPhases } from "@oh-my-pi/pi-tui/tools/todo";
import { safeLine, safeText } from "../formatters/base.ts";
import { ompExtraLines, ompSessionLabel, ompUsageText } from "../formatters/omp.ts";
import { isOmpSessionEnded, type OmpSession } from "../protocol/omp.ts";

/** The `agent` node's props, via pi-tui's node type (pi-wire is not a direct dependency). */
type AgentProps = NonNullable<Extract<NativeNode, { k: "agent" }>["p"]>;
type AgentBadge = NonNullable<AgentProps["badges"]>[number];

const TODO_STATUS: Record<string, TodoStatus> = {
	pending: "pending",
	in_progress: "in_progress",
	completed: "completed",
	done: "completed",
	abandoned: "abandoned",
	blocked: "blocked",
};

const SUBAGENT_STATUS: Record<string, AgentProps["status"]> = {
	pending: "pending",
	queued: "pending",
	running: "running",
	completed: "done",
	done: "done",
	failed: "failed",
	error: "failed",
	aborted: "aborted",
	cancelled: "aborted",
};

/** The `agent` vocabulary for a session's lifecycle; a closed session reports how its last turn ended. */
export function ompAgentStatus(session: OmpSession): AgentProps["status"] {
	switch (session.status) {
		case "starting":
			return "pending";
		case "running":
			return "running";
		case "failed":
			return "failed";
		case "closed":
			return session.lastTurn === "error"
				? "failed"
				: session.lastTurn === "aborted"
					? "aborted"
					: "done";
		default:
			return "idle";
	}
}

/** How long the session has run (live) or ran (ended), from the daemon's own timestamps. */
export function ompElapsedMs(session: OmpSession, now: number): number | undefined {
	if (session.startedAt == null) return undefined;
	const end = isOmpSessionEnded(session) ? (session.endedAt ?? session.updatedAt ?? now) : now;
	return Math.max(0, end - session.startedAt);
}

export interface OmpAgentNodeOptions {
	now: number;
	key: string;
	/** Panel cursor; drawn as an accent badge. */
	selected?: boolean;
	collapsed?: boolean;
	children?: readonly NativeChild[];
}

export function ompAgentNode(session: OmpSession, options: OmpAgentNodeOptions): NativeNode {
	const elapsed = ompElapsedMs(session, options.now);
	const tool = session.activeTools[0];
	const badges: AgentBadge[] = [];
	if (options.selected) badges.push({ text: "selected", tone: "accent" });
	if (session.cwd) badges.push({ text: safeLine(basename(session.cwd), 40), tone: "muted" });
	if (session.declinedPrompts > 0) {
		badges.push({ text: `${session.declinedPrompts} declined`, tone: "warning" });
	}
	for (const line of ompExtraLines(session)) {
		if (line.startsWith("waiting for approval:")) badges.push({ text: line, tone: "warning" });
	}
	const props: AgentProps = {
		name: ompSessionLabel(session, 80),
		agent: "omp",
		status: ompAgentStatus(session),
		...(session.activity ? { task: safeLine(session.activity) } : {}),
		...(session.model ? { model: safeLine(session.model, 60) } : {}),
		...(session.thinking ? { thinking: safeLine(session.thinking, 20) } : {}),
		tool: tool
			? {
					name: safeLine(tool.name, 40),
					...(tool.intent ? { intent: safeLine(tool.intent, 120) } : {}),
				}
			: null,
		stats: {
			tools: session.toolCalls,
			requests: session.turns,
			...(session.usage?.totalTokens != null ? { tokens: session.usage.totalTokens } : {}),
			...(session.contextPercent != null
				? { context: Math.min(1, Math.max(0, session.contextPercent / 100)) }
				: {}),
			...(session.usage?.cost != null ? { cost: session.usage.cost } : {}),
			...(elapsed === undefined
				? {}
				: isOmpSessionEnded(session)
					? { took: elapsed }
					: { age: elapsed }),
		},
		...(badges.length > 0 ? { badges } : {}),
		...(options.children?.length
			? { collapsible: true, collapsed: options.collapsed ?? false }
			: {}),
	};
	return node("agent", props, options.children ?? [], options.key);
}

/** omp todos as the native checklist, one phase per omp phase in first-seen order. */
export function ompTodoChecklist(session: OmpSession): NativeNode | undefined {
	if (session.todos.length === 0) return undefined;
	const phases = new Map<string, TodoItem[]>();
	for (const todo of session.todos) {
		const name = todo.phase ? safeLine(todo.phase, 60) : "";
		const tasks = phases.get(name) ?? [];
		const status = Object.hasOwn(TODO_STATUS, todo.status) ? TODO_STATUS[todo.status] : "pending";
		tasks.push({ content: safeLine(todo.content), status: status ?? "pending" });
		phases.set(name, tasks);
	}
	return node(
		"checklist",
		{
			mode: "full",
			phases: todoChecklistPhases([...phases].map(([name, tasks]) => ({ name, tasks }))),
		},
		[],
		"todos",
	);
}

/** A labelled plain-text block (assistant text, result, error); never markdown. */
function textBlock(label: string, value: string, tone: string, key: string): NativeNode {
	return text([span(`${label}  `, "muted"), span(safeText(value).trim(), tone)], {
		wrap: "word",
		key,
	});
}

/** The detail body of one session: tools, todos, subagents, usage and its latest words. */
export function ompDetailNodes(session: OmpSession): NativeNode[] {
	const nodes: NativeNode[] = ompExtraLines(session).map((line, index) =>
		text([span(line, line.startsWith("waiting for approval:") ? "warning" : "muted")], {
			key: `extra:${index}`,
			wrap: "word",
		}),
	);
	const facts = [
		session.cwd ? `cwd ${safeLine(session.cwd, 120)}` : undefined,
		session.ompSessionId ? `omp ${safeLine(session.ompSessionId, 40)}` : undefined,
		`${session.turns} turn${session.turns === 1 ? "" : "s"} · ${session.toolCalls} tool call${session.toolCalls === 1 ? "" : "s"}`,
		ompUsageText(session),
		session.exit
			? `exit ${session.exit.code ?? "?"}${session.exit.reason ? ` (${safeLine(session.exit.reason, 40)})` : ""}`
			: undefined,
	].filter((fact): fact is string => Boolean(fact));
	nodes.push(text([span(facts.join(" · "), "muted")], { wrap: "word", key: "facts" }));
	if (session.recentTools.length > 0) {
		const recent = session.recentTools.map((tool) => {
			const mark = tool.isError ? "✗" : "✓";
			const took = tool.durationMs != null ? ` ${Math.round(tool.durationMs)}ms` : "";
			const intent = tool.intent ? ` — ${safeLine(tool.intent, 100)}` : "";
			return `${mark} ${safeLine(tool.name, 40)}${took}${intent}`;
		});
		nodes.push(
			text([span("recent  ", "muted"), span(recent.join("\n"), "dim")], {
				wrap: "word",
				key: "recent",
			}),
		);
	}
	const checklist = ompTodoChecklist(session);
	if (checklist) nodes.push(checklist);
	for (const [index, agent] of session.subagents.slice(0, 8).entries()) {
		const activity = (agent as typeof agent & { activity?: string | null }).activity;
		nodes.push(
			node(
				"agent",
				{
					name: safeLine(agent.id ?? `subagent ${index + 1}`, 60),
					...(agent.agent ? { agent: safeLine(agent.agent, 40) } : {}),
					...(activity || agent.description
						? { task: safeLine(activity || agent.description || "") }
						: {}),
					status:
						agent.status && Object.hasOwn(SUBAGENT_STATUS, agent.status)
							? (SUBAGENT_STATUS[agent.status] ?? "idle")
							: "idle",
					depth: 1,
				},
				[],
				`sub:${index}`,
			),
		);
	}
	if (session.declinedPrompts > 0) {
		nodes.push(
			text(
				[
					span(
						`${session.declinedPrompts} interactive omp prompt(s) were declined (headless)`,
						"warning",
					),
				],
				{ key: "declined" },
			),
		);
	}
	if (session.error) nodes.push(textBlock("error", session.error, "error", "error"));
	if (session.result) nodes.push(textBlock("result", session.result, "text", "result"));
	else if (session.lastText) nodes.push(textBlock("latest", session.lastText, "text", "latest"));
	return nodes;
}
