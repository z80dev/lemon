defmodule LemonPlatformTest.StubSubagent do
  @moduledoc """
  The reference `LemonCore.SubagentRunner`: everything the contract asks for and
  nothing else.

  It runs no process at all — `events/1` is a literal list — which is what makes
  it a useful probe target: any failure the suite reports against it is a bug in
  the suite, not in an executor.
  """

  @behaviour LemonCore.SubagentRunner

  alias LemonCore.ResumeToken

  @impl true
  def id, do: "stub"

  @impl true
  def describe do
    %{summary: "In-process stub runner", caveats: ["echoes the prompt; spawns nothing"]}
  end

  # A stub is not an engine anyone can route a conversation to.
  @impl true
  def routable?, do: false

  @impl true
  def start(opts) do
    case Keyword.fetch(opts, :prompt) do
      {:ok, prompt} -> {:ok, %{prompt: prompt, cwd: Keyword.get(opts, :cwd, File.cwd!())}}
      :error -> {:error, :missing_prompt}
    end
  end

  @impl true
  def events(%{prompt: prompt}) do
    [
      {:started, ResumeToken.new("stub", "stub-session")},
      {:action, %{id: "1", kind: :note, title: "thinking", detail: nil}, :completed, [ok: true]},
      {:completed, "echo: " <> prompt, [ok: true]}
    ]
  end

  @impl true
  def cancel(_session), do: :ok

  @impl true
  def resume_token(_session), do: ResumeToken.new("stub", "stub-session")
end

defmodule LemonPlatformTest.Compliance.StubSubagentRunnerTest do
  @moduledoc """
  Self-validation: the suite run against a runner known to be correct.

  `async: false` because the registry round-trip mutates global state.
  """

  use LemonPlatformTest.SubagentRunnerCase,
    async: false,
    runner: LemonPlatformTest.StubSubagent,
    run_probe: {__MODULE__, :start_opts}

  def start_opts(_context), do: [prompt: "ping", cwd: System.tmp_dir!()]
end
