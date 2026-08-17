/**
 * A command context wired to the fake control plane and a recording host.
 *
 * Commands are pure "read the store, call a method, say something", so this is
 * all a command test needs: what did it send, and what did it say.
 */

import type { CommandContext, CommandHost, PickerSpec } from "../../src/commands/index.ts";
import { createCommandRegistry } from "../../src/commands/index.ts";
import { FakeControlPlane, type FakeControlPlaneOptions } from "../../src/dev/fake-server.ts";
import { ControlPlaneClient } from "../../src/protocol/client.ts";
import { ControlPlaneMethods } from "../../src/protocol/methods.ts";
import type { ChatHistoryMessage } from "../../src/protocol/types.ts";
import { AppStore } from "../../src/store/app-store.ts";
import type { NoticeLevel } from "../../src/store/transcript-model.ts";

export interface RecordedNotice {
	text: string;
	level: NoticeLevel;
}

export class RecordingHost implements CommandHost {
	readonly notices: RecordedNotice[] = [];
	readonly pickers: PickerSpec[] = [];
	readonly exits: number[] = [];
	readonly replays: ChatHistoryMessage[][] = [];
	cleared = 0;
	reconnects = 0;
	statusRefreshes = 0;
	draft = "";
	frames: string[] = [];
	modelPickerOpens = 0;

	notice(text: string, level: NoticeLevel = "info"): void {
		this.notices.push({ text, level });
	}

	noticeBlock(lines: string[], level: NoticeLevel = "info"): void {
		this.notices.push({ text: lines.join("\n"), level });
	}

	clearTranscript(): void {
		this.cleared += 1;
	}

	requestExit(code: number): void {
		this.exits.push(code);
	}

	reconnect(): void {
		this.reconnects += 1;
	}

	refreshStatus(): void {
		this.statusRefreshes += 1;
	}

	getDraft(): string {
		return this.draft;
	}

	setDraft(text: string): void {
		this.draft = text;
	}

	openPicker(spec: PickerSpec): void {
		this.pickers.push(spec);
	}

	closeOverlay(): void {}

	frameLog(): readonly string[] {
		return this.frames;
	}

	replayHistory(messages: ChatHistoryMessage[]): void {
		this.replays.push(messages);
	}

	openModelPicker(): void {
		this.modelPickerOpens += 1;
	}

	/** Every notice body joined, for `toContain` assertions. */
	get text(): string {
		return this.notices.map((notice) => notice.text).join("\n");
	}

	get last(): RecordedNotice | undefined {
		return this.notices[this.notices.length - 1];
	}
}

export interface Harness {
	server: FakeControlPlane;
	client: ControlPlaneClient;
	methods: ControlPlaneMethods;
	store: AppStore;
	host: RecordingHost;
	registry: ReturnType<typeof createCommandRegistry>;
	/** Run a command line through the registry. */
	run(line: string): Promise<boolean>;
	/** A context for calling a command's `run` directly. */
	context(overrides?: Partial<CommandContext>): CommandContext;
	stop(): void;
}

export async function createHarness(
	options: FakeControlPlaneOptions & { sessionKey?: string } = {},
): Promise<Harness> {
	const { sessionKey = "tui-test", ...serverOptions } = options;
	const server = await FakeControlPlane.start(serverOptions);
	const client = new ControlPlaneClient({
		url: server.url,
		socketOptions: { minBackoffMs: 10, maxBackoffMs: 20, jitter: 0 },
	});
	await client.connect();
	const methods = new ControlPlaneMethods(client);
	const store = new AppStore(sessionKey);
	const host = new RecordingHost();
	const registry = createCommandRegistry({
		openExternalEditor: async () => {
			host.notice("external editor opened");
		},
	});

	const base = () => ({ store, session: store.focused, methods, client, ui: host });

	return {
		server,
		client,
		methods,
		store,
		host,
		registry,
		run: (line: string) => registry.dispatch(line, base()),
		context: (overrides: Partial<CommandContext> = {}) => ({
			...base(),
			registry,
			name: "test",
			rest: "",
			...overrides,
		}),
		stop() {
			client.close();
			server.stop();
		},
	};
}
