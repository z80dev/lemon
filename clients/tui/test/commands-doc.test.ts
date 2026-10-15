import { expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { cell, renderCommandsDoc } from "../scripts/generate-commands-doc.ts";
import { createCommandRegistry } from "../src/commands/index.ts";
import { LEMON_KEYBINDINGS } from "../src/ui/controllers/input-controller.ts";

test("reference contains every registered command, aliases, args and summary", async () => {
	const doc = await renderCommandsDoc();
	for (const command of createCommandRegistry().list()) {
		expect(doc).toContain(`| /${cell(command.name)} |`);
		expect(doc).toContain(cell(command.summary));
		if (command.usage) expect(doc).toContain(cell(command.usage));
		for (const alias of command.aliases ?? []) expect(doc).toContain(`/${cell(alias)}`);
	}
	expect(doc).toContain("## core");
	expect(doc).toContain("## session-tree");
	for (const binding of Object.values(LEMON_KEYBINDINGS)) {
		expect(doc).toContain(`| ${cell(binding.defaultKeys)} | ${cell(binding.description)} |`);
	}
	expect(doc).toBe(
		await readFile(new URL("../../../docs/user-guide/tui-commands.md", import.meta.url), "utf8"),
	);
});

test("table cells escape Markdown and HTML syntax", () => {
	expect(cell("<id>|`name` &\nnext")).toBe("&lt;id&gt;&#124;&#96;name&#96; &amp; next");
});

test("check rejects stale docs without rewriting them", async () => {
	const target = new URL("../../../docs/user-guide/tui-commands.md", import.meta.url);
	const original = await readFile(target, "utf8");
	try {
		await Bun.write(target, `${original}\nstale\n`);
		const result = Bun.spawnSync(["bun", "scripts/generate-commands-doc.ts", "--check"], {
			cwd: new URL("..", import.meta.url).pathname,
		});
		expect(result.exitCode).toBe(1);
		expect(result.stderr.toString()).toContain("Stale TUI command docs");
		expect(await readFile(target, "utf8")).toBe(`${original}\nstale\n`);
	} finally {
		await Bun.write(target, original);
	}
});
