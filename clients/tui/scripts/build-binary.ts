#!/usr/bin/env bun
/**
 * Compiles `lemon-tui` into a standalone Bun binary and stages the
 * `@oh-my-pi/pi-natives` addon next to it.
 *
 * Layout produced (one platform per invocation):
 *
 *   <outdir>/<platform>/tui/bin/lemon-tui
 *   <outdir>/<platform>/tui/bin/pi_natives.<tag>[-baseline|-modern].node
 *
 * `tui/` is the directory the release tarball is built from, and it is also the
 * directory the installer drops into the release root — so `dirname(execPath)`
 * holds the addon at runtime, which is one of the paths the pi-natives loader
 * probes (`resolveLoaderCandidates` in @oh-my-pi/pi-natives). No embedding hack
 * is needed; the files just have to sit beside the binary.
 *
 * Usage:
 *   bun scripts/build-binary.ts [--target linux-x86_64|linux-arm64|darwin-arm64]
 *                               [--outdir dist]
 *
 * Without `--target` the host platform is built.
 */

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { chmod, mkdir, mkdtemp, readdir, readFile, rm } from "node:fs/promises";
import * as path from "node:path";

const PACKAGE_DIR = path.join(import.meta.dir, "..");
const ENTRYPOINT = path.join(PACKAGE_DIR, "src", "main.ts");

interface TargetSpec {
	/** Release platform id — also the artifact filename fragment. */
	readonly platform: string;
	/** Bun `compile.target` triple. */
	readonly bunTarget: Bun.Build.CompileTarget;
	/** `@oh-my-pi/pi-natives-<npmTag>` leaf package holding the prebuilt addon. */
	readonly npmTag: string;
}

/**
 * linux-x86_64 compiles against the *baseline* Bun runtime on purpose: release
 * binaries have to boot on pre-AVX2 hosts. The addon variant is a separate,
 * runtime-side decision — the leaf package ships baseline and modern `.node`
 * files and the loader picks per-CPU, so both are staged.
 */
const TARGETS: readonly TargetSpec[] = [
	{ platform: "linux-x86_64", bunTarget: "bun-linux-x64-baseline", npmTag: "linux-x64" },
	{ platform: "linux-arm64", bunTarget: "bun-linux-arm64", npmTag: "linux-arm64" },
	{ platform: "darwin-arm64", bunTarget: "bun-darwin-arm64", npmTag: "darwin-arm64" },
];

interface Options {
	readonly target: TargetSpec;
	readonly outdir: string;
}

function hostPlatform(): string {
	if (process.platform === "linux" && process.arch === "x64") return "linux-x86_64";
	if (process.platform === "linux" && process.arch === "arm64") return "linux-arm64";
	if (process.platform === "darwin" && process.arch === "arm64") return "darwin-arm64";
	return `${process.platform}-${process.arch}`;
}

export function resolveTarget(platform: string): TargetSpec {
	const spec = TARGETS.find((candidate) => candidate.platform === platform);
	if (!spec) {
		throw new Error(
			`unsupported --target '${platform}' (supported: ${TARGETS.map((t) => t.platform).join(", ")})`,
		);
	}
	return spec;
}

export function parseArgs(argv: readonly string[]): Options {
	let platform: string | undefined;
	let outdir = "dist";
	for (let index = 0; index < argv.length; index++) {
		const arg = argv[index];
		const takeValue = (name: string): string => {
			const inline = arg.startsWith(`${name}=`) ? arg.slice(name.length + 1) : undefined;
			if (inline !== undefined) return inline;
			const next = argv[index + 1];
			if (next === undefined) throw new Error(`${name} requires a value`);
			index += 1;
			return next;
		};
		if (arg === "--target" || arg.startsWith("--target=")) {
			platform = takeValue("--target");
		} else if (arg === "--outdir" || arg.startsWith("--outdir=")) {
			outdir = takeValue("--outdir");
		} else if (arg === "--help" || arg === "-h") {
			process.stdout.write(
				"Usage: bun scripts/build-binary.ts [--target <platform>] [--outdir <dir>]\n" +
					`Platforms: ${TARGETS.map((t) => t.platform).join(", ")}\n`,
			);
			process.exit(0);
		} else {
			throw new Error(`unknown argument: ${arg}`);
		}
	}
	return {
		target: resolveTarget(platform ?? hostPlatform()),
		outdir: path.resolve(PACKAGE_DIR, outdir),
	};
}

