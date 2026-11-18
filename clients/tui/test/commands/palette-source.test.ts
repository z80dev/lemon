import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { link, mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import {
	discoverFileCommands,
	discoverPaletteResources,
	type PaletteEntry,
	rankPaletteEntries,
	skillPrompt,
} from "../../src/commands/palette-source.ts";

let root: string;
let cwd: string;
let home: string;

beforeEach(async () => {
	root = await mkdtemp(join(tmpdir(), "lemon-palette-"));
	cwd = join(root, "project");
	home = join(root, "home");
	await gitRepo(cwd);
	await mkdir(home);
});

afterEach(async () => {
	await rm(root, { recursive: true, force: true });
});

/** A genuine repository layout: HEAD file plus objects/ and refs/. */
async function gitRepo(dir: string): Promise<void> {
	await mkdir(join(dir, ".git/objects"), { recursive: true });
	await mkdir(join(dir, ".git/refs"), { recursive: true });
	await writeFile(join(dir, ".git/HEAD"), "ref: refs/heads/main\n");
}

async function fixture(path: string, content: string): Promise<void> {
	await mkdir(dirname(path), { recursive: true });
	await writeFile(path, content);
}

function entry(name: string, aliases: string[], description: string): PaletteEntry {
	return {
		name,
		aliases,
		description,
		value: `command:${name}`,
		label: `/${name}`,
		kind: "command",
		insertText: `/${name}`,
		available: true,
	};
}

describe("fuzzy palette search", () => {
	test("exact alias wins over description; names and descriptions match fuzzily", () => {
		const entries = [
			entry("debug", [], "reasoning log"),
			entry("think", ["reasoning"], "set model effort"),
			entry("reset", [], "forget durable conversation"),
		];
		expect(rankPaletteEntries(entries, "/reasoning")[0].name).toBe("think");
		expect(rankPaletteEntries(entries, "effort").map((item) => item.name)).toContain("think");
		expect(rankPaletteEntries(entries, "frgt").map((item) => item.name)).toContain("reset");
		expect(rankPaletteEntries(entries, "")).toEqual(entries);
	});
});

describe("native resources", () => {
	test("reads real md/txt templates with native project and extension precedence", async () => {
		await fixture(join(cwd, ".lemon/prompts/review.md"), "Review project code");
		await fixture(join(cwd, ".lemon/prompts/review.txt"), "Text shadow");
		await fixture(join(cwd, ".claude/prompts/review.md"), "Claude shadow");
		await fixture(join(home, ".lemon/agent/prompts/review.md"), "Global shadow");
		await fixture(join(home, ".lemon/agent/prompts/explain.txt"), "Explain $1 literally");
		await fixture(join(cwd, ".lemon/prompts/ignored.json"), "not a prompt");
		const result = await discoverPaletteResources({ cwd, home, env: {} });
		expect(result.issues).toEqual([]);
		expect(
			result.entries.filter((item) => item.kind === "template").map((item) => item.insertText),
		).toEqual(["Review project code", "Explain $1 literally"]);
	});

	test("discovers installed skills, nearest ancestor precedence, and genuine read_skill instructions", async () => {
		const nested = join(cwd, "packages/app");
		await mkdir(nested, { recursive: true });
		await fixture(
			join(nested, ".lemon/skill/review/SKILL.md"),
			"---\ndescription: Review local code\n---\nLocal guidance",
		);
		await fixture(join(cwd, ".agents/skills/review/SKILL.md"), "Shadow guidance");
		await fixture(
			join(cwd, ".omp/skills/deploy/SKILL.md"),
			"---\ndescription: >-\n  Deploy a service\n  safely\n---\nSteps",
		);
		await fixture(join(home, ".lemon/agent/skill/global/SKILL.md"), "Global guidance");
		const result = await discoverPaletteResources({ cwd: nested, home, env: {} });
		expect(result.issues).toEqual([]);
		const skills = result.entries.filter((item) => item.kind === "skill");
		expect(skills.map((item) => item.name)).toEqual(["review", "deploy", "global"]);
		expect(skills[0].description).toContain("Review local code");
		expect(skills[1].description).toContain("Deploy a service safely");
		expect(skills[0].insertText).toBe(skillPrompt("review"));
		expect(skills[0].description).toContain("daemon checks readiness");
	});

	test("respects configured isolated agent roots and explicit compatibility overrides", async () => {
		const agentDir = join(root, "custom-agent");
		const ompDir = join(root, "custom-omp");
		await fixture(join(agentDir, "prompts/custom.md"), "Custom prompt");
		await fixture(join(ompDir, "allowed/SKILL.md"), "Configured skill");
		await fixture(join(home, ".omp/agent/skills/hidden/SKILL.md"), "Isolated out");
		const result = await discoverPaletteResources({
			cwd,
			home,
			env: {
				LEMON_AGENT_DIR: agentDir,
				LEMON_OMP_SKILLS_DIR: ompDir,
			},
		});
		expect(result.entries.map((item) => item.name)).toEqual(["custom", "allowed"]);
	});

	test("missing roots are empty but failed discovery is explicitly partial", async () => {
		const empty = await discoverPaletteResources({ cwd, home, env: {} });
		expect(empty).toEqual({ entries: [], issues: [] });
		await fixture(join(cwd, ".lemon/prompts"), "not a directory");
		await fixture(join(cwd, ".lemon/skill/working/SKILL.md"), "Working skill");
		const failed = await discoverPaletteResources({ cwd, home, env: {} });
		expect(failed.issues.join(" ")).toContain("Cannot discover resources");
		expect(failed.entries.map((item) => item.name)).toEqual(["working"]);
	});
});

test("TOML skill descriptions follow the native manifest convention", async () => {
	await fixture(
		join(cwd, ".lemon/skill/toml/SKILL.md"),
		'+++\ndescription = "Review TOML configuration"\n+++\nInstructions',
	);
	const result = await discoverPaletteResources({ cwd, home, env: {} });
	expect(result.entries[0].description).toContain("Review TOML configuration");
});

test("codex and github skill roots follow claude, with the codex user override", async () => {
	await fixture(join(cwd, ".github/skills/shared/SKILL.md"), "GitHub shadow");
	await fixture(join(cwd, ".codex/skills/shared/SKILL.md"), "Codex wins");
	await fixture(join(cwd, ".github/skills/gh-only/SKILL.md"), "GitHub skill");
	await fixture(join(home, ".codex/skills/user-codex/SKILL.md"), "User codex");
	const result = await discoverPaletteResources({ cwd, home, env: {} });
	expect(result.entries.map((item) => [item.name, item.description?.split(" · ")[0]])).toEqual([
		["shared", "Codex wins"],
		["gh-only", "GitHub skill"],
		["user-codex", "User codex"],
	]);

	const override = join(root, "codex-override");
	await fixture(join(override, "pinned/SKILL.md"), "Pinned");
	const isolated = await discoverPaletteResources({
		cwd,
		home,
		env: { LEMON_AGENT_DIR: join(root, "agent"), LEMON_CODEX_SKILLS_DIR: override },
	});
	expect(isolated.entries.map((item) => item.name)).toEqual(["shared", "gh-only", "pinned"]);
});

describe("file commands", () => {
	test("mirror every CodingAgent.Commands root, format and name rule", async () => {
		await fixture(join(cwd, ".lemon/command/legacy.md"), "legacy");
		await fixture(join(cwd, ".lemon/commands/native.md"), "native");
		await fixture(join(cwd, ".omp/commands/omp-cmd.md"), "omp");
		await fixture(join(cwd, ".agents/commands/agents-cmd.md"), "agents");
		await fixture(join(cwd, ".agent/commands/agent-cmd.md"), "agent");
		await fixture(join(cwd, ".claude/commands/git/commit.md"), "nested");
		await fixture(join(cwd, ".codex/prompts/codex-prompt.md"), "codex");
		await fixture(join(cwd, ".codex/commands/codex-cmd.md"), "codex");
		await fixture(join(cwd, ".github/prompts/review.prompt.md"), "github");
		await fixture(join(cwd, ".github/prompts/README.md"), "not a prompt file");
		await fixture(
			join(cwd, ".gemini/commands/team/explain.toml"),
			'description = "Explain code"\nprompt = "Explain {{args}}"',
		);
		await fixture(join(cwd, ".gemini/commands/broken.toml"), 'description = "no prompt"');
		await fixture(join(cwd, ".omp/commands/sub/flat-only.md"), "not recursive");
		await fixture(join(cwd, ".lemon/commands/two words.md"), "unreachable");
		await fixture(join(cwd, ".lemon/commands/huge.md"), "x".repeat(64 * 1024 + 1));
		await fixture(join(home, ".claude/commands/user-claude.md"), "user");
		await fixture(join(home, ".gemini/commands/user-gemini.toml"), 'prompt = "user"');
		await fixture(join(home, ".lemon/agent/commands/user-lemon.md"), "user");
		const result = await discoverFileCommands({ cwd, home, env: {} });
		expect(result.issues).toEqual([]);
		expect(result.commands.map((command) => [command.name, command.source, command.scope])).toEqual(
			[
				["agent-cmd", "agents", "project"],
				["agents-cmd", "agents", "project"],
				["codex-cmd", "codex", "project"],
				["codex-prompt", "codex", "project"],
				["git:commit", "claude", "project"],
				["legacy", "lemon", "project"],
				["native", "lemon", "project"],
				["omp-cmd", "omp", "project"],
				["review", "github", "project"],
				["team:explain", "gemini", "project"],
				["user-claude", "claude", "global"],
				["user-gemini", "gemini", "global"],
				["user-lemon", "lemon", "global"],
			],
		);
		expect(result.commands.find((command) => command.name === "team:explain")?.description).toBe(
			"Explain code",
		);
	});

	test("project beats global and Lemon beats other tools", async () => {
		await fixture(join(home, ".lemon/agent/commands/ship.md"), "global lemon");
		await fixture(join(cwd, ".gemini/commands/ship.toml"), 'prompt = "project gemini"');
		await fixture(
			join(cwd, ".claude/commands/ship.md"),
			'---\r\ndescription: "Ship it"\r\nargument-hint: [version]\r\n---\r\nShip $1',
		);
		const claude = await discoverFileCommands({ cwd, home, env: {} });
		expect(claude.commands).toMatchObject([
			{ name: "ship", source: "claude", description: "Ship it", argumentHint: "[version]" },
		]);
		await fixture(join(cwd, ".omp/commands/ship.md"), "---\ndescription: OMP ship\n---\nbody");
		await fixture(join(cwd, ".lemon/commands/ship.md"), "---\ndescription: Lemon ship\n---\nbody");
		const lemon = await discoverFileCommands({ cwd, home, env: {} });
		expect(lemon.commands).toMatchObject([{ name: "ship", source: "lemon", scope: "project" }]);
	});
});

describe("trusted-root confinement", () => {
	const secret = "PRIVATE KEY MATERIAL";

	test("a template symlinked outside the repo is neither listed nor read", async () => {
		await fixture(join(root, "outside/id_ed25519"), secret);
		await mkdir(join(cwd, ".lemon/prompts"), { recursive: true });
		await symlink(join(root, "outside/id_ed25519"), join(cwd, ".lemon/prompts/review.md"));
		const result = await discoverPaletteResources({ cwd, home, env: {} });
		expect(result.entries.map((item) => item.name)).not.toContain("review");
		expect(JSON.stringify(result.entries)).not.toContain(secret);
	});

	test("a hard-linked template is rejected", async () => {
		await fixture(join(cwd, "secret.txt"), secret);
		await mkdir(join(cwd, ".lemon/prompts"), { recursive: true });
		await link(join(cwd, "secret.txt"), join(cwd, ".lemon/prompts/review.md"));
		const result = await discoverPaletteResources({ cwd, home, env: {} });
		expect(result.entries).toEqual([]);
		expect(result.issues.join(" ")).toContain("hard-linked");
	});

	test("a commands dir symlinked to / is not traversed", async () => {
		await mkdir(join(cwd, ".claude"), { recursive: true });
		await symlink("/", join(cwd, ".claude/commands"));
		await fixture(join(root, "outside/cmds/leak.md"), "---\ndescription: leaked\n---\nx");
		await mkdir(join(cwd, ".gemini"), { recursive: true });
		await symlink(join(root, "outside/cmds"), join(cwd, ".gemini/commands"));
		await mkdir(join(cwd, ".lemon/commands"), { recursive: true });
		await symlink(join(root, "outside/cmds/leak.md"), join(cwd, ".lemon/commands/leak.md"));
		const result = await discoverFileCommands({ cwd, home, env: {} });
		expect(result.commands).toEqual([]);
		expect(result.issues.join(" ")).toContain("EOUTSIDEROOT");
	});

	test("a skill dir symlinked outside the repo is ignored", async () => {
		await fixture(join(root, "outside/evil/SKILL.md"), secret);
		await mkdir(join(cwd, ".agents/skills"), { recursive: true });
		await symlink(join(root, "outside/evil"), join(cwd, ".agents/skills/evil"));
		await symlink(join(root, "outside"), join(cwd, ".omp"));
		const result = await discoverPaletteResources({ cwd, home, env: {} });
		expect(result.entries).toEqual([]);
	});

	test("an empty fake .git in a parent does not widen the root", async () => {
		const parent = join(root, "fake");
		const work = join(parent, "work");
		await mkdir(join(parent, ".git"), { recursive: true });
		await mkdir(work, { recursive: true });
		await fixture(join(parent, ".agents/skills/above/SKILL.md"), "Above the root");
		await fixture(join(work, ".agents/skills/here/SKILL.md"), "Here");
		const result = await discoverPaletteResources({ cwd: work, home, env: {} });
		expect(result.entries.map((item) => item.name)).toEqual(["here"]);
	});

	// Parity with LemonCore.TrustedRoot.resolve/1: a symlinked `.git`, a gitfile
	// naming a non-repository, or one with trailing junk never widens the root.
	test("symlinked or malformed .git markers in a parent do not widen the root", async () => {
		const real = join(root, "realrepo");
		await gitRepo(real);
		const markers: Array<[string, (dotGit: string) => Promise<void>]> = [
			["linked", (dotGit) => symlink(join(real, ".git"), dotGit)],
			["bad-gitdir", (dotGit) => writeFile(dotGit, `gitdir: ${join(root, "nowhere")}\n`)],
			["junk", (dotGit) => writeFile(dotGit, `gitdir: ${join(real, ".git")}\nextra\n`)],
		];
		for (const [name, plant] of markers) {
			const parent = join(root, name);
			const work = join(parent, "work");
			await mkdir(work, { recursive: true });
			await plant(join(parent, ".git"));
			await fixture(join(parent, ".agents/skills/above/SKILL.md"), "Above the root");
			await fixture(join(work, ".agents/skills/here/SKILL.md"), "Here");
			const result = await discoverPaletteResources({ cwd: work, home, env: {} });
			expect(result.entries.map((item) => item.name)).toEqual(["here"]);
		}
	});

	test("a gitfile naming a real git directory widens the root, like the daemon", async () => {
		const real = join(root, "realrepo");
		await gitRepo(real);
		const parent = join(root, "sub");
		const work = join(parent, "work");
		await mkdir(work, { recursive: true });
		await writeFile(join(parent, ".git"), `gitdir: ${join(real, ".git")}\n`);
		await fixture(join(parent, ".agents/skills/above/SKILL.md"), "In the root");
		const result = await discoverPaletteResources({ cwd: work, home, env: {} });
		expect(result.entries.map((item) => item.name)).toEqual(["above"]);
	});

	test("in-root symlinks still work", async () => {
		await fixture(join(cwd, "docs/review.md"), "Review in repo");
		await mkdir(join(cwd, ".lemon/prompts"), { recursive: true });
		await symlink(join(cwd, "docs/review.md"), join(cwd, ".lemon/prompts/review.md"));
		await fixture(join(cwd, "shared/cmds/ship.md"), "---\ndescription: Ship\n---\nx");
		await mkdir(join(cwd, ".lemon"), { recursive: true });
		await symlink(join(cwd, "shared/cmds"), join(cwd, ".lemon/commands"));
		const prompts = await discoverPaletteResources({ cwd, home, env: {} });
		expect(prompts.entries.map((item) => item.insertText)).toEqual(["Review in repo"]);
		const commands = await discoverFileCommands({ cwd, home, env: {} });
		expect(commands.commands.map((command) => command.name)).toEqual(["ship"]);
	});
});
