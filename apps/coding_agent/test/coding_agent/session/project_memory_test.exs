defmodule CodingAgent.Session.ProjectMemoryTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Session.ProjectMemory

  alias LemonAi.Types.{
    AssistantMessage,
    Model,
    TextContent,
    ThinkingContent,
    ToolResultMessage,
    UserMessage
  }

  alias LemonMemory.Project

  @moduletag :tmp_dir

  setup context do
    if context[:exclusive_capture_capacity], do: await_capture_capacity()
    :ok
  end

  setup %{tmp_dir: dir} do
    cwd = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(cwd, ".git"))
    File.mkdir_p!(Path.join(cwd, ".lemon"))

    File.write!(
      Path.join(cwd, ".lemon/config.toml"),
      "[features]\nsession_search = \"default-on\"\n"
    )

    store =
      start_supervised!(
        {LemonMemory.Store, name: __MODULE__.Store, path: Path.join(dir, "store")}
      )

    state = %{
      cwd: cwd,
      workspace_dir: Path.join(dir, "profile"),
      session_scope: :main,
      session_key: "agent:capture:test:#{System.unique_integer([:positive])}",
      agent_id: "capture",
      model: %Model{id: "capture-test", api: :capture_test, provider: :openai},
      settings_manager: %CodingAgent.SettingsManager{
        providers: %{"openai" => %{api_key: "test-only-key"}}
      }
    }

    on_exit(fn -> ProjectMemory.flush(state, 1_000) end)
    %{state: state, store: store}
  end

  test "completed turn extracts real durable facts using bounded model options", %{
    state: state,
    store: store
  } do
    owner = self()
    fact = "Run mix test from the umbrella root."

    complete = fn model, context, options ->
      send(owner, {:extraction, model, context, options})
      response([fact])
    end

    assert {:ok, _} =
             ProjectMemory.after_turn(state, turn(fact), store: store, complete: complete)

    assert :ok = ProjectMemory.flush(state, 5_000)
    assert_receive {:extraction, model, context, options}
    assert model == state.model
    assert options.max_tokens == 1_200
    assert options.api_key == "test-only-key"
    assert context.tools == []
    assert context.system_prompt =~ "confirmed architectural decisions"
    assert [%UserMessage{content: input}] = context.messages
    assert input =~ fact
    assert byte_size(input) <= 12_000
    assert {:ok, [^fact]} = Project.read(state, store: store)
  end

  test "capture uses the configured summary model with its matching credentials", %{
    state: state,
    store: store
  } do
    owner = self()

    settings = %{
      state.settings_manager
      | model_roles: %{"smol" => "anthropic:claude-3-5-haiku-20241022"},
        providers: %{"anthropic" => %{api_key: "summary-only-key", auth_source: :api_key}}
    }

    state = %{state | settings_manager: settings}

    complete = fn model, _, options ->
      send(owner, {:summary_selection, model, options.api_key})
      response([])
    end

    assert {:ok, _} =
             ProjectMemory.after_turn(state, turn("Run checks from the root."),
               store: store,
               complete: complete
             )

    assert :ok = ProjectMemory.flush(state, 5_000)

    assert_receive {:summary_selection,
                    %Model{provider: :anthropic, id: "claude-3-5-haiku-20241022"},
                    "summary-only-key"}

    assert state.model.provider == :openai
  end

  test "successful compaction summary is extracted rather than stored verbatim", %{
    state: state,
    store: store
  } do
    summary = "Confirmed: use SQL migrations. TODO: finish the temporary fixture."
    fact = "Database schema changes use SQL migrations."
    owner = self()

    complete = fn _, context, _ ->
      send(owner, {:summary_input, context.messages})
      response([fact])
    end

    assert {:ok, _} =
             ProjectMemory.after_compaction(state, summary, store: store, complete: complete)

    assert :ok = ProjectMemory.flush(state, 5_000)
    assert_receive {:summary_input, [%UserMessage{content: ^summary}]}
    assert {:ok, [^fact]} = Project.read(state, store: store)
  end

  test "a failed compaction does not invoke capture or alter session state", %{
    state: state,
    store: store
  } do
    assert {:error, :provider_unavailable, ^state} =
             CodingAgent.Session.CompactionManager.apply_compaction_result(
               state,
               {:error, :provider_unavailable},
               nil,
               fn _ -> flunk("failed compaction must not restore messages") end,
               fn _, _ -> flunk("failed compaction must not publish success") end
             )

    assert :ok = ProjectMemory.flush(state, 0)
    assert {:ok, []} = Project.read(state, store: store)
  end

  test "failed, aborted, truncated and unfinished turns never extract", %{
    state: state,
    store: store
  } do
    owner = self()

    complete = fn _, _, _ ->
      send(owner, :unexpected_extraction)
      response(["Unsafe success claim."])
    end

    for reason <- [:error, :aborted, :length, :tool_use, nil] do
      assert :skip =
               ProjectMemory.after_turn(state, [assistant("not complete", reason)],
                 store: store,
                 complete: complete
               )
    end

    assert :skip = ProjectMemory.after_turn(state, [], store: store, complete: complete)
    refute_receive :unexpected_extraction
    assert {:ok, []} = Project.read(state, store: store)
  end

  test "subagents, unscoped sessions and disabled durable memory do no extraction", %{
    state: state,
    store: store
  } do
    owner = self()

    opts = [
      store: store,
      complete: fn _, _, _ ->
        send(owner, :unexpected_extraction)
        response([])
      end
    ]

    assert :skip =
             ProjectMemory.after_turn(%{state | session_scope: :subagent}, turn("mix test"), opts)

    assert :skip = ProjectMemory.after_turn(Map.delete(state, :agent_id), turn("mix test"), opts)

    assert :skip =
             ProjectMemory.after_compaction(Map.delete(state, :workspace_dir), "mix test", opts)

    assert :skip =
             ProjectMemory.after_turn(Map.delete(state, :session_key), turn("mix test"), opts)

    File.write!(
      Path.join(state.cwd, ".lemon/config.toml"),
      "[features]\nsession_search = \"off\"\n"
    )

    assert :skip = ProjectMemory.after_turn(state, turn("mix test"), opts)
    assert :skip = ProjectMemory.after_compaction(state, "mix test", opts)
    refute_receive :unexpected_extraction
  end

  test "disabling auto recall does not disable fact capture", %{state: state, store: store} do
    File.write!(
      Path.join(state.cwd, ".lemon/config.toml"),
      "[memory]\nauto_recall = false\n[features]\nsession_search = \"default-on\"\n"
    )

    fact = "Run mix test from the umbrella root."

    assert {:ok, _} =
             ProjectMemory.after_turn(state, turn(fact),
               store: store,
               complete: fn _, _, _ -> response([fact]) end
             )

    assert :ok = ProjectMemory.flush(state, 5_000)
    assert {:ok, [^fact]} = Project.read(state, store: store)
  end

  test "failed providers and invalid output never claim or persist successful capture", %{
    state: state,
    store: store
  } do
    outputs = [
      {:error, :provider_unavailable},
      {:ok, assistant("[\"Run mix test.\"]", :error)},
      {:ok, assistant("[\"Run mix test.\"]", :length)},
      {:ok, assistant("not JSON")},
      response(List.duplicate("Run mix test.", 13)),
      response([String.duplicate("x", 513)]),
      response(["API_KEY=sk-private123456789"])
    ]

    for output <- outputs do
      assert {:ok, _} =
               ProjectMemory.after_turn(state, turn("Run mix test."),
                 store: store,
                 complete: fn _, _, _ -> output end
               )

      assert :ok = ProjectMemory.flush(state, 5_000)
      assert {:ok, []} = Project.read(state, store: store)
    end
  end

  test "input excludes tools and thinking and redacts secrets before model extraction", %{
    state: state,
    store: store
  } do
    owner = self()

    messages = [
      %UserMessage{content: "Build with mix compile. API_KEY=sk-secret123456789"},
      %ToolResultMessage{content: [%TextContent{text: "raw tool transcript sk-tool123456789"}]},
      %AssistantMessage{
        stop_reason: :stop,
        content: [
          %ThinkingContent{thinking: "private deliberation"},
          %TextContent{text: "Use mix compile."}
        ]
      }
    ]

    complete = fn _, context, _ ->
      send(owner, {:safe_input, hd(context.messages).content})
      response(["Use mix compile."])
    end

    assert {:ok, _} = ProjectMemory.after_turn(state, messages, store: store, complete: complete)
    assert :ok = ProjectMemory.flush(state, 5_000)
    assert_receive {:safe_input, input}
    refute input =~ "sk-secret"
    refute input =~ "API_KEY"
    refute input =~ "raw tool transcript"
    refute input =~ "private deliberation"
    assert {:ok, ["Use mix compile."]} = Project.read(state, store: store)
  end

  test "capture survives the submitting session process exiting", %{state: state, store: store} do
    owner = self()
    fact = "Use deterministic fixtures for provider tests."
    complete = blocking_completion(owner, [fact])

    {caller, ref} =
      spawn_monitor(fn ->
        result = ProjectMemory.after_turn(state, turn(fact), store: store, complete: complete)
        send(owner, {:submitted, result})
      end)

    assert_receive {:submitted, {:ok, worker}}, 2_000
    assert_receive {:DOWN, ^ref, :process, ^caller, :normal}
    assert_receive {:extracting, extraction, _input}, 2_000
    assert Process.alive?(worker)
    assert {:error, :timeout} = ProjectMemory.flush(state, 0)
    send(extraction, :finish)
    assert :ok = ProjectMemory.flush(state, 5_000)
    assert {:ok, [^fact]} = Project.read(state, store: store)
  end

  test "inflight duplicates coalesce and only latest pending snapshot follows the older commit",
       %{state: state, store: store} do
    owner = self()
    old = "Build with mix compile."
    newest = "Test with mix test."

    complete = fn _, context, _ ->
      owner_ref = Process.monitor(owner)
      input = hd(context.messages).content
      send(owner, {:extracting, self(), input})

      receive do
        :finish -> response([if(String.contains?(input, newest), do: newest, else: old)])
        {:DOWN, ^owner_ref, :process, ^owner, _} -> {:error, :test_stopped}
      end
    end

    opts = [store: store, complete: complete]

    assert {:ok, worker} = ProjectMemory.after_turn(state, turn(old), opts)
    assert_receive {:extracting, first, _}, 2_000
    for _ <- 1..10, do: assert({:ok, ^worker} = ProjectMemory.after_turn(state, turn(old), opts))

    for i <- 1..30 do
      assert {:ok, ^worker} =
               ProjectMemory.after_turn(state, turn("Intermediate snapshot #{i}"), opts)
    end

    assert {:ok, ^worker} = ProjectMemory.after_turn(state, turn(newest), opts)
    assert {:error, :busy} = ProjectMemory.after_turn(state, turn("Over admission budget"), opts)
    send(first, :finish)
    assert_receive {:extracting, second, input}, 2_000
    assert input =~ newest
    # A duplicate of the old active snapshot cannot be queued behind the new one.
    assert {:ok, ^worker} = ProjectMemory.after_turn(state, turn(old), opts)
    send(second, :finish)
    assert :ok = ProjectMemory.flush(state, 5_000)
    refute_receive {:extracting, _, _}
    assert {:ok, [^newest, ^old]} = Project.read(state, store: store)
  end

  @tag :exclusive_capture_capacity
  test "project admission is bounded and profile/project identities never share facts", %{
    state: state,
    store: store
  } do
    owner = self()
    complete = blocking_completion(owner, ["Use mix test."])
    opts = [store: store, complete: complete]

    states = for i <- 1..9, do: scoped(state, i)

    for scoped <- Enum.take(states, 8) do
      assert {:ok, _} = ProjectMemory.after_turn(scoped, turn("Use mix test."), opts)
    end

    assert {:error, :busy} =
             ProjectMemory.after_turn(List.last(states), turn("Use mix test."), opts)

    for _ <- 1..8 do
      assert_receive {:extracting, pid, _}, 2_000
      send(pid, :finish)
    end

    for scoped <- states, do: assert(:ok = ProjectMemory.flush(scoped, 5_000))
    assert {:ok, []} = Project.read(state, store: store)
    assert {:ok, []} = Project.read(List.last(states), store: store)
    assert {:ok, ["Use mix test."]} = Project.read(hd(states), store: store)
    assert {:ok, []} = Project.read(%{hd(states) | cwd: Path.dirname(state.cwd)}, store: store)
  end

  @tag :exclusive_capture_capacity
  test "exited workers free their project and slot before the registry prunes them", %{
    state: state,
    store: store
  } do
    owner = self()
    opts = [store: store, complete: blocking_completion(owner, ["Use mix test."])]
    {first, second} = Enum.split(for(i <- 1..16, do: scoped(state, i)), 8)

    # Registry drops an exited process's keys asynchronously, in its partition
    # processes. Holding them leaves every finished worker's entries behind, as
    # a loaded scheduler does between a worker exiting and the next admission.
    partitions =
      for {_, pid, _, _} <- Supervisor.which_children(CodingAgent.ProcessRegistry), do: pid

    Enum.each(partitions, &:sys.suspend/1)

    try do
      capture_all(first, opts)
      capture_all(second, opts)
      capture_all([hd(first)], opts)
    after
      Enum.each(partitions, &:sys.resume/1)
    end

    assert {:ok, ["Use mix test."]} = Project.read(hd(second), store: store)
  end

  test "provider jobs time out without blocking flush or persisting facts", %{
    state: state,
    store: store
  } do
    owner = self()
    complete = blocking_completion(owner, ["Must not persist after timeout."])

    assert {:ok, _} =
             ProjectMemory.after_turn(state, turn("mix test"),
               store: store,
               complete: complete,
               timeout_ms: 500
             )

    assert_receive {:extracting, pid, _}, 2_000
    ref = Process.monitor(pid)
    assert :ok = ProjectMemory.flush(state, 5_000)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    assert {:ok, []} = Project.read(state, store: store)
  end

  test "input and output byte budgets include Unicode and reject oversized blocks" do
    text = String.duplicate("é", 10_000)
    assert {:ok, input} = ProjectMemory.turn_input(turn(text))
    assert String.valid?(input)
    assert byte_size(input) <= 12_000
    assert {:ok, bounded} = ProjectMemory.turn_input(turn(String.duplicate("x", 32_001)))
    refute bounded =~ "xxx"

    assert {:error, :invalid_extraction} =
             ProjectMemory.decode_response(
               response(List.duplicate(String.duplicate("x", 500), 9))
             )

    assert {:error, :invalid_extraction} =
             ProjectMemory.decode_response(response([%{"fact" => "mix test"}]))

    assert {:ok, []} = ProjectMemory.decode_response(response([]))
  end

  defp await_capture_capacity do
    # Captures intentionally outlive their sessions. Earlier suite cases can
    # still own slots after their test processes exit; wait for their actual
    # workers to drain before asserting that all eight slots are available.
    workers =
      for slot <- 1..8,
          {pid, _} <- Registry.lookup(CodingAgent.ProcessRegistry, {ProjectMemory, :slot, slot}),
          Process.alive?(pid),
          do: {slot, pid, Process.monitor(pid)}

    deadline = System.monotonic_time(:millisecond) + 31_000

    for {slot, pid, ref} <- workers do
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        remaining ->
          flunk(
            "capture slot #{slot} still held by #{inspect(pid)}; " <>
              "initial_call=#{inspect(:proc_lib.translate_initial_call(pid))}; " <>
              "keys=#{inspect(Registry.keys(CodingAgent.ProcessRegistry, pid))}"
          )
      end
    end
  end

  defp scoped(state, i), do: %{state | workspace_dir: state.workspace_dir <> "-#{i}"}

  defp capture_all(states, opts) do
    for scoped <- states do
      assert {:ok, _} = ProjectMemory.after_turn(scoped, turn("Use mix test."), opts)
    end

    for _ <- states do
      assert_receive {:extracting, pid, _}, 2_000
      send(pid, :finish)
    end

    for scoped <- states, do: assert(:ok = ProjectMemory.flush(scoped, 5_000))
  end

  defp turn(text),
    do: [%UserMessage{content: "What are the repository conventions?"}, assistant(text)]

  defp assistant(text, reason \\ :stop),
    do: %AssistantMessage{stop_reason: reason, content: [%TextContent{text: text}]}

  defp response(facts), do: {:ok, assistant(Jason.encode!(facts))}

  defp blocking_completion(owner, facts) do
    fn _, context, _ ->
      owner_ref = Process.monitor(owner)
      send(owner, {:extracting, self(), hd(context.messages).content})

      receive do
        :finish -> response(facts)
        {:DOWN, ^owner_ref, :process, ^owner, _} -> {:error, :test_stopped}
      end
    end
  end
end
