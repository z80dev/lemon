defmodule LemonControlPlane.EventProjectionTest do
  use ExUnit.Case, async: true

  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.{Cost, ImageContent, TextContent, ThinkingContent, Usage}
  alias LemonControlPlane.EventProjection

  test "projects real typed results, nested usage and ordered visible content without runtime state" do
    result = %AgentToolResult{
      content: [
        %TextContent{text: "first", text_signature: "private-signature"},
        %ThinkingContent{thinking: "hidden-subagent-thought"},
        %TextContent{text: "api_key=projection-secret\nsecond"},
        %ImageContent{data: "aGVsbG8=", mime_type: "image/png"}
      ],
      details: %{
        exit_code: 0,
        runId: "run-1",
        session_id: "session-1",
        actionId: "tool-1",
        usage: %Usage{input: 3, output: 2, total_tokens: 5, cost: %Cost{total: 0.1}},
        diagnostics: %{
          message: "visible diagnostic",
          api_key: "private-key",
          callback: fn -> :private end,
          pid: self(),
          unknown: %URI{path: "private-runtime-path"}
        },
        callback: fn -> :private end,
        state: %{private: "private-state"},
        raw_response: "private-provider-response"
      }
    }

    projected = EventProjection.tool_result(result)
    assert projected["is_error"] == false
    assert projected["trust"] == "trusted"

    assert projected["content"] == [
             %{"type" => "text", "text" => "first"},
             %{"type" => "text", "text" => "api_key=[REDACTED]\nsecond"},
             %{"type" => "image", "mime_type" => "image/png", "data" => "aGVsbG8="}
           ]

    assert projected["details"]["exit_code"] == 0
    assert projected["details"]["runId"] == "run-1"
    assert projected["details"]["session_id"] == "session-1"
    assert projected["details"]["actionId"] == "tool-1"
    assert projected["details"]["usage"]["total_tokens"] == 5
    assert projected["details"]["usage"]["cost"]["total"] == 0.1

    assert projected["details"]["diagnostics"] == %{
             "message" => "visible diagnostic",
             "api_key" => "[REDACTED]"
           }

    json = Jason.encode!(projected)
    refute json =~ "projection-secret"
    refute json =~ "private-"
    refute json =~ "hidden-subagent-thought"
  end

  test "map results use the same public shape and omit unknown structs and signatures" do
    projected =
      EventProjection.tool_result(%{
        "content" => [
          %{"type" => "text", "text" => "visible", "text_signature" => "hidden"},
          %{"type" => "thinking", "thinking" => "hidden"},
          %URI{path: "hidden"}
        ],
        "details" => %{"status" => "done", "private" => "hidden"},
        "isError" => true,
        "trust" => "untrusted",
        "callback" => fn -> :hidden end
      })

    assert projected == %{
             "content" => [%{"type" => "text", "text" => "visible"}],
             "details" => %{"status" => "done"},
             "is_error" => true,
             "trust" => "untrusted"
           }

    assert EventProjection.tool_result(%URI{}) == %{}
  end

  test "display media paths survive typed and operator result projections" do
    result = %AgentToolResult{
      content: [%TextContent{text: "model-visible content"}],
      details: %{media_path: "/repo/drawing.svg", path: "/repo/drawing.svg"}
    }

    projected = EventProjection.tool_result(result)
    assert projected["details"]["media_path"] == "/repo/drawing.svg"
    assert projected["content"] == [%{"type" => "text", "text" => "model-visible content"}]

    operator =
      %{result: "model-visible content"}
      |> CodingAgent.Session.Presentation.put_operator_result(result)
      |> EventProjection.action_detail()

    assert operator.details.media_path == "/repo/drawing.svg"
    assert operator.result == "model-visible content"
  end

  test "bounds JSON bytes, entries, nesting and UTF-8 without exposing a clipped credential" do
    nested = Enum.reduce(1..50, "hidden-at-depth", fn _, acc -> %{"child" => acc} end)

    result = %AgentToolResult{
      content: Enum.map(1..200, fn _ -> %TextContent{text: String.duplicate("é", 20_000)} end),
      details: %{diagnostics: nested, output: "api_key=" <> String.duplicate("s", 50_000)}
    }

    projected = EventProjection.tool_result(result)
    json = Jason.encode!(projected)
    assert byte_size(json) <= 32 * 1024
    assert length(projected["content"]) <= 100
    assert String.valid?(json)
    refute json =~ "hidden-at-depth"

    secret =
      EventProjection.tool_result(%AgentToolResult{
        content: [%TextContent{text: "api_key=" <> String.duplicate("s", 50_000) <> "\nvisible"}]
      })

    assert hd(secret["content"])["text"] == "api_key=[REDACTED]\nvisible"
    bounded = EventProjection.action_detail(%{nested: nested, list: Enum.to_list(1..1_000)})
    refute Jason.encode!(bounded) =~ "hidden-at-depth"
    assert length(Map.get(bounded, :list, [])) <= 100
  end

  test "retains complete diff snapshots and drops both when either would be incomplete" do
    complete =
      EventProjection.tool_result(%AgentToolResult{
        details: %{oldText: "old", newText: "new", path: "lib/a.ex"}
      })

    assert complete["details"]["oldText"] == "old"
    assert complete["details"]["newText"] == "new"

    oversized =
      EventProjection.tool_result(%AgentToolResult{
        details: %{oldText: String.duplicate("o", 17 * 1024), newText: "new", path: "lib/a.ex"}
      })

    refute Map.has_key?(oversized["details"], "oldText")
    refute Map.has_key?(oversized["details"], "newText")
    assert oversized["details"]["path"] == "lib/a.ex"

    image =
      EventProjection.tool_result(%AgentToolResult{
        content: [%ImageContent{data: String.duplicate("a", 17 * 1024)}]
      })

    assert image["content"] == []
  end

  test "action details keep their wire names and project every result spelling" do
    result = %AgentToolResult{content: [%TextContent{text: "bash output"}]}

    projected =
      EventProjection.action_detail(%{
        "partialResult" => result,
        partial_result: result,
        result: result,
        args: %{"command" => "echo hello"},
        callback: fn -> :private end
      })

    assert projected.partial_result["content"] == [%{"type" => "text", "text" => "bash output"}]
    assert projected["partialResult"] == projected.partial_result
    assert projected.result == projected.partial_result
    assert projected.args == %{"command" => "echo hello"}
    refute Map.has_key?(projected, :callback)

    assert EventProjection.tool_result(%{content: [%TextContent{text: "one"} | self()]})[
             "content"
           ] ==
             [%{"type" => "text", "text" => "one"}]
  end

  test "typed completion usage retains current context and budget instead of cumulative fallback" do
    budget = %{
      tokens: 920,
      window: 272_000,
      source: "usage",
      reserve_tokens: 32_000,
      threshold_tokens: 240_000,
      headroom_tokens: 239_080,
      enabled: true
    }

    usage =
      %Usage{
        input: 100,
        output: 20,
        cache_read: 800,
        total_tokens: 100_000,
        cost: %Cost{total: 0.2}
      }
      |> Map.put(:context_tokens, 920)
      |> Map.put(:context_budget, budget)
      |> Map.put(:turns, 3)
      |> Map.put(:tokens, 100_000)
      |> Map.put(:cost_usd, 0.5)
      |> Map.put(:tool_errors, 2)

    projected = EventProjection.action_detail(%{usage: usage})
    assert projected.usage["context_tokens"] == 920
    assert projected.usage["total_tokens"] == 100_000
    assert projected.usage["context_budget"]["tokens"] == 920
    assert projected.usage["context_budget"]["reserve_tokens"] == 32_000
    assert projected.usage["context_budget"]["headroom_tokens"] == 239_080
    assert projected.usage["turns"] == 3
    assert projected.usage["tokens"] == 100_000
    assert projected.usage["cost_usd"] == 0.5
    assert projected.usage["tool_errors"] == 2
  end

  test "actual aborted tool snapshots preserve cancellation and unknown outcome" do
    result = %AgentToolResult{
      content: [%TextContent{text: "STARTED\n"}],
      is_error: true,
      details: %{
        cancelled: true,
        outcome: "unknown",
        started: true,
        partial: true,
        error_type: "aborted",
        execution_duration_ms: 21
      }
    }

    projected = EventProjection.tool_result(result)
    assert projected["details"]["cancelled"] == true
    assert projected["details"]["outcome"] == "unknown"
    assert projected["details"]["partial"] == true
    assert projected["content"] == [%{"type" => "text", "text" => "STARTED\n"}]
  end
end
