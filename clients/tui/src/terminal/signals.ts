import { truncateLineBytes } from "@oh-my-pi/pi-tui/tools/streaming-output";
import { sanitizeText } from "@oh-my-pi/pi-utils/sanitize-text";
import { oscText } from "./capabilities.ts";

/** OSC 7501 rejects controls and limits decoded messages to 2048 UTF-8 bytes. */
export function encodeProgramStatusMessage(text: string | undefined): string | undefined {
	if (!text) return undefined;
	const line = sanitizeText(text).replace(/\s+/g, " ").trim();
	if (!line) return undefined;
	return Buffer.from(truncateLineBytes(line, 2048).text).toString("base64");
}

/** Tern's parked-card convention: 1–8 non-ASCII icon codepoints and an uppercase code. */
export function isCardTitle(title: string): boolean {
	const match = /^(\S+) ([A-Z0-9]{1,6}): (\S.*)$/u.exec(title);
	if (!match) return false;
	let codepoints = 0;
	for (const char of match[1]!) {
		if (char.charCodeAt(0) < 0x80 || ++codepoints > 8) return false;
	}
	return codepoints > 0;
}

/** Tern shows run state from OSC 7501, so its card title stays stable. */
export function sessionTerminalTitle(name: string, status: string, tern: boolean): string {
	const label = oscText(name);
	if (!tern) return `Lemon · ${label} · ${status}`;
	return isCardTitle(label) ? label : `🍋 LEMON: ${label}`;
}
