import { expect, test } from "bun:test";
import { copyNotice, copyText } from "../src/terminal/clipboard.ts";

test("OSC 52 and local pbcopy both receive exact text, never shell argv", async () => {
	const writes: string[] = [];
	const calls: Array<{ argv: string[]; text: string }> = [];
	const text = "secret $(touch /tmp/nope)\nπ\x1b]9;injected\x07";
	const result = await copyText(text, {
		write: (sequence) => {
			writes.push(sequence);
		},
		env: {},
		platform: "darwin",
		spawn: async (argv, input) => {
			calls.push({ argv, text: input });
			return true;
		},
	});
	expect(writes).toEqual([`\x1b]52;c;${Buffer.from(text).toString("base64")}\x07`]);
	expect(calls).toEqual([{ argv: ["pbcopy"], text }]);
	expect(result).toEqual({ osc52: true, native: "pbcopy" });
	expect(copyNotice(result)).toContain("OSC 52 (unconfirmed); copied with pbcopy");
	expect(copyNotice(result)).not.toContain(text);
});

test.each(["SSH_TTY", "SSH_CONNECTION"])("%s prevents native clipboard access", async (key) => {
	let spawned = false;
	const result = await copyText("remote", {
		write: () => {},
		env: { [key]: "remote" },
		platform: "darwin",
		spawn: async () => {
			spawned = true;
			return true;
		},
	});
	expect(spawned).toBe(false);
	expect(result).toEqual({ osc52: true });
});

test.each(["wl-copy", "xclip", "xsel"])(
	"Linux selects %s after unavailable alternatives",
	async (winner) => {
		const calls: string[][] = [];
		const result = await copyText("payload", {
			write: () => {},
			env: {},
			platform: "linux",
			spawn: async (argv) => {
				calls.push(argv);
				if (argv[0] === winner) return true;
				if (argv[0] === "wl-copy") throw new Error("not found");
				return false;
			},
		});
		const commands = [
			["wl-copy"],
			["xclip", "-selection", "clipboard"],
			["xsel", "--clipboard", "--input"],
		];
		expect(calls).toEqual(commands.slice(0, commands.findIndex((argv) => argv[0] === winner) + 1));
		expect(result).toEqual({ osc52: true, native: winner });
	},
);

test("native copy still runs after a failed terminal write, and failures stay content-free", async () => {
	const options = {
		write: () => {
			throw new Error("private terminal failure");
		},
		env: {},
		platform: "darwin" as const,
		spawn: async () => true,
	};
	expect(await copyText("private", options)).toEqual({ osc52: false, native: "pbcopy" });
	const result = await copyText("private", { ...options, spawn: async () => false });
	expect(copyNotice(result)).toBe("Clipboard unavailable: no copy path succeeded.");
});
