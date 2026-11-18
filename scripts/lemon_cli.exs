# Mix.Shell.Quiet still prints application headers to its group leader when
# reporting errors, including ordinary build-lock waits. Keep every bootstrap
# diagnostic on stderr, then restore stdin/stdout before running the real CLI.
Process.put(:lemon_cli_group_leader, Process.group_leader())
Process.group_leader(self(), Process.whereis(:standard_error))

Mix.CLI.main(
  [
    "run",
    "--no-start",
    "--no-compile",
    "--no-deps-check",
    "-e",
    """
    Process.group_leader(self(), Process.delete(:lemon_cli_group_leader))
    File.cd!(System.fetch_env!("LEMON_NODE_LAUNCH_CWD"))
    LemonCore.NodeCredentials.consume_handoff()
    LemonCli.CLI.main(System.argv())
    """,
    "--"
  ] ++ System.argv()
)
