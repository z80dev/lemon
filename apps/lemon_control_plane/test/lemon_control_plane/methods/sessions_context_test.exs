defmodule LemonControlPlane.Methods.SessionsContextTest do
  use ExUnit.Case, async: false
  alias LemonControlPlane.Methods.{Registry, SessionsContext}

  defmodule Provider do
    def session_context_usage(key, cwd) do
      send(self(), {:context_usage, key, cwd})
      Process.get(:context_result, {:ok, LemonControlPlane.Methods.SessionsContextTest.report()})
    end
  end

  @categories ~w(system_prompt tool_definitions skills context_files memory user_messages assistant_messages tool_results summaries)a

  def report(overrides \\ %{}) do
    tokens = [3_000, 6_000, 500, 2_500, 400, 600, 4_000, 23_000, 0]

    categories =
      @categories
      |> Enum.zip(tokens)
      |> Enum.map(fn {id, tokens} -> %{id: id, tokens: tokens, percent: 0.0, items: 2} end)

    Map.merge(
      %{
        live: false,
        overhead: :snapshot,
        model: %{provider: "anthropic", id: "claude-sonnet-4-5"},
        window: 200_000,
        used_tokens: 40_000,
        free_tokens: 160_000,
        percent_used: 20.0,
        source: "usage",
        estimated_tokens: 36_123,
        auto_compaction: %{
          enabled: true,
          threshold_tokens: 168_000,
          reserve_tokens: 32_000,
          headroom_tokens: 128_000
        },
        categories: categories,
        top: [
          %{category: :tool_results, label: "read result #12", tokens: 9_000},
          %{category: :context_files, label: "AGENTS.md (project)", tokens: 2_000},
          %{category: :tool_results, label: "/Users/me/secret/path", tokens: 1_000},
          %{category: :bogus, label: "dropped", tokens: 5},
          %{category: :memory, label: "Recalled\nmemory #3", tokens: 400}
        ],
        message_count: 18,
        measured_at: 1_760_000_000_000,
        private_prompt: "must never cross the wire"
      },
      overrides
    )
  end

  setup do
    original = Application.get_env(:lemon_core, :agent_runtime_provider)
    Application.put_env(:lemon_core, :agent_runtime_provider, Provider)

    on_exit(fn ->
      if original,
        do: Application.put_env(:lemon_core, :agent_runtime_provider, original),
        else: Application.delete_env(:lemon_core, :agent_runtime_provider)
    end)

    :ok
  end

  @params %{"sessionKey" => "agent:default:tui:local:dm:abc", "cwd" => "/repo"}

  test "projects a bounded breakdown whose categories sum to the reported total" do
    assert {:ok, result} =
             Registry.dispatch("sessions.context", @params, %{
               auth: %{role: :operator, scopes: [:read]}
             })

    assert_receive {:context_usage, "agent:default:tui:local:dm:abc", "/repo"}

    assert result["sessionKey"] == "agent:default:tui:local:dm:abc"
    assert result["usedTokens"] == 40_000
    assert Enum.sum(Enum.map(result["categories"], & &1["tokens"])) == result["usedTokens"]
    assert result["window"] == 200_000
    assert result["freeTokens"] == 160_000
    assert result["percentUsed"] == 20.0
    assert result["source"] == "usage"
    assert result["overhead"] == "snapshot"
    assert result["live"] == false
    assert result["estimatedTokens"] == 36_123
    assert result["model"] == %{"provider" => "anthropic", "id" => "claude-sonnet-4-5"}
    assert result["autoCompaction"]["headroomTokens"] == 128_000
    assert Enum.map(result["categories"], & &1["id"]) == Enum.map(@categories, &Atom.to_string/1)

    tool_results = Enum.find(result["categories"], &(&1["id"] == "tool_results"))

    assert tool_results == %{
             "id" => "tool_results",
             "label" => "Tool results",
             "tokens" => 23_000,
             "items" => 2,
             "percent" => 11.5
           }

    assert result["top"] == [
             %{"category" => "tool_results", "label" => "read result #12", "tokens" => 9_000},
             %{
               "category" => "context_files",
               "label" => "AGENTS.md (project)",
               "tokens" => 2_000
             },
             %{"category" => "tool_results", "label" => "Item", "tokens" => 1_000},
             %{"category" => "memory", "label" => "Recalled memory #3", "tokens" => 400}
           ]

    refute inspect(result) =~ "must never cross the wire"
    refute inspect(result) =~ "/Users/me"
    assert {:ok, _} = Jason.encode(result)
  end

  test "unknown windows report null percentages and no compaction budget" do
    Process.put(:context_result, {:ok, report(%{window: nil, auto_compaction: nil})})
    assert {:ok, result} = SessionsContext.handle(@params, %{})
    assert result["window"] == nil
    assert result["freeTokens"] == nil
    assert result["percentUsed"] == nil
    assert result["autoCompaction"] == nil
    assert Enum.all?(result["categories"], &is_nil(&1["percent"]))
  end

  test "projects numeric-only session usage and tolerates a missing block" do
    assert {:ok, without} = SessionsContext.handle(@params, %{})
    assert without["usage"] == nil

    usage = %{
      tokens: 12_345,
      cost_usd: 0.4231,
      input: 9_000,
      output: 1_200,
      cache_read: 2_000,
      cache_write: 145,
      assistant_messages: 7,
      prompt: "must never cross the wire"
    }

    Process.put(:context_result, {:ok, report(%{usage: usage})})
    assert {:ok, result} = SessionsContext.handle(@params, %{})

    assert result["usage"] == %{
             "tokens" => 12_345,
             "costUsd" => 0.4231,
             "input" => 9_000,
             "output" => 1_200,
             "cacheRead" => 2_000,
             "cacheWrite" => 145,
             "assistantMessages" => 7
           }

    refute inspect(result) =~ "must never cross"

    bad = %{tokens: -1, cost_usd: "free", input: nil, output: 1.5}
    Process.put(:context_result, {:ok, report(%{usage: bad})})
    assert {:ok, bounded} = SessionsContext.handle(@params, %{})
    assert bounded["usage"]["tokens"] == 0
    assert bounded["usage"]["costUsd"] == 0.0
    assert bounded["usage"]["input"] == 0
    assert bounded["usage"]["output"] == 0
  end

  test "an unattributed overhead row is labelled and still sums to the total" do
    categories = report().categories ++ [%{id: :unattributed, tokens: 1_000, items: 0}]

    Process.put(
      :context_result,
      {:ok, report(%{categories: categories, used_tokens: 41_000, overhead: :unavailable})}
    )

    assert {:ok, result} = SessionsContext.handle(@params, %{})
    assert result["overhead"] == "unavailable"
    assert List.last(result["categories"])["label"] == "System prompt and tools (not itemized)"
    assert Enum.sum(Enum.map(result["categories"], & &1["tokens"])) == 41_000
  end

  test "a report violating the sum invariant is refused rather than shown" do
    Process.put(:context_result, {:ok, report(%{used_tokens: 39_999})})
    assert {:error, {:unavailable, _, _}} = SessionsContext.handle(@params, %{})
  end

  test "errors are bounded classifications" do
    Process.put(:context_result, {:error, :session_not_found})
    assert {:error, {:not_found, _, _}} = SessionsContext.handle(@params, %{})

    Process.put(:context_result, {:error, :unavailable})
    assert {:error, {:unavailable, _, _}} = SessionsContext.handle(@params, %{})

    Process.put(:context_result, {:error, {:secret, "/private/path"}})
    assert {:error, {:internal_error, message, nil}} = SessionsContext.handle(@params, %{})
    refute message =~ "/private"
  end

  test "requires read scope, an operator, and bounded params" do
    assert SessionsContext.scopes() == [:read]
    assert "sessions.context" in Registry.list_methods()

    assert {:error, _} =
             Registry.dispatch("sessions.context", @params, %{
               auth: %{role: :node, scopes: [:node]}
             })

    assert {:error, {:invalid_params, _, _}} =
             SessionsContext.handle(%{"sessionKey" => "agent:x:main"}, %{})

    assert {:error, {:invalid_params, _, _}} =
             SessionsContext.handle(%{@params | "sessionKey" => String.duplicate("k", 1025)}, %{})

    refute_receive {:context_usage, _, _}
  end
end