function run(command: string, args: string[], cwd: string): string {
	const result = spawnSync(command, args, {
		cwd,
		encoding: "utf-8",
		stdio: ["ignore", "pipe", "inherit"],
	});
	if (result.error) throw result.error;
	if (result.status !== 0) {
		throw new Error(`command failed (exit ${result.status}): ${command} ${args.join(" ")}`);
	}
	return (result.stdout || "").trim();
}

async function readJson(file: string): Promise<Record<string, unknown>> {
	return JSON.parse(await readFile(file, "utf-8")) as Record<string, unknown>;
}

/** Version of the workspace's package, used as the fallback release version. */
async function packageVersion(): Promise<string> {
	const pkg = await readJson(path.join(PACKAGE_DIR, "package.json"));
	const version = pkg.version;
	if (typeof version !== "string" || version.length === 0) {
		throw new Error("clients/tui/package.json has no version");
	}
	return version;
}

/**
 * The addon version is whatever `bun install` resolved, never a hardcoded
 * constant: pi-tui, pi-utils and pi-natives release in lockstep and a mismatched
 * `.node` fails the loader's version-sentinel check at startup.
 */
async function nativesVersion(): Promise<string> {
	const manifest = path.join(
		PACKAGE_DIR,
		"node_modules",
		"@oh-my-pi",
		"pi-natives",
		"package.json",
	);
	if (!existsSync(manifest)) {
		throw new Error(
			`@oh-my-pi/pi-natives is not installed (${manifest} missing) — run \`bun install\` first`,
		);
	}
	const version = (await readJson(manifest)).version;
	if (typeof version !== "string" || version.length === 0) {
		throw new Error(`${manifest} has no version`);
	}
	return version;
}

function gitCommit(): string {
	try {
		return run("git", ["rev-parse", "--short", "HEAD"], PACKAGE_DIR);
	} catch {
		return "unknown";
	}
}

/** Already-installed leaf package for this target, when the host matches. */
async function localLeafDir(spec: TargetSpec, version: string): Promise<string | null> {
	const dir = path.join(PACKAGE_DIR, "node_modules", "@oh-my-pi", `pi-natives-${spec.npmTag}`);
	const manifest = path.join(dir, "package.json");
	if (!existsSync(manifest)) return null;
	const installed = (await readJson(manifest)).version;
	return installed === version ? dir : null;
}

/**
 * Downloads the leaf package for a cross target and returns its extracted dir.
 * The scratch dir lives under `--outdir` rather than the system temp dir: these
 * addons are 150-300 MB and a tmpfs `/tmp` runs out well before the copy lands.
 */
async function packLeafDir(
	spec: TargetSpec,
	version: string,
	outdir: string,
): Promise<{ dir: string; cleanup: string }> {
	await mkdir(outdir, { recursive: true });
	const scratch = await mkdtemp(path.join(outdir, `.natives-${spec.npmTag}-`));
	const packageSpec = `@oh-my-pi/pi-natives-${spec.npmTag}@${version}`;
	console.log(`  fetching ${packageSpec}`);
	run("npm", ["pack", packageSpec, "--silent", "--pack-destination", scratch], scratch);
	const tarballs = (await readdir(scratch)).filter((name) => name.endsWith(".tgz"));
	if (tarballs.length !== 1) {
		throw new Error(
			`expected one tarball from \`npm pack ${packageSpec}\`, got ${tarballs.length}`,
		);
	}
	run("tar", ["-xzf", tarballs[0]], scratch);
	const dir = path.join(scratch, "package");
	if (!existsSync(dir)) throw new Error(`${packageSpec} tarball has no package/ directory`);
	return { dir, cleanup: scratch };
}

/**
 * Stages every `.node` in the leaf package next to the binary. x64 ships
 * baseline+modern variants and the loader picks one at runtime, so all of them
 * are copied rather than guessing here.
 */
