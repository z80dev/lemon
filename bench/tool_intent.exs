Code.require_file("support.exs", __DIR__)

# Run from the umbrella root: mix run --no-start bench/tool_intent.exs
# TMPDIR selects the filesystem under measurement; TOOL_INTENT_SAMPLES defaults
# to 1,000 calls per class. No provider, network request, or tool effect runs.

defmodule LemonBench.ToolIntentOwner do
  use GenServer

  def init(dir) do
    session = CodingAgent.SessionManager.new(dir)
    session = CodingAgent.SessionManager.persist(session, Path.join(dir, "session.jsonl"))

    {:ok,
     %{session_manager: session, tool_opts: [], is_streaming: false, pending_tool_intents: %{}}}
  end

  def handle_call(request, from, state), do: CodingAgent.Session.handle_call(request, from, state)
end

alias CodingAgent.ToolIntent
alias LemonAgent.Types.{AgentTool, AgentToolResult}

LemonBench.banner("CodingAgent.ToolIntent append + datasync")
scratch = LemonBench.scratch_dir("tool-intent")
samples = System.get_env("TOOL_INTENT_SAMPLES", "1000") |> String.to_integer()
if samples < 1, do: raise("TOOL_INTENT_SAMPLES must be positive")
{:ok, owner} = GenServer.start_link(LemonBench.ToolIntentOwner, scratch)

try do
  timings =
    for effect <- [:none, :external], into: %{} do
      tool = %AgentTool{
        name: "intent_benchmark",
        effect: effect,
        execute: fn _, _, _, _ -> %AgentToolResult{} end
      }

      tool = ToolIntent.wrap(tool, session_pid: owner)
      params = %{"path" => "benchmark.txt", "content" => String.duplicate("x", 1024)}

      times =
        for i <- 1..samples do
          {us, %AgentToolResult{is_error: false}} =
            :timer.tc(fn -> tool.execute.("#{effect}-#{i}", params, nil, nil) end)

          us
        end

      sorted = Enum.sort(times)
      mean = Enum.sum(times) / samples
      percentile = fn p -> Enum.at(sorted, max(ceil(samples * p) - 1, 0)) end

      IO.puts(
        "#{effect}: samples=#{samples} mean_us=#{LemonBench.num(mean)} p50_us=#{percentile.(0.5)} p95_us=#{percentile.(0.95)} p99_us=#{percentile.(0.99)}"
      )

      {effect, mean}
    end

  IO.puts(
    "added_mean_us=#{LemonBench.num(timings.external - timings.none)} filesystem=#{scratch}"
  )
after
  GenServer.stop(owner)
  File.rm_rf!(scratch)
end
