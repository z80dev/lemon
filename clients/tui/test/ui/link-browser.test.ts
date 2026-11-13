import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { Markdown } from "@oh-my-pi/pi-tui/components/markdown";
import {
	extensionLinkLabels,
	extensionLinksVersion,
} from "@oh-my-pi/pi-tui/render/extension-links";
import { TERMINAL } from "@oh-my-pi/pi-tui/terminal-capabilities";
import { TUI } from "@oh-my-pi/pi-tui/tui";
import type { Block } from "../../src/store/transcript-model.ts";
import { LinkBrowserOverlay } from "../../src/ui/link-browser.ts";
import { linkTargets, rowLinkLabels } from "../../src/ui/link-hints.ts";
import { getMarkdownTheme } from "../../src/ui/theme/tui-adapters.ts";
import { blocksToTranscriptEntries } from "../../src/ui/transcript-entries.ts";
import { MemoryTerminal } from "../helpers/memory-terminal.ts";

const OPEN = (uri: string, params = "") => `\x1b]8;${params};${uri}\x07`;
const CLOSE = "\x1b]8;;\x07";
const link = (label: string, uri: string, params = "") => `${OPEN(uri, params)}${label}${CLOSE}`;
const urls = (rows: string[], width?: number) => linkTargets(rows, width).map((t) => t.url);

describe("rowLinkLabels", () => {
	test("finds http, https and file hyperlinks with their cells", () => {
		const row = `a ${link("one", "http://example.com/a")} ${link("two", "https://example.com/b")} ${link("three", "file:///tmp/a%20b.ts#L4")}`;
		expect(rowLinkLabels(row).map(({ url, start, end }) => ({ url, start, end }))).toEqual([
			{ url: "http://example.com/a", start: 2, end: 5 },
			{ url: "https://example.com/b", start: 6, end: 9 },
			{ url: "file:///tmp/a%20b.ts#L4", start: 10, end: 15 },
		]);
	});

	test("accepts the ST terminator", () => {
		const row = `\x1b]8;;https://example.com\x1b\\x\x1b]8;;\x1b\\`;
		expect(rowLinkLabels(row).map((l) => l.url)).toEqual(["https://example.com"]);
	});

	test("ignores every other scheme", () => {
		for (const uri of [
			"javascript:alert(1)",
			"vscode://file/etc/passwd",
			"ssh://host",
			"mailto:a@b.c",
		]) {
			expect(rowLinkLabels(link("x", uri))).toEqual([]);
		}
		expect(rowLinkLabels("plain row")).toEqual([]);
	});

	test("wraps a bare URL and leaves trailing punctuation outside it", () => {
		expect(rowLinkLabels("see https://example.org/x.")).toEqual([
			{ url: "https://example.org/x", id: expect.any(String), start: 4, end: 25, endsRow: false },
		]);
	});

	test("an unbalanced closing bracket is not part of the URL, a balanced one is", () => {
		expect(urls(["(see https://example.org/a)"])).toEqual(["https://example.org/a"]);
		expect(urls(["https://example.org/a_(b)"])).toEqual(["https://example.org/a_(b)"]);
	});

	test("styled URL text keeps its escapes and cells", () => {
		const row = "\x1b[34mhttps://example.org/\x1b[1mpath\x1b[0m tail";
		expect(rowLinkLabels(row).map(({ url, start, end }) => ({ url, start, end }))).toEqual([
			{ url: "https://example.org/path", start: 0, end: 24 },
		]);
	});

	test("text inside an existing hyperlink is not linked twice", () => {
		const row = link("https://example.org/shown", "https://example.org/target");
		expect(urls([row])).toEqual(["https://example.org/target"]);
	});

	test("a URL that runs to the last cell may be wrapped and is skipped", () => {
		const row = "go https://example.org/very-long";
		expect(urls([row], row.length)).toEqual([]);
		expect(urls([row], row.length + 10)).toEqual(["https://example.org/very-long"]);
	});

	test("non-http schemes in plain text are never linked", () => {
		expect(urls(["javascript://x ftp://example.org file:///etc/passwd"])).toEqual([]);
	});
});

