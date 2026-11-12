import { expect, test } from "bun:test";
import {
	encodeProgramStatusMessage,
	isCardTitle,
	sessionTerminalTitle,
} from "../src/terminal/signals.ts";

const decode = (text: string | undefined) => Buffer.from(text ?? "", "base64").toString("utf8");

test("program status messages flatten whitespace and remove ANSI, controls and lone surrogates", () => {
	expect(
		decode(
			encodeProgramStatusMessage(
				"  Which\n\tbranch?\r\n\x1b[31mRed\x1b[0m\x07\x00\x7f\x85\ud800  ",
			),
		),
	).toBe("Which branch? Red");
	expect(encodeProgramStatusMessage(undefined)).toBeUndefined();
	expect(encodeProgramStatusMessage(" \n\t\x07\x1b[0m")).toBeUndefined();
});

test.each(["é", "界", "🍋"])(
	"program status truncates %s on a UTF-8 boundary with omp's ellipsis",
	(char) => {
		const exact = `${"a".repeat(2048 - Buffer.byteLength(char))}${char}`;
		expect(decode(encodeProgramStatusMessage(exact))).toBe(exact);
		const decoded = decode(encodeProgramStatusMessage(char.repeat(2048)));
		const count = Math.floor(2045 / Buffer.byteLength(char));
		expect(decoded).toBe(`${char.repeat(count)}…`);
		expect(Buffer.byteLength(decoded)).toBeLessThanOrEqual(2048);
		expect(decoded).not.toContain("\ufffd");
	},
);

test.each([
	["🍋 LEMON: Fix the build", true],
	["🧑‍💻 A1: Work", true],
	["\ue0b0 CODE99: Nerd Font", true],
	[`${"🍋".repeat(8)} Z: Eight codepoints`, true],
	[`${"🍋".repeat(9)} Z: Too many codepoints`, false],
	["L LEMON: ASCII icon", false],
	["🍋a LEMON: Mixed icon", false],
	["#️⃣ KEY: ASCII keycap", false],
	["🍋 lower: Lowercase code", false],
	["🍋 TOOLONG: Long code", false],
	["🍋 A_B: Punctuation code", false],
	["🍋 : Missing code", false],
	["🍋 OK: ", false],
	["🍋 OK:  Leading space", false],
	["🍋 OK:Title", false],
	["🍋 OK: Multi\nline", false],
] as const)("card title %s is valid: %s", (title, expected) => {
	expect(isCardTitle(title)).toBe(expected);
});

test("Tern keeps card titles verbatim and delegates run state to program status", () => {
	for (const status of ["ready", "working", "approval needed", "question waiting", "offline"]) {
		expect(sessionTerminalTitle("🧪 FLAKY: Repair tests", status, true)).toBe(
			"🧪 FLAKY: Repair tests",
		);
		expect(sessionTerminalTitle("Repair tests", status, true)).toBe("🍋 LEMON: Repair tests");
		expect(sessionTerminalTitle("session-key", status, false)).toBe(
			`Lemon · session-key · ${status}`,
		);
	}
	expect(sessionTerminalTitle("🍋 lower: Invalid card", "working", true)).toBe(
		"🍋 LEMON: 🍋 lower: Invalid card",
	);
	expect(sessionTerminalTitle("🧪 FLAKY: Repair tests", "ready", false)).toBe(
		"Lemon · 🧪 FLAKY: Repair tests · ready",
	);
	expect(sessionTerminalTitle("title\x07\x1b", "ready", true)).toBe("🍋 LEMON: title");
});
