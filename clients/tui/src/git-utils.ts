/**
 * Git utility functions for retrieving repository status information.
 */

import { execFile } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

const GIT_STATUS_TIMEOUT_MS = 2_000;

export interface GitReadOptions {
	/** `[runtime] git_path` from the global config (never a project file). */
	gitPath?: unknown;
}

/**
 * Retrieves a formatted modeline string showing the current git branch status.
 * The modeline includes the branch name (or short commit hash for detached HEAD),
 * ahead/behind indicators, and a dirty state marker.
 *
 * @param cwd - The working directory to check git status in
 * @returns A formatted string like "main +2 -1 *" or null if not a git repository
 */
export async function getGitModeline(
	cwd: string,
	options: GitReadOptions = {},
): Promise<string | null> {
	const output = await getGitStatusOutput(cwd, options);
	if (!output) {
		return null;
	}

	const lines = output.split(/\r?\n/);
	let head: string | null = null;
	let oid: string | null = null;
	let ahead = 0;
	let behind = 0;
	let dirty = false;

	for (const line of lines) {
		if (!line) {
			continue;
		}
		if (line.startsWith("# branch.head ")) {
			head = line.slice("# branch.head ".length).trim();
			continue;
		}
		if (line.startsWith("# branch.oid ")) {
			oid = line.slice("# branch.oid ".length).trim();
			continue;
		}
		if (line.startsWith("# branch.ab ")) {
			const match = line.match(/\+(\d+)\s+-(\d+)/);
			if (match) {
				ahead = Number.parseInt(match[1] || "0", 10);
				behind = Number.parseInt(match[2] || "0", 10);
			}
			continue;
		}
		if (!line.startsWith("#")) {
			dirty = true;
		}
	}

	if (!head && !oid) {
		return null;
	}

	let branch = head;
	if (branch === "(detached)" || branch === "HEAD" || !branch) {
		const shortOid = oid ? oid.slice(0, 7) : "";
		branch = shortOid || "detached";
	}

	let suffix = "";
	if (ahead > 0) {
		suffix += ` +${ahead}`;
	}
	if (behind > 0) {
		suffix += ` -${behind}`;
	}
	if (dirty) {
		suffix += " *";
	}

	return `${branch}${suffix}`;
}

// The repository the TUI runs in may be an unpacked archive or a shared
// checkout, so neither its configuration nor the workspace's PATH may make
// this read run a program. It mirrors the server's LemonCore.SafeGit:
//
// - `git` is `[runtime] git_path` from the global config or the first git in
//   fixed system directories, never a PATH lookup; Git older than 2.31 is
//   refused. The child's PATH is the same fixed list.
// - Git locates the repository itself under a minimal environment (no system or
//   global configuration, so no `safe.directory` exceptions: its ownership
//   check refuses another user's repository), and the work tree, Git directory,
//   common directory and its config must belong to this user.
// - status then runs with GIT_DIR set to a private directory holding a config
//   Lemon writes (format, a few comparison settings, excludes file, remote and
//   upstream data read with `git config --file … --no-includes`), a copy of
//   HEAD and links to the validated object/ref stores. The repository's live
//   configuration, includes and drivers are never read, so no attributes file
//   can select a configured program.
const TRUSTED_DIRS = ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin", "/bin"];
const MINIMUM_VERSION = [2, 31, 0];
const STORE_ENTRIES = [
	"objects",
	"refs",
	"packed-refs",
	"reftable",
	"logs",
	"info",
	"shallow",
	"worktrees",
];

const SAFE_CONFIG: Array<[string, string]> = [
	["core.fsmonitor", "false"],
	["core.hooksPath", "/dev/null"],
	["core.pager", "cat"],
	["core.editor", ":"],
	["sequence.editor", ":"],
	["core.askPass", ""],
	["core.sshCommand", ""],
	["core.gitProxy", ""],
	["core.alternateRefsCommand", ""],
	["diff.external", ""],
	["credential.helper", ""],
	["log.showSignature", "false"],
	["gpg.program", ""],
	["gpg.ssh.program", ""],
	["gpg.x509.program", ""],
	["gc.auto", "0"],
	["maintenance.auto", "false"],
	["submodule.recurse", "false"],
	["color.ui", "never"],
];

const BOOL = ["true", "false", "yes", "no", "on", "off", "1", "0"];
const COPIED_SETTINGS: Record<string, string[] | "string"> = {
	"core.repositoryformatversion": ["0", "1"],
	"extensions.objectformat": ["sha1", "sha256"],
	"extensions.refstorage": ["files", "reftable"],
	"core.filemode": BOOL,
	"core.ignorecase": BOOL,
	"core.precomposeunicode": BOOL,
	"core.symlinks": BOOL,
	"core.trustctime": BOOL,
	"core.quotepath": BOOL,
	"core.checkstat": ["default", "minimal"],
	"core.autocrlf": ["input", ...BOOL],
	"core.eol": ["lf", "crlf", "native"],
	"core.excludesfile": "string",
};
const COPIED_SUBSECTIONS =
	/^(?:remote\.[^"\\\n]+\.(?:url|fetch)|branch\.[^"\\\n]+\.(?:remote|merge))$/;