describe("linkTargets", () => {
	test("lists OSC 8 and plain links in reading order with their cells", () => {
		const rows = [
			`open ${link("docs", "https://example.com/docs")} or https://example.org/x.`,
			"nothing here",
			`edit ${link("a.ts", "file:///work/a.ts#L9")}`,
		];
		expect(linkTargets(rows).map(({ url, row, start }) => ({ url, row, start }))).toEqual([
			{ url: "https://example.com/docs", row: 0, start: 5 },
			{ url: "https://example.org/x", row: 0, start: 13 },
			{ url: "file:///work/a.ts#L9", row: 2, start: 5 },
		]);
	});

	test("a hyperlink wrapped across rows is one link at its first row", () => {
		const uri = "https://example.com/long";
		const rows = [link("https://exa", uri, "id=w"), link("mple.com/long", uri, "id=w")];
		expect(linkTargets(rows).map(({ url, row, start }) => ({ url, row, start }))).toEqual([
			{ url: uri, row: 0, start: 0 },
		]);
	});

	test("markdown's linked text plus linked `(url)` copy is one link", () => {
		const uri = "https://example.com/docs";
		const row = `${link("docs", uri)} ${link(`(${uri})`, uri)}`;
		expect(urls([row])).toEqual([uri]);
	});

	test("unsupported schemes are not listed", () => {
		expect(urls([link("x", "javascript:alert(1)"), link("y", "vscode://x")])).toEqual([]);
	});
});

describe("LinkBrowserOverlay", () => {
	// Markdown only draws OSC 8 hyperlinks where the terminal supports them.
	let hyperlinks: boolean;
	beforeEach(() => {
		hyperlinks = TERMINAL.hyperlinks;
		TERMINAL.hyperlinks = true;
	});
	afterEach(() => {
		TERMINAL.hyperlinks = hyperlinks;
	});

	const blocks: Block[] = [
		{ id: "user-1", kind: "user", at: 1, text: "where are the docs?" },
		{
			id: "asst-1",
			kind: "assistant",
			at: 2,
			runId: "run-1",
			status: "done",
			text: "Read [docs](https://example.com/docs) first.",
		},
	];

	function open(entries = blocksToTranscriptEntries(blocks)) {
		const terminal = new MemoryTerminal();
		const tui = new TUI(terminal);
		const activated: string[] = [];
		let closed = 0;
		const overlay = new LinkBrowserOverlay(entries, {
			ui: tui,
			cwd: process.cwd(),
			requestRender: () => {},
			onActivate: (url) => activated.push(url),
			onClose: () => {
				closed += 1;
			},
		});
		return { overlay, activated, closed: () => closed };
	}

	test("finds transcript links, tags them, and typing the tag activates the link", () => {
		const { overlay, activated } = open();
		try {
			expect(overlay.hasLinks(80)).toBe(true);
			const frame = overlay.render(80).join("\n");
			expect(Bun.stripANSI(frame)).toContain("docs");
			// A lone label's tag is its own first letter.
			overlay.handleInput("d");
			expect(activated).toEqual(["https://example.com/docs"]);
		} finally {
			overlay.dispose();
		}
	});

	test("Esc closes and other keys do not activate", () => {
		const { overlay, activated, closed } = open();
		try {
			overlay.render(80);
			overlay.handleInput("z");
			expect(activated).toEqual([]);
			overlay.handleInput("\x1b");
			expect(closed()).toBe(1);
		} finally {
			overlay.dispose();
		}
	});

	test("a transcript without links reports none", () => {
		const { overlay } = open(blocksToTranscriptEntries([blocks[0]!]));
		try {
			expect(overlay.hasLinks(80)).toBe(false);
		} finally {
			overlay.dispose();
		}
	});

	test("keeps no global link state: ordinary markdown renders identically with the browser open", () => {
		const text =
			"See [docs](https://example.com/docs), https://example.org/x and `code`.\n\n- [a](file:///tmp/a.ts)";
		const render = () => new Markdown(text, 1, 0, getMarkdownTheme()).render(60);
		const before = render();
		const version = extensionLinksVersion();
		const { overlay } = open();
		try {
			overlay.render(80);
			expect(render()).toEqual(before);
			expect(extensionLinksVersion()).toBe(version);
			// omp's marker detection stays off: nothing in the rows reads as an extension link.
			expect(before.some((row) => extensionLinkLabels(row).length > 0)).toBe(false);
		} finally {
			overlay.dispose();
		}
		expect(render()).toEqual(before);
		expect(extensionLinksVersion()).toBe(version);
	});
});
