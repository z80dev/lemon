import { describe, expect, test } from "bun:test";
import {
	defaultUrl,
	hasInteractiveTerminal,
	main,
	parseArgs,
	resolveVersion,
	satisfiesVersion,
} from "../src/main.ts";

describe("parseArgs", () => {
	const env = {} as NodeJS.ProcessEnv;

	test("defaults to the local control plane", () => {
		expect(parseArgs([], env).url).toBe("ws://127.0.0.1:4040/ws");
	});

	test("accepts --ws-url, --url and -u", () => {
		expect(parseArgs(["--ws-url", "ws://host:1/ws"], env).url).toBe("ws://host:1/ws");
		expect(parseArgs(["--url", "ws://host:2/ws"], env).url).toBe("ws://host:2/ws");
		expect(parseArgs(["-u", "ws://host:3/ws"], env).url).toBe("ws://host:3/ws");
		expect(parseArgs(["--url=ws://host:4/ws"], env).url).toBe("ws://host:4/ws");
	});

	test("accepts a session key", () => {
		expect(parseArgs(["--session", "s1"], env).sessionKey).toBe("s1");
		expect(parseArgs(["-s", "s2"], env).sessionKey).toBe("s2");
		expect(parseArgs(["--session=s3"], env).sessionKey).toBe("s3");
	});

	test("flags help and version", () => {
		expect(parseArgs(["--help"], env).help).toBe(true);
		expect(parseArgs(["-h"], env).help).toBe(true);
		expect(parseArgs(["--version"], env).version).toBe(true);
		expect(parseArgs(["-V"], env).version).toBe(true);
	});

	test("reports missing values and unknown flags", () => {
		expect(parseArgs(["--ws-url"], env).error).toMatch(/requires a value/);
		expect(parseArgs(["--wat"], env).error).toMatch(/unknown argument/);
	});
});

describe("defaultUrl", () => {
	test("prefers LEMON_WS_URL, then the port, then the built-in default", () => {
		expect(defaultUrl({ LEMON_WS_URL: "ws://a/ws" } as NodeJS.ProcessEnv)).toBe("ws://a/ws");
		expect(defaultUrl({ LEMON_CONTROL_PLANE_PORT: "5555" } as NodeJS.ProcessEnv)).toBe(
			"ws://127.0.0.1:5555/ws",
		);
		expect(defaultUrl({} as NodeJS.ProcessEnv)).toBe("ws://127.0.0.1:4040/ws");
	});
});

describe("satisfiesVersion", () => {
	test("compares numerically, not lexically", () => {
		expect(satisfiesVersion("1.3.14", "1.3.14")).toBe(true);
		expect(satisfiesVersion("1.3.20", "1.3.14")).toBe(true);
		expect(satisfiesVersion("1.10.0", "1.3.14")).toBe(true);
		expect(satisfiesVersion("1.3.9", "1.3.14")).toBe(false);
		expect(satisfiesVersion("0.9.9", "1.3.14")).toBe(false);
		expect(satisfiesVersion("2.0.0-canary.1", "1.3.14")).toBe(true);
	});
});

describe("version reporting", () => {
	test("LEMON_TUI_VERSION wins", async () => {
		expect(await resolveVersion({ LEMON_TUI_VERSION: "2026.08.1" } as NodeJS.ProcessEnv)).toBe(
			"2026.08.1",
		);
	});

	test("falls back to the package version in a checkout", async () => {
		const version = await resolveVersion({} as NodeJS.ProcessEnv);
		expect(version).toMatch(/^\d+\.\d+\.\d+$/);
	});

	test("--version exits 0 and prints the version, no TUI involved", async () => {
		const printed = await captureOutput(() => main(["--version"]));
		expect(printed.code).toBe(0);
		expect(printed.stdout.trim()).toMatch(/^\d/);
	});

	test("--help exits 0 and a bad flag exits 2", async () => {
		expect((await captureOutput(() => main(["--help"]))).code).toBe(0);
		const bad = await captureOutput(() => main(["--nope"]));
		expect(bad.code).toBe(2);
		expect(bad.stderr).toContain("unknown argument");
	});
});

/** Run `fn` with stdout/stderr captured so CLI output stays out of test logs. */
async function captureOutput(
	fn: () => Promise<number>,
): Promise<{ code: number; stdout: string; stderr: string }> {
	const originalOut = process.stdout.write;
	const originalErr = process.stderr.write;
	let stdout = "";
	let stderr = "";
	process.stdout.write = ((chunk: string) => {
		stdout += chunk;
		return true;
	}) as typeof process.stdout.write;
	process.stderr.write = ((chunk: string) => {
		stderr += chunk;
		return true;
	}) as typeof process.stderr.write;
	try {
		const code = await fn();
		return { code, stdout, stderr };
	} finally {
		process.stdout.write = originalOut;
		process.stderr.write = originalErr;
	}
}

describe("terminal requirement", () => {
	test("an explicit override allows a non-TTY start", () => {
		expect(hasInteractiveTerminal({ LEMON_TUI_ALLOW_NO_TTY: "1" } as NodeJS.ProcessEnv)).toBe(true);
	});

	test("otherwise it follows the real stdio TTY flags", () => {
		expect(hasInteractiveTerminal({} as NodeJS.ProcessEnv)).toBe(
			Boolean(process.stdin.isTTY) && Boolean(process.stdout.isTTY),
		);
	});
});
