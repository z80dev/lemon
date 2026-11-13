/**
 * Shared construction for pi-tui's transcript-replay overlays (`/copy`, rewind).
 *
 * Those components draw through pi-tui's own theme singleton, which Lemon's
 * theme setup never initializes (Lemon owns a separate palette), and they build
 * `ChatTranscriptBuilder`s that need a TUI, a working directory and a repaint
 * hook. This is the one place that supplies all three.
 */

import { ensureThemeSync } from "@oh-my-pi/pi-tui/theme/theme";
import type { OverlayHost } from "../commands/registry.ts";

/** What every replay selector takes besides its own callbacks. */
export interface ReplayDeps {
	ui: OverlayHost["tui"];
	cwd: string;
	requestRender: () => void;
}

/** Deps for a replay selector mounted in `host`; initializes pi-tui's theme if nothing has. */
export function replayDeps(host: OverlayHost, cwd: string): ReplayDeps {
	ensureThemeSync();
	return { ui: host.tui, cwd, requestRender: () => host.tui.requestRender() };
}
