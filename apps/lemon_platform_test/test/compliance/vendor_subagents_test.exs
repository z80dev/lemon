defmodule LemonPlatformTest.Compliance.VendorSubagentsTest do
  @moduledoc """
  The static contract, run against every vendor CLI wrapper this repo ships.

  `LemonPlatformTest.Compliance.CodexSubagentTest` fakes a `codex` binary and
  drives a whole run through it; that is worth doing once, not five times. What
  every vendor wrapper must hold to regardless — a registrable id, a
  description the tool can render, a total `cancel/1`, a resume syntax that
  reads back what it printed — is checked here, so the guard rail covers the
  whole surface `LemonCliRunners.Application` registers rather than one runner
  of it.

  `async: false` throughout: the registry round-trip is global state.
  """

  defmodule ClaudeTest do
    use LemonPlatformTest.SubagentRunnerCase,
      async: false,
      runner: LemonCliRunners.ClaudeSubagent
  end

  defmodule KimiTest do
    use LemonPlatformTest.SubagentRunnerCase,
      async: false,
      runner: LemonCliRunners.KimiSubagent
  end

  defmodule OpencodeTest do
    use LemonPlatformTest.SubagentRunnerCase,
      async: false,
      runner: LemonCliRunners.OpencodeSubagent
  end

  defmodule PiTest do
    use LemonPlatformTest.SubagentRunnerCase,
      async: false,
      runner: LemonCliRunners.PiSubagent,
      # Pi names a session by transcript path, so the round-trip has to prove
      # the quoting survives it.
      resume_sample: "/tmp/pi sessions/abc.jsonl"
  end
end