async function stageNatives(
	spec: TargetSpec,
	version: string,
	binDir: string,
	outdir: string,
): Promise<string[]> {
	const local = await localLeafDir(spec, version);
	const source: { dir: string; cleanup: string | null } = local
		? { dir: local, cleanup: null }
		: await packLeafDir(spec, version, outdir);
	if (local) console.log(`  using installed @oh-my-pi/pi-natives-${spec.npmTag}@${version}`);
	try {
		const addons = (await readdir(source.dir)).filter((name) => name.endsWith(".node"));
		if (addons.length === 0) {
			throw new Error(`@oh-my-pi/pi-natives-${spec.npmTag}@${version} contains no .node addon`);
		}
		const staged: string[] = [];
		for (const addon of addons) {
			const destination = path.join(binDir, addon);
			await Bun.write(destination, Bun.file(path.join(source.dir, addon)));
			await chmod(destination, 0o755);
			staged.push(destination);
		}
		return staged;
	} finally {
		if (source.cleanup) await rm(source.cleanup, { recursive: true, force: true });
	}
}

async function compile(
	options: Options,
	version: string,
	commit: string,
	outfile: string,
): Promise<void> {
	const result = await Bun.build({
		entrypoints: [ENTRYPOINT],
		define: {
			// Both spellings: `src/main.ts` reads the bare identifier (Bun's
			// `--define` substitutes that form), while `process.env.*` keeps the
			// value available to any module that reaches for it that way.
			LEMON_TUI_VERSION: JSON.stringify(version),
			LEMON_TUI_COMMIT: JSON.stringify(commit),
			"process.env.LEMON_TUI_VERSION": JSON.stringify(version),
			"process.env.LEMON_TUI_COMMIT": JSON.stringify(commit),
		},
		compile: {
			target: options.target.bunTarget,
			outfile,
			// A standalone Bun binary otherwise autoloads bunfig.toml, .env,
			// tsconfig.json and package.json from the *user's* CWD. `lemon-tui`
			// runs from arbitrary project directories, so a stray bunfig with a
			// `preload` would inject code into the client. All four stay off.
			// (`.env` still reaches `process.env`: @oh-my-pi/pi-utils parses the
			// CWD/home/profile `.env` files itself at module load, independently
			// of Bun's autoload.)
			autoloadBunfig: false,
			autoloadDotenv: false,
			autoloadTsconfig: false,
			autoloadPackageJson: false,
		},
		throw: false,
	});
	if (!result.success) {
		throw new Error(
			`lemon-tui bundle failed:\n${result.logs.map((log) => log.message).join("\n")}`,
		);
	}
}

async function main(): Promise<void> {
	const options = parseArgs(Bun.argv.slice(2));
	if (!existsSync(ENTRYPOINT)) {
		throw new Error(`entrypoint ${ENTRYPOINT} does not exist — nothing to compile`);
	}

	const version = Bun.env.LEMON_VERSION?.trim() || (await packageVersion());
	const commit = Bun.env.LEMON_GIT_SHA?.trim() || gitCommit();
	const addonVersion = await nativesVersion();

	const stageDir = path.join(options.outdir, options.target.platform);
	const binDir = path.join(stageDir, "tui", "bin");
	const outfile = path.join(binDir, "lemon-tui");

	console.log(`Building lemon-tui ${version} (${commit}) for ${options.target.platform}`);
	await rm(stageDir, { recursive: true, force: true });
	await mkdir(binDir, { recursive: true });

	await compile(options, version, commit, outfile);
	await chmod(outfile, 0o755);
	console.log(`  compiled ${path.relative(PACKAGE_DIR, outfile)} (${options.target.bunTarget})`);

	const staged = await stageNatives(options.target, addonVersion, binDir, options.outdir);
	for (const addon of staged) {
		const size = (Bun.file(addon).size / 1024 / 1024).toFixed(1);
		console.log(`  staged   ${path.basename(addon)} (${size} MiB)`);
	}
	console.log(`Done: ${stageDir}`);
}

if (import.meta.main) {
	try {
		await main();
	} catch (error) {
		process.stderr.write(
			`build-binary: ${error instanceof Error ? error.message : String(error)}\n`,
		);
		process.exit(1);
	}
}
