defmodule LemonSimUi.PhilosopherChat.ThreadServer do
  @moduledoc """
  One durable, serialized GenServer per PhilosopherChat thread.

  Owns the conversation loop: user messages, paced autonomous agent turns
  (jittered delays, chained replies, idle chatter), typing status, per-agent
  memory roots, persistence, and PubSub broadcasts for the SSE API.

  Turn lifecycle invariants:

    * At most one AI task runs per thread (`ai_ref`), monitored with a hard
      timeout — a dead or hung task never wedges the thread.
    * At most one turn timer is armed (`turn_timer`); stale fires are ignored.
    * `pending_turn` stays persisted until the turn actually starts, so a
      crash between arming and firing never loses it.
    * Agent results are re-ingested against the live world, so user messages
      posted mid-turn are never clobbered.
  """

  use GenServer

  require Logger

  alias LemonCore.{Bus, Event, Store}
  alias LemonSim.Examples.PhilosopherChat, as: Domain
  alias LemonSim.Examples.PhilosopherChat.Pacing
  alias LemonSim.Kernel.Runner
  alias LemonSim.Kernel.State
  alias LemonSim.LLM.GameHelpers.Config, as: GameConfig
  alias LemonSimUi.PhilosopherChat
  alias LemonSimUi.PhilosopherChat.Thread

  @ai_timeout_ms 120_000
  @ai_start_retry_ms 500
  @broadcast_log_size 200
  @max_client_msg_ids 64
  @max_client_msg_id_chars 128
  @max_consecutive_failures 3

  def start_link(thread_id) when is_binary(thread_id) do
    case Store.get(PhilosopherChat.thread_table(), thread_id) |> Thread.normalize() do
      %Thread{} = thread -> GenServer.start_link(__MODULE__, thread, name: via(thread_id))
      _ -> {:error, :thread_not_found}
    end
  end

  def via(thread_id), do: {:via, Registry, {LemonSimUi.PhilosopherChat.Registry, thread_id}}

  def view(thread_id), do: GenServer.call(via(thread_id), :view, 10_000)

  def post_user_message(thread_id, text, client_msg_id \\ nil),
    do: GenServer.call(via(thread_id), {:post_user_message, text, client_msg_id}, 15_000)

  def nudge(thread_id, agent_id), do: GenServer.call(via(thread_id), {:nudge, agent_id}, 10_000)

  def set_status(thread_id, status),
    do: GenServer.call(via(thread_id), {:set_status, status}, 10_000)

  def memories(thread_id, agent_id),
    do: GenServer.call(via(thread_id), {:memories, agent_id}, 10_000)

  def events(thread_id, since), do: GenServer.call(via(thread_id), {:events, since}, 10_000)

  @impl true
  def init(%Thread{} = thread) do
    state = %{
      thread: thread,
      rng: restore_rng(thread.rng_state),
      ai_ref: nil,
      ai_pid: nil,
      ai_timeout_timer: nil,
      typing: nil,
      turn_timer: nil,
      chain_remaining: 0,
      quiet_timer: nil,
      event_seq: 0,
      # Wall-clock ms + a unique component: fast restarts (supervisor restart
      # within the same millisecond) must still produce a distinct epoch.
      epoch: "#{now_ms()}-#{System.unique_integer([:positive])}",
      broadcast_log: [],
      consecutive_failures: 0,
      user_reply_pending: false
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
    {:reply, {:ok, view_payload(state)}, state}
  end

  def handle_call({:post_user_message, text, client_msg_id}, _from, state) do
    with :ok <- require_active(state),
         :ok <- validate_client_msg_id(client_msg_id) do
      case find_duplicate(state, client_msg_id) do
        {:duplicate, message} ->
          # Idempotent repost: the client retried a message we already committed.
          reply = Map.merge(view_payload(state), %{duplicate: true, message: message})
          {:reply, {:ok, reply}, state}

        :new ->
          case Domain.post_message(state.thread.game_state, Domain.user_id(), text) do
            {:ok, next_state, _signal} ->
              next_state = remember_client_msg_id(next_state, client_msg_id)
              state = commit_message(%{state | thread: %{state.thread | game_state: next_state}})
              {:reply, {:ok, view_payload(state)}, state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:nudge, agent_id}, _from, state) do
    {result, next_state} =
      cond do
        state.thread.status != "active" ->
          {{:error, :thread_not_active}, state}

        not is_binary(agent_id) or agent_id == Domain.user_id() or
            agent_id not in state.thread.member_ids ->
          {{:error, :not_a_member}, state}

        not agent_turn_available?(state) ->
          {{:error, :cooldown_active}, state}

        true ->
          {{:ok, %{scheduled: agent_id}}, schedule_agent_turn(state, agent_id, :nudge)}
      end

    {:reply, result, next_state}
  end

  def handle_call({:set_status, status}, _from, state)
      when status in ["active", "paused", "closed"] do
    with {:ok, next_state} <- Domain.set_status(state.thread.game_state, status) do
      thread = %{state.thread | game_state: next_state, status: status, updated_at_ms: now_ms()}
      state = %{state | thread: thread}
      :ok = persist(state)
      state = broadcast(state, "status", %{status: status})

      state =
        if status == "active" do
          schedule_idle_check(state)
        else
          # Pausing/closing drops any armed turn; the timer is cancelled and
          # the persisted pending_turn cleared so nothing fires stale.
          state
          |> clear_pending_turn()
          |> cancel_quiet_timer()
        end

      {:reply, {:ok, %{status: status}}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:set_status, _status}, _from, state),
    do: {:reply, {:error, :invalid_status}, state}

  def handle_call({:memories, agent_id}, _from, state) do
    if is_binary(agent_id) and agent_id != Domain.user_id() and
         agent_id in state.thread.member_ids do
      {:reply, {:ok, read_agent_memories(state.thread.id, agent_id)}, state}
    else
      {:reply, {:error, :not_a_member}, state}
    end
  end

  def handle_call({:events, since}, _from, state) do
    since = if is_integer(since), do: since, else: 0

    events =
      state.broadcast_log
      |> Enum.reverse()
      |> Enum.filter(&(&1.event_seq > since))

    # The epoch changes on every server start; clients compare it to detect
    # an event_seq reset and rewind their cursor.
    reply = %{events: events, epoch: state.epoch, latest_seq: state.event_seq}
    {:reply, {:ok, reply}, state}
  end

  # -- timers --

  @impl true
  def handle_info({:agent_turn, actor_id, ref}, state) do
    case state.turn_timer do
      %{ref: ^ref} ->
        state = %{state | turn_timer: nil}

        cond do
          state.thread.status != "active" ->
            {:noreply, clear_pending_turn(state)}

          state.ai_ref != nil ->
            # Another turn is already running; drop this one.
            {:noreply, clear_pending_turn(state)}

          not agent_turn_available?(state) ->
            {:noreply, clear_pending_turn(state)}

          true ->
            {:noreply, start_ai_turn(state, actor_id)}
        end

      _ ->
        # Stale fire from a cancelled/replaced timer.
        {:noreply, state}
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
    case state.ai_ref do
      {^generation, ^actor_id, mon} ->
        Process.demonitor(mon, [:flush])

        state = %{
          state
          | ai_ref: nil,
            ai_pid: nil,
            ai_timeout_timer: cancel_timer(state.ai_timeout_timer)
        }

        state = clear_typing(state)

        state =
          case result do
            {:ok, %{events: [_ | _] = events}} ->
              %{state | consecutive_failures: 0}
              |> commit_agent_events(actor_id, events)

            {:ok, %{events: []}} ->
              # Silent turn: the model only touched memory. Nothing visible to post.
              thread = %{state.thread | updated_at_ms: now_ms()}
              state = %{state | thread: thread, consecutive_failures: 0}
              :ok = persist(state)
              state

            {:error, reason} ->
              Logger.error(
                "PhilosopherChat agent turn failed (#{actor_id}): #{PhilosopherChat.error_class(reason)}"
              )

              broadcast(state, "agent_error", %{
                agent_id: actor_id,
                reason: PhilosopherChat.error_class(reason)
              })
          end

        {:noreply, schedule_idle_check(state)}

      _ ->
        # Result from a superseded/timed-out turn; ignore.
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, mon, :process, _pid, reason}, state) do
    case state.ai_ref do
      {_generation, actor_id, ^mon} ->
        Logger.error("PhilosopherChat AI task died (#{actor_id}): #{inspect(reason)}")

        state =
          state
          |> fail_active_turn(actor_id, "ai_task_died")
          |> retry_or_stall(actor_id, "ai_task_died")

        {:noreply, schedule_idle_check(state)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:ai_timeout, generation}, state) do
    case state.ai_ref do
      {^generation, actor_id, _mon} ->
        Logger.error("PhilosopherChat AI turn timed out (#{actor_id})")

        # Kill the hung task so it cannot linger or double-write memories
        # alongside the retry.
        if state.ai_pid, do: Process.exit(state.ai_pid, :kill)

        state =
          state
          |> fail_active_turn(actor_id, "ai_timeout")
          |> retry_or_stall(actor_id, "ai_timeout")

        {:noreply, schedule_idle_check(state)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- AI turn result handling --

  # Re-ingests the turn's events against the LIVE world so user messages
  # posted while the model ran survive (the task worked from a snapshot).
  defp commit_agent_events(state, actor_id, events) do
    live = Domain.with_actor(state.thread.game_state, actor_id)
    old_last_seq = last_seq(live.world)
    updater = Map.get(chat_modules(), :updater, Domain.Updater)

    case Runner.ingest_events(live, events, updater, halt_on_decide?: false) do
      {:ok, next_state, _signal} ->
        new_msgs =
          (next_state.world[:messages] || [])
          |> Enum.filter(&(Map.get(&1, :seq, 0) > old_last_seq))

        commit_agent_messages(state, next_state, new_msgs)

      {:error, reason} ->
        Logger.error("PhilosopherChat agent turn ingest failed (#{actor_id}): #{inspect(reason)}")

        broadcast(state, "agent_error", %{
          agent_id: actor_id,
          reason: PhilosopherChat.error_class(reason)
        })
    end
  end

  defp commit_agent_messages(state, next_state, new_msgs) do
    thread = %{
      state.thread
      | game_state: Domain.clear_actor(next_state),
        last_message: List.last(new_msgs) || state.thread.last_message,
        updated_at_ms: now_ms()
    }

    state = %{state | thread: thread}
    :ok = persist(state)

    state =
      Enum.reduce(new_msgs, state, fn msg, acc ->
        broadcast(acc, "message", %{message: msg})
      end)

    schedule_after_message(state)
  end

  # Clears ai_ref + timeout, clears typing (with a wire update), counts the
  # failure, and broadcasts the failure reason.
  defp fail_active_turn(state, actor_id, reason) do
    state = %{
      state
      | ai_ref: nil,
        ai_pid: nil,
        ai_timeout_timer: cancel_timer(state.ai_timeout_timer),
        consecutive_failures: state.consecutive_failures + 1
    }

    state = clear_typing(state)
    broadcast(state, "agent_error", %{agent_id: actor_id, reason: reason})
  end

  # Bounded retries: after @max_consecutive_failures in a row the agent is
  # declared stalled instead of retrying forever (a hung provider would
  # otherwise loop at real cost — the hourly cap only counts *posted*
  # messages). The counter resets on the next successful turn, and also on
  # stall, so a later nudge/user message gets a fresh set of retries.
  defp retry_or_stall(state, actor_id, reason) do
    if state.consecutive_failures >= @max_consecutive_failures do
      broadcast(%{state | consecutive_failures: 0}, "agent_stalled", %{
        agent_id: actor_id,
        reason: "has gone quiet after repeated failed attempts",
        failure_class: reason
      })
    else
      schedule_agent_turn(state, actor_id, :retry)
    end
  end

  defp clear_typing(state) do
    state = %{state | typing: nil}
    broadcast(state, "typing", %{agent_id: nil})
  end

  # -- message commit & scheduling --

  defp commit_message(state) do
    world = state.thread.game_state.world
    last = List.last(Map.get(world, :messages) || [])

    thread = %{state.thread | last_message: last, updated_at_ms: now_ms()}
    state = %{state | thread: thread}
    :ok = persist(state)
    state = broadcast(state, "message", %{message: last})
    schedule_after_message(state)
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
        cond do
          state.user_reply_pending ->
            # A user message arrived while this turn was running; schedule its
            # reply before any continue-chatter roll.
            %{state | user_reply_pending: false} |> schedule_next_in_chain()

          state.chain_remaining > 0 ->
            {chime, rng} = Pacing.continue_chatter?(state.thread.pace, state.rng)
            state = %{state | rng: rng}
            if chime, do: schedule_next_in_chain(state), else: %{state | chain_remaining: 0}

          true ->
            state
        end

      _ ->
        state
    end
  end

  defp schedule_next_in_chain(state) do
    cond do
      state.chain_remaining <= 0 ->
        state

      state.ai_ref != nil ->
        # A turn is in flight and was computed from a pre-message snapshot —
        # defer the reply instead of dropping it, so the user's message gets
        # answered once the in-flight turn commits (see schedule_after_message).
        %{state | user_reply_pending: true}

      true ->
        # No agent_turn_available? gate here: the pacing delay exceeds the
        # cooldown, and the fire-time handler / start_ai_turn re-check
        # availability (dropping or re-arming as needed). Gating here would
        # kill every chain reply, since an agent just spoke.
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
        :nudge ->
          Pacing.nudge_delay_ms(state.thread.pace, state.rng)

        :retry ->
          # Exponential backoff keyed on the consecutive-failure count.
          Pacing.retry_delay_ms(
            state.thread.pace,
            max(state.consecutive_failures, 1),
            state.rng
          )

        _ ->
          Pacing.reply_delay_ms(state.thread.pace, state.rng)
      end

    state = %{state | rng: rng}
    arm_turn_timer(state, agent_id, delay_ms)
  end

  # Single armed turn timer: replaces any previously armed one and persists
  # pending_turn (kept until the turn actually starts — see start_ai_turn/2).
  defp arm_turn_timer(state, agent_id, delay_ms) do
    state = cancel_turn_timer(state)
    ref = make_ref()
    timer = Process.send_after(self(), {:agent_turn, agent_id, ref}, delay_ms)

    thread = %{
      state.thread
      | pending_turn: %{actor_id: agent_id, due_at_ms: now_ms() + delay_ms},
        updated_at_ms: now_ms()
    }

    state = %{state | thread: thread, turn_timer: %{ref: ref, timer: timer}}
    :ok = persist(state)
    state
  end

  defp cancel_turn_timer(%{turn_timer: nil} = state), do: state

  defp cancel_turn_timer(%{turn_timer: %{timer: timer}} = state) do
    Process.cancel_timer(timer)
    %{state | turn_timer: nil}
  end

  defp clear_pending_turn(state) do
    state = cancel_turn_timer(state)

    if state.thread.pending_turn do
      thread = %{state.thread | pending_turn: nil, updated_at_ms: now_ms()}
      state = %{state | thread: thread}
      :ok = persist(state)
      state
    else
      state
    end
  end

  # Re-arms an armed-but-unfired persisted turn after a restart. The
  # persisted pending_turn is left in place: only start_ai_turn/2 consumes it,
  # so a crash in between never loses the turn.
  defp reschedule_pending_turn(state) do
    case {state.thread.status, state.thread.pending_turn} do
      {"active", %{actor_id: agent_id, due_at_ms: due_at_ms}} ->
        remaining = max(due_at_ms - now_ms(), 0)
        arm_turn_timer(state, agent_id, remaining)

      _ ->
        state
    end
  end

  defp schedule_idle_check(state) do
    state = cancel_quiet_timer(state)

    if state.thread.status == "active" do
      ref = Process.send_after(self(), :idle_chatter, Pacing.idle_after_ms(state.thread.pace))
      %{state | quiet_timer: ref}
    else
      state
    end
  end

  defp cancel_quiet_timer(%{quiet_timer: nil} = state), do: state

  defp cancel_quiet_timer(%{quiet_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | quiet_timer: nil}
  end

  # -- AI turn execution --

  defp start_ai_turn(state, actor_id) do
    generation = make_ref()
    world = state.thread.game_state.world
    now = now_ms()
    last_agent_at = Map.get(world, :last_agent_at_ms)
    cooldown = Pacing.min_cooldown_ms(state.thread.pace)

    if is_integer(last_agent_at) and now - last_agent_at < cooldown do
      # Cooldown not met yet — re-arm instead of dropping.
      schedule_agent_turn(state, actor_id, :reply)
    else
      # The turn is actually starting: consume the persisted pending_turn.
      state = clear_pending_turn(state)
      state = broadcast(state, "typing", %{agent_id: actor_id})
      state = %{state | typing: actor_id}
      parent = self()
      game_state = state.thread.game_state

      case Task.Supervisor.start_child(LemonSimUi.PhilosopherChat.AiTaskSupervisor, fn ->
             result = run_ai_turn(game_state, actor_id)
             send(parent, {:ai_result, generation, actor_id, result})
           end) do
        {:ok, pid} ->
          mon = Process.monitor(pid)
          timer = Process.send_after(self(), {:ai_timeout, generation}, @ai_timeout_ms)
          %{state | ai_ref: {generation, actor_id, mon}, ai_pid: pid, ai_timeout_timer: timer}

        {:error, :max_children} ->
          # All AI slots busy — retry shortly instead of eating the turn.
          state = clear_typing(state)
          arm_turn_timer(state, actor_id, @ai_start_retry_ms)

        {:error, reason} ->
          Logger.error("PhilosopherChat AI task start failed: #{inspect(reason)}")
          state = clear_typing(state)
          broadcast(state, "agent_error", %{agent_id: actor_id, reason: "ai_task_failed"})
      end
    end
  end

  # Runs inside the AI task. Returns the raw events only — the server
  # re-ingests them against the live world (see commit_agent_events/3).
  defp run_ai_turn(game_state, actor_id) do
    modules = chat_modules()

    opts =
      ai_opts()
      |> Domain.default_opts()
      |> Keyword.put(:persist?, false)
      |> Keyword.put(:memory_root, PhilosopherChat.memory_root())
      |> Keyword.put(:memory_namespace, PhilosopherChat.memory_namespace(game_state.sim_id))

    game_state = Domain.with_actor(game_state, actor_id)
    adapter = Map.get(modules, :decision_adapter)

    with {:ok, decision, _state} <- Runner.decide_once(game_state, modules, opts),
         {:ok, events} <- adapter.to_events(decision, game_state, opts) do
      {:ok, %{events: events}}
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp chat_modules do
    Application.get_env(:lemon_sim_ui, :philosopher_chat_modules) || Domain.modules()
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
        # No overrides: let build_default_opts/3 resolve the configured game model.
        []
    end
  end

  # -- idempotent user messages --

  defp validate_client_msg_id(nil), do: :ok

  defp validate_client_msg_id(client_msg_id) when is_binary(client_msg_id) do
    if byte_size(client_msg_id) <= @max_client_msg_id_chars,
      do: :ok,
      else: {:error, :invalid_client_msg_id}
  end

  defp validate_client_msg_id(_), do: {:error, :invalid_client_msg_id}

  defp find_duplicate(_state, nil), do: :new

  defp find_duplicate(state, client_msg_id) do
    world = state.thread.game_state.world

    case get_in(world, [:client_msg_ids, client_msg_id]) do
      nil ->
        :new

      seq ->
        case Enum.find(Map.get(world, :messages) || [], &(Map.get(&1, :seq) == seq)) do
          nil -> :new
          message -> {:duplicate, message}
        end
    end
  end

  defp remember_client_msg_id(%State{} = state, nil), do: state

  defp remember_client_msg_id(%State{} = state, client_msg_id) do
    world = state.world
    seq = Map.get(world, :next_seq, 1) - 1

    order =
      Enum.take([client_msg_id | Map.get(world, :client_msg_order, [])], @max_client_msg_ids)

    ids =
      world
      |> Map.get(:client_msg_ids, %{})
      |> Map.put(client_msg_id, seq)
      |> Map.take(order)

    world =
      world
      |> Map.put(:client_msg_ids, ids)
      |> Map.put(:client_msg_order, order)

    State.put_world(state, world)
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

  defp last_seq(world) do
    case List.last(Map.get(world, :messages) || []) do
      nil -> 0
      message -> Map.get(message, :seq, 0)
    end
  end

  defp read_agent_memories(thread_id, agent_id) do
    memory_root = PhilosopherChat.memory_root() |> Path.expand()

    root =
      Path.join([memory_root, PhilosopherChat.memory_namespace(thread_id), agent_id])
      |> Path.expand()

    if root == memory_root or not String.starts_with?(root, memory_root <> "/") do
      # Refuse to read outside the memory root (defense in depth; agent_id is
      # already validated against the member list).
      %{root: root, files: []}
    else
      case File.ls(root) do
        {:ok, _entries} ->
          files =
            root
            |> Path.join("**/*")
            |> Path.wildcard()
            |> Enum.filter(&File.regular?/1)
            |> Enum.sort()
            |> Enum.map(fn path ->
              content =
                case File.read(path) do
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
  end

  defp view_payload(state) do
    world = state.thread.game_state.world

    Domain.thread_projection(world)
    |> Map.merge(%{
      typing: state.typing,
      ai_busy: state.ai_ref != nil,
      epoch: state.epoch,
      latest_seq: state.event_seq
    })
  end

  defp require_active(state) do
    if state.thread.status == "active", do: :ok, else: {:error, :thread_not_active}
  end

  # Centralized persistence: the stored thread always carries the live rng
  # state, so restarts continue the pacing sequence instead of replaying it.
  defp persist(state) do
    thread = %{state.thread | rng_state: state.rng}
    Store.put(PhilosopherChat.thread_table(), thread.id, thread)
  end

  # Broadcasts increment event_seq and are kept in a bounded log so SSE
  # clients can resume with `?since=<last_seq>`.
  defp broadcast(state, type, payload) do
    seq = state.event_seq + 1
    payload = payload |> Map.put(:type, type) |> Map.put(:event_seq, seq)
    event = Event.new(:philosopher_chat_update, payload)
    Bus.broadcast(PhilosopherChat.topic(state.thread.id), event)

    entry = %{event_seq: seq, type: type, payload: payload}
    log = Enum.take([entry | state.broadcast_log], @broadcast_log_size)
    %{state | event_seq: seq, broadcast_log: log}
  end

  defp cancel_timer(nil), do: nil

  defp cancel_timer(timer) do
    Process.cancel_timer(timer)
    nil
  end

  # All rng state is kept in `:rand` export format (plain `{atom, tuple}`
  # data) so it survives the store round-trip.
  defp restore_rng(nil), do: :rand.seed_s(:exsss) |> :rand.export_seed_s()
  defp restore_rng(:undefined), do: restore_rng(nil)
  defp restore_rng(seed), do: seed

  defp now_ms, do: System.system_time(:millisecond)
end
