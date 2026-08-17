/**
 * Client-side chatter: reconnects, aborts, send failures. One styled line,
 * finalized from birth.
 */

import { Container } from "@oh-my-pi/pi-tui/tui";
import type { NoticeLevel } from "../../store/transcript-model.ts";
import { getTheme } from "../theme/theme.ts";
import { ClampedText } from "./width-safe.ts";

const SLOT: Record<NoticeLevel, "noticeText" | "warning" | "error"> = {
	info: "noticeText",
	warning: "warning",
	error: "error",
};

export class NoticeComponent extends Container {
	constructor(text: string, level: NoticeLevel = "info") {
		super();
		const theme = getTheme();
		// Word-wraps at the render width, and clamps the rows that pi-tui's fixed
		// padding would otherwise push past it at very narrow widths.
		this.addChild(new ClampedText(theme.fg(SLOT[level], `· ${text}`), 1, 0));
	}
}
