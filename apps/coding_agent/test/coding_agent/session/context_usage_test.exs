defmodule CodingAgent.Session.ContextUsageTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{Compaction, SessionManager, SettingsManager}
  alias CodingAgent.Session.{ContextUsage, Persistence, PromptComposer}
  alias LemonAgent.Types.AgentTool

  alias LemonAi.Types.{
    AssistantMessage,
    Model,
    TextContent,
    ToolCall,
    ToolResultMessage,
    Usage,
    UserMessage
  }

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    settings = %{SettingsManager.load(tmp_dir) | reserve_tokens: 1_000, compaction_enabled: true}
    %{settings: settings}
  end

  defp model(window), do: %Model{id: "test-model", provider: :anthropic, context_window: window}

  defp tools do
    for name <- ~w(read bash) do
      %AgentTool{
        name: name,
        description: "#{name} tool " <> String.duplicate("description ", 20),
        parameters: %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}},
        label: name,
        execute: fn _, _, _, _ -> :ok end
      }
    end
  end

  defp transcript(opts \\ []) do
    usage = Keyword.get(opts, :usage)

    [
      %UserMessage{content: "please inspect the repository", timestamp: 10},
      %AssistantMessage{
        content: [
          %TextContent{text: "Reading."},
          %ToolCall{id: "c1", name: "read", arguments: %{"path" => "lib/app.ex"}}
        ],
        usage: usage,
        stop_reason: :tool_use,
        timestamp: 20
      },
      %ToolResultMessage{
        tool_call_id: "c1",
        tool_name: "read",
        content: [%TextContent{text: String.duplicate("defmodule App do end\n", 400)}],
        timestamp: 30
      },
      %AssistantMessage{
        content: [%TextContent{text: "Done reading."}],
        usage: usage,
        stop_reason: :stop,
        timestamp: 40
      }
    ]
  end

  defp live_state(tmp_dir, settings, window) do
    workspace = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace)

    File.write!(
      Path.join(workspace, "MEMORY.md"),
      "remembered fact " <> String.duplicate("x", 400)
    )

    File.write!(Path.join(tmp_dir, "AGENTS.md"), "project rules " <> String.duplicate("y", 2_000))

    sections =
      PromptComposer.compose_sections(tmp_dir, nil, nil, workspace, :main, "", %{
        tool_names: ~w(read bash read_skill remember),
        contributed_sections: []
      })

    %{
      session_manager: SessionManager.new(tmp_dir),
      settings_manager: settings,
      model: model(window),
      prompt_sections: sections
    }
  end

  defp sum(report), do: Enum.reduce(report.categories, 0, &(&1.tokens + &2))
  defp tokens(report, id), do: Enum.find(report.categories, &(&1.id == id)).tokens

  test "estimated categories sum to the compaction trigger's request estimate", %{
    tmp_dir: tmp_dir,
    settings: settings
  } do
    state = live_state(tmp_dir, settings, 200_000)
    # Planning guidance is appended after the composed base prompt.
    prompt = CodingAgent.SystemPrompt.join_sections(state.prompt_sections) <> "\n\n## Planning"
    agent = %{system_prompt: prompt, tools: tools(), messages: transcript()}

    report = ContextUsage.measure(state, agent)

    assert report.source == "estimate"
    assert report.overhead == :live
    assert sum(report) == report.used_tokens
    assert report.used_tokens == report.estimated_tokens

    assert report.used_tokens ==
             Compaction.estimate_request_context_tokens(agent.messages, prompt, agent.tools)

    assert Enum.map(report.categories, & &1.id) == ContextUsage.categories()
    assert tokens(report, :context_files) > 500
    assert tokens(report, :memory) > 100
    assert tokens(report, :tool_results) > tokens(report, :user_messages)
    assert Enum.find(report.categories, &(&1.id == :tool_definitions)).items == 2

    labels = Enum.map(report.top, & &1.label)
    assert "read result #3" in labels
    assert "AGENTS.md (project)" in labels
    assert length(report.top) <= 10
    assert report.top == Enum.sort_by(report.top, & &1.tokens, :desc)

    other =
      Enum.find(
        ContextUsage.overhead(state, agent).items,
        &(&1.label == "Other system prompt text")
      )

    assert other.category == :system_prompt
    refute Enum.any?(labels, &String.contains?(&1, tmp_dir))
  end

  test "provider-reported usage is the total and categories are scaled to sum to it", %{
    tmp_dir: tmp_dir,
    settings: settings
  } do
    state = live_state(tmp_dir, settings, 200_000)
    usage = %Usage{input: 41_000, output: 300, cache_read: 2_000, cache_write: 7}
    agent = %{system_prompt: "short", tools: tools(), messages: transcript(usage: usage)}

    report = ContextUsage.measure(state, agent)

    assert report.source == "usage"
    assert report.used_tokens == 43_307
    assert sum(report) == 43_307
    assert report.estimated_tokens < 43_307
    assert report.free_tokens == 200_000 - 43_307
    assert report.percent_used == 21.7
    assert report.auto_compaction.threshold_tokens == 199_000
    assert report.auto_compaction.headroom_tokens == 199_000 - 43_307

    # Newer messages after the usage anchor are estimated on top of it.
    newer = agent.messages ++ [%UserMessage{content: String.duplicate("z", 400), timestamp: 50}]
    plus = ContextUsage.measure(state, %{agent | messages: newer})
    assert plus.source == "usage+estimate"
    assert plus.used_tokens == 43_407
    assert sum(plus) == 43_407
  end

  test "window and percent boundaries", %{tmp_dir: tmp_dir, settings: settings} do
    agent = %{system_prompt: nil, tools: [], messages: transcript(usage: %Usage{input: 5_000})}
    state = live_state(tmp_dir, settings, 5_000)

    full = ContextUsage.measure(state, agent)
    assert full.used_tokens == 5_000
    assert full.free_tokens == 0
    assert full.percent_used == 100.0

    over = ContextUsage.measure(%{state | model: model(4_000)}, agent)
    assert over.free_tokens == 0
    assert over.percent_used == 125.0
    assert over.auto_compaction.headroom_tokens == 0

    unknown = ContextUsage.measure(%{state | model: model(nil)}, agent)
    assert unknown.window == nil
    assert unknown.free_tokens == nil
    assert unknown.percent_used == nil
    assert unknown.auto_compaction == nil
    assert Enum.all?(unknown.categories, &is_nil(&1.percent))
    assert sum(unknown) == 5_000

    empty = ContextUsage.measure(state, %{system_prompt: nil, tools: [], messages: []})
    assert empty.used_tokens == 0
    assert empty.percent_used == 0.0
    assert sum(empty) == 0
  end

  test "an automatic recall block counts as memory, not as the user's words", %{
    tmp_dir: tmp_dir,
    settings: settings
  } do
    recall = "\n\n<recalled-context>" <> String.duplicate("past ", 200) <> "</recalled-context>"
    user = %UserMessage{content: "what did we decide?" <> recall, timestamp: 1}

    strip = fn
      %UserMessage{content: content} = message ->
        %{message | content: String.replace_suffix(content, recall, "")}

      message ->
        message
    end

    state = live_state(tmp_dir, settings, 100_000)
    agent = %{system_prompt: nil, tools: [], messages: [user]}
    report = ContextUsage.measure(state, agent, strip_recall: strip)

    assert tokens(report, :user_messages) ==
             Compaction.estimate_text_tokens("what did we decide?")

    assert tokens(report, :memory) + tokens(report, :user_messages) ==
             Compaction.estimate_message_tokens(user)

    assert sum(report) == report.used_tokens
  end

  test "compaction replaces message share with a summary in durable reads", %{
    tmp_dir: tmp_dir,
    settings: settings
  } do
    manager =
      transcript()
      |> Enum.map(&CodingAgent.Session.MessageSerialization.serialize_message/1)
      |> Enum.reduce(SessionManager.new(tmp_dir), &SessionManager.append_message(&2, &1))

    overhead = %{
      items: [
        %{category: :system_prompt, label: "Identity", tokens: 400},
        %{category: :tool_definitions, label: "read", tokens: 300}
      ],
      measured_at: 1
    }

    state = %{session_manager: manager, model: model(100_000), settings_manager: settings}
    messages = Persistence.restore_messages_from_session(manager)
    assert {:ok, before} = ContextUsage.measure_durable(state, messages, overhead)

    assert before.overhead == :snapshot
    assert before.live == false
    assert sum(before) == before.used_tokens
    assert tokens(before, :system_prompt) == 400
    assert tokens(before, :summaries) == 0

    kept_id = manager.leaf_id

    compacted =
      SessionManager.append_compaction(
        manager,
        "Read lib/app.ex; nothing left.",
        kept_id,
        before.used_tokens
      )

    state = %{state | session_manager: compacted}
    messages = Persistence.restore_messages_from_session(compacted)
    assert {:ok, after_compaction} = ContextUsage.measure_durable(state, messages, overhead)

    assert sum(after_compaction) == after_compaction.used_tokens
    assert tokens(after_compaction, :summaries) > 0
    assert tokens(after_compaction, :tool_results) == 0
    assert after_compaction.used_tokens < before.used_tokens

    message_ids = [:user_messages, :assistant_messages, :tool_results, :summaries]

    share = fn report ->
      Enum.sum(Enum.map(message_ids, &tokens(report, &1))) / report.used_tokens
    end

    assert share.(after_compaction) < share.(before)
  end

  test "durable reads without a recorded overhead profile", %{
    tmp_dir: tmp_dir,
    settings: settings
  } do
    state = %{
      session_manager: SessionManager.new(tmp_dir),
      model: model(100_000),
      settings_manager: settings
    }

    assert {:error, :unavailable} = ContextUsage.measure_durable(state, transcript(), nil)

    measured = transcript(usage: %Usage{input: 9_000, output: 100})
    assert {:ok, report} = ContextUsage.measure_durable(state, measured, nil)
    assert report.overhead == :unavailable
    assert report.used_tokens == 9_100
    assert sum(report) == 9_100
    unattributed = Enum.find(report.categories, &(&1.id == :unattributed))
    assert unattributed.tokens == 9_100 - report.estimated_tokens

    # Messages estimated above the reported total are scaled down, never negative overhead.
    small = transcript(usage: %Usage{input: 10, output: 1})
    assert {:ok, scaled} = ContextUsage.measure_durable(state, small, nil)
    assert scaled.used_tokens == 11
    assert sum(scaled) == 11
    refute Enum.any?(scaled.categories, &(&1.id == :unattributed))
  end

  test "overhead profiles round-trip through the store and skip identical rewrites", %{
    tmp_dir: tmp_dir,
    settings: settings
  } do
    id = "context-usage-test-" <> LemonCore.Id.uuid()
    on_exit(fn -> LemonCore.Store.delete(:session_context_overhead, id) end)

    state = live_state(tmp_dir, settings, 100_000)

    agent = %{
      system_prompt: CodingAgent.SystemPrompt.join_sections(state.prompt_sections),
      tools: tools()
    }

    profile = ContextUsage.overhead(state, agent)

    assert ContextUsage.record_overhead(id, profile) == profile
    stored = ContextUsage.stored_overhead(id)
    assert stored.items == profile.items

    LemonCore.Store.delete(:session_context_overhead, id)
    assert ContextUsage.record_overhead(id, %{profile | measured_at: 2}, profile) == profile
    assert ContextUsage.stored_overhead(id) == nil
    assert ContextUsage.record_overhead(nil, profile) == nil
  end

  describe "session usage" do
    alias CodingAgent.Session.{BudgetLedger, MessageSerialization}

    defp assistant(input, output, cache_read, cache_write, cost) do
      %AssistantMessage{
        role: :assistant,
        content: [%TextContent{text: "done"}],
        stop_reason: :stop,
        timestamp: 1,
        usage: %Usage{
          input: input,
          output: output,
          cache_read: cache_read,
          cache_write: cache_write,
          total_tokens: input + output + cache_read + cache_write,
          cost: %LemonAi.Types.Cost{total: cost}
        }
      }
    end

    test "sums active-branch assistant tokens and reports the cumulative ledger", %{
      tmp_dir: tmp_dir
    } do
      manager = SessionManager.new(tmp_dir)
      manager = SessionManager.append_message(manager, %{"role" => "user", "content" => "hi"})
      root_id = manager.leaf_id

      # An abandoned branch: counted by the ledger, not by the branch sums.
      manager =
        SessionManager.append_message(
          manager,
          MessageSerialization.serialize_message(assistant(1_000, 100, 0, 0, 0.5))
        )

      manager = SessionManager.set_leaf_id(manager, root_id)

      manager =
        SessionManager.append_message(
          manager,
          MessageSerialization.serialize_message(assistant(200, 30, 400, 50, 0.25))
        )

      manager =
        SessionManager.append_message(
          manager,
          MessageSerialization.serialize_message(assistant(300, 20, 600, 0, 0.125))
        )

      assert ContextUsage.session_usage(manager) == %{
               tokens: 1_100 + 680 + 920,
               cost_usd: 0.875,
               input: 500,
               output: 50,
               cache_read: 1_000,
               cache_write: 50,
               assistant_messages: 2
             }

      # An explicit ledger wins over derived values.
      usage = ContextUsage.session_usage(manager, %{tokens: 9_999, cost_usd: 1.5})
      assert usage.tokens == 9_999
      assert usage.cost_usd == 1.5

      {manager, _ledger} = BudgetLedger.initialize(manager)
      assert ContextUsage.session_usage(manager).tokens == 2_700
    end

    test "nullable branch counters stay unknown independently of numeric budget totals", %{
      tmp_dir: tmp_dir
    } do
      manager =
        SessionManager.new(tmp_dir)
        |> SessionManager.append_message(%{
          "role" => "assistant",
          "usage" => %{"input" => 20, "output" => 3, "cache_read" => 0, "cache_write" => 0}
        })
        |> SessionManager.append_message(%{
          "role" => "assistant",
          "usage" => %{"input" => nil, "output" => 2, "cache_read" => nil, "cache_write" => 0}
        })
        |> SessionManager.append_message(%{
          "role" => "assistant",
          "usage" => %{"input" => 10, "output" => 1, "cache_read" => 0, "cache_write" => 0}
        })

      assert ContextUsage.session_usage(manager, %{tokens: 36, cost_usd: 0.5}) == %{
               tokens: 36,
               cost_usd: 0.5,
               input: nil,
               output: 6,
               cache_read: nil,
               cache_write: 0,
               assistant_messages: 3
             }
    end

    test "nullable cumulative ledger metrics remain unknown in session projections", %{
      tmp_dir: tmp_dir
    } do
      manager =
        SessionManager.new(tmp_dir)
        |> BudgetLedger.append(%{tokens: nil, cost_usd: nil})

      usage = ContextUsage.session_usage(manager)
      assert usage.tokens == nil
      assert usage.cost_usd == nil
      assert usage.input == 0
      assert usage.output == 0

      known_tokens = ContextUsage.session_usage(manager, %{tokens: 130, cost_usd: nil})
      assert known_tokens.tokens == 130
      assert known_tokens.cost_usd == nil
    end

    test "missing assistant usage is unknown while an empty branch has zero counters", %{
      tmp_dir: tmp_dir
    } do
      manager = SessionManager.new(tmp_dir)
      empty = ContextUsage.session_usage(manager, %{tokens: 0, cost_usd: 0.0})
      assert empty.input == 0
      assert empty.output == 0
      assert empty.assistant_messages == 0

      manager =
        SessionManager.append_message(manager, %{"role" => "assistant", "usage" => nil})

      usage = ContextUsage.session_usage(manager, %{tokens: 0, cost_usd: 0.0})
      assert is_nil(usage.input)
      assert is_nil(usage.output)
      assert is_nil(usage.cache_read)
      assert is_nil(usage.cache_write)
      assert usage.assistant_messages == 1
      assert usage.tokens == 0
      assert usage.cost_usd == 0.0
    end
  end
end
