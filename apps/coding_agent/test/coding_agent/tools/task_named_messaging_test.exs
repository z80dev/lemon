defmodule CodingAgent.Tools.TaskNamedMessagingTest do
  use ExUnit.Case, async: false

  alias CodingAgent.TaskStore
  alias CodingAgent.Tools.Task.{Control, Messaging}
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.AgentToolResult
  alias LemonCore.AgentMessaging

  # A stateful runtime boundary: admission is sender-scoped, fixed IDs reserve
  # one intent, and status reads reconcile it without dispatching another turn.
  # Router integration tests own actual queue/transport admission; these tests
  # exercise the model-facing tool against observable effects, not echoed args.
  defmodule Runtime do
    use Agent

    def start_link(_),
      do:
        Agent.start_link(
          fn -> %{receipts: %{}, deliveries: [], calls: 0, name: nil, mode: :normal} end,
          name: __MODULE__
        )

    def state, do: Agent.get(__MODULE__, & &1)
    def mode(mode), do: Agent.update(__MODULE__, &Map.put(&1, :mode, mode))

    def list("operator", _opts) do
      state = state()

      {:ok,
       [
         %{
           id: "session://agent:research:main",
           name: state.name,
           kind: :session,
           session_key: "agent:research:main",
           label: "Research",
           status: :unknown,
           scope: "operator",
           metadata: %{private: "secret"}
         }
       ]}
    end

    def rename("operator", "session://agent:research:main" = id, name) do
      Agent.get_and_update(__MODULE__, fn state ->
        cond do
          state.mode == :unknown_rename ->
            {{:ok, %{id: id, name: "wrong"}}, state}

          name == "taken" ->
            {{:error, :name_taken}, state}

          true ->
            name =
              if is_binary(name), do: name |> String.replace_prefix("@", "") |> String.downcase()

            {{:ok, %{id: id, name: name, kind: :session}}, %{state | name: name}}
        end
      end)
    end

    def send(scope, source, target, text, opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        state = %{state | calls: state.calls + 1}
        context = Keyword.fetch!(opts, :source_context)
        id = Keyword.fetch!(opts, :message_id)
        key = {scope, source, id}
        intent = {target, text}

        cond do
          scope != "operator" or source != "session://" <> context.session_key ->
            {{:error, :forbidden}, state}

          context.cwd != "/captured/workspace" or context.tool_policy != %{deny: ["bash"]} ->
            {{:error, :forbidden}, state}

          target not in [
            "@bob",
            "@unknown",
            "@malformed",
            "session://agent:bob:main",
            "bot://fixture/bob"
          ] ->
            {{:error, :not_found}, state}

          Map.has_key?(state.receipts, key) ->
            case state.receipts[key] do
              {^intent, receipt} -> {{:ok, receipt}, state}
              _ -> {{:error, :message_id_conflict}, state}
            end

          true ->
            receipt = %{
              message_id: id,
              source_id: source,
              target_id: "session://agent:bob:main",
              status: :accepted,
              run_id: "run-#{length(state.deliveries) + 1}",
              response: nil
            }

            state = %{
              state
              | receipts: Map.put(state.receipts, key, {intent, receipt}),
                deliveries: state.deliveries ++ [{source, target, text}]
            }

            result =
              case target do
                "@unknown" -> {:error, :outcome_unknown}
                "@malformed" -> {:ok, %{receipt | source_id: "session://agent:foreign:main"}}
                _ -> {:ok, receipt}
              end

            {result, state}
        end
      end)
    end

    def get(scope, source, id) do
      case state().receipts[{scope, source, id}] do
        {_intent, receipt} -> {:ok, receipt}
        nil -> {:error, :not_found}
      end
    end

    def register_external(_, _, _), do: raise("Unexpected external registration")
    def unregister_external(_, _, _), do: raise("Unexpected external deletion")
    def complete_external(_, _, _), do: raise("Unexpected external completion")
  end

  defmodule Mailbox do
    use GenServer
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    def init(owner), do: {:ok, owner}

    def handle_cast({:steer, text}, owner) do
      send(owner, {:family_message, text})
      {:noreply, owner}
    end
  end

  setup do
    start_supervised!(Runtime)
    previous = Application.get_env(:lemon_core, :agent_messaging_runtime)
    assert :ok = AgentMessaging.configure(Runtime)
    on_exit(fn -> AgentMessaging.configure(previous) end)

    opts = [
      session_key: "agent:research:main",
      session_id: "research-session",
      parent_session: "research-session",
      agent_id: "research",
      task_child: false,
      run_id: "source-run-1",
      native_managed_context: false,
      native_source_profile_id: "research",
      native_lineage_handle: "ordinary-lineage",
      tool_policy: %{deny: ["bash"]}
    ]

    %{opts: opts, tool: Messaging.tool("/captured/workspace", opts)}
  end

  test "captured source and policy defeat model authority spoofing; receipt is sender-scoped", %{
    tool: tool,
    opts: opts
  } do
    result =
      invoke(tool, "call-1", %{
        "to" => "@bob",
        "message" => "Review this",
        "source_id" => "session://agent:foreign:main",
        "session_key" => "agent:foreign:main",
        "scope" => "bot:foreign:owner",
        "message_id" => "forged",
        "cwd" => "/wrong",
        "source_context" => %{"tool_policy" => %{}}
      })

    assert %AgentToolResult{
             is_error: false,
             details: %{status: "accepted", source_id: "session://agent:research:main"}
           } = result

    refute result.details.message_id == "forged"

    assert Runtime.state().deliveries == [
             {"session://agent:research:main", "@bob", "Review this"}
           ]

    assert %AgentToolResult{details: %{run_id: "run-1"}} =
             invoke(tool, "status", %{
               "action" => "status",
               "message_id" => result.details.message_id
             })

    other =
      Messaging.tool("/captured/workspace", Keyword.put(opts, :session_key, "agent:other:main"))

    assert {:error, _} =
             invoke(other, "status", %{
               "action" => "status",
               "message_id" => result.details.message_id
             })

    assert Runtime.state().calls == 1
  end

  test "fixed source and run plus tool-call ID deduplicate only the same turn's intent", %{
    tool: tool,
    opts: opts
  } do
    first = invoke(tool, "fixed", %{"to" => "@bob", "message" => "One"})
    assert invoke(tool, "fixed", %{"to" => "@bob", "message" => "One"}).details == first.details
    assert {:error, _} = invoke(tool, "fixed", %{"to" => "@bob", "message" => "Changed"})
    assert length(Runtime.state().deliveries) == 1

    other =
      Messaging.tool("/captured/workspace", Keyword.put(opts, :session_key, "agent:other:main"))

    second = invoke(other, "fixed", %{"to" => "@bob", "message" => "One"})
    refute second.details.message_id == first.details.message_id
    assert length(Runtime.state().deliveries) == 2
    next_turn = Messaging.tool("/captured/workspace", Keyword.put(opts, :run_id, "source-run-2"))

    third =
      invoke(next_turn, "fixed", %{"to" => "@bob", "message" => "One", "run_id" => "source-run-1"})

    refute third.details.message_id in [first.details.message_id, second.details.message_id]

    assert invoke(next_turn, "fixed", %{"to" => "@bob", "message" => "One"}).details ==
             third.details

    assert length(Runtime.state().deliveries) == 3
  end

  test "unknown and malformed admission reconcile without resend or family fallback", %{
    tool: tool
  } do
    for target <- ["@unknown", "@malformed"] do
      before = Runtime.state().calls
      result = invoke(tool, target, %{"to" => target, "message" => "May have arrived"})
      assert %AgentToolResult{is_error: true, details: %{status: "outcome_unknown"}} = result
      assert Runtime.state().calls == before + 1

      assert %AgentToolResult{details: %{status: "accepted"}} =
               invoke(tool, "status", %{
                 "action" => "status",
                 "message_id" => result.details.message_id
               })

      assert Runtime.state().calls == before + 1
    end
  end

  test "bare and agent addresses stay in the real task family while explicit refs route named", %{
    opts: opts
  } do
    parent = start_supervised!({Mailbox, self()}, id: :parent)
    child = start_supervised!({Mailbox, self()}, id: :child)
    opts = Keyword.put(opts, :session_pid, parent)

    id =
      TaskStore.new_task(%{
        owner: Control.owner(opts),
        name: "bob",
        run_id: "family-run",
        parent_session_id: opts[:session_id]
      })

    :ok = Control.register(id, AbortSignal.new(), nil, parent, fn _ -> :ok end)
    :ok = Control.attach_session(id, child, "family-child")

    on_exit(fn ->
      if Process.whereis(Control), do: Control.complete(id)
      TaskStore.delete_task(id)
    end)

    tool = Messaging.tool("/captured/workspace", opts)

    for target <- ["bob", "agent://bob"] do
      assert %AgentToolResult{} =
               invoke(tool, target, %{"to" => target, "message" => "Family only"})

      assert_receive {:family_message, text}
      assert text =~ "Family only"
    end

    assert Runtime.state().calls == 0

    for target <- ["@bob", "session://agent:bob:main", "bot://fixture/bob"] do
      assert %AgentToolResult{details: %{status: "accepted"}} =
               invoke(tool, target, %{"to" => target, "message" => "Named only"})

      refute_receive {:family_message, _}
    end

    assert Runtime.state().calls == 3
    assert {:error, _} = invoke(tool, "missing", %{"to" => "@missing", "message" => "No spawn"})
    assert length(Runtime.state().deliveries) == 3
  end

  test "managed invocations and actual children cannot acquire operator authority", %{opts: opts} do
    for extra <- [
          [native_managed_context: true],
          [invocation_mcp_servers: [%{url: "https://localhost/lemon_bot/invocations/private"}]],
          [task_child: true],
          [task_child: nil, session_scope: :subagent],
          [approval_context: %{native_managed_context: true}]
        ] do
      tool = Messaging.tool("/captured/workspace", Keyword.merge(opts, extra))

      for params <- [
            %{"to" => "@bob", "message" => "Denied"},
            %{"action" => "list", "scope" => "named"},
            %{"action" => "rename", "name" => "bob"},
            %{"action" => "status", "message_id" => "foreign"}
          ] do
        assert {:error, _} = invoke(tool, "denied", params)
      end
    end

    assert Runtime.state().calls == 0
    assert Runtime.state().name == nil
  end

  test "ordinary non-default profile forks can list and rename only themselves", %{opts: opts} do
    tool =
      Messaging.tool(
        "/captured/workspace",
        Keyword.merge(opts,
          parent_session: "ordinary-fork-parent",
          session_scope: :subagent,
          task_child: false
        )
      )

    assert %AgentToolResult{
             details: %{agent: %{id: "session://agent:research:main", name: "alice"}}
           } =
             invoke(tool, "rename", %{
               "action" => "rename",
               "name" => "@Alice",
               "id" => "session://agent:foreign:main"
             })

    assert Runtime.state().name == "alice"
    assert {:error, _} = invoke(tool, "collision", %{"action" => "rename", "name" => "taken"})
    assert Runtime.state().name == "alice"
    roster = invoke(tool, "list", %{"action" => "list", "scope" => "named"})
    assert roster.details.source_id == "session://agent:research:main"
    assert [%{status: :unknown, name: "alice"} = entry] = roster.details.agents
    refute Map.has_key?(entry, :scope)
    refute Map.has_key?(entry, :metadata)

    assert %AgentToolResult{details: %{agent: %{name: nil}}} =
             invoke(tool, "clear", %{"action" => "rename", "name" => nil})

    assert Runtime.state().name == nil
    Runtime.mode(:unknown_rename)

    assert {:error, _} =
             invoke(tool, "uncertain", %{"action" => "rename", "name" => "not-verified"})

    assert Runtime.state().name == nil
  end

  test "invalid input and missing captured call identity never dispatch", %{
    tool: tool,
    opts: opts
  } do
    for text <- [nil, "", "   ", <<255>>, String.duplicate("a", 32_769)] do
      assert {:error, _} = invoke(tool, "bad", %{"to" => "@bob", "message" => text})
    end

    assert {:error, _} = invoke(tool, nil, %{"to" => "@bob", "message" => "No call ID"})
    assert {:error, _} = Messaging.send("@bob", "No call ID", opts)
    no_turn = Messaging.tool("/captured/workspace", Keyword.delete(opts, :run_id))

    assert {:error, _} =
             invoke(no_turn, "fixed", %{
               "to" => "@bob",
               "message" => "No turn",
               "run_id" => "forged"
             })

    unpersisted =
      Messaging.tool("/captured/workspace", Keyword.put(opts, :session_key, "random-id"))

    assert {:error, _} = invoke(unpersisted, "bad", %{"to" => "@bob", "message" => "No session"})
    signal = AbortSignal.new()
    AbortSignal.abort(signal)
    assert {:error, _} = tool.execute.("abort", %{"to" => "@bob", "message" => "No"}, signal, nil)
    assert Runtime.state().calls == 0
  end

  defp invoke(tool, id, params), do: tool.execute.(id, params, nil, nil)
end
