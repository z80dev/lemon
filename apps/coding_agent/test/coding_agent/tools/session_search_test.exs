defmodule CodingAgent.Tools.SessionSearchTest do
  use ExUnit.Case, async: true

  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent
  alias CodingAgent.Tools.SessionSearch

  defp doc(attrs) do
    defaults = %{
      doc_id: "mem_1",
      session_key: "agent:test:older",
      started_at_ms: 1_000,
      ingested_at_ms: 1_100,
      prompt_summary: "Investigate modpack launch",
      answer_summary: "Found the modpack launch fix."
    }

    Map.merge(defaults, attrs)
  end

  defp decode(%AgentToolResult{content: [%TextContent{text: text}]}) do
    Jason.decode!(text)
  end

  test "schema exposes Hermes-compatible inferred shapes without mode" do
    tool = SessionSearch.tool("/tmp/project")
    params = tool.parameters["properties"]

    assert tool.name == "session_search"
    assert "query" in Map.keys(params)
    assert "session_id" in Map.keys(params)
    assert "around_message_id" in Map.keys(params)
    assert "window" in Map.keys(params)
    assert "role_filter" in Map.keys(params)
    refute Map.has_key?(params, "mode")
    assert tool.description =~ "DISCOVERY"
    assert tool.description =~ "SCROLL"
    assert tool.description =~ "BROWSE"
    assert String.downcase(tool.description) =~ "no-llm"
  end

  test "discovery searches the calling agent's own sessions and returns scroll anchors" do
    tool =
      SessionSearch.tool("/tmp/project",
        session_key: "agent:test:current",
        session_search_fn: fn query, opts ->
          send(self(), {:search, query, opts})

          [
            doc(%{
              doc_id: "mem_old",
              session_key: "agent:test:older",
              started_at_ms: 1_000,
              prompt_summary: "modpack launch failure"
            }),
            doc(%{
              doc_id: "mem_current",
              session_key: "agent:test:current",
              started_at_ms: 2_000,
              prompt_summary: "current session should be filtered"
            })
          ]
        end
      )

    payload =
      tool.execute.("call-1", %{"query" => "modpack", "limit" => 999}, nil, nil) |> decode()

    assert_receive {:search, "modpack", [scope: :agent, scope_key: "test", limit: 10]}

    assert payload["success"] == true
    assert payload["mode"] == "discover"
    assert payload["count"] == 1

    assert [%{"session_id" => "agent:test:older", "matchMessageId" => 10_001}] =
             payload["results"]
  end

  test "discovery searches the whole store only with the explicit :all opt-in" do
    tool =
      SessionSearch.tool("/tmp/project",
        session_key: "agent:test:current",
        session_search_scope: :all,
        session_search_fn: fn query, opts ->
          send(self(), {:search, query, opts})
          []
        end
      )

    tool.execute.("call-all", %{"query" => "modpack"}, nil, nil)

    assert_receive {:search, "modpack", [scope: :all, scope_key: nil, limit: 3]}
  end

  test "discovery supports newest and oldest sorting" do
    docs = [
      doc(%{session_key: "old", started_at_ms: 1_000}),
      doc(%{session_key: "new", started_at_ms: 3_000})
    ]

    tool =
      SessionSearch.tool("/tmp/project",
        session_search_fn: fn _query, _opts -> docs end
      )

    newest =
      tool.execute.("call-2", %{"query" => "modpack", "sort" => "newest"}, nil, nil) |> decode()

    oldest =
      tool.execute.("call-3", %{"query" => "modpack", "sort" => "oldest"}, nil, nil) |> decode()

    assert get_in(newest, ["results", Access.at(0), "session_id"]) == "new"
    assert get_in(oldest, ["results", Access.at(0), "session_id"]) == "old"
  end

  test "browse returns recent current-session runs" do
    tool =
      SessionSearch.tool("/tmp/project",
        session_key: "agent:test:main",
        session_history_fn: fn session_key, opts ->
          send(self(), {:history, session_key, opts})

          [
            {"run_2",
             %{
               started_at: 2_000,
               summary: %{prompt: "second prompt", completed: %{answer: "second answer"}}
             }},
            {"run_1",
             %{
               started_at: 1_000,
               summary: %{prompt: "first prompt", completed: %{answer: "first answer"}}
             }}
          ]
        end
      )

    payload = tool.execute.("call-4", %{}, nil, nil) |> decode()

    assert_receive {:history, "agent:test:main", [limit: 3]}
    assert payload["success"] == true
    assert payload["mode"] == "browse"
    assert payload["count"] == 2
    assert get_in(payload, ["results", Access.at(0), "run_id"]) == "run_2"
  end

  test "browse without current session fails closed" do
    tool = SessionSearch.tool("/tmp/project")
    payload = tool.execute.("call-5", %{}, nil, nil) |> decode()

    assert payload["success"] == false
    assert payload["mode"] == "browse"
    assert payload["error"] =~ "current session"
  end

  test "scroll uses session_id and around_message_id ahead of query" do
    tool =
      SessionSearch.tool("/tmp/project",
        session_key: "agent:test:current",
        session_search_fn: fn _query, _opts ->
          flunk("search should not run when scroll args are present")
        end,
        session_history_fn: fn "agent:test:old", opts ->
          send(self(), {:history, opts})

          [
            {"run_2",
             %{started_at: 2_000, summary: %{prompt: "two", completed: %{answer: "done two"}}}},
            {"run_1",
             %{started_at: 1_000, summary: %{prompt: "one", completed: %{answer: "done one"}}}}
          ]
        end
      )

    payload =
      tool.execute.(
        "call-6",
        %{
          "query" => "ignored",
          "session_id" => "agent:test:old",
          "around_message_id" => 10_002,
          "window" => 1
        },
        nil,
        nil
      )
      |> decode()

    assert_receive {:history, [limit: 50]}
    assert payload["success"] == true
    assert payload["mode"] == "scroll"
    assert payload["window"] == 1
    assert Enum.any?(payload["messages"], &(&1["anchor"] == true and &1["id"] == 10_002))
  end

  test "scroll rejects the current session and bad anchors" do
    current =
      SessionSearch.tool("/tmp/project",
        session_key: "agent:test:current",
        session_history_fn: fn _session, _opts -> [] end
      )

    current_payload =
      current.execute.(
        "call-7",
        %{"session_id" => "agent:test:current", "around_message_id" => 1},
        nil,
        nil
      )
      |> decode()

    missing =
      SessionSearch.tool("/tmp/project",
        session_key: "agent:test:current",
        session_history_fn: fn _session, _opts -> [] end
      )

    missing_payload =
      missing.execute.(
        "call-8",
        %{"session_id" => "agent:test:old", "around_message_id" => 99},
        nil,
        nil
      )
      |> decode()

    assert current_payload["success"] == false
    assert current_payload["error"] =~ "current session"
    assert missing_payload["success"] == false
    assert missing_payload["error"] =~ "not in session"
  end

  test "scroll refuses sessions belonging to a different agent without the :all opt-in" do
    tool =
      SessionSearch.tool("/tmp/project",
        session_key: "agent:test:current",
        session_history_fn: fn _session, _opts ->
          flunk("history must not be read for a cross-agent session")
        end
      )

    payload =
      tool.execute.(
        "call-cross",
        %{"session_id" => "agent:other:main", "around_message_id" => 1},
        nil,
        nil
      )
      |> decode()

    assert payload["success"] == false
    assert payload["error"] =~ "outside this agent's scope"
  end

  test "scroll allows cross-agent sessions with the :all opt-in" do
    tool =
      SessionSearch.tool("/tmp/project",
        session_key: "agent:test:current",
        session_search_scope: :all,
        session_history_fn: fn "agent:other:main", _opts ->
          [
            {"run_1",
             %{started_at: 1_000, summary: %{prompt: "one", completed: %{answer: "done one"}}}}
          ]
        end
      )

    payload =
      tool.execute.(
        "call-cross-ok",
        %{"session_id" => "agent:other:main", "around_message_id" => 10_001},
        nil,
        nil
      )
      |> decode()

    assert payload["success"] == true
    assert payload["mode"] == "scroll"
  end

  test "scroll and browse redact run-history content that matches secret patterns" do
    history_fn = fn _session, _opts ->
      [
        {"run_1",
         %{
           started_at: 1_000,
           summary: %{
             prompt: "please use api_key: sk-abcdefghijklmnopqrstu123456 for the deploy",
             completed: %{answer: "done, no secrets here"}
           }
         }}
      ]
    end

    browse_tool =
      SessionSearch.tool("/tmp/project",
        session_key: "agent:test:current",
        session_history_fn: history_fn
      )

    browse_payload = browse_tool.execute.("call-redact-1", %{}, nil, nil) |> decode()

    browse_contents =
      browse_payload["results"]
      |> List.first()
      |> Map.get("messages")
      |> Enum.map(& &1["content"])

    assert Enum.any?(browse_contents, &(&1 =~ "redacted"))
    refute Enum.any?(browse_contents, &(&1 =~ "sk-abcdefghijklmnop"))
    assert "done, no secrets here" in browse_contents

    scroll_tool =
      SessionSearch.tool("/tmp/project",
        session_key: "agent:test:current",
        session_history_fn: history_fn
      )

    scroll_payload =
      scroll_tool.execute.(
        "call-redact-2",
        %{"session_id" => "agent:test:old", "around_message_id" => 10_001},
        nil,
        nil
      )
      |> decode()

    scroll_contents = Enum.map(scroll_payload["messages"], & &1["content"])
    assert Enum.any?(scroll_contents, &(&1 =~ "redacted"))
    refute Enum.any?(scroll_contents, &(&1 =~ "sk-abcdefghijklmnop"))
  end
end
