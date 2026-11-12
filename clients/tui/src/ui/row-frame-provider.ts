import type {
	DescribeContext,
	NativeSurface,
	NativeSurfaceProvider,
} from "@oh-my-pi/pi-tui/native/node";
import type {
	Component,
	HistoryBatch,
	TerminalFramePlan,
	TerminalFrameProvider,
	TUI,
	ViewportSize,
} from "@oh-my-pi/pi-tui/tui";
import { Container } from "@oh-my-pi/pi-tui/tui";
import type { TranscriptContainer } from "./components/transcript-container.ts";

interface OfferedHistory {
	batch: HistoryBatch;
	width: number;
	transcriptId?: number;
	header?: readonly string[];
}

/** Animated chrome (the banner's intro) stays live until it settles: retired rows are frozen. */
function isSettled(component: Component): boolean {
	const block = component as Component & { isTranscriptBlockFinalized?(): boolean };
	if (block.isTranscriptBlockFinalized?.() === false) return false;
	return !(component instanceof Container) || component.children.every(isSettled);
}

/** Owns Lemon's main/dock layout and the terminal's monotonic history id space. */
export class RowFrameProvider implements TerminalFrameProvider, NativeSurfaceProvider {
	readonly #transcript: TranscriptContainer;
	readonly #main: readonly Component[];
	readonly #dock: readonly Component[];
	readonly #tui: Pick<TUI, "hasProviderHistory" | "getFilledHistoryRows"> | undefined;
	#generation: number;
	#nextId = 1;
	#offered: OfferedHistory | undefined;
	#headerRetired = false;
	#replay = false;
	#replayRequested = false;
	#flush = false;
	#dockFloor: number | undefined;
	#surface: NativeSurface = { main: [], dock: [] };

	constructor(
		transcript: TranscriptContainer,
		main: readonly Component[],
		dock: readonly Component[],
		tui?: Pick<TUI, "hasProviderHistory" | "getFilledHistoryRows">,
	) {
		this.#transcript = transcript;
		this.#main = main;
		this.#dock = dock;
		this.#tui = tui;
		this.#generation = transcript.generation;
	}

