/**
 * Poll helpers for the streaming paths: the reveal controller lands text over
 * several 30fps frames, so tests wait for a condition instead of guessing a
 * sleep long enough to cover it.
 */

export async function waitFor(
	predicate: () => boolean,
	{ timeoutMs = 2000, intervalMs = 5, what = "condition" } = {},
): Promise<void> {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		if (predicate()) return;
		await Bun.sleep(intervalMs);
	}
	throw new Error(`timed out after ${timeoutMs}ms waiting for ${what}`);
}

export function waitForText(read: () => string, needle: string, timeoutMs = 2000): Promise<void> {
	return waitFor(() => read().includes(needle), {
		timeoutMs,
		what: `text containing ${JSON.stringify(needle)}`,
	});
}
