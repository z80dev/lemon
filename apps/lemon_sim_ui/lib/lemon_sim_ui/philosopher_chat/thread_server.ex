defmodule LemonSimUi.PhilosopherChat.ThreadServer do
  @moduledoc """
  One durable, serialized GenServer per PhilosopherChat thread.

  Owns the conversation loop: user messages, paced autonomous agent turns
  (jittered delays, chained replies, idle chatter), typing status, per-agent
  memory roots, persistence, and PubSub broadcasts for the SSE API.
  """

  use GenServer

  require Logger

  alias LemonCore.{Bus, Event, Store}
  alias LemonSim.Examples.PhilosopherChat, as: Domain
  alias LemonSim.Examples.PhilosopherChat.Pacing
  alias LemonSim.Kernel.Runner
  alias LemonSim.LLM.GameHelpers.Config, as: GameConfig
  alias LemonSimUi.PhilosopherChat
  alias LemonSimUi.PhilosopherChat.Thread

  def start_link(thread_id) when is_binary(thread_id) do
    case Store.get(PhilosopherChat.thread_table(), thread_id) |> Thread.normalize() do
      %Thread{} = thread -> GenServer.start_link(__MODULE__, thread, name: via(thread_id))
      _ -> {:error, :thread_not_found}
    end
  end

  def via(thread_id), do: {:via, Registry, {LemonSimUi.PhilosopherChat.Registry, thread_id}}

  def view(thread_id), do: GenServer.call(via(thread_id), :view, 10_000)
  def post_user_message(thread_id, text), do: GenServer.call(via(thread_id), {:post_user_message, text}, 15_000)
  def nudge(thread_id, agent_id), do: GenServer.call(via(thread_id), {:nudge, agent_id}, 10_000)
  def set_status(thread_id, status), do: GenServer.call(via(thread_id), {:set_status, status}, 10_000)
  def memories(thread_id, agent_id), do: GenServer.call(via(thread_id), {:memories, agent_id}, 10_000)

  @impl true
  def init(%Thread{} = thread) do
    restore_rng(thread.rng_state)

    state = %{
      thread: thread,
      rng: :rand.export_seed(),
      ai_ref: nil,
      typing: nil,
      timers: %{},
      chain_remaining: 0,
      quiet_timer: nil
    }

    {:ok, state, {:continue, :restore_runtime}}
  end

  @impl true
  def handle_continue(:restore_runtime, state) do
    state = reschedule_pending_turn(state)
    {:noreply, schedule_idle_check(state)}
  end

  # -- calls --

  @impl true
  def handle_call(:view, _from, state) do
    world = state.thread.game_state.world
    projection = Domain.thread_projection(world)

    {:reply,
     {:ok,
      Map.merge(projection, %{
        typing: state.typing,
        ai_busy: state.ai_ref != nil
      })},
     state}
  end

  def handle_call({:post_user_message, text}, _from, state) do
    with :ok <- require_active(state),
         {:ok, next_state, _signal} <- Domain.post_message(state.thread.game_state, "you", text) do
      state = commit_message(%{state | thread: %{state.thread | game_state: next_state}}, "you")
      {:reply, {:ok, view_payload(state)}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:nudge, agent_id}, _from, state) do
    {result, next_state} =
      cond do
        state.thread.status != "active" ->
          {{:error, :thread_not_active}, state}

        not is_binary(agent_id) or agent_id == "you" or agent_id not in state.thread.member_ids ->
          {{:error, :not_a_member}, state}

        not agent_turn_available?(state) ->
          {{:error, :cooldown_active}, state}

        true ->
          {{:ok, %{scheduled: agent_id}}, schedule_agent_turn(state, agent_id, :nudge)}
      end

    {:reply, result, next_state}
  end

  def handle_call({:set_status, status}, _from, state) when status in ["active", "paused", "closed"] do
    with {:ok, next_state} <- Domain.set_status(state.thread.game_state, status) do
      thread = %{state.thread | game_state: next_state, status: status, updated_at_ms: now_ms()}
      :ok = persist(thread)
      broadcast(state, "status", %{status: status})
      state = %{state | thread: thread}

      state =
        if status == "active" do
          schedule_idle_check(state)
        else
          state
        end

      {:reply, {:ok, %{status: status}}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:set_status, _status}, _from, state),
    do: {:reply, {:error, :invalid_status}, state}

  def handle_call({:memories, agent_id}, _from, state) do
    {:reply, {:ok, read_agent_memories(state.thread.id, agent_id)}, state}
  end

  # -- timers --

  @impl true
  def handle_info({:agent_turn, actor_id, ref}, state) do
    state = %{state | timers: Map.delete(state.timers, ref)}

    cond do
      state.thread.status != "active" ->
        state = clear_pending_turn(state)
        {:noreply, state}

      state.ai_ref != nil ->
        # Another turn is already running; drop this one.
        state = clear_pending_turn(state)
        {:noreply, state}

      not agent_turn_available?(state) ->
        state = clear_pending_turn(state)
        {:noreply, state}

      true ->
        state = clear_pending_turn(state)
        {:noreply, start_ai_turn(state, actor_id)}
    end
  end

  def handle_info(:idle_chatter, state) do
    state = %{state | quiet_timer: nil}
    state = schedule_idle_check(state)

    if state.thread.status == "active" and state.ai_ref == nil and agent_turn_available?(state) do
      {chatter, rng} = Pacing.idle_chatter?(state.thread.pace, state.rng)
      state = %{state | rng: rng}

      if chatter do
        {agent, rng} = Pacing.random_agent(state.thread.game_state.world, state.rng)
        state = %{state | rng: rng}
        {:noreply, maybe_schedule(state, agent)}
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:ai_result, generation, actor_id, result}, state) do
    if state.ai_ref == {generation, actor_id} do
      state = %{state | ai_ref: nil, typing: nil}

      state =
        case result do
          {:ok, %{state: next_state, message_count_delta: delta}} when delta > 0 ->
            commit_agent_messages(state, next_state, actor_id)

          {:ok, _} ->
            # Silent turn: the model only touched memory. Nothing visible to post.
            thread = %{state.thread | updated_at_ms: now_ms()}
            :ok = persist(thread)
            %{state | thread: thread}

          {:error, reason} ->
            Logger.error(
              "PhilosopherChat agent turn failed (#{actor_id}): #{PhilosopherChat.error_class(reason)}"
            )

            broadcast(state, "agent_error", %{
              agent_id: actor_id,
              reason: PhilosopherChat.error_class(reason)
            })

            state
        end

      {:noreply, schedule_idle_check(state)}
    else
      {:noreply, state}
    end
  end

  # -- message commit & scheduling --

  defp commit_message(state, _author) do
    world = state.thread.game_state.world
    messages = get_in(world, [:messages]) || []
    last = List.last(messages)

    thread = %{
      state.thread
      | game_state: state.thread.game_state,
        last_message: last,
        updated_at_ms: now_ms()
    }

    :ok = persist(thread)
    broadcast(state, "message", %{message: last})
    state = %{state | thread: thread}
    schedule_after_message(state)
  end

  defp commit_agent_messages(state, next_state, actor_id) do
    old_count = length(get_in(state.thread.game_state.world, [:messages]) || [])
    new_msgs = get_in(next_state.world, [:messages]) || []
    added = Enum.drop(new_msgs, old_count)

    thread = %{
      state.thread
      | game_state: Domain.clear_actor(next_state),
        last_message: List.last(added),
        updated_at_ms: now_ms()
    }

    :ok = persist(thread)
    state = %{state | thread: thread}

    Enum.each(added, fn msg -> broadcast(state, "message", %{message: msg}) end)
    schedule_after_message(state)
    _ = actor_id
    state
  end

  defp schedule_after_message(state) do
    world = state.thread.game_state.world
    last_author = Map.get(world, :last_author)
    user_id = Domain.user_id()

    state =
      if last_author == user_id do
        %{state | chain_remaining: Pacing.max_chain(state.thread.pace)}
      else
        state
      end

    case last_author do
      ^user_id ->
        schedule_next_in_chain(state)

      a when is_binary(a) ->
        if state.chain_remaining > 0 do
          {chime, rng} = Pacing.continue_chatter?(state.thread.pace, state.rng)
          state = %{state | rng: rng}
          if chime, do: schedule_next_in_chain(state), else: %{state | chain_remaining: 0}
        else
          state
        end

      _ ->
        state
    end
  end

  defp schedule_next_in_chain(state) do
    cond do
      state.chain_remaining <= 0 -> state
      state.ai_ref != nil -> state
      not agent_turn_available?(state) -> state
      true ->
        {agent, rng} = Pacing.pick_responder(state.thread.game_state.world, state.rng)
        state = %{state | rng: rng, chain_remaining: state.chain_remaining - 1}
        maybe_schedule(state, agent)
    end
  end

  defp maybe_schedule(state, nil), do: state

  defp maybe_schedule(state, agent_id) do
    schedule_agent_turn(state, agent_id, :reply)
  end

  defp schedule_agent_turn(state, agent_id, kind) do
    {delay_ms, rng} =
      case kind do
        :nudge -> Pacing.nudge_delay_ms(state.thread.pace, state.rng)
        _ -> Pacing.reply_delay_ms(state.thread.pace, state.rng)
      end

    state = %{state | rng: rng}
    ref = make_ref()
    timer = Process.send_after(self(), {:agent_turn, agent_id, ref}, delay_ms)

    thread = %{
      state.thread
      | pending_turn: %{actor_id: agent_id, due_at_ms: now_ms() + delay_ms},
        updated_at_ms: now_ms()
    }

    :ok = persist(thread)
    %{state | thread: thread, timers: Map.put(state.timers, ref, timer)}
  end

  defp clear_pending_turn(state) do
    if state.thread.pending_turn do
      thread = %{state.thread | pending_turn: nil, updated_at_ms: now_ms()}
      :ok = persist(thread)
      %{state | thread: thread}
    else
      state
    end
  end

  defp reschedule_pending_turn(state) do
    case state.thread.pending_turn do
      %{actor_id: agent_id, due_at_ms: due_at_ms}
      when state.thread.status == "active" ->
        remaining = max(due_at_ms - now_ms(), 0)
        ref = make_ref()
        timer = Process.send_after(self(), {:agent_turn, agent_id, ref}, remaining)

        thread = %{state.thread | pending_turn: nil, updated_at_ms: now_ms()}
        :ok = persist(thread)

        %{state | thread: thread, timers: Map.put(state.timers, ref, timer)}

      _ ->
        state
    end
  end

  defp schedule_idle_check(state) do
    if state.quiet_timer do
      Process.cancel_timer(state.quiet_timer)
    end

    if state.thread.status == "active" do
      ref = Process.send_after(self(), :idle_chatter, Pacing.idle_after_ms(state.thread.pace))
      %{state | quiet_timer: ref}
    else
      %{state | quiet_timer: nil}
    end
  end

  # -- AI turn execution --

  defp start_ai_turn(state, actor_id) do
    generation = make_ref()
    thread = state.thread
    world = thread.game_state.world
    now = now_ms()
    last_agent_at = Map.get(world, :last_agent_at_ms)
    cooldown = Pacing.min_cooldown_ms(thread.pace)

    if is_integer(last_agent_at) and now - last_agent_at < cooldown do
      # Cooldown not met yet — reschedule.
      {delay, rng} = Pacing.reply_delay_ms(thread.pace, state.rng)
      state = %{state | rng: rng}
      ref = make_ref()
      timer = Process.send_after(self(), {:agent_turn, actor_id, ref}, delay)

      thread = %{thread | pending_turn: %{actor_id: actor_id, due_at_ms: now + delay}}
      :ok = persist(thread)

      %{state | thread: thread, timers: Map.put(state.timers, ref, timer)}
    else
      broadcast(state, "typing", %{agent_id: actor_id})
      state = %{state | typing: actor_id}
      parent = self()

      case Task.Supervisor.start_child(LemonSimUi.PhilosopherChat.AiTaskSupervisor, fn ->
             result = run_ai_turn(thread, actor_id)
             send(parent, {:ai_result, generation, actor_id, result})
           end) do
        {:ok, _pid} ->
          %{state | ai_ref: {generation, actor_id}}

        {:error, reason} ->
          Logger.error("PhilosopherChat AI task start failed: #{inspect(reason)}")
          broadcast(state, "agent_error", %{agent_id: actor_id, reason: "ai_task_failed"})
          %{state | typing: nil}
      end
    end
  end

  defp run_ai_turn(thread, actor_id) do
    modules =
      Application.get_env(:lemon_sim_ui, :philosopher_chat_modules) || Domain.modules()

    opts =
      ai_opts()
      |> Domain.default_opts()
      |> Keyword.put(:persist?, false)
      |> Keyword.put(:memory_root, PhilosopherChat.memory_root())
      |> Keyword.put(:memory_namespace, PhilosopherChat.memory_namespace(thread.id))

    game_state = Domain.with_actor(thread.game_state, actor_id)
    old_count = length(get_in(game_state.world, [:messages]) || [])
    adapter = Map.get(modules, :decision_adapter)

    with {:ok, decision, _state} <- Runner.decide_once(game_state, modules, opts),
         {:ok, events} <- adapter.to_events(decision, game_state, opts),
         {:ok, next_state, signal} <-
           Runner.ingest_events(game_state, events, Map.fetch!(modules, :updater), halt_on_decide?: false) do
      new_count = length(get_in(next_state.world, [:messages]) || [])
      {:ok, %{state: next_state, signal: signal, message_count_delta: new_count - old_count}}
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp ai_opts do
    overrides =
      Application.get_env(:lemon_sim_ui, :philosopher_chat_ai_opts) ||
        Application.get_env(:lemon_sim_ui, :hosted_ai_opts, [])

    model_spec = Application.get_env(:lemon_sim_ui, :philosopher_chat_ai_model)

    cond do
      Keyword.has_key?(overrides, :model) ->
        overrides

      is_binary(model_spec) and model_spec != "" ->
        config = LemonCore.Config.Modular.load(project_dir: File.cwd!())

        model =
          GameConfig.resolve_model_spec(nil, model_spec) ||
            raise ArgumentError, "Unknown PhilosopherChat AI model: #{model_spec}"

        model = GameConfig.apply_provider_base_url(model, config)
        api_key = GameConfig.resolve_provider_api_key!(model.provider, config, "philosopher_chat")

        overrides
        |> Keyword.put(:model, model)
        |> Keyword.put(:stream_options, %{api_key: api_key})

      true ->
        [model: nil, stream_options: %{}]
    end
  end

  # -- helpers --

  defp agent_turn_available?(state) do
    thread = state.thread
    world = thread.game_state.world
    now = now_ms()
    last_agent_at = Map.get(world, :last_agent_at_ms)

    cond do
      thread.status != "active" ->
        false

      state.ai_ref != nil ->
        false

      Pacing.recent_agent_count(world, now) >= Pacing.hourly_cap(thread.pace) ->
        false

      is_integer(last_agent_at) and now - last_agent_at < Pacing.min_cooldown_ms(thread.pace) ->
        false

      true ->
        true
    end
  end

  defp read_agent_memories(thread_id, agent_id) do
    root =
      Path.join([
        PhilosopherChat.memory_root(),
        PhilosopherChat.memory_namespace(thread_id),
        agent_id
      ])

    case File.ls(root) do
      {:ok, _entries} ->
        files =
          root
          |> Path.join("**/*")
          |> Path.wildcard()
          |> Enum.filter(&File.regular?/1)
          |> Enum.sort()
          |> Enum.map(fn path ->
            content = File.read(path) |> case do
              {:ok, text} -> text
              _ -> ""
            end

            %{
              path: Path.relative_to(path, root),
              content: String.slice(content, 0, 4_000)
            }
          end)

        %{root: root, files: files}

      {:error, _} ->
        %{root: root, files: []}
    end
  end

  defp view_payload(state) do
    world = state.thread.game_state.world
    Domain.thread_projection(world)
    |> Map.merge(%{typing: state.typing, ai_busy: state.ai_ref != nil})
  end

  defp require_active(state) do
    if state.thread.status == "active", do: :ok, else: {:error, :thread_not_active}
  end

  defp persist(thread) do
    Store.put(PhilosopherChat.thread_table(), thread.id, thread)
  end

  defp broadcast(state, type, payload) do
    event = Event.new(:philosopher_chat_update, Map.put(payload, :type, type))
    Bus.broadcast(PhilosopherChat.topic(state.thread.id), event)
  end

  defp restore_rng(nil), do: :rand.seed(:default)
  defp restore_rng(:undefined), do: :rand.seed(:default)
  defp restore_rng(seed), do: :rand.seed(seed)

  defp now_ms, do: System.system_time(:millisecond)
end
