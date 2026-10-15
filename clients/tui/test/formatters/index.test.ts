/**
 * Tests for the FormatterRegistry.
 */

import { beforeEach, describe, expect, it } from "bun:test";
import { defaultRegistry, FormatterRegistry } from "../../src/formatters/index.js";
import type { FormattedOutput, ToolFormatter } from "../../src/formatters/types.js";

/**
 * Creates a mock formatter for testing.
 */
function createMockFormatter(
	tools: string[],
	options: {
		argsResult?: FormattedOutput;
		resultResult?: FormattedOutput;
		partialResult?: FormattedOutput;
		argsThrows?: boolean;
		resultThrows?: boolean;
		partialThrows?: boolean;
	} = {},
): ToolFormatter {
	const defaultArgs: FormattedOutput = {
		summary: "mock args summary",
		details: ["mock args detail"],
	};

	const defaultResult: FormattedOutput = {
		summary: "mock result summary",
		details: ["mock result detail"],
	};

	return {
		tools,
		formatArgs: (_args) => {
			if (options.argsThrows) {
				throw new Error("formatArgs error");
			}
			return options.argsResult ?? defaultArgs;
		},
		formatResult: (_result, _args) => {
			if (options.resultThrows) {
				throw new Error("formatResult error");
			}
			return options.resultResult ?? defaultResult;
		},
		...(options.partialResult || options.partialThrows
			? {
					formatPartial: (_partial, _args) => {
						if (options.partialThrows) {
							throw new Error("formatPartial error");
						}
						return options.partialResult!;
					},
				}
			: {}),
	};
}

