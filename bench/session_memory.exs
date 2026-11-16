# Run only through session_memory.py, which supplies a disposable HOME and VM.
defmodule LemonBench.SessionMemory do
  alias CodingAgent.{Session, SessionRegistry, SessionSupervisor, SettingsManager}
  alias CodingAgent.Session.RootLifecycle
  alias LemonAgent.Agent, as: NativeAgent
  alias LemonAi.Types.{AssistantMessage, Model, ModelCost, TextContent, Usage}

  @prompt String.duplicate("fixture request ", 128)
  @answer String.duplicate("fixture answer ", 256)

  def run do
    root = System.fetch_env!("LEMON_MEMORY_BENCH_ROOT")
    ^root = Path.dirname(System.fetch_env!("HOME"))
    File.cd!(Path.join(root, "cwd"))
    Application.put_env(:tzdata, :autoupdate, :disabled)
    Application.put_env(:lemon_gateway, :health_enabled, false)
    Application.put_env(:lemon_gateway, :gateway_ingress_enabled, false)
    Application.put_env(:lemon_core, LemonCore.Secrets, key_providers: [:file])
    Application.put_env(:coding_agent, :primary_session, nil)
    Application.put_env(:coding_agent, :process_store_path, Path.join(root, "processes.dets"))
    # Reject any accidental provider/HTTP path instead of falling back to a real service.
    Req.default_options(plug: fn _conn -> raise "memory benchmark forbids HTTP requests" end)
    {:ok, _started} = Application.ensure_all_started(:coding_agent)

    samples = integer_env("SAMPLES")
    turns = integer_env("TURNS")
    hibernate_ms = integer_env("HIBERNATE_MS")

    rows =
      for kind <- [:child, :root], mode <- [:idle, :hibernated], reduce: [] do
        rows ->
          # Warm module/tool caches identically before retaining each cohort's samples.
          _ = trial(kind, mode, turns, hibernate_ms, 0)
          rows ++ Enum.map(1..samples, &trial(kind, mode, turns, hibernate_ms, &1))
      end

    File.write!(
      Path.join(root, "result.json"),
      Jason.encode!(%{
        environment: %{
          elixir: System.version(),
          otp: to_string(:erlang.system_info(:otp_release)),
          erts: to_string(:erlang.system_info(:version)),
          schedulers_online: :erlang.system_info(:schedulers_online),
          word_size_bytes: :erlang.system_info(:wordsize)
        },
        settings: %{
          prompt_bytes_per_turn: byte_size(@prompt),
          answer_bytes_per_turn: byte_size(@answer),
          production_hibernate_after_ms: 5_000,
          root_idle_ttl_ms: RootLifecycle.idle_ttl_ms(),
          max_idle_roots: RootLifecycle.max_idle_roots(),
          task_max_concurrency: Application.fetch_env!(:coding_agent, :task_max_concurrency),
          task_max_depth: SettingsManager.load(File.cwd!()).task.max_depth
        },
        samples: rows
      })
    )
  end

  defp trial(kind, mode, turns, hibernate_ms, index) do
    observer = self()
    id = "memory-#{kind}-#{System.unique_integer([:positive, :monotonic])}"

    opts = [
      cwd: File.cwd!(),
      session_id: id,
      session_key: "agent:memory:#{id}",
      run_id: id,
      agent_id: "memory-benchmark",
      register: true,
      session_scope: if(kind == :child, do: :subagent, else: :main),
      task_child: kind == :child,
      task_depth: if(kind == :child, do: 1, else: 0),
      parent_session: if(kind == :child, do: "memory-fixture-parent"),
      executor_root: kind == :root,
      session_mode: :coding,
      persona: false,
      project_memory_capture: false,
      extension_inventory: {[], []},
      mcp_tools: [],
      thinking_level: :off,
      settings_manager: %SettingsManager{
        compaction_enabled: false,
        retry_enabled: false,
        default_thinking_level: :off
      },
      model: model(),
      stream_fn: fn model, context, _options -> fixture(observer, model, context) end,
      hibernate_after: if(mode == :idle, do: :infinity, else: hibernate_ms)
    ]

    {:ok, session} = SessionSupervisor.start_session(opts)

    try do
      initial = Session.get_state(session)
      agent = initial.agent
      budget = Map.fetch!(initial.budget_limits, :scope)
      unsubscribe = Session.subscribe(session)

      for turn <- 1..turns do
        run_turn(kind, session, agent, id, opts, turn > 1)
      end

      state = NativeAgent.get_state(agent)
      message_count = length(state.messages)
      true = message_count >= turns * 2
      tool_count = length(state.tools)

      settle([session, agent], mode, hibernate_ms)
      memory = memory(session, agent, budget, mode)
      settle([session, agent], mode, hibernate_ms)

      {session_us, false} = timed(fn -> Session.streaming?(session) end)
      settle([session, agent], mode, hibernate_ms)
      {agent_us, ^id} = timed(fn -> NativeAgent.get_session_id(agent) end)
      settle([session, agent], mode, hibernate_ms)

      # Root checkout uses #564's actual rebind/retention path, not a resumed journal.
      provider_us = run_turn(kind, session, agent, id, opts, true)
      ^agent = Session.get_state(session).agent
      {:ok, ^session} = SessionRegistry.lookup(id)
      settle([session, agent], mode, hibernate_ms)

      {reload_us, %{refreshed: 1, busy: 0, failed: 0}} =
        timed(fn -> CodingAgent.CodeReload.refresh_sessions([id]) end)

      {:ok, ^session} = SessionRegistry.lookup(id)
      ^agent = Session.get_state(session).agent
      false = Session.streaming?(session)
      :ok = unsubscribe.()

      %{
        cohort: "#{kind}_#{mode}",
        sample: index,
        retained_messages_at_memory_sample: message_count,
        tool_count: tool_count,
        same_session_and_agent_after_turn_and_refresh: true,
        metrics:
          Map.merge(memory, %{
            session_scalar_call_us: session_us,
            agent_scalar_call_us: agent_us,
            next_turn_to_provider_us: provider_us,
            reload_refresh_us: reload_us
          })
      }
    after
      monitor = Process.monitor(session)
      :ok = SessionSupervisor.stop_session(session)

      receive do
        {:DOWN, ^monitor, :process, ^session, _reason} -> drain_session_events(id)
      after
        5_000 -> raise "session teardown timed out"
      end
    end
  end

  defp run_turn(kind, session, agent, id, opts, checkout?) do
    started = now()

    if kind == :root and checkout? do
      {:ok, ^session} = RootLifecycle.checkout(id, opts)
    end

    :ok = Session.prompt(session, @prompt)

    {provider, requested_at} =
      receive do
        {:fixture_request, provider, requested_at} -> {provider, requested_at}
      after
        15_000 -> raise "fixture provider request missing"
      end

    send(provider, :release_fixture)
    wait_terminal(id, now() + 15_000_000)
    :ok = NativeAgent.wait_for_idle(agent, timeout: 15_000)
    false = Session.streaming?(session)

    if kind == :root do
      :ok = RootLifecycle.retain(session)
      true = is_integer(Session.get_state(session).root_idle_token)
    else
      :ok = Session.save(session)
    end

    requested_at - started
  end

  defp fixture(observer, model, _context) do
    send(observer, {:fixture_request, self(), now()})

    receive do
      :release_fixture -> :ok
    after
      15_000 -> raise "fixture provider release missing"
    end

    message = %AssistantMessage{
      content: [%TextContent{text: @answer}],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: %Usage{},
      stop_reason: :stop,
      timestamp: 0
    }

    {:ok, stream} = LemonAi.EventStream.start_link()
    :ok = LemonAi.EventStream.push(stream, {:start, message})
    :ok = LemonAi.EventStream.push(stream, {:text_start, 0, message})
    :ok = LemonAi.EventStream.push(stream, {:text_delta, 0, @answer, message})
    :ok = LemonAi.EventStream.push(stream, {:text_end, 0, @answer, message})
    :ok = LemonAi.EventStream.push(stream, {:done, :stop, message})
    :ok = LemonAi.EventStream.complete(stream, message)
    {:ok, stream}
  end

  # Refresh/teardown can emit events after the final turn. Do not let old
  # subscriptions fill the observer's mailbox and trip later delivery limits.
  defp drain_session_events(id) do
    receive do
      {:session_event, ^id, _event, _cursor} -> drain_session_events(id)
    after
      0 -> :ok
    end
  end

  defp wait_terminal(id, deadline) do
    remaining = max(div(deadline - now(), 1_000), 0)

    receive do
      {:session_event, ^id, {:agent_end, _messages}, _cursor} -> :ok
      {:session_event, ^id, {:error, _reason}, _cursor} -> raise "fixture turn failed"
      {:session_event, ^id, _event, _cursor} -> wait_terminal(id, deadline)
    after
      remaining -> raise "session terminal event missing"
    end
  end

  # process_info does not send GenServer requests, reset idle timeouts, copy
  # histories, or force GC. Never use :sys.get_state to detect hibernation.
  defp settle(pids, mode, hibernate_ms) do
    deadline = now() + (hibernate_ms + 15_000) * 1_000
    await_quiet(pids, mode, deadline)
  end

  defp await_quiet(pids, mode, deadline) do
    if Enum.all?(pids, &quiet?(&1, mode)) do
      :ok
    else
      if now() >= deadline, do: raise("session/agent did not enter #{mode} state")
      Process.sleep(1)
      await_quiet(pids, mode, deadline)
    end
  end

  defp quiet?(pid, mode) do
    case Process.info(pid, [:status, :message_queue_len, :current_function]) do
      [status: :waiting, message_queue_len: 0, current_function: function] ->
        hibernated =
          function in [{:erlang, :hibernate, 3}, {:gen_server, :loop_hibernate, 4}]

        hibernated == (mode == :hibernated)

      nil ->
        raise "measured process exited"

      _ ->
        false
    end
  end

  defp memory(session, agent, budget, mode) do
    true = quiet?(session, mode) and quiet?(agent, mode)
    session_info = Process.info(session, [:memory, :binary])
    agent_info = Process.info(agent, [:memory, :binary])
    {:memory, budget_bytes} = Process.info(budget, :memory)
    true = quiet?(session, mode) and quiet?(agent, mode)
    session_bytes = Keyword.fetch!(session_info, :memory)
    agent_bytes = Keyword.fetch!(agent_info, :memory)

    # Ref-counted binaries can be shared between both owners (and other processes).
    # Report their unique referenced size separately, never call it private memory.
    binaries =
      (Keyword.fetch!(session_info, :binary) ++ Keyword.fetch!(agent_info, :binary))
      |> Enum.reduce(%{}, fn {identity, size, _refs}, sizes ->
        Map.update(sizes, identity, size, &max(&1, size))
      end)
      |> Map.values()
      |> Enum.sum()

    %{
      session_process_bytes: session_bytes,
      agent_process_bytes: agent_bytes,
      session_agent_process_bytes: session_bytes + agent_bytes,
      budget_scope_process_bytes: budget_bytes,
      session_agent_budget_process_bytes: session_bytes + agent_bytes + budget_bytes,
      session_agent_unique_referenced_binary_bytes: binaries
    }
  end

  defp model do
    %Model{
      id: "memory-fixture",
      name: "Memory fixture (no provider)",
      api: :mock,
      provider: :mock_provider,
      base_url: "https://memory.invalid",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{},
      context_window: 128_000,
      max_tokens: 4_096
    }
  end

  defp timed(fun) do
    started = now()
    result = fun.()
    {now() - started, result}
  end

  defp now, do: System.monotonic_time(:microsecond)

  defp integer_env(name),
    do: System.fetch_env!("LEMON_MEMORY_BENCH_" <> name) |> String.to_integer()
end

LemonBench.SessionMemory.run()
