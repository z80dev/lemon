import { afterEach, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import {
	chmodSync,
	existsSync,
	mkdirSync,
	mkdtempSync,
	readdirSync,
	realpathSync,
	rmSync,
	utimesSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { loadConfig } from "../src/config.ts";
import { getGitModeline } from "../src/git-utils.ts";

// The status bar reads the repository the TUI was started in, which may be an
// unpacked archive or a shared checkout. Its configuration must not make that
// read run programs.
const dirs: string[] = [];

afterEach(() => {
	for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function tempDir(): string {
	const dir = realpathSync(mkdtempSync(join(tmpdir(), "lemon-tui-git-")));
	dirs.push(dir);
	return dir;
}

function git(cwd: string, ...args: string[]): string {
	return execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8" });
}

function repo(dir: string): string {
	execFileSync("git", ["init", "-q", "-b", "main", dir]);
	writeFileSync(join(dir, "tracked.txt"), "tracked\n");
	git(dir, "add", "tracked.txt");
	git(
		dir,
		"-c",
		"user.name=T",
		"-c",
		"user.email=t@example.invalid",
		"-c",
		"core.hooksPath=/dev/null",
		"commit",
		"-qm",
		"init",
	);
	return dir;
}

function program(dir: string, name: string, marker: string, tail: string): string {
	const path = join(dir, name);
	writeFileSync(path, `#!/bin/sh\n: > '${marker}'\n${tail}\n`);
	chmodSync(path, 0o755);
	return path;
}

describe("getGitModeline", () => {
	test("runs no fsmonitor program or clean filter named by the repository", async () => {
		const tmp = tempDir();
		const dir = repo(join(tmp, "repo"));
		const marker = join(tmp, "program-ran");
		git(dir, "config", "core.fsmonitor", program(tmp, "fsmonitor", marker, "exit 1"));
		git(dir, "config", "filter.Evil.clean", program(tmp, "clean", marker, "cat"));
		writeFileSync(join(dir, ".git/info/attributes"), "* filter=Evil\n");
		utimesSync(join(dir, "tracked.txt"), new Date(2020, 0, 1), new Date(2020, 0, 1));

		expect(await getGitModeline(dir)).toBe("main");
		expect(existsSync(marker)).toBe(false);
	});

	test("reports changes and ignores an inherited GIT_DIR", async () => {
		const tmp = tempDir();
		const dir = repo(join(tmp, "repo"));
		const other = repo(join(tmp, "other"));
		git(other, "checkout", "-q", "-b", "elsewhere");
		writeFileSync(join(dir, "tracked.txt"), "changed\n");
		const previous = process.env.GIT_DIR;
		process.env.GIT_DIR = join(other, ".git");

		try {
			expect(await getGitModeline(dir)).toBe("main *");
		} finally {
			if (previous === undefined) delete process.env.GIT_DIR;
			else process.env.GIT_DIR = previous;
		}
	});

	test("never reads the repository's configuration, whatever its driver names", async () => {
		const tmp = tempDir();
		const dir = repo(join(tmp, "repo"));
		const marker = join(tmp, "program-ran");
		git(dir, "config", "filter.a=b.clean", program(tmp, "clean", marker, "cat"));
		writeFileSync(join(dir, ".git/info/attributes"), "* filter=a=b\n");
		utimesSync(join(dir, "tracked.txt"), new Date(2020, 0, 1), new Date(2020, 0, 1));

		expect(await getGitModeline(dir)).toBe("main");
		expect(existsSync(marker)).toBe(false);
		expect(readdirSync(join(dir, ".git/objects")).length).toBeGreaterThan(0);
	});

	test("a concurrently replaced include cannot introduce a driver", async () => {
		const tmp = tempDir();
		const dir = repo(join(tmp, "repo"));
		const marker = join(tmp, "program-ran");
		const included = join(tmp, "included.gitconfig");
		const benign = "[core]\n\tquotepath = false\n";
		const evil = `[filter "late"]\n\tclean = ${program(tmp, "clean", marker, "cat")}\n`;
		writeFileSync(included, benign);
		git(dir, "config", "include.path", included);
		writeFileSync(join(dir, ".git/info/attributes"), "* filter=late\n");

		let flipping = true;
		const flipper = (async () => {
			for (let i = 0; flipping; i++) {
				writeFileSync(included, i % 2 ? evil : benign);
				await new Promise((resolve) => setImmediate(resolve));
			}
		})();
		const results: Array<string | null> = [];
		try {
			for (let second = 1; second <= 10; second++) {
				const time = new Date(2020, 0, 1, 0, 0, second);
				utimesSync(join(dir, "tracked.txt"), time, time);
				results.push(await getGitModeline(dir));
			}
		} finally {
			flipping = false;
			await flipper;
		}
		// Discovery reads the live file, so a half-written include may make a
		// read unavailable (null); it never runs the driver.
		for (const result of results) expect([null, "main"]).toContain(result);
		expect(results).toContain("main");
		expect(existsSync(marker)).toBe(false);

		// The payload is live: plain Git with the same repository runs it.
		writeFileSync(included, evil);
		utimesSync(join(dir, "tracked.txt"), new Date(2021, 0, 1), new Date(2021, 0, 1));
		git(dir, "status", "--porcelain");
		expect(existsSync(marker)).toBe(true);
	});

	test("never runs a git found on PATH", async () => {
		const tmp = tempDir();
		const dir = repo(join(tmp, "repo"));
		const marker = join(tmp, "planted-git-ran");
		mkdirSync(join(dir, "bin"));
		program(join(dir, "bin"), "git", marker, "echo 'git version 9.9.9'");
		program(dir, "git", marker, "echo 'git version 9.9.9'");
		const previousPath = process.env.PATH;
		const previousCwd = process.cwd();
		// Absolute workspace entry, relative entry and empty entry (cwd = repo).
		process.env.PATH = `${dir}/bin:bin::${previousPath}`;
		process.chdir(dir);

		try {
			// The planted files are untracked, so the tree reads as dirty.
			expect(await getGitModeline(dir)).toBe("main *");
		} finally {
			process.chdir(previousCwd);
			process.env.PATH = previousPath;
		}
		expect(existsSync(marker)).toBe(false);
	});

	test("an operator git_path is honoured and a project file cannot set one", async () => {
		const tmp = tempDir();
		const dir = repo(join(tmp, "repo"));
		const marker = join(tmp, "configured-git-ran");
		const real = execFileSync("git", ["--exec-path"], { encoding: "utf8" }).trim();
		const configured = program(tmp, "configured-git", marker, `exec ${real}/git "$@"`);
		expect(await getGitModeline(dir, { gitPath: configured })).toBe("main");
		expect(existsSync(marker)).toBe(true);

		const home = join(tmp, "home");
		mkdirSync(join(dir, ".lemon"), { recursive: true });
		writeFileSync(join(dir, ".lemon/config.toml"), `[runtime]\ngit_path = "${configured}"\n`);
		const previousHome = process.env.HOME;
		process.env.HOME = home;
		try {
			expect((await loadConfig(dir)).runtime?.git_path).toBeUndefined();
		} finally {
			process.env.HOME = previousHome;
		}
	});
});