const checkedVersions = new Map<string, boolean>();

/** The operator-trusted git: `[runtime] git_path`, else the fixed system directories. */
export function resolveGit(configured?: unknown): string | null {
	const candidates =
		typeof configured === "string" && configured !== ""
			? [configured]
			: TRUSTED_DIRS.map((dir) => path.join(dir, "git"));
	for (const candidate of candidates) {
		if (!path.isAbsolute(candidate)) continue;
		try {
			if (fs.statSync(candidate).isFile()) {
				fs.accessSync(candidate, fs.constants.X_OK);
				return candidate;
			}
		} catch {
			// Not present or not executable.
		}
	}
	return null;
}

function baseEnv(extra: Record<string, string> = {}): NodeJS.ProcessEnv {
	const env: NodeJS.ProcessEnv = {
		PATH: TRUSTED_DIRS.join(":"),
		GIT_CONFIG_NOSYSTEM: "1",
		GIT_CONFIG_GLOBAL: "/dev/null",
		GIT_ATTR_NOSYSTEM: "1",
		// No transport name (they are URL-scheme characters) is "/".
		GIT_ALLOW_PROTOCOL: "/",
		GIT_NO_LAZY_FETCH: "1",
		GIT_TERMINAL_PROMPT: "0",
		GIT_OPTIONAL_LOCKS: "0",
		LC_ALL: "C",
		...extra,
	};
	if (process.env.HOME !== undefined) env.HOME = process.env.HOME;
	return env;
}

function configArgs(pairs: Array<[string, string]>): string[] {
	return pairs.flatMap(([key, value]) => ["-c", `${key}=${value}`]);
}

function runGit(
	git: string,
	cwd: string,
	args: string[],
	env: NodeJS.ProcessEnv,
	deadline: number,
): Promise<string | null> {
	const timeout = deadline - Date.now();
	if (timeout <= 0) return Promise.resolve(null);
	const { promise, resolve } = Promise.withResolvers<string | null>();
	execFile(
		git,
		["--no-pager", "--no-optional-locks", ...args],
		{ cwd, env, timeout, killSignal: "SIGKILL", maxBuffer: 1024 * 1024 },
		(err, stdout) => resolve(err ? null : stdout),
	);
	return promise;
}

async function supportedVersion(git: string, deadline: number): Promise<boolean> {
	const known = checkedVersions.get(git);
	if (known !== undefined) return known;
	const output = await runGit(git, "/", ["--version"], baseEnv(), deadline);
	if (output === null) return false;
	const match = output.match(/^git version (\d+)\.(\d+)(?:\.(\d+))?/);
	const version = match ? [Number(match[1]), Number(match[2]), Number(match[3] ?? 0)] : [0, 0, 0];
	let supported = true;
	for (let i = 0; i < 3; i++) {
		if (version[i] !== MINIMUM_VERSION[i]) {
			supported = version[i] > MINIMUM_VERSION[i];
			break;
		}
	}
	checkedVersions.set(git, supported);
	return supported;
}

function ownedByUser(file: string): boolean {
	try {
		return fs.lstatSync(file).uid === process.getuid?.();
	} catch {
		return false;
	}
}

/** A small regular file, opened without following links or blocking on FIFOs. */
function readMetadata(file: string, max: number): string | null {
	let fd: number | undefined;
	try {
		fd = fs.openSync(
			file,
			fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK,
		);
		if (!fs.fstatSync(fd).isFile()) return null;
		const buffer = Buffer.alloc(max + 1);
		const size = fs.readSync(fd, buffer, 0, max + 1, 0);
		return size <= max ? buffer.subarray(0, size).toString("utf8") : null;
	} catch {
		return null;
	} finally {
		if (fd !== undefined) fs.closeSync(fd);
	}
}

/** Allowlisted `key\nvalue` entries of a `git config --list -z` listing. */
export function copiedSettings(listing: string): Array<[string, string]> {
	const settings: Array<[string, string]> = [];
	for (const entry of listing.split("\0")) {
		if (!entry) continue;
		const newline = entry.indexOf("\n");
		const key = newline < 0 ? entry : entry.slice(0, newline);
		const value = newline < 0 ? "true" : entry.slice(newline + 1);
		if (/[\n\0]/.test(value)) continue;
		const allowed = COPIED_SETTINGS[key];
		if (allowed === "string" || allowed?.includes(value.toLowerCase())) {
			settings.push([key, value]);
		} else if (!allowed && COPIED_SUBSECTIONS.test(key)) {
			settings.push([key, value]);
		}
	}
	return settings;
}

function quote(value: string): string {
	return `"${value.replaceAll("\\", "\\\\").replaceAll('"', '\\"')}"`;
}

