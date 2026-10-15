import { describeOmpError, ompUnavailableReason, syncOmp } from "../../commands/omp.ts";
import { ompSessionLabel } from "../../formatters/omp.ts";
import type { ControlPlaneClient } from "../../protocol/client.ts";
import { type ControlPlaneMethods, METHOD } from "../../protocol/methods.ts";
import {
	isOmpSessionBusy,
	OMP_MESSAGE_MAX_BYTES,
	type OmpDiscoveredSession,
	type OmpSendMode,
	type OmpSession,
	parseOmpSessionEvent,
} from "../../protocol/omp.ts";
import type { OmpStore } from "../../store/omp-store.ts";
import type { NoticeLevel } from "../../store/transcript-model.ts";
import { OmpPanelComponent } from "../components/omp-panel.ts";

/** Discovery rows asked for per scan (the server allows up to 100). */
const DISCOVER_LIMIT = 30;

export interface OmpControllerOptions {
	store: OmpStore;
	methods: ControlPlaneMethods;
	client: ControlPlaneClient;
	/** The TUI's working directory: where `/omp run` starts and `d` discovers. */
	cwd: string;
	requestRender: () => void;
	/** Host restores editor focus; Escape also hides the panel. */
	onBlur?: () => void;
	/** Transcript notice for the record of what was asked and what happened. */
	notice: (text: string, level?: NoticeLevel) => void;
	now?: () => number;
	tickMs?: number;
}

/**
 * Keeps the omp store in step with the daemon and drives the panel.
 *
 * Sync: `omp.status` + `omp.sessions.list` on every handshake (first connect
 * and each reconnect), on panel open and on `r`; live `omp.session` events
 * upsert in between. Mutations (send, cancel, close, resume) are sent only to
 * a connected daemon and report their actual outcome in the panel and the
 * transcript — a refusal or a timeout is never shown as success.
 */
export class OmpController {
	readonly panel: OmpPanelComponent;
	readonly #options: OmpControllerOptions;
	readonly #disposers: Array<() => void> = [];
	#timer: NodeJS.Timeout | undefined;
	#discoverGeneration = 0;
	#disposed = false;

	constructor(options: OmpControllerOptions) {
		this.#options = options;
		this.panel = new OmpPanelComponent({
			requestRender: options.requestRender,
			now: options.now,
			onBlur: () => {
				this.setVisible(false);
				options.onBlur?.();
			},
			onSend: (session, mode, message) => this.send(session, mode, message),
			onCancel: (session) => void this.cancel(session),
			onClose: (session) => void this.close(session),
			onRefresh: () => void this.refresh(true),
			onDiscover: () => void this.discover(),
			onResume: (row) => void this.resume(row),
			onContinue: (row) => void this.resume(row, true),
		});
	}

	attach(): void {
		const { client, store } = this.#options;
		this.#disposers.push(
			client.events.on("hello-ok", () => void this.refresh(false)),
			client.events.on("omp.session", (payload) => this.ingest(payload)),
			store.events.on("changed", () => this.#present()),
		);
		this.#present();
	}

