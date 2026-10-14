defmodule CodingAgent.ControlPlaneProviderTest do
  @moduledoc """
  Checks the coding provider against the shared core runtime contract and
  verifies boot registration and adapter return shapes.
  """

  use ExUnit.Case, async: false

  alias CodingAgent.ControlPlaneProvider

  @behaviour_module LemonCore.AgentRuntime.Provider

  test "implements every callback the core runtime declares" do
    expected = @behaviour_module.behaviour_info(:callbacks) |> Enum.sort()
    assert Code.ensure_loaded?(ControlPlaneProvider)

    missing =
      Enum.reject(expected, fn {fun, arity} ->
        function_exported?(ControlPlaneProvider, fun, arity)
      end)

    assert missing == [],
           "provider is missing: #{inspect(missing)} — a typo here degrades the method to its fallback silently"
  end

  test "the running application has registered this provider" do
    assert LemonCore.AgentRuntime.provider() == ControlPlaneProvider
    assert LemonCore.AgentRuntime.available?()
  end

  describe "adapters return the shapes the control plane expects" do
    @tag :tmp_dir
    test "resolves reviewer instructions with enforced read-only policy", %{tmp_dir: cwd} do
      agents = Path.join(cwd, ".lemon/agents")
      File.mkdir_p!(agents)

      File.write!(Path.join(agents, "reviewer.md"), """
      ---
      description: Local review policy
      model: openai-codex:gpt-6.1-sol
      read_only: false
      tools: [read, write, bash]
      ---
      Check the exact proposed changes before approval.
      """)

      assert {:ok, persona} = ControlPlaneProvider.resolve_subagent(cwd, "reviewer")
      assert persona.prompt =~ "Check the exact proposed changes"
      assert persona.model == "openai-codex:gpt-6.1-sol"
      assert persona.tool_policy.allow == ["read"]
      refute Map.has_key?(persona, :source)

      assert {:error, :persona_unavailable} =
               ControlPlaneProvider.resolve_subagent(cwd, "../reviewer")
    end

    test "list_tasks returns id/record pairs" do
      assert is_list(ControlPlaneProvider.list_tasks())
    end

    test "compact_session reports a missing session rather than raising" do
      assert ControlPlaneProvider.compact_session(
               "no-such-session-#{System.unique_integer()}",
               []
             ) ==
               {:error, :session_not_found}
    end

    test "todo_progress carries the actionable count for the control plane to rename" do
      progress = ControlPlaneProvider.todo_progress("no-such-session-#{System.unique_integer()}")
      assert progress.actionable_count == 0
    end

    test "wasm_sidecar_running? is a boolean" do
      assert is_boolean(ControlPlaneProvider.wasm_sidecar_running?())
    end

    test "extension_dirs returns global then project" do
      dirs = ControlPlaneProvider.extension_dirs("/tmp/some-project")

      assert length(dirs) == 2
      assert Enum.all?(dirs, &is_binary/1)
    end
  end

  describe "durable native session adapters" do
    setup do
      cwd = Path.join(System.tmp_dir!(), "provider-session-#{System.unique_integer([:positive])}")
      File.mkdir_p!(cwd)
      source_key = "source-#{LemonCore.Id.uuid()}"
      destination_key = "fork-#{LemonCore.Id.uuid()}"

      session =
        CodingAgent.SessionManager.new(cwd)
        |> CodingAgent.SessionManager.append_entry(
          CodingAgent.SessionManager.SessionEntry.model_change("openai-codex", "gpt-6.1-sol")
        )
        |> CodingAgent.SessionManager.append_message(%{
          "role" => "user",
          "content" => "Decision: append-only JSONL"
        })
        |> CodingAgent.SessionManager.append_message(%{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Remembered"}]
        })
        |> CodingAgent.SessionManager.append_message(%{
          "role" => "user",
          "content" => "TODO: blue widgets"
        })

      path = CodingAgent.Session.Presentation.session_file_path(session.header.id, cwd)
      :ok = CodingAgent.SessionManager.save_to_file(path, session)

      :ok =
        LemonCore.ChatStateStore.put(source_key, %LemonCore.ChatState{
          last_engine: "lemon",
          last_resume_token: session.header.id
        })

      on_exit(fn ->
        LemonCore.ChatStateStore.delete(source_key)
        LemonCore.ChatStateStore.delete(destination_key)
        File.rm_rf!(CodingAgent.Config.sessions_dir(cwd))
        File.rm_rf!(cwd)
      end)

      %{cwd: cwd, source: source_key, destination: destination_key, session: session, path: path}
    end

    test "fork creates a distinct resume token and replays independent history", context do
      assert :ok =
               ControlPlaneProvider.session_fork(context.source, context.cwd, context.destination)

      child = LemonCore.ChatStateStore.get(context.destination)
      assert child.last_engine == "lemon"
      refute child.last_resume_token == context.session.header.id

      assert {:ok, entries} =
               ControlPlaneProvider.session_history(context.destination, context.cwd)

      child_path =
        CodingAgent.Session.Presentation.session_file_path(child.last_resume_token, context.cwd)

      assert {:ok, child_session} = CodingAgent.SessionManager.load_from_file(child_path)
      assert entries == CodingAgent.SessionManager.get_branch(child_session)

      assert CodingAgent.SessionManager.build_session_context(child_session) ==
               CodingAgent.SessionManager.build_session_context(context.session)

      assert CodingAgent.Session.BudgetLedger.restore(child_session) ==
               CodingAgent.Session.BudgetLedger.restore(context.session)

      assert {:error, :destination_exists} =
               ControlPlaneProvider.session_fork(context.source, context.cwd, context.destination)
    end

    test "manual compaction works after the native session process has stopped", context do
      assert :ok =
               ControlPlaneProvider.compact_session(context.source,
                 cwd: context.cwd,
                 summary: "Decision: append-only JSONL",
                 keep_recent_tokens: 5
               )

      assert {:ok, session} = CodingAgent.SessionManager.load_from_file(context.path)
      assert Enum.any?(CodingAgent.SessionManager.get_branch(session), &(&1.type == :compaction))
    end

    test "durable context usage carries the session usage ledger and branch token sums",
         context do
      assistant = %LemonAi.Types.AssistantMessage{
        role: :assistant,
        content: [%LemonAi.Types.TextContent{text: "Counted."}],
        stop_reason: :stop,
        timestamp: 1,
        usage: %LemonAi.Types.Usage{
          input: 700,
          output: 80,
          cache_read: 300,
          cache_write: 20,
          total_tokens: 1_100,
          cost: %LemonAi.Types.Cost{total: 0.0375}
        }
      }

      session =
        context.session
        |> CodingAgent.SessionManager.append_message(
          CodingAgent.Session.MessageSerialization.serialize_message(assistant)
        )

      :ok = CodingAgent.SessionManager.save_to_file(context.path, session)

      assert {:ok, report} =
               ControlPlaneProvider.session_context_usage(context.source, context.cwd)

      assert report.live == false
      assert report.usage.input == 700
      assert report.usage.output == 80
      assert report.usage.cache_read == 300
      assert report.usage.cache_write == 20
      assert report.usage.assistant_messages == 2
      assert report.usage.tokens == 1_100
      assert report.usage.cost_usd == 0.0375
    end
  end
end
