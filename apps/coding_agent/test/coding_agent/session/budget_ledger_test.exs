defmodule CodingAgent.Session.BudgetLedgerTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{Session, SessionManager, SettingsManager}
  alias CodingAgent.Session.{BudgetLedger, EventHandler, MessageSerialization, Persistence}
  alias LemonAi.Types.{AssistantMessage, Cost, Model, ModelCost, TextContent, Usage}

  @moduletag :tmp_dir

  defp message do
    %AssistantMessage{
      role: :assistant,
      content: [%TextContent{text: "done"}],
      api: :mock,
      provider: :mock_provider,
      model: "budget-test",
      stop_reason: :stop,
      timestamp: 1,
      usage: %Usage{input: 6, output: 4, total_tokens: 10, cost: %Cost{total: 0.25}}
    }
  end

  defp start_session(dir, limits, opts \\ []) do
    parent = self()

    model = %Model{
      id: "budget-test",
      name: "Budget test",
      api: :mock,
      provider: :mock_provider,
      base_url: "https://example.invalid",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{},
      context_window: 128_000,
      max_tokens: 1024
    }

    stream_fn = fn _model, _context, _options ->
      send(parent, :provider_called)
      response = message()
      {:ok, stream} = LemonAi.EventStream.start_link()
      LemonAi.EventStream.push(stream, {:start, response})
      LemonAi.EventStream.push(stream, {:done, :stop, response})
      LemonAi.EventStream.complete(stream, response)
      {:ok, stream}
    end

    settings = %SettingsManager{
      budgets: limits,
      compaction_enabled: false,
      retry_enabled: false,
      provider_routing: %{enabled: false}
    }

    options =
      Keyword.merge(
        [
          cwd: dir,
          workspace_dir: Path.join(dir, "workspace"),
          model: model,
          settings_manager: settings,
          stream_fn: stream_fn,
          tools: []
        ],
        opts
      )

    {:ok, session} = Session.start_link(options)

    on_exit(fn ->
      if Process.alive?(session) do
        try do
          GenServer.stop(session)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    session
  end

  defp prompt(session) do
    {:ok, stream} = Session.subscribe(session, mode: :stream)
    :ok = Session.prompt(session, "continue")
    events = stream |> LemonAgent.EventStream.events() |> Enum.to_list()
    refute Session.get_state(session).is_streaming
    events
  end

  defp budget_stop?(events, scope, used) do
    Enum.any?(events, fn
      {:error, {:budget_exceeded, %{scope: ^scope, used: ^used}}, _} -> true
      _ -> false
    end)
  end

  test "descendant ledger persists separately without changing provider usage", %{tmp_dir: dir} do
    session = SessionManager.new(dir)
    session = BudgetLedger.append(session, %{tokens: 10, cost_usd: 0.25})
    session = BudgetLedger.append_children(session, %{tokens: 20, cost_usd: 0.5})
    assert BudgetLedger.restore(session) == %{tokens: 10, cost_usd: 0.25}
    assert BudgetLedger.restore_children(session) == %{tokens: 20, cost_usd: 0.5}
    path = Path.join(dir, "inclusive-budget.jsonl")
    :ok = SessionManager.save_to_file(path, session)
    assert {:ok, restored} = SessionManager.load_from_file(path)
    assert BudgetLedger.restore(restored) == %{tokens: 10, cost_usd: 0.25}
    assert BudgetLedger.restore_children(restored) == %{tokens: 20, cost_usd: 0.5}
  end

  test "native child usage enforces ancestor caps while both usage ledgers stay local", %{
    tmp_dir: dir
  } do
    parent = start_session(dir, %{max_session_cost_usd: 0.25})
    parent_scope = Session.get_state(parent).budget_limits.scope

    child =
      start_session(dir, %{},
        parent_budget_scope: LemonAgent.BudgetScope.attachment(parent_scope),
        run_id: "live-child"
      )

    prompt(child)
    assert_receive :provider_called
    assert %{scope: :session, used: 0.25} = LemonAgent.BudgetScope.check(parent_scope)
    assert Session.get_state(child).budget_usage == %{tokens: 10, cost_usd: 0.25}
    state = Session.get_state(parent)
    assert state.budget_usage == %{tokens: 0, cost_usd: 0.0}
    assert BudgetLedger.restore_children(state.session_manager) == %{tokens: 10, cost_usd: 0.25}
    path = state.session_file
    GenServer.stop(parent)
    resumed = start_session(dir, %{max_session_cost_usd: 0.25}, session_file: path)
    assert budget_stop?(prompt(resumed), :session, 0.25)
    refute_receive :provider_called
  end

  test "unpriced dollar-capped model warns visibly but still runs", %{tmp_dir: dir} do
    session = start_session(dir, %{max_run_cost_usd: 1.0})
    events = prompt(session)

    assert Enum.any?(events, fn
             {:session_event, _, {:budget_warning, %{message: message}}} ->
               message =~ "no known catalog price"

             _ ->
               false
           end)

    assert_receive :provider_called
  end

  test "zero configured cap blocks requests and explicit session limits override settings", %{
    tmp_dir: dir
  } do
    blocked = start_session(dir, %{max_run_tokens: 0})
    assert budget_stop?(prompt(blocked), :run, 0)
    refute_receive :provider_called

    allowed = start_session(dir, %{max_run_tokens: 0}, budget_limits: %{max_run_tokens: 20})
    refute budget_stop?(prompt(allowed), :run, 0)
    assert_receive :provider_called
    assert Session.get_state(allowed).budget_usage.tokens == 10
  end

  test "run counters reset while session usage accumulates across prompts and durable resume", %{
    tmp_dir: dir
  } do
    limits = %{max_run_tokens: 11, max_session_tokens: 20}
    session = start_session(dir, limits)
    refute budget_stop?(prompt(session), :run, 10)
    assert_receive :provider_called
    assert budget_stop?(prompt(session), :session, 20)
    assert_receive :provider_called
    assert Session.get_state(session).budget_usage == %{tokens: 20, cost_usd: 0.5}

    path = Session.get_state(session).session_file
    GenServer.stop(session)
    resumed = start_session(dir, limits, session_file: path)
    assert budget_stop?(prompt(resumed), :session, 20)
    refute_receive :provider_called
  end

  test "rewind and clear do not refund an exhausted session", %{tmp_dir: dir} do
    session = start_session(dir, %{max_session_tokens: 10})
    assert budget_stop?(prompt(session), :session, 10)
    assert_receive :provider_called
    state = Session.get_state(session)

    user =
      Enum.find(SessionManager.entries(state.session_manager), fn entry ->
        entry.type == :message and entry.message["role"] == "user"
      end)

    assert {:ok, preview} = Session.rewind(session, user.id)

    assert {:ok, _} =
             Session.rewind(session, user.id,
               dry_run: false,
               confirmation_token: preview["confirmationToken"]
             )

    assert budget_stop?(prompt(session), :session, 10)
    refute_receive :provider_called

    assert :ok = Session.reset(session)
    assert Session.get_messages(session) == []
    assert budget_stop?(prompt(session), :session, 10)
    refute_receive :provider_called
    state = Session.get_state(session)
    assert {:ok, persisted} = SessionManager.load_from_file(state.session_manager.file_path)
    assert BudgetLedger.restore(persisted) == %{tokens: 10, cost_usd: 0.25}
  end

  test "legacy off-branch spend and compaction survive a branch-only fork", %{tmp_dir: dir} do
    source = SessionManager.new(dir)
    source = SessionManager.append_message(source, %{"role" => "user", "content" => "first"})
    first_id = source.leaf_id

    source =
      SessionManager.append_message(source, MessageSerialization.serialize_message(message()))

    source = SessionManager.set_leaf_id(source, first_id)

    source =
      SessionManager.append_message(source, MessageSerialization.serialize_message(message()))

    assert BudgetLedger.restore(source) == %{tokens: 20, cost_usd: 0.5}

    {source, usage} = BudgetLedger.initialize(source)
    {same, ^usage} = BudgetLedger.initialize(source)
    assert SessionManager.entry_count(same) == SessionManager.entry_count(source)
    source = SessionManager.append_compaction(source, "summary", first_id, 20)
    source_path = Path.join(dir, "source.jsonl")
    destination = Path.join(dir, "fork.jsonl")
    :ok = SessionManager.save_to_file(source_path, source)
    assert {:ok, _fork} = SessionManager.fork_file(source_path, destination, leaf_id: first_id)
    assert {:ok, fork} = SessionManager.load_from_file(destination)
    assert BudgetLedger.restore(fork) == usage

    forked = start_session(dir, %{max_session_tokens: 20}, session_file: destination)
    assert budget_stop?(prompt(forked), :session, 20)
    refute_receive :provider_called
  end

  test "reported interrupted usage is durable without an assistant transcript entry", %{
    tmp_dir: dir
  } do
    manager =
      SessionManager.new(dir) |> SessionManager.persist(Path.join(dir, "interrupted.jsonl"))

    state = %{session_manager: manager, budget_usage: %{tokens: 0, cost_usd: 0.0}}

    event =
      {:usage_budget_updated,
       %{run_usage: %{tokens: 7, cost_usd: 0.2}, session_usage: %{tokens: 7, cost_usd: 0.2}}}

    state = EventHandler.handle(event, state, %{})
    assert BudgetLedger.restore(state.session_manager) == %{tokens: 7, cost_usd: 0.2}
    assert {:ok, restored} = SessionManager.load_from_file(manager.file_path)
    assert BudgetLedger.restore(restored) == %{tokens: 7, cost_usd: 0.2}
    assert SessionManager.build_session_context(restored).messages == []
  end

  test "uncapped completed spend is retained when a cap is enabled later", %{tmp_dir: dir} do
    manager = SessionManager.new(dir) |> SessionManager.persist(Path.join(dir, "uncapped.jsonl"))
    {manager, usage} = BudgetLedger.initialize(manager)
    state = %{session_manager: manager, budget_usage: usage, budget_limits: %{}}
    state = Persistence.persist_message(state, message())
    assert state.budget_usage == %{tokens: 10, cost_usd: 0.25}
    # Reset's agent-side snapshot may lag when counting is disabled; never refund.
    state = BudgetLedger.update(state, %{session_usage: %{tokens: 0, cost_usd: 0}})
    assert state.budget_usage.tokens == 10
    session = start_session(dir, %{max_session_tokens: 10}, session_file: manager.file_path)
    assert budget_stop?(prompt(session), :session, 10)
    refute_receive :provider_called
  end
end