	dispose(): void {
		this.#disposed = true;
		for (const dispose of this.#disposers.splice(0)) dispose();
		this.#stopTicker();
		this.panel.setVisible(false);
	}

	/** Apply one `omp.session` event payload. Malformed payloads are ignored. */
	ingest(payload: unknown): boolean {
		if (this.#disposed) return false;
		const event = parseOmpSessionEvent(payload);
		return event ? this.#options.store.upsert(event.session) : false;
	}

	/** Returns the new visibility; the host focuses the panel when it opens. */
	toggle(): boolean {
		this.setVisible(!this.panel.visible);
		return this.panel.visible;
	}

	setVisible(visible: boolean): void {
		if (this.#disposed) return;
		const opening = visible && !this.panel.visible;
		this.panel.setVisible(visible);
		if (opening) {
			this.panel.setFlash(undefined);
			void this.refresh(false);
		}
		this.#present();
	}

	/**
	 * Re-read status and sessions. A failed read is shown in the panel (and,
	 * when the user asked for it, the transcript); the store keeps its last
	 * known state rather than pretending the daemon reported nothing. A
	 * background refresh never overwrites a message that arrived while it ran.
	 */
	async refresh(requested: boolean): Promise<void> {
		const { methods, store } = this.#options;
		const flashBefore = this.panel.flash;
		const problem = await syncOmp(methods, store);
		if (this.#disposed) return;
		const quiet = !requested && this.panel.flash !== flashBefore;
		if (problem) {
			if (!quiet) this.panel.setFlash({ text: `refresh failed: ${problem}`, level: "warning" });
			if (requested) this.#options.notice(`omp refresh failed: ${problem}`, "warning");
		} else if (requested) {
			this.panel.setFlash({ text: "refreshed", level: "info" });
		}
		this.#present();
	}

	async send(session: OmpSession, mode: OmpSendMode, message: string): Promise<boolean> {
		const verb = mode === "steer" ? "steer" : mode === "redirect" ? "redirect" : "follow-up";
		if (Buffer.byteLength(message, "utf8") > OMP_MESSAGE_MAX_BYTES) {
			this.#report(`${verb} not sent: message exceeds 16 KiB`, "warning");
			return false;
		}
		if (!this.#ready(METHOD.ompSessionsSend, verb)) return false;
		try {
			const { delivery } = await this.#options.methods.ompSessionsSend({
				id: session.id,
				message,
				mode,
			});
			const as = delivery && delivery !== mode ? ` (delivered as ${delivery})` : "";
			this.#report(`${verb} accepted by ${session.id}${as}`, "info");
			return true;
		} catch (error) {
			this.#report(`${verb} to ${session.id} failed: ${describeOmpError(error)}`, "error");
			return false;
		}
	}

	async cancel(session: OmpSession): Promise<void> {
		if (!isOmpSessionBusy(session)) {
			this.panel.setFlash({
				text: `${session.id} has no running turn to cancel`,
				level: "warning",
			});
			return;
		}
		if (!this.#ready(METHOD.ompSessionsCancel, "cancel")) return;
		try {
			const { cancelled } = await this.#options.methods.ompSessionsCancel({ id: session.id });
			if (cancelled) this.#report(`cancelled the running turn of ${session.id}`, "info");
			else this.#report(`${session.id} did not confirm cancellation; refresh to check`, "warning");
		} catch (error) {
			this.#report(`cancel ${session.id} failed: ${describeOmpError(error)}`, "error");
		}
	}

	async close(session: OmpSession): Promise<void> {
		if (!this.#ready(METHOD.ompSessionsClose, "close")) return;
		try {
			const { session: closed } = await this.#options.methods.ompSessionsClose({ id: session.id });
			this.#options.store.upsert(closed);
			this.#report(`closed ${session.id}; its omp session stays resumable (d)`, "info");
		} catch (error) {
			this.#report(`close ${session.id} failed: ${describeOmpError(error)}`, "error");
		}
	}

	/** Scan omp session files for the TUI's working directory. Read-only. */
	async discover(): Promise<void> {
		const { methods, cwd } = this.#options;
		if (!methods.supports(METHOD.ompSessionsDiscover)) {
			this.panel.setFlash({
				text: `daemon does not support ${METHOD.ompSessionsDiscover}`,
				level: "warning",
			});
			return;
		}
		const generation = ++this.#discoverGeneration;
		this.panel.setDiscover({ cwd, rows: [], loading: true });
		try {
			const { sessions } = await methods.ompSessionsDiscover({ cwd, limit: DISCOVER_LIMIT });
			if (generation !== this.#discoverGeneration || this.panel.mode !== "discover") return;
			this.panel.setDiscover({ cwd, rows: sessions, loading: false });
		} catch (error) {
			if (generation !== this.#discoverGeneration || this.panel.mode !== "discover") return;
			this.panel.setDiscover({ cwd, rows: [], loading: false, error: describeOmpError(error) });
		}
	}

	/** Resume a discovered omp session in the TUI's working directory. */
	async resume(row: OmpDiscoveredSession, continueInterrupted = false): Promise<void> {
		if (row.liveId) {
			this.panel.setFlash({
				text: `already live as ${row.liveId} — select it in the list instead`,
				level: "warning",
			});
			return;
		}
		if (!this.#ready(METHOD.ompSessionsResume, "resume")) return;
		this.panel.setFlash({ text: `resuming ${row.ompSessionId}…`, level: "info" });
		try {
			const { session } = await this.#options.methods.ompSessionsResume({
				ompSessionId: row.ompSessionId,
				cwd: this.#options.cwd,
				...(continueInterrupted ? { continue: true } : {}),
			});
			this.#options.store.upsert(session);
			this.panel.setDiscover(undefined);
			this.#report(`resumed ${ompSessionLabel(session)} as ${session.id}`, "info");
		} catch (error) {
			this.#report(`resume ${row.ompSessionId} failed: ${describeOmpError(error)}`, "error");
		}
	}

	/** A mutation is only attempted against a connected daemon that advertises it. */
	#ready(method: string, verb: string): boolean {
		const { methods, client, store } = this.#options;
		if (!methods.supports(method)) {
			this.#report(`${verb} unavailable: daemon does not support ${method}`, "warning");
			return false;
		}
		const unavailable = ompUnavailableReason(methods, store);
		if (unavailable) {
			this.#report(`${verb} unavailable: ${unavailable}`, "warning");
			return false;
		}
		if (!client.online) {
			this.#report(`offline — ${verb} not sent; reconnect and retry`, "warning");
			return false;
		}
		return true;
	}

	#report(text: string, level: NoticeLevel): void {
		this.panel.setFlash({ text, level });
		this.#options.notice(`omp: ${text}`, level);
	}

	#present(): void {
		if (this.#disposed) return;
		const { store, methods } = this.#options;
		this.panel.setUnavailable(ompUnavailableReason(methods, store));
		this.panel.update(store.sessions());
		const ticking = this.panel.visible && store.busyCount() > 0;
		if (ticking && this.#timer === undefined) {
			this.#timer = setInterval(this.#options.requestRender, this.#options.tickMs ?? 1000);
			this.#timer.unref?.();
		} else if (!ticking) {
			this.#stopTicker();
		}
		this.#options.requestRender();
	}

	#stopTicker(): void {
		if (this.#timer === undefined) return;
		clearInterval(this.#timer);
		this.#timer = undefined;
	}
}
