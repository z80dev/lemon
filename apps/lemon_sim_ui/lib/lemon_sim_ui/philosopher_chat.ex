defmodule LemonSimUi.PhilosopherChat.Thread do
  @moduledoc false

  @schema_version 1

  defstruct schema_version: @schema_version,
            id: nil,
            name: nil,
            member_ids: [],
            pace: "relaxed",
            status: "active",
            game_state: nil,
            rng_state: nil,
            pending_turn: nil,
            last_message: nil,
            created_at_ms: nil,
            updated_at_ms: nil

  def normalize(%__MODULE__{} = thread), do: struct(__MODULE__, Map.from_struct(thread))

  def normalize(%{} = thread) do
    fields = Map.keys(%__MODULE__{}) -- [:__struct__]

    attrs =
      Enum.reduce(fields, %{}, fn field, acc ->
        value = Map.get(thread, field, Map.get(thread, Atom.to_string(field)))
        if is_nil(value), do: acc, else: Map.put(acc, field, value)
      end)

    struct(__MODULE__, attrs)
  end

  def normalize(_), do: nil
end

defmodule LemonSimUi.PhilosopherChat do
  @moduledoc """
  Durable single-node coordinator for PhilosopherChat threads.

  Each thread is serialized by its own `ThreadServer`; this coordinator
  creates threads, restarts persisted ones after boot, and lazily restores
  them on demand.
  """

  use GenServer

  require Logger

  alias LemonCore.Store
  alias LemonSim.Examples.PhilosopherChat, as: Domain
  alias LemonSim.Examples.PhilosopherChat.Persona
  alias LemonSimUi.PhilosopherChat.{Thread, ThreadServer}

  @user_id Domain.user_id()

  @thread_table :philosopher_chat_threads
  @recovery_retry_ms 1_000
  @prune_interval_ms 60_000
  @max_thread_name_chars 60
  @max_agents_per_thread 6
  @min_agents_per_thread 1

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def thread_table, do: @thread_table
  def enabled?, do: Application.get_env(:lemon_sim_ui, :philosopher_chat_enabled, true)

  def topic(thread_id) when is_binary(thread_id), do: "philosopher_chat:#{thread_id}"

  def memory_root do
    Application.get_env(:lemon_sim_ui, :philosopher_chat_data_root) ||
      Path.join(File.cwd!(), "tmp/philosopher_chat")
  end

  def memory_namespace(thread_id), do: thread_id

  def error_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  def error_class({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  def error_class(_reason), do: "runtime_error"

  # -- API --

  def create_thread(name, member_ids, opts \\ %{}) when is_binary(name) and is_list(member_ids) do
    GenServer.call(__MODULE__, {:create_thread, name, member_ids, Map.new(opts)}, 15_000)
  end

  def list_threads do
    GenServer.call(__MODULE__, :list_threads, 15_000)
  end

  def delete_thread(thread_id) when is_binary(thread_id) do
    GenServer.call(__MODULE__, {:delete_thread, thread_id}, 15_000)
  end

  def get_thread(thread_id) when is_binary(thread_id) do
    Store.get(thread_table(), thread_id) |> Thread.normalize()
  end

  def view(thread_id) do
    with {:ok, _pid} <- ensure_thread(thread_id), do: ThreadServer.view(thread_id)
  end

  def post_user_message(thread_id, text, client_msg_id \\ nil) do
    with {:ok, _pid} <- ensure_thread(thread_id),
         do: ThreadServer.post_user_message(thread_id, text, client_msg_id)
  end

  def events(thread_id, since \\ 0) do
    with {:ok, _pid} <- ensure_thread(thread_id),
         do: ThreadServer.events(thread_id, since)
  end

  def nudge(thread_id, agent_id) do
    with {:ok, _pid} <- ensure_thread(thread_id), do: ThreadServer.nudge(thread_id, agent_id)
  end

  def set_status(thread_id, status) do
    with {:ok, _pid} <- ensure_thread(thread_id), do: ThreadServer.set_status(thread_id, status)
  end

  def memories(thread_id, agent_id) do
    with {:ok, _pid} <- ensure_thread(thread_id),
         do: ThreadServer.memories(thread_id, agent_id)
  end

  @doc false
  def ensure_thread(thread_id) when is_binary(thread_id) do
    case Registry.lookup(LemonSimUi.PhilosopherChat.Registry, thread_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case Store.get(thread_table(), thread_id) |> Thread.normalize() do
          %Thread{} = thread ->
            DynamicSupervisor.start_child(
              LemonSimUi.PhilosopherChat.ThreadSupervisor,
              thread_child_spec(thread)
            )

          _ ->
            {:error, :thread_not_found}
        end
    end
  end

  def thread_summary(%Thread{} = thread) do
    world = thread.game_state && thread.game_state.world
    messages = if world, do: get_in(world, [:messages]) || [], else: []

    %{
      id: thread.id,
      name: thread.name,
      member_ids: thread.member_ids,
      members:
        Enum.map(thread.member_ids, fn id ->
          %{id: id, name: member_name(id), is_user: id == @user_id}
        end),
      pace: thread.pace,
      status: thread.status,
      created_at_ms: thread.created_at_ms,
      updated_at_ms: thread.updated_at_ms,
      message_count: length(messages),
      last_message: thread.last_message
    }
  end

  def member_name(@user_id), do: "You"
  def member_name(id), do: (Persona.get(id) && Persona.get(id).name) || id

  def thread_child_spec(%Thread{} = thread), do: thread_child_spec(thread.id)

  def thread_child_spec(thread_id) when is_binary(thread_id) do
    %{
      id: {ThreadServer, thread_id},
      start: {ThreadServer, :start_link, [thread_id]},
      restart: :transient
    }
  end

  # -- GenServer --

  @impl true
  def init(_) do
    Process.send_after(self(), :recover_threads, 0)
    Process.send_after(self(), :prune_threads, @prune_interval_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:create_thread, name, member_ids, opts}, _from, state) do
    result =
      cond do
        not enabled?() ->
          {:error, :philosopher_chat_disabled}

        true ->
          with :ok <- validate_name(name),
               :ok <- validate_members(member_ids),
               :ok <- enforce_thread_limit() do
            create_and_start(name, member_ids, opts)
          end
      end

    {:reply, result, state}
  end

  def handle_call(:list_threads, _from, state) do
    summaries =
      Store.list(@thread_table)
      |> Enum.map(fn {_id, thread} -> Thread.normalize(thread) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.updated_at_ms, :desc)
      |> Enum.map(&thread_summary/1)

    {:reply, {:ok, summaries}, state}
  end

  def handle_call({:delete_thread, thread_id}, _from, state) do
    # Terminate the ThreadServer BEFORE deleting the stored record, in every
    # case — otherwise a live server can persist itself back after the delete.
    result =
      with :ok <- terminate_thread_server(thread_id),
           :ok <- Store.delete(@thread_table, thread_id) do
        :ok
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info(:recover_threads, state) do
    case {enabled?(), Store.ping()} do
      {false, _} ->
        {:noreply, state}

      {true, :ok} ->
        threads =
          Store.list(@thread_table)
          |> Enum.map(fn {_id, thread} -> Thread.normalize(thread) end)
          |> Enum.reject(&is_nil/1)

        Enum.each(threads, fn thread ->
          if thread.status in ["active", "paused"] do
            case DynamicSupervisor.start_child(
                   LemonSimUi.PhilosopherChat.ThreadSupervisor,
                   thread_child_spec(thread)
                 ) do
              {:ok, _pid} ->
                :ok

              {:error, reason} ->
                Logger.error("PhilosopherChat recovery failed: #{inspect(reason)}")
            end
          end
        end)

        {:noreply, state}

      {true, _} ->
        Process.send_after(self(), :recover_threads, @recovery_retry_ms)
        {:noreply, state}
    end
  end

  def handle_info(:prune_threads, state) do
    retention_ms =
      Application.get_env(
        :lemon_sim_ui,
        :philosopher_chat_retention_ms,
        30 * 24 * 3600 * 1000
      )

    now = System.system_time(:millisecond)

    Store.list(@thread_table)
    |> Enum.each(fn {_id, thread} ->
      thread = Thread.normalize(thread)

      if thread.status in ["closed", "paused"] and
           now - (thread.updated_at_ms || 0) > retention_ms do
        _ = Store.delete(@thread_table, thread.id)
      end
    end)

    Process.send_after(self(), :prune_threads, @prune_interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- internals --

  defp terminate_thread_server(thread_id) do
    case Registry.lookup(LemonSimUi.PhilosopherChat.Registry, thread_id) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(LemonSimUi.PhilosopherChat.ThreadSupervisor, pid)

      [] ->
        :ok
    end
  end

  defp create_and_start(name, member_ids, opts) do
    member_ids = [@user_id | Enum.reject(member_ids, &(&1 == @user_id))]
    thread_id = new_thread_id()
    pace = Map.get(opts, "pace", Map.get(opts, :pace, "relaxed"))
    now = System.system_time(:millisecond)

    game_state = Domain.initial_state(thread_id, name, member_ids, pace: pace)

    rng_state =
      :rand.seed_s(
        :exsss,
        {System.system_time(:microsecond), :erlang.unique_integer(),
         :erlang.phash2({thread_id, now})}
      )
      |> :rand.export_seed_s()

    thread = %Thread{
      id: thread_id,
      name: name,
      member_ids: member_ids,
      pace: pace,
      status: "active",
      game_state: game_state,
      rng_state: rng_state,
      created_at_ms: now,
      updated_at_ms: now
    }

    with :ok <- Store.put(@thread_table, thread_id, thread),
         {:ok, _pid} <-
           DynamicSupervisor.start_child(
             LemonSimUi.PhilosopherChat.ThreadSupervisor,
             thread_child_spec(thread)
           ) do
      {:ok, thread_id}
    else
      {:error, reason} ->
        _ = Store.delete(@thread_table, thread_id)
        {:error, reason}
    end
  end

  defp new_thread_id do
    "t" <> Base.url_encode64(:crypto.strong_rand_bytes(5), padding: false)
  end

  defp validate_name(name) do
    cond do
      not is_binary(name) or String.trim(name) == "" -> {:error, :name_required}
      byte_size(name) > @max_thread_name_chars -> {:error, :name_too_long}
      true -> :ok
    end
  end

  defp validate_members(member_ids) do
    agents = Enum.reject(member_ids, &(&1 == @user_id))

    cond do
      length(agents) < @min_agents_per_thread -> {:error, :too_few_members}
      length(agents) > @max_agents_per_thread -> {:error, :too_many_members}
      Enum.any?(agents, fn id -> is_nil(Persona.get(id)) end) -> {:error, :unknown_member}
      length(Enum.uniq(agents)) != length(agents) -> {:error, :duplicate_member}
      true -> :ok
    end
  end

  defp enforce_thread_limit do
    limit = Application.get_env(:lemon_sim_ui, :philosopher_chat_thread_limit, 20)

    active =
      Store.list(@thread_table)
      |> Enum.count(fn {_id, thread} ->
        thread = Thread.normalize(thread)
        thread.status in ["active", "paused"]
      end)

    if active >= limit, do: {:error, :thread_limit_reached}, else: :ok
  end
end
