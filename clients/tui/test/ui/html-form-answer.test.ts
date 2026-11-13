import { expect, test } from "bun:test";
import { defaultFormData } from "@oh-my-pi/pi-tui/html-form/data";
import { parseHtmlForm } from "@oh-my-pi/pi-tui/html-form/parse";
import { clip, formSubmission } from "../../src/ui/components/html-form-answer.ts";

const FORM = parseHtmlForm(`<form>
	<fieldset><legend>Database</legend>
	<label><input type="radio" name="db" value="sqlite" checked> SQLite</label>
	<label><input type="radio" name="db" value="pg"> Postgres</label></fieldset>
	<label>Replicas <input type="number" name="replicas" value="2"></label>
</form>`);

test("a submission carries the form data verbatim plus readable answers", () => {
	const data = { ...defaultFormData(FORM), replicas: 3 };
	const result = formSubmission(FORM, data, [
		{ name: "db", question: "Database", option: "SQLite", value: "sqlite", text: "embedded" },
	]);
	expect(result.ok).toBe(true);
	if (!result.ok) return;
	expect(result.answer.action).toBe("accept");
	expect(result.answer.content).toEqual({ db: "sqlite", replicas: 3 });
	expect(result.answer.answers).toEqual([
		{ name: "db", question: "Database", answer: "SQLite" },
		{ name: "replicas", question: "Replicas", answer: "3" },
	]);
	expect(result.answer.notes).toHaveLength(1);
});

test("data over the wire bounds is refused, not truncated", () => {
	const big = formSubmission(FORM, { db: "x".repeat(4_001) }, []);
	expect(big.ok).toBe(false);
	const nan = formSubmission(FORM, { replicas: Number.NaN }, []);
	expect(nan.ok).toBe(false);
	const many = formSubmission(
		FORM,
		Object.fromEntries(Array.from({ length: 65 }, (_, i) => [`f${i}`, "v"])),
		[],
	);
	expect(many.ok).toBe(false);
});

test("readable listings are clipped on a UTF-8 boundary", () => {
	const clipped = clip("é".repeat(100), 11);
	expect(Buffer.byteLength(clipped, "utf8")).toBeLessThanOrEqual(11);
	expect(clipped.endsWith("…")).toBe(true);
	expect(clipped).not.toContain("\uFFFD");
	expect(clip("short", 100)).toBe("short");
});
