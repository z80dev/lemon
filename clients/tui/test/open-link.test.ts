import { describe, expect, test } from "bun:test";
import { classifyLink, openerCommand, openLink } from "../src/terminal/open-link.ts";

describe("classifyLink allowlist", () => {
	test("http(s) URLs with a host are web links", () => {
		expect(classifyLink("https://example.com/a?b=1#c")).toEqual({
			kind: "web",
			url: "https://example.com/a?b=1#c",
		});
		expect(classifyLink("http://localhost:4040")).toEqual({
			kind: "web",
			url: "http://localhost:4040/",
		});
	});

	test("local file links carry their path and line", () => {
		expect(classifyLink("file:///tmp/a%20b.ts#L12")).toEqual({
			kind: "file",
			path: "/tmp/a b.ts",
			line: 12,
		});
		expect(classifyLink("file://localhost/tmp/a.ts")).toEqual({ kind: "file", path: "/tmp/a.ts" });
		expect(classifyLink("file:///tmp/a.ts#L0")).toEqual({ kind: "file", path: "/tmp/a.ts" });
	});

	test("every other scheme, remote file hosts and malformed links are refused", () => {
		for (const raw of [
			"javascript:alert(1)",
			"data:text/html,<b>",
			"vscode://file/etc/passwd",
			"ssh://host",
			"ftp://example.com",
			"mailto:a@example.com",
			"file://evil.example/share/x",
			"https:///nohost",
			"https://example.com/with space",
			"https://example.com/\x1b]8;;x",
			"not a url",
			"",
			"/just/a/path",
		]) {
			expect(classifyLink(raw)).toBeUndefined();
		}
	});
});

describe("openLink", () => {
	test("opens an allowed URL through the OS opener argv, never a shell", async () => {
		const calls: string[][] = [];
		const result = await openLink("https://example.com/a", {
			platform: "linux",
			spawn: async (argv) => {
				calls.push(argv);
				return 0;
			},
		});
		expect(calls).toEqual([["xdg-open", "https://example.com/a"]]);
		expect(result).toEqual({ ok: true, message: "opened https://example.com/a" });
	});

	test("refused schemes spawn nothing", async () => {
		const calls: string[][] = [];
		const result = await openLink("javascript:alert(1)", {
			spawn: async (argv) => {
				calls.push(argv);
				return 0;
			},
		});
		expect(calls).toEqual([]);
		expect(result.ok).toBe(false);
		expect(result.message).toContain("javascript:");
	});

	test("a file link opens its path only when it exists", async () => {
		const calls: string[][] = [];
		const spawn = async (argv: string[]) => {
			calls.push(argv);
			return 0;
		};
		const missing = await openLink("file:///no/such.ts#L3", {
			platform: "darwin",
			exists: () => false,
			spawn,
		});
		expect(missing).toEqual({ ok: false, message: "no such file: /no/such.ts" });
		expect(calls).toEqual([]);
		const found = await openLink("file:///etc/hosts#L3", {
			platform: "darwin",
			exists: () => true,
			spawn,
		});
		expect(found.ok).toBe(true);
		expect(calls).toEqual([["open", "/etc/hosts"]]);
	});

	test("a failing or missing opener is reported, not thrown", async () => {
		const failed = await openLink("https://example.com", { spawn: async () => 3 });
		expect(failed.ok).toBe(false);
		expect(failed.message).toContain("exited with 3");
		const missing = await openLink("https://example.com", {
			spawn: async () => {
				throw new Error("ENOENT");
			},
		});
		expect(missing.ok).toBe(false);
		expect(missing.message).toContain("could not run");
	});

	test("opener argv per platform", () => {
		expect(openerCommand("https://x.y", "darwin")).toEqual(["open", "https://x.y"]);
		expect(openerCommand("https://x.y", "win32")).toEqual([
			"rundll32",
			"url.dll,FileProtocolHandler",
			"https://x.y",
		]);
		expect(openerCommand("https://x.y", "linux")).toEqual(["xdg-open", "https://x.y"]);
	});
});