/** The private directory's config: only the copied settings, never includes. */
export function renderConfig(settings: Array<[string, string]>): string {
	let version = "0";
	const sections = new Map<string, Array<[string, string]>>([["[core]", []]]);
	for (const [key, value] of settings) {
		if (key === "core.repositoryformatversion") {
			version = value;
			continue;
		}
		const first = key.indexOf(".");
		const last = key.lastIndexOf(".");
		const section = key.slice(0, first);
		const header =
			first === last ? `[${section}]` : `[${section} ${quote(key.slice(first + 1, last))}]`;
		const entries = sections.get(header) ?? [];
		entries.push([key.slice(last + 1), value]);
		sections.set(header, entries);
	}
	sections.get("[core]")?.unshift(["repositoryformatversion", version], ["bare", "false"]);
	let text = "";
	for (const [header, entries] of sections) {
		text += `${header}\n`;
		for (const [name, value] of entries) text += `\t${name} = ${quote(value)}\n`;
	}
	return text;
}

interface Repository {
	root: string;
	gitDir: string;
	commonDir: string;
}

async function repository(git: string, cwd: string, deadline: number): Promise<Repository | null> {
	const output = await runGit(
		git,
		cwd,
		["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir"],
		baseEnv(),
		deadline,
	);
	const [root, gitDir, commonDir] = output?.split("\n") ?? [];
	if (!root || !gitDir || !commonDir) return null;
	try {
		const repo = {
			root: fs.realpathSync(root),
			gitDir: fs.realpathSync(gitDir),
			commonDir: fs.realpathSync(commonDir),
		};
		const config = path.join(repo.commonDir, "config");
		const owned =
			[repo.root, repo.gitDir, repo.commonDir].every(ownedByUser) &&
			(!fs.existsSync(config) || ownedByUser(config));
		return owned ? repo : null;
	} catch {
		return null;
	}
}

function isLink(file: string): boolean {
	try {
		return fs.lstatSync(file).isSymbolicLink();
	} catch {
		return false;
	}
}

async function privateDir(git: string, repo: Repository, deadline: number): Promise<string | null> {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "lemon-git-"));
	try {
		const config = path.join(repo.commonDir, "config");
		let settings: Array<[string, string]> = [];
		if (fs.existsSync(config)) {
			if (!fs.lstatSync(config).isFile()) throw new Error("config is not a regular file");
			const listing = await runGit(
				git,
				dir,
				["config", "--file", config, "--no-includes", "--list", "-z"],
				baseEnv({ GIT_CEILING_DIRECTORIES: path.dirname(dir) }),
				deadline,
			);
			if (listing === null) throw new Error("config unreadable");
			settings = copiedSettings(listing);
		}
		const head = readMetadata(path.join(repo.gitDir, "HEAD"), 1024)?.replace(/\n$/, "");
		if (
			!head ||
			head.includes("..") ||
			!/^(?:ref: refs\/[!-~]+|[0-9a-f]{40}|[0-9a-f]{64})$/.test(head)
		) {
			throw new Error("HEAD unreadable");
		}
		fs.writeFileSync(path.join(dir, "config"), renderConfig(settings));
		fs.writeFileSync(path.join(dir, "HEAD"), `${head}\n`);
		const links: Array<[string, string]> = STORE_ENTRIES.map((name) => [repo.commonDir, name]);
		for (const name of fs.readdirSync(repo.gitDir)) {
			if (name.startsWith("sharedindex.")) links.push([repo.gitDir, name]);
		}
		for (const [source, name] of links) {
			const target = path.join(source, name);
			if (fs.existsSync(target) || isLink(target)) fs.symlinkSync(target, path.join(dir, name));
		}
		return dir;
	} catch {
		fs.rmSync(dir, { recursive: true, force: true });
		return null;
	}
}

/**
 * Executes git status and returns the raw output.
 *
 * @param cwd - The working directory to run git status in
 * @returns The raw git status output or null if the command fails
 */
export async function getGitStatusOutput(
	cwd: string,
	options: GitReadOptions = {},
): Promise<string | null> {
	const deadline = Date.now() + GIT_STATUS_TIMEOUT_MS;
	const git = resolveGit(options.gitPath);
	if (!git || !(await supportedVersion(git, deadline))) return null;
	const repo = await repository(git, cwd, deadline);
	if (!repo) return null;
	const realGit = fs.realpathSync(git);
	const inside = (dir: string) => realGit === dir || realGit.startsWith(`${dir}${path.sep}`);
	if ([repo.root, repo.gitDir, repo.commonDir].some(inside)) return null;
	const dir = await privateDir(git, repo, deadline);
	if (!dir) return null;
	try {
		const output = await runGit(
			git,
			repo.root,
			[
				...configArgs(SAFE_CONFIG),
				"--literal-pathspecs",
				"status",
				"--porcelain=v2",
				"--branch",
				"--ignore-submodules=all",
			],
			baseEnv({
				GIT_DIR: dir,
				GIT_WORK_TREE: repo.root,
				GIT_INDEX_FILE: path.join(repo.gitDir, "index"),
			}),
			deadline,
		);
		return output?.trim() || null;
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
}
