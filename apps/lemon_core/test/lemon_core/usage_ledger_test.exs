defmodule LemonCore.UsageLedgerTest do
  use ExUnit.Case, async: true

  alias LemonCore.UsageLedger

  test "entry extracts provider, model, tokens and cost without prompts or answers" do
    entry =
      UsageLedger.entry("run-1", "agent:s", %{
        completed: %LemonCore.Events.Completion{
          ok: true,
          answer: "secret answer",
          usage: %{"prompt_tokens" => 40, "completion_tokens" => 8, "cost" => 0.01}
        },
        meta: %{model: "openai:gpt-5"},
        prompt: "secret prompt"
      })

    assert %{
             run_id: "run-1",
             session_key: "agent:s",
             provider: "openai",
             model: "gpt-5",
             input: 40,
             output: 8,
             cost: 0.01
           } = entry
  end

  test "an unprefixed model uses the provider from meta, else unknown" do
    usage = %{completed: %{usage: %{input: 1, output: 1}}}

    assert %{provider: "zai", model: "glm"} =
             UsageLedger.entry("r", nil, Map.put(usage, :meta, %{model: "glm", provider: "zai"}))

    assert %{provider: "unknown", model: "glm", session_key: nil} =
             UsageLedger.entry("r", nil, Map.put(usage, :meta, %{model: "glm"}))
  end

  test "sessions per day are bounded and the rest counted as omitted" do
    record =
      Enum.reduce(1..105, %{}, fn i, record ->
        UsageLedger.add_to_record(
          record,
          %{session_key: "s#{i}", provider: "p", model: "m", input: 1, output: 1, cost: 0.0},
          "2026-01-01",
          i
        )
      end)

    assert map_size(record.sessions) == 100
    assert record.sessions_omitted == 5
    assert record.requests == %{"p" => 105}
    assert record.models["p:m"].requests == 105
  end

  test "the finalize hook ignores malformed payloads without raising" do
    assert UsageLedger.handle_finalize_run(:no_such_server, %{run_id: "r", summary: %{}}) == :ok
    assert UsageLedger.handle_finalize_run(%{}) == :ok
  end
end
