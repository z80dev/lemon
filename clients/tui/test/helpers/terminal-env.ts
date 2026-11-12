// Tests must not inherit the developer's terminal: running the suite inside a
// Tern pane would otherwise bind prompts to that pane and switch on Tern-only
// behavior. Tests that exercise those paths set the variables themselves.
for (const name of ["TERN_PANE", "TERN_PANE_SOCKET", "TERN_DAEMON_SOCKET", "TERM_PROGRAM"]) {
	delete process.env[name];
}