	renderFrame(size: ViewportSize): TerminalFramePlan {
		this.#syncReset();
		const width = Math.max(1, size.columns);
		const height = Math.max(0, size.rows);
		if (height === 0) return { viewport: [] };
		const dock = this.#renderRoots(this.#dock, width);
		// A temporary approval, queue or tall draft must not retire the rows it
		// covers. They refill the screen when the dock shrinks again.
		this.#dockFloor = Math.min(this.#dockFloor ?? dock.length, dock.length);
		const capacity = Math.max(0, height - this.#dockFloor);
		const now = performance.now();
		const frame = { now, tick: Math.floor(now / 80) };
		this.#transcript.beginFrame(frame);
		const history = this.#offer(width, capacity);
		const header =
			this.#headerRetired || this.#offered?.header !== undefined
				? []
				: this.#renderRoots(this.#main, width);
		const live = this.#transcript.renderViewport(
			width,
			Math.max(0, capacity - header.length),
			frame,
		);
		const viewport = [...header, ...live, ...dock].slice(-height);
		// Once history has scrolled away it cannot be pulled back into the
		// mutable viewport. Keep input bottom-aligned after a dock collapse.
		const filled =
			history?.kind !== "replay" && (history || this.#tui?.hasProviderHistory())
				? this.#tui?.getFilledHistoryRows()
				: undefined;
		if (filled !== undefined) {
			const padding = Math.max(
				0,
				height - Math.min(height, filled + (history?.rows.length ?? 0)) - viewport.length,
			);
			if (padding > 0) viewport.unshift(...Array<string>(padding).fill(""));
		}
		return { history, viewport };
	}

	acknowledgeHistory(id: number): void {
		this.#syncReset();
		const offered = this.#offered;
		if (offered === undefined || offered.batch.id !== id) return;
		if (offered.transcriptId !== undefined) {
			this.#transcript.acknowledgeFinalizedBatch(offered.transcriptId);
		}
		if (offered.header !== undefined) {
			this.#headerRetired = true;
		}
		this.#offered = undefined;
		if (this.#replayRequested) {
			this.#replayRequested = false;
			this.beginHistoryReplay();
		}
	}

	beginHistoryReplay(): void {
		this.#syncReset();
		if (this.#offered !== undefined) {
			this.#replayRequested = true;
			return;
		}
		this.#replay = true;
		this.#transcript.beginReplay();
	}

	beginHistoryFlush(): void {
		this.#syncReset();
		this.#flush = true;
		this.#replay = false;
		this.#replayRequested = false;
		this.#transcript.cancelReplay();
	}

	/** Resize/overlay previews never advance the acknowledgement ledger. */
	renderResizeFrame(size: ViewportSize): readonly string[] {
		const width = Math.max(1, size.columns);
		const height = Math.max(0, size.rows);
		if (height === 0) return [];
		const dock = this.#renderRoots(this.#dock, width);
		const tail = this.#transcript.renderTail(width, Math.max(0, height - dock.length));
		const header = tail.length + dock.length < height ? this.#renderRoots(this.#main, width) : [];
		return [...header, ...tail, ...dock].slice(-height);
	}

	/** TSP owns its whole document; ANSI retirement never removes native nodes. */
	describeSurface(_cx: DescribeContext): NativeSurface {
		const blocks = this.#transcript.nativeBlocks();
		const main = this.#surface.main;
		if (
			main.length !== this.#main.length + blocks.length ||
			this.#main.some((child, index) => main[index] !== child) ||
			blocks.some((child, index) => main[this.#main.length + index] !== child)
		) {
			this.#surface = { main: [...this.#main, ...blocks], dock: this.#dock };
		} else if (this.#surface.dock !== this.#dock) {
			this.#surface = { main, dock: this.#dock };
		}
		return this.#surface;
	}

	#offer(width: number, capacity: number): HistoryBatch | undefined {
		if (this.#offered !== undefined) {
			const offered = this.#offered;
			// A discarded frame may be offered at a new width before acceptance.
			// Preserve its logical cut and id, never retire it speculatively.
			if (offered.width !== width) {
				const transcript =
					offered.transcriptId === undefined
						? undefined
						: this.#transcript.rerenderOfferedBatch(width);
				const header = offered.header === undefined ? [] : this.#renderRoots(this.#main, width);
				if (offered.header !== undefined) offered.header = header;
				offered.batch = { ...offered.batch, rows: [...header, ...(transcript?.rows ?? [])] };
				offered.width = width;
			}
			return offered.batch;
		}
		if (this.#replay) {
			this.#replay = false;
			const transcript = this.#transcript.peekReplayBatch(width);
			const header = this.#headerRetired ? this.#renderRoots(this.#main, width) : undefined;
			const rows = [...(header ?? []), ...(transcript?.rows ?? [])];
			if (rows.length > 0) {
				const batch: HistoryBatch = { id: this.#nextId++, rows, kind: "replay" };
				this.#offered = { batch, width, transcriptId: transcript?.id, header };
				return batch;
			}
		}
		if (!this.#headerRetired) {
			const header = this.#renderRoots(this.#main, width);
			if (header.length > 0) {
				if (
					!this.#flush &&
					(!this.#main.every(isSettled) ||
						header.length + this.#transcript.liveRowCount(width, capacity - header.length) <=
							capacity)
				) {
					return undefined;
				}
				const batch: HistoryBatch = { id: this.#nextId++, rows: header };
				this.#offered = { batch, width, header };
				return batch;
			}
			this.#headerRetired = true;
		}
		const transcript = this.#flush
			? this.#transcript.peekFlushBatch(width)
			: this.#transcript.peekFinalizedBatch(width, capacity);
		if (transcript === undefined) {
			this.#flush = false;
			return undefined;
		}
		const batch: HistoryBatch = { ...transcript, id: this.#nextId++ };
		this.#offered = { batch, width, transcriptId: transcript.id };
		return batch;
	}

	#syncReset(): void {
		if (this.#generation === this.#transcript.generation) return;
		this.#generation = this.#transcript.generation;
		this.#offered = undefined;
		this.#headerRetired = false;
		this.#replay = false;
		this.#replayRequested = false;
		this.#flush = false;
	}

	#renderRoots(roots: readonly Component[], width: number): string[] {
		const rows: string[] = [];
		for (const root of roots) rows.push(...root.render(width));
		return rows;
	}
}
