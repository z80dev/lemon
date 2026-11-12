import { node, span, stableKey } from "@oh-my-pi/pi-tui/native/describe";
import type { DescribeContext, NativeChild, NativeNode } from "@oh-my-pi/pi-tui/native/node";
import { DEFAULT_TERMINAL_PREVIEW_LINES } from "@oh-my-pi/pi-tui/render/render-utils";
import { fileRow } from "@oh-my-pi/pi-tui/tools/native-view";
import type { NativeToolView } from "@oh-my-pi/pi-tui/tools/renderer";
import type { ToolBlock } from "../store/transcript-model.ts";
import type { ToolCardState, ToolView } from "../ui/tool-view.ts";
import { nativeToolRole, nativeToolView } from "./native-tool-view.ts";

const STATUS = {
	streaming: "pending",
	running: "running",
	success: "done",
	error: "error",
	cancelled: "cancelled",
	unknown: "cancelled",
} as const satisfies Record<ToolCardState, string>;

const NOTE: Partial<Record<ToolCardState, string>> = {
	cancelled: "cancelled",
	unknown: "outcome unknown",
};

/** Settled clamp of a collapsed tool body when the view names none (omp's transcript default). */
const DEFAULT_PREVIEW = { lines: DEFAULT_TERMINAL_PREVIEW_LINES } as const;

/**
 * One tool call as TSP's data-first `tool` kind, the way omp's
 * `ToolExecutionComponent` wraps a renderer's {@link NativeToolView}: the head
 * data, status, timer and collapse as props, the body as borderless children.
 * Tern styles it by its `omp.tool.<name>` role; Carly reads the same metadata.
 */
export function nativeTool(
	block: ToolBlock,
	view: ToolView,
	collapsed: boolean,
	elapsed: number | undefined,
	context?: DescribeContext,
): NativeNode {
	const tool = nativeToolView(block, view, { expanded: !collapsed, elapsedMs: elapsed, context });
	return toolNode(nativeToolRole(view), view.toolName ?? view.kind, tool, {
		state: view.state,
		title: view.title,
		collapsed,
		elapsed,
		completed: block.phase === "completed",
	});
}

interface ToolNodeState {
	state: ToolCardState;
	/** Head verb when the view names none. */
	title: string;
	collapsed: boolean;
	elapsed: number | undefined;
	completed: boolean;
}

function toolNode(role: string, name: string, view: NativeToolView, s: ToolNodeState): NativeNode {
	const head = view.tool;
	const body = view.body ?? [];
	const hasBody = body.length > 0;
	const inline = view.inline === true;
	const preview = view.preview ?? (inline ? "none" : DEFAULT_PREVIEW);
	return node(
		"tool",
		{
			role: `omp.tool.${role}`,
			name,
			title: (head?.title ?? s.title) as string,
			target: head?.target,
			targetKind: head?.targetKind,
			lang: head?.lang,
			command: head?.command,
			href: head?.href,
			meta: head?.meta && head.meta.length > 0 ? head.meta : undefined,
			badges: head?.badges,
			note: head?.note ?? NOTE[s.state],
			exit: head?.exit ?? undefined,
			status: STATUS[s.state],
			...(s.elapsed === undefined ? {} : s.completed ? { took: s.elapsed } : { age: s.elapsed }),
			frame: inline ? "inline" : "card",
			collapsible: hasBody,
			collapsed: hasBody ? (view.open ? false : s.collapsed) : undefined,
			preview: hasBody ? (preview === "auto" ? DEFAULT_PREVIEW : preview) : undefined,
			tools: view.tools,
			tone: view.tone,
		},
		body,
	);
}

/** A read the shelf folds into a group: its block and current view. */
export interface GroupedRead {
	block: ToolBlock;
	view: ToolView;
}

/** `src/app.ts:10-40` → path and `:10-40` range. */
const TARGET_RANGE = /^(.*?)(:\d+(?:-\d*)?)?$/;

/** Key of the read-group node a shelf describes for the run starting at `firstId`. */
export function readGroupKey(firstId: string): string {
	return stableKey(`reads:${firstId}`);
}

/**
 * Consecutive reads as one inline `tool` (omp's `ReadToolGroupComponent`,
 * §7.3 read group): `Read 3 files` over one 22px file row per read (dim dir,
 * strong name, quiet range, linked to the read offset). Open, each read's
 * numbered content follows as a section.
 */
export function nativeReadGroup(
	reads: readonly GroupedRead[],
	expanded: boolean,
	context?: DescribeContext,
): NativeNode {
	const rows: NativeChild[] = [];
	const previews: NativeChild[] = [];
	let failed = 0;
	for (const { block, view } of reads) {
		const read = nativeToolView(block, view, { expanded, elapsedMs: undefined, context });
		const target = typeof read.tool?.target === "string" ? read.tool.target : "…";
		const [, path = target, range] = TARGET_RANGE.exec(target) ?? [];
		const meta = read.tool?.meta?.at(-1);
		const gist = typeof meta === "string" ? meta : meta?.map((s) => s.t).join("");
		const error = view.state === "error";
		if (error) failed++;
		rows.push(
			fileRow(path, {
				range,
				href: read.tool?.href,
				icon: error ? "x-circle" : undefined,
				tone: error ? "error" : undefined,
				detail: error && gist ? [span(gist, "error")] : undefined,
				key: block.id,
			}),
		);
		if (expanded && !error && read.body && read.body.length > 0) {
			previews.push(node("section", { head: [span(target, "path")] }, read.body, `p:${block.id}`));
		}
	}
	const body = [...rows, ...previews];
	return node(
		"tool",
		{
			role: "omp.tool.read",
			name: "read",
			title: "Read",
			target: `${reads.length} files`,
			targetKind: "text",
			meta: failed > 0 ? [`${failed} failed`] : undefined,
			status: failed === reads.length ? "error" : "done",
			tone: failed === reads.length ? "error" : undefined,
			frame: "inline",
			collapsible: true,
			collapsed: !expanded,
			preview: { lines: reads.length + 1 },
		},
		body,
		readGroupKey(reads[0]!.block.id),
	);
}