describe("FormatterRegistry", () => {
	let registry: FormatterRegistry;

	beforeEach(() => {
		registry = new FormatterRegistry();
	});

	describe("register(formatter)", () => {
		it("should register a formatter for multiple tools", () => {
			const formatter = createMockFormatter(["tool1", "tool2", "tool3"]);
			registry.register(formatter);

			expect(registry.hasFormatter("tool1")).toBe(true);
			expect(registry.hasFormatter("tool2")).toBe(true);
			expect(registry.hasFormatter("tool3")).toBe(true);
			expect(registry.getFormatter("tool1")).toBe(formatter);
			expect(registry.getFormatter("tool2")).toBe(formatter);
			expect(registry.getFormatter("tool3")).toBe(formatter);
		});

		it("should allow multiple formatters for different tools", () => {
			const formatter1 = createMockFormatter(["tool1"]);
			const formatter2 = createMockFormatter(["tool2"]);

			registry.register(formatter1);
			registry.register(formatter2);

			expect(registry.getFormatter("tool1")).toBe(formatter1);
			expect(registry.getFormatter("tool2")).toBe(formatter2);
		});
	});

	describe("unregister(formatter)", () => {
		it("should remove formatter registration", () => {
			const formatter = createMockFormatter(["mytool"]);
			registry.register(formatter);
			expect(registry.hasFormatter("mytool")).toBe(true);

			registry.unregister(formatter);
			expect(registry.hasFormatter("mytool")).toBe(false);
		});

		it("should remove all tool mappings for formatter with multiple tools", () => {
			const formatter = createMockFormatter(["tool1", "tool2", "tool3"]);
			registry.register(formatter);

			registry.unregister(formatter);

			expect(registry.hasFormatter("tool1")).toBe(false);
			expect(registry.hasFormatter("tool2")).toBe(false);
			expect(registry.hasFormatter("tool3")).toBe(false);
		});

		it("should only unregister if the current registration matches the formatter", () => {
			const formatter1 = createMockFormatter(["mytool"]);
			const formatter2 = createMockFormatter(["mytool"]);

			registry.register(formatter1);
			registry.register(formatter2); // Overwrites formatter1

			// Trying to unregister formatter1 should not remove formatter2
			registry.unregister(formatter1);
			expect(registry.hasFormatter("mytool")).toBe(true);
			expect(registry.getFormatter("mytool")).toBe(formatter2);
		});
	});

	describe("getRegisteredTools()", () => {
		it("should return empty array when no formatters registered", () => {
			expect(registry.getRegisteredTools()).toEqual([]);
		});

		it("should return all registered tool names", () => {
			const formatter1 = createMockFormatter(["tool1", "tool2"]);
			const formatter2 = createMockFormatter(["tool3"]);

			registry.register(formatter1);
			registry.register(formatter2);

			const tools = registry.getRegisteredTools();
			expect(tools).toHaveLength(3);
			expect(tools).toContain("tool1");
			expect(tools).toContain("tool2");
			expect(tools).toContain("tool3");
		});

		it("should not include unregistered tools", () => {
			const formatter = createMockFormatter(["tool1", "tool2"]);
			registry.register(formatter);
			registry.unregister(formatter);

			expect(registry.getRegisteredTools()).toEqual([]);
		});
	});

	describe("formatArgs(toolName, args)", () => {
		it("should use registered formatter", () => {
			const customOutput: FormattedOutput = {
				summary: "custom summary",
				details: ["custom detail 1", "custom detail 2"],
			};
			const formatter = createMockFormatter(["mytool"], { argsResult: customOutput });
			registry.register(formatter);

			const result = registry.formatArgs("mytool", { key: "value" });
			expect(result).toEqual(customOutput);
		});

		it("should fall back to default for unknown tool", () => {
			const result = registry.formatArgs("unknowntool", { key: "value" });

			expect(result.summary).toContain("key");
			expect(result.details).toBeDefined();
			expect(Array.isArray(result.details)).toBe(true);
		});

		it("should handle empty args", () => {
			const result = registry.formatArgs("unknowntool", {});

			expect(result.summary).toBe("(no arguments)");
			expect(result.details).toEqual([]);
		});

		it("should handle null-like args", () => {
			// @ts-expect-error - Testing edge case with null
			const resultNull = registry.formatArgs("unknowntool", null);
			expect(resultNull.summary).toBe("(no arguments)");

			// @ts-expect-error - Testing edge case with undefined
			const resultUndefined = registry.formatArgs("unknowntool", undefined);
			expect(resultUndefined.summary).toBe("(no arguments)");
		});

		it("should fall back to default when formatter throws", () => {
			const formatter = createMockFormatter(["mytool"], { argsThrows: true });
			registry.register(formatter);

			const result = registry.formatArgs("mytool", { key: "value" });

			// Should return default formatting, not throw
			expect(result.summary).toContain("key");
		});

		it("should format each key-value pair in details", () => {
			const result = registry.formatArgs("unknowntool", {
				command: "ls -la",
				timeout: 5000,
				verbose: true,
			});

			expect(result.details.some((d) => d.includes("command:"))).toBe(true);
			expect(result.details.some((d) => d.includes("timeout:"))).toBe(true);
			expect(result.details.some((d) => d.includes("verbose:"))).toBe(true);
		});
	});

	describe("formatResult(toolName, result, args)", () => {
		it("should use registered formatter", () => {
			const customOutput: FormattedOutput = {
				summary: "custom result",
				details: ["result line 1"],
				isError: false,
			};
			const formatter = createMockFormatter(["mytool"], { resultResult: customOutput });
			registry.register(formatter);

			const result = registry.formatResult("mytool", "some output", { key: "value" });
			expect(result).toEqual(customOutput);
		});

		it("should fall back to default for unknown tool", () => {
			const result = registry.formatResult("unknowntool", "hello world");

			expect(result.summary).toContain("hello");
			expect(result.details).toBeDefined();
		});

		it("should handle null result", () => {
			const result = registry.formatResult("unknowntool", null);

			expect(result.summary).toBe("(no result)");
			expect(result.details).toEqual([]);
		});

		it("should handle undefined result", () => {
			const result = registry.formatResult("unknowntool", undefined);

			expect(result.summary).toBe("(no result)");
			expect(result.details).toEqual([]);
		});

		it("should handle object result with text content", () => {
			const result = registry.formatResult("unknowntool", { text: "extracted text" });

			expect(result.summary).toContain("extracted text");
		});

		it("should handle object result with content field", () => {
			const result = registry.formatResult("unknowntool", { content: "content text" });

			expect(result.summary).toContain("content text");
		});

		it("should handle array of content blocks", () => {
			const result = registry.formatResult("unknowntool", [
				{ type: "text", text: "first block" },
				{ type: "text", text: " second block" },
			]);

			expect(result.summary).toContain("first block");
		});

		it("should detect error results with is_error flag", () => {
			const result = registry.formatResult("unknowntool", {
				is_error: true,
				message: "Something went wrong",
			});

			expect(result.isError).toBe(true);
		});

		it("should detect error results with isError flag", () => {
			const result = registry.formatResult("unknowntool", {
				isError: true,
				text: "Error occurred",
			});

			expect(result.isError).toBe(true);
		});

		it("should detect error results with error field", () => {
			const result = registry.formatResult("unknowntool", {
				error: "File not found",
			});

			expect(result.isError).toBe(true);
		});

		it("should not mark non-error objects as errors", () => {
			const result = registry.formatResult("unknowntool", {
				success: true,
				data: "some data",
			});

			expect(result.isError).toBeFalsy();
		});

		it("should fall back to default when formatter throws", () => {
			const formatter = createMockFormatter(["mytool"], { resultThrows: true });
			registry.register(formatter);

			const result = registry.formatResult("mytool", "test output");

			// Should return default formatting, not throw
			expect(result.summary).toContain("test output");
		});

		it("should pass args to formatter", () => {
			let receivedArgs: Record<string, unknown> | undefined;
			const formatter: ToolFormatter = {
				tools: ["mytool"],
				formatArgs: () => ({ summary: "", details: [] }),
				formatResult: (_result, args) => {
					receivedArgs = args;
					return { summary: "", details: [] };
				},
			};
			registry.register(formatter);

			registry.formatResult("mytool", "output", { path: "/test.txt" });

			expect(receivedArgs).toEqual({ path: "/test.txt" });
		});
	});

	describe("formatPartial(toolName, partial, args)", () => {
		it("should use formatPartial when formatter has it", () => {
			const partialOutput: FormattedOutput = {
				summary: "partial output",
				details: ["streaming..."],
			};
			const formatter = createMockFormatter(["mytool"], { partialResult: partialOutput });
			registry.register(formatter);

			const result = registry.formatPartial("mytool", "partial data");
			expect(result).toEqual(partialOutput);
		});

		it("should fall back to formatResult when no formatPartial", () => {
			const resultOutput: FormattedOutput = {
				summary: "result output",
				details: ["from result"],
			};
			const formatter = createMockFormatter(["mytool"], { resultResult: resultOutput });
			registry.register(formatter);

			const result = registry.formatPartial("mytool", "partial data");
			expect(result).toEqual(resultOutput);
		});

		it("should fall back to default for unknown tool", () => {
			const result = registry.formatPartial("unknowntool", "streaming data");

			expect(result.summary).toContain("streaming data");
		});

		it("should fall back to default when formatPartial throws", () => {
			const formatter = createMockFormatter(["mytool"], { partialThrows: true });
			registry.register(formatter);

			const result = registry.formatPartial("mytool", "test data");

			// Should return default formatting, not throw
			expect(result.summary).toContain("test data");
		});

		it("should fall back to default when formatResult throws (no formatPartial)", () => {
			const formatter = createMockFormatter(["mytool"], { resultThrows: true });
			registry.register(formatter);

			const result = registry.formatPartial("mytool", "test data");

			// Should return default formatting, not throw
			expect(result.summary).toContain("test data");
		});

		it("should pass args to formatPartial", () => {
			let receivedArgs: Record<string, unknown> | undefined;
			const formatter: ToolFormatter = {
				tools: ["mytool"],
				formatArgs: () => ({ summary: "", details: [] }),
				formatResult: () => ({ summary: "", details: [] }),
				formatPartial: (_partial, args) => {
					receivedArgs = args;
					return { summary: "", details: [] };
				},
			};
			registry.register(formatter);

			registry.formatPartial("mytool", "partial", { key: "value" });

			expect(receivedArgs).toEqual({ key: "value" });
		});
	});

	describe("default formatting behavior", () => {
		it("should truncate long summary text", () => {
			const longText = "a".repeat(500);
			const result = registry.formatResult("unknown", longText);

			expect(result.summary.length).toBeLessThanOrEqual(203); // 200 + "..."
			expect(result.summary).toContain("...");
		});

		it("should truncate long details", () => {
			const manyLines = Array(50)
				.fill("line")
				.map((_, i) => `line ${i}`);
			const result = registry.formatResult("unknown", manyLines.join("\n"));

			// Default max lines is 20, plus 1 for "... (N more)"
			expect(result.details.length).toBeLessThanOrEqual(21);
			expect(result.details[result.details.length - 1]).toContain("more");
		});

		it("should format JSON properly", () => {
			const result = registry.formatArgs("unknown", {
				nested: { a: 1, b: 2 },
				array: [1, 2, 3],
			});

			// Summary should be JSON-like
			expect(result.summary).toContain("nested");
			expect(result.summary).toContain("array");
		});

		it("should handle multiline string results", () => {
			const multiline = "line1\nline2\nline3";
			const result = registry.formatResult("unknown", multiline);

			expect(result.details.length).toBe(3);
			expect(result.details[0]).toContain("line1");
			expect(result.details[1]).toContain("line2");
			expect(result.details[2]).toContain("line3");
		});

		it("should handle number results", () => {
			const result = registry.formatResult("unknown", 42);

			expect(result.summary).toBe("42");
		});

		it("should handle boolean results", () => {
			const resultTrue = registry.formatResult("unknown", true);
			expect(resultTrue.summary).toBe("true");

			const resultFalse = registry.formatResult("unknown", false);
			expect(resultFalse.summary).toBe("false");
		});
	});

	describe("defaultRegistry", () => {
		it("should be a FormatterRegistry instance", () => {
			expect(defaultRegistry).toBeInstanceOf(FormatterRegistry);
		});

		it("registers exactly Lemon's native tool names", () => {
			const expected = [
				"agent",
				"bash",
				"bash_output",
				"browser_analyze",
				"browser_back",
				"browser_clear_state",
				"browser_click",
				"browser_download",
				"browser_evaluate",
				"browser_events",
				"browser_get_content",
				"browser_get_cookies",
				"browser_hover",
				"browser_navigate",
				"browser_press",
				"browser_screenshot",
				"browser_scroll",
				"browser_select_option",
				"browser_set_cookies",
				"browser_snapshot",
				"browser_tab_activate",
				"browser_tab_close",
				"browser_tab_open",
				"browser_tabs",
				"browser_type",
				"browser_upload_file",
				"browser_wait_for_selector",
				"edit",
				"find",
				"grep",
				"kill_process",
				"ls",
				"omp",
				"patch",
				"read",
				"task",
				"todo",
				"webfetch",
				"websearch",
				"write",
			];

			expect([...defaultRegistry.getRegisteredTools()].sort()).toEqual(expected);
		});

		it("registers no formatter for tools Lemon does not have", () => {
			for (const tool of [
				"process",
				"glob",
				"exec",
				"multiedit",
				"todoread",
				"todowrite",
				"hashline_edit",
			]) {
				expect(defaultRegistry.hasFormatter(tool)).toBe(false);
			}
		});

		it("formats native read args by path", () => {
			const result = defaultRegistry.formatArgs("read", {
				path: "/path/to/file.txt",
				offset: 0,
				limit: 100,
			});

			expect(result.summary).toContain("file.txt");
		});
	});

	describe("edge cases", () => {
		it("should handle formatter with empty tools array", () => {
			const formatter = createMockFormatter([]);
			registry.register(formatter);

			expect(registry.getRegisteredTools()).toEqual([]);
		});

		it("should handle circular references in args", () => {
			const obj: Record<string, unknown> = { a: 1 };
			obj.self = obj;

			const result = registry.formatArgs("unknown", obj);

			expect(result.summary).toContain("[Circular]");
		});

		it("should handle special values in args", () => {
			const result = registry.formatArgs("unknown", {
				bigint: BigInt(123),
				func: () => {},
				symbol: Symbol("test"),
			});

			expect(result.summary).toBeDefined();
			expect(typeof result.summary).toBe("string");
		});

		it("should handle deeply nested objects", () => {
			const deep = { l1: { l2: { l3: { l4: { l5: "deep" } } } } };
			const result = registry.formatArgs("unknown", deep);

			expect(result.summary).toContain("l1");
		});

		it("should handle very long single values", () => {
			const result = registry.formatArgs("unknown", {
				content: "x".repeat(10000),
			});

			// Should be truncated
			expect(result.summary.length).toBeLessThan(10000);
			expect(result.details[0].length).toBeLessThan(10000);
		});

		it("should handle empty string result", () => {
			const result = registry.formatResult("unknown", "");

			// extractText returns '' for empty string, which is falsy,
			// so it falls back to JSON formatting
			expect(result.summary).toBe('""');
		});

		it("should handle whitespace-only result", () => {
			const result = registry.formatResult("unknown", "   \n\t  ");

			expect(result.summary).toBeDefined();
		});

		it("should handle array results", () => {
			const result = registry.formatResult("unknown", [1, 2, 3]);

			expect(result.summary).toContain("1");
		});

		it("should handle object with output field", () => {
			const result = registry.formatResult("unknown", { output: "command output" });

			expect(result.summary).toContain("command output");
		});

		it("should handle object with message field", () => {
			const result = registry.formatResult("unknown", { message: "status message" });

			expect(result.summary).toContain("status message");
		});

		it("should handle content blocks with images", () => {
			const result = registry.formatResult("unknown", [
				{ type: "text", text: "Some text" },
				{ type: "image", data: "base64..." },
				{ type: "image", data: "base64..." },
			]);

			expect(result.summary).toContain("Some text");
			expect(result.details.join(" ")).toContain("2 images");
		});
	});
});
