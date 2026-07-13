defmodule LemonSimUi.HostedGame.Room do
  @moduledoc false

  @schema_version 1

  defstruct schema_version: @schema_version,
            id: nil,
            join_code: nil,
            host_token_hash: nil,
            status: "lobby",
            terminal_reason: nil,
            config: %{},
            seats: %{},
            game_state: nil,
            rng_state: nil,
            command_seq: 0,
            command_ids: [],
            replay: [],
            match_archives: [],
            deadline_at_ms: nil,
            paused_remaining_ms: nil,
            paused_at_ms: nil,
            phase_started_at_ms: nil,
            match_number: 1,
            created_at_ms: nil,
            updated_at_ms: nil,
            started_at_ms: nil,
            finished_at_ms: nil

  def normalize(%__MODULE__{} = room), do: struct(__MODULE__, Map.from_struct(room))

  def normalize(%{} = room) do
    fields = Map.keys(%__MODULE__{}) -- [:__struct__]

    attrs =
      Enum.reduce(fields, %{}, fn field, acc ->
        value = Map.get(room, field, Map.get(room, Atom.to_string(field)))
        if is_nil(value), do: acc, else: Map.put(acc, field, value)
      end)

    struct(__MODULE__, attrs)
  end

  def normalize(_), do: nil
end

defmodule LemonSimUi.HostedGame do
  @moduledoc """
  Durable single-node coordinator for hosted Werewolf rooms.

  Each room is serialized by its own `RoomServer`; this coordinator reserves
  join codes, starts persisted rooms after boot, and lazily restores rooms on
  demand. Raw host and player credentials never enter storage.
  """

  use GenServer

  require Logger

  alias LemonCore.Store
  alias LemonSim.Examples.Werewolf
  alias LemonSim.Examples.Werewolf.RulesConfig
  alias LemonSim.LLM.GameHelpers.Config, as: GameConfig
  alias LemonSimUi.HostedGame.{Room, RoomServer}

  @room_table :hosted_werewolf_rooms
  @join_table :hosted_werewolf_join_codes
  @recovery_retry_ms 1_000
  @prune_interval_ms 60_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def room_table, do: @room_table
  def join_table, do: @join_table
  def enabled?, do: Application.get_env(:lemon_sim_ui, :hosted_rooms_enabled, true)

  def error_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  def error_class({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  def error_class(_reason), do: "runtime_error"

  def recovery_status do
    GenServer.call(__MODULE__, :recovery_status)
  catch
    :exit, _ -> %{status: "unavailable", errors: 1}
  end

  def reserve_active_slot(room_id),
    do: GenServer.call(__MODULE__, {:reserve_active_slot, room_id})

  def release_active_slot(room_id),
    do: GenServer.cast(__MODULE__, {:release_active_slot, room_id})

  def terminalization_pending(room_id),
    do: GenServer.cast(__MODULE__, {:terminalization_pending, room_id})

  def terminalization_complete(room_id),
    do: GenServer.cast(__MODULE__, {:terminalization_complete, room_id})

  def ai_ready?(model_spec \\ Application.get_env(:lemon_sim_ui, :hosted_ai_model)) do
    overrides = Application.get_env(:lemon_sim_ui, :hosted_ai_opts, [])

    cond do
      Keyword.has_key?(overrides, :model) ->
        :ok

      not is_binary(model_spec) or String.trim(model_spec) == "" ->
        {:error, :hosted_ai_not_configured}

      true ->
        config = LemonCore.Config.Modular.load(project_dir: File.cwd!())

        with %{} = model <- GameConfig.resolve_model_spec(nil, model_spec) do
          model = GameConfig.apply_provider_base_url(model, config)

          _api_key =
            GameConfig.resolve_provider_api_key!(model.provider, config, "hosted werewolf")

          :ok
        else
          _ -> {:error, :invalid_hosted_ai_model}
        end
    end
  rescue
    _ -> {:error, :invalid_hosted_ai_credentials}
  end

  def topic(room_id) when is_binary(room_id), do: "hosted_werewolf:#{room_id}"
  def host_session_key(room_id), do: "hosted_werewolf_host:#{room_id}"
  def player_session_key(room_id), do: "hosted_werewolf_player:#{room_id}"

  def create_room(attrs \\ %{}) when is_map(attrs) do
    GenServer.call(__MODULE__, {:create_room, attrs}, 15_000)
  end

  def claim_seat(join_code, seat_id, display_name) do
    with :ok <- hosted_rooms_enabled?(),
         {:ok, room_id} <- room_id_for_join_code(join_code),
         {:ok, _pid} <- ensure_room(room_id) do
      RoomServer.claim_seat(room_id, seat_id, display_name)
    end
  end

  def join_view(join_code) do
    with :ok <- hosted_rooms_enabled?(),
         {:ok, room_id} <- room_id_for_join_code(join_code),
         {:ok, _pid} <- ensure_room(room_id) do
      RoomServer.join_view(room_id)
    end
  end

  def creation_authorized?(provided) do
    case Application.get_env(:lemon_sim_ui, :hosted_room_create_token) do
      expected when expected in [nil, ""] -> true
      expected -> secure_token_value?(provided, expected)
    end
  end

  def host_view(room_id, host_token),
    do: with_room(room_id, fn -> RoomServer.host_view(room_id, host_token) end)

  def player_view(room_id, player_token),
    do: with_room(room_id, fn -> RoomServer.player_view(room_id, player_token) end)

  def public_view(room_id, credential \\ nil),
    do: with_room(room_id, fn -> RoomServer.public_view(room_id, credential) end)

  def control(room_id, host_token, action, params \\ %{}),
    do: with_room(room_id, fn -> RoomServer.control(room_id, host_token, action, params) end)

  def configure_seat(room_id, host_token, seat_id, kind),
    do:
      with_room(room_id, fn ->
        RoomServer.configure_seat(room_id, host_token, seat_id, kind)
      end)

  def release_seat(room_id, host_token, seat_id),
    do: with_room(room_id, fn -> RoomServer.release_seat(room_id, host_token, seat_id) end)

  def submit_command(
        room_id,
        player_token,
        command_id,
        expected_match_number,
        expected_version,
        action,
        params
      ) do
    with_room(room_id, fn ->
      RoomServer.submit_command(
        room_id,
        player_token,
        command_id,
        expected_match_number,
        expected_version,
        action,
        params
      )
    end)
  end

  def connect_player(room_id, player_token, pid \\ self()),
    do: with_room(room_id, fn -> RoomServer.connect_player(room_id, player_token, pid) end)

  def export_replay(room_id, host_token),
    do: with_room(room_id, fn -> RoomServer.export_replay(room_id, host_token) end)

  def raw_room(room_id) when is_binary(room_id), do: Store.get(@room_table, room_id)

  def room_child_spec(%Room{} = room), do: room_child_spec(room.id)

  def room_child_spec(room_id) when is_binary(room_id) do
    %{
      id: {RoomServer, room_id},
      start: {RoomServer, :start_link, [room_id]},
      restart: :transient
    }
  end

  @impl true
  def init(_) do
    Process.send_after(self(), :recover_rooms, 0)
    Process.send_after(self(), :prune_rooms, @prune_interval_ms)

    {:ok,
     %{
       recovered?: false,
       recovery_errors: [],
       active_reservations: %{},
       pending_terminalizations: MapSet.new()
     }}
  end

  @impl true
  def handle_call(:recovery_status, _from, state) do
    pending = MapSet.size(state.pending_terminalizations)
    status = if state.recovered? and pending == 0, do: "ok", else: "recovering"

    {:reply,
     %{status: status, errors: length(state.recovery_errors), pending_terminalizations: pending},
     state}
  end

  def handle_call({:reserve_active_slot, room_id}, _from, state) do
    now = System.monotonic_time(:millisecond)

    reservations =
      Map.reject(state.active_reservations, fn {_id, at_ms} -> now - at_ms > 30_000 end)

    active_count = active_room_count(room_id)
    limit = Application.get_env(:lemon_sim_ui, :hosted_room_limit, 100)

    if Map.has_key?(reservations, room_id) or active_count + map_size(reservations) < limit do
      reservations = Map.put(reservations, room_id, now)
      {:reply, :ok, %{state | active_reservations: reservations}}
    else
      {:reply, {:error, :room_limit_reached}, %{state | active_reservations: reservations}}
    end
  end

  @impl true
  def handle_call({:create_room, attrs}, _from, state) do
    state = prune_active_reservations(state)

    result =
      with :ok <- hosted_rooms_enabled?(),
           :ok <- prune_finished_rooms(),
           :ok <- enforce_room_limit(state.active_reservations),
           {:ok, room, host_token} <- build_room(attrs),
           {:ok, _pid, persisted_room} <- reserve_persist_and_start(room) do
        emit(:room_created, %{count: 1}, %{room_id: persisted_room.id})

        {:ok,
         %{
           room_id: persisted_room.id,
           join_code: persisted_room.join_code,
           host_token: host_token,
           host_path: "/rooms/#{persisted_room.id}/host"
         }}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_cast({:release_active_slot, room_id}, state) do
    {:noreply, %{state | active_reservations: Map.delete(state.active_reservations, room_id)}}
  end

  def handle_cast({:terminalization_pending, room_id}, state) do
    pending = MapSet.put(state.pending_terminalizations, room_id)
    {:noreply, %{state | pending_terminalizations: pending}}
  end

  def handle_cast({:terminalization_complete, room_id}, state) do
    pending = MapSet.delete(state.pending_terminalizations, room_id)
    {:noreply, %{state | pending_terminalizations: pending}}
  end

  @impl true
  def handle_info(:recover_rooms, state) do
    case {enabled?(), Store.ping()} do
      {false, _} ->
        {:noreply, %{state | recovered?: true, recovery_errors: []}}

      {true, :ok} ->
        rooms =
          Store.list(@room_table)
          |> Enum.map(fn {_id, room} -> Room.normalize(room) end)
          |> Enum.reject(&is_nil/1)

        failures =
          Enum.flat_map(rooms, fn room ->
            with :ok <- reconcile_join_code(room) do
              if room.status in ["lobby", "running", "paused"] do
                with :ok <- validate_room_ai(room),
                     {:ok, _pid} <- start_room(room) do
                  []
                else
                  {:error, reason} -> [{room.id, reason}]
                end
              else
                []
              end
            else
              {:error, reason} -> [{room.id, reason}]
            end
          end)

        if failures == [] do
          {:noreply, %{state | recovered?: true, recovery_errors: []}}
        else
          Logger.error("Hosted Werewolf recovery failed for #{length(failures)} room(s)")
          Process.send_after(self(), :recover_rooms, @recovery_retry_ms)
          {:noreply, %{state | recovered?: false, recovery_errors: failures}}
        end

      {true, {:error, reason}} ->
        Logger.warning("Hosted Werewolf recovery waiting for store: #{error_class(reason)}")
        Process.send_after(self(), :recover_rooms, @recovery_retry_ms)
        {:noreply, state}
    end
  end

  def handle_info(:prune_rooms, state) do
    if enabled?() do
      _ = prune_expired_lobbies()
      _ = prune_finished_rooms()
    end

    Process.send_after(self(), :prune_rooms, @prune_interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp with_room(room_id, fun) when is_binary(room_id) and is_function(fun, 0) do
    with :ok <- hosted_rooms_enabled?(),
         {:ok, _pid} <- ensure_room(room_id) do
      try do
        fun.()
      catch
        :exit, {:noproc, _details} -> retry_room_call(room_id, fun)
        :exit, {:normal, _details} -> retry_room_call(room_id, fun)
      end
    end
  end

  defp with_room(_room_id, _fun), do: {:error, :not_found}

  defp retry_room_call(room_id, fun) do
    Process.sleep(10)
    with {:ok, _pid} <- ensure_room(room_id, 10), do: fun.()
  end

  defp ensure_room(room_id, attempts \\ 10)

  defp ensure_room(_room_id, 0), do: {:error, :room_unavailable}

  defp ensure_room(room_id, attempts) do
    case Registry.lookup(LemonSimUi.HostedGame.Registry, room_id) do
      [{pid, _}] ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          Process.sleep(10)
          ensure_room(room_id, attempts - 1)
        end

      [] ->
        case Store.get(@room_table, room_id) |> Room.normalize() do
          %Room{} = room -> start_room(room)
          _ -> {:error, :not_found}
        end
    end
  end

  defp start_room(%Room{} = room) do
    case DynamicSupervisor.start_child(
           LemonSimUi.HostedGame.RoomSupervisor,
           room_child_spec(room)
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, {:already_present, _child}} -> ensure_room(room.id, 10)
      {:error, reason} -> {:error, {:room_start_failed, reason}}
    end
  end

  defp room_id_for_join_code(join_code) when is_binary(join_code) do
    normalized = join_code |> String.trim() |> String.upcase()

    if normalized =~ ~r/^[A-Z2-9]{10}$/ do
      case Store.get(@join_table, normalized) do
        room_id when is_binary(room_id) -> {:ok, room_id}
        _ -> {:error, :invalid_join_code}
      end
    else
      {:error, :invalid_join_code}
    end
  end

  defp room_id_for_join_code(_join_code), do: {:error, :invalid_join_code}

  defp build_room(attrs) do
    with {:ok, config} <- normalize_config(attrs) do
      room_id = random_hex(12)
      host_token = random_token()
      join_code = random_join_code()
      now = System.system_time(:millisecond)
      {game_state, rng_state} = initial_game(room_id, config)

      player_ids = game_state.world.players |> Map.keys() |> Enum.sort()
      ai_seats = config.ai_seats

      seats =
        player_ids
        |> Enum.with_index()
        |> Map.new(fn {player_id, index} ->
          kind = if index < ai_seats, do: "ai", else: "human"

          {player_id,
           %{
             kind: kind,
             display_name: if(kind == "ai", do: "AI · #{player_id}", else: nil),
             token_hash: nil,
             claimed_at_ms: nil
           }}
        end)

      room = %Room{
        id: room_id,
        join_code: join_code,
        host_token_hash: hash_token(host_token),
        config: Map.from_struct(config),
        seats: seats,
        game_state: game_state,
        rng_state: rng_state,
        created_at_ms: now,
        updated_at_ms: now,
        phase_started_at_ms: now,
        replay: [replay_entry("room_created", nil, %{config: Map.from_struct(config)}, now)]
      }

      {:ok, room, host_token}
    end
  end

  defmodule Config do
    @moduledoc false

    defstruct schema_version: 1,
              player_count: 6,
              ai_seats: 0,
              turn_timeout_seconds: 90,
              visibility: "private",
              rules_preset: "story",
              seed: nil,
              ai_model: nil
  end

  defp normalize_config(attrs) do
    player_count = parse_integer(value(attrs, :player_count, 6))
    ai_seats = parse_integer(value(attrs, :ai_seats, 0))
    timeout = parse_integer(value(attrs, :turn_timeout_seconds, 90))
    visibility = value(attrs, :visibility, "private")
    rules_preset = value(attrs, :rules_preset, "story")
    seed = parse_optional_integer(value(attrs, :seed, nil))

    cond do
      player_count not in 5..8 ->
        {:error, :invalid_player_count}

      not is_integer(ai_seats) or ai_seats < 0 or ai_seats > player_count ->
        {:error, :invalid_ai_seats}

      ai_seats > 0 and ai_ready?() != :ok ->
        {:error, :hosted_ai_not_configured}

      timeout not in 15..600 ->
        {:error, :invalid_turn_timeout}

      visibility not in ["private", "public_safe"] ->
        {:error, :invalid_visibility}

      rules_preset not in ["story", "classic"] ->
        {:error, :invalid_rules_preset}

      not is_nil(seed) and (not is_integer(seed) or seed < 1 or seed > 2_147_483_647) ->
        {:error, :invalid_seed}

      true ->
        seed = seed || random_seed()

        {:ok,
         %Config{
           player_count: player_count,
           ai_seats: ai_seats,
           turn_timeout_seconds: timeout,
           visibility: visibility,
           rules_preset: rules_preset,
           seed: seed,
           ai_model: Application.get_env(:lemon_sim_ui, :hosted_ai_model)
         }}
    end
  end

  defp reserve_and_persist(room, attempts \\ 5)

  defp reserve_and_persist(_room, 0), do: {:error, :join_code_exhausted}

  defp reserve_and_persist(room, attempts) do
    case Store.put_new(@join_table, room.join_code, room.id) do
      :ok ->
        case Store.put(@room_table, room.id, room) do
          :ok ->
            {:ok, room}

          {:error, reason} ->
            _ = Store.delete(@join_table, room.join_code)
            {:error, {:persistence_failed, reason}}
        end

      {:error, :exists} ->
        reserve_and_persist(%{room | join_code: random_join_code()}, attempts - 1)

      {:error, reason} ->
        {:error, {:persistence_failed, reason}}
    end
  end

  defp reserve_persist_and_start(room) do
    case reserve_and_persist(room) do
      {:ok, persisted_room} ->
        case start_room(persisted_room) do
          {:ok, pid} ->
            {:ok, pid, persisted_room}

          {:error, reason} ->
            _ = Store.delete(@room_table, persisted_room.id)
            _ = Store.delete(@join_table, persisted_room.join_code)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile_join_code(room) do
    case Store.put_new(@join_table, room.join_code, room.id) do
      :ok ->
        :ok

      {:error, :exists} ->
        case Store.get(@join_table, room.join_code) do
          room_id when room_id == room.id -> :ok
          other -> {:error, {:join_code_conflict, other}}
        end

      {:error, reason} ->
        Logger.error("Failed to restore join code for #{room.id}: #{error_class(reason)}")
        {:error, {:join_code_restore_failed, reason}}
    end
  end

  defp initial_game(room_id, config) do
    previous_seed = :rand.export_seed()
    :rand.seed(:exsss, {config.seed, config.seed + 1, config.seed + 2})

    game_state =
      Werewolf.initial_state(
        sim_id: "hosted_#{room_id}",
        player_count: config.player_count,
        generate_lore?: false
      )

    game_state =
      put_in(
        game_state.world[:rules],
        config.rules_preset
        |> RulesConfig.for_preset()
        |> Map.put(:turn_timeout_seconds, config.turn_timeout_seconds)
      )

    rng_state = :rand.export_seed()
    restore_seed(previous_seed)
    {game_state, rng_state}
  end

  defp validate_room_ai(room) do
    if Enum.any?(room.seats, fn {_seat_id, seat} -> seat.kind == "ai" end) do
      ai_ready?(room.config.ai_model)
    else
      :ok
    end
  end

  defp restore_seed(:undefined), do: :rand.seed(:default)
  defp restore_seed(seed), do: :rand.seed(seed)

  defp enforce_room_limit(reservations) do
    limit = Application.get_env(:lemon_sim_ui, :hosted_room_limit, 100)

    active_count =
      Store.list(@room_table)
      |> Enum.count(fn {_id, value} ->
        case Room.normalize(value) do
          %Room{status: status} when status in ["lobby", "running", "paused"] -> true
          _ -> false
        end
      end)

    if active_count + map_size(reservations) < limit,
      do: :ok,
      else: {:error, :room_limit_reached}
  end

  defp prune_active_reservations(state) do
    now = System.monotonic_time(:millisecond)

    reservations =
      Map.reject(state.active_reservations, fn {_id, at_ms} -> now - at_ms > 30_000 end)

    %{state | active_reservations: reservations}
  end

  defp active_room_count(excluded_room_id) do
    Store.list(@room_table)
    |> Enum.count(fn {room_id, value} ->
      room_id != excluded_room_id and
        match?(
          %Room{status: status} when status in ["lobby", "running", "paused"],
          Room.normalize(value)
        )
    end)
  end

  defp prune_finished_rooms do
    retention = Application.get_env(:lemon_sim_ui, :hosted_room_retention, 500)

    Store.list(@room_table)
    |> Enum.map(fn {_id, value} -> Room.normalize(value) end)
    |> Enum.filter(&match?(%Room{status: status} when status in ["completed", "stopped"], &1))
    |> Enum.sort_by(&(&1.updated_at_ms || 0), :desc)
    |> Enum.drop(retention)
    |> Enum.each(&prune_room_if_current/1)

    :ok
  end

  defp prune_expired_lobbies do
    now = System.system_time(:millisecond)

    lobby_cutoff =
      now - Application.get_env(:lemon_sim_ui, :hosted_lobby_ttl_seconds, 86_400) * 1_000

    paused_cutoff =
      now - Application.get_env(:lemon_sim_ui, :hosted_inactive_ttl_seconds, 604_800) * 1_000

    Store.list(@room_table)
    |> Enum.map(fn {_id, value} -> Room.normalize(value) end)
    |> Enum.filter(fn
      %Room{status: "lobby", updated_at_ms: updated} -> (updated || 0) < lobby_cutoff
      %Room{status: "paused", updated_at_ms: updated} -> (updated || 0) < paused_cutoff
      _ -> false
    end)
    |> Enum.each(&prune_room_if_current/1)

    :ok
  end

  defp prune_room_if_current(room) do
    case ensure_room(room.id) do
      {:ok, _pid} -> RoomServer.prune(room.id, room.status, room.updated_at_ms)
      {:error, reason} -> Logger.warning("Hosted Werewolf prune failed: #{error_class(reason)}")
    end
  end

  defp hosted_rooms_enabled? do
    if enabled?(),
      do: :ok,
      else: {:error, :hosted_rooms_disabled}
  end

  defp value(attrs, key, default),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil
  defp parse_optional_integer(value) when value in [nil, ""], do: nil
  defp parse_optional_integer(value), do: parse_integer(value)

  defp random_hex(bytes), do: :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)

  defp random_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp random_join_code do
    alphabet = ~c"ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

    for <<byte <- :crypto.strong_rand_bytes(10)>>, into: "" do
      <<Enum.at(alphabet, rem(byte, length(alphabet)))>>
    end
  end

  defp random_seed do
    :crypto.strong_rand_bytes(4)
    |> :binary.decode_unsigned()
    |> rem(2_147_483_646)
    |> Kernel.+(1)
  end

  def hash_token(token) when is_binary(token) do
    :crypto.hash(:sha256, token) |> Base.url_encode64(padding: false)
  end

  def secure_token?(token, expected_hash) when is_binary(token) and is_binary(expected_hash) do
    provided = hash_token(token)

    byte_size(provided) == byte_size(expected_hash) and
      Plug.Crypto.secure_compare(provided, expected_hash)
  end

  def secure_token?(_token, _expected_hash), do: false

  defp secure_token_value?(provided, expected)
       when is_binary(provided) and is_binary(expected) do
    byte_size(provided) == byte_size(expected) and Plug.Crypto.secure_compare(provided, expected)
  end

  defp secure_token_value?(_provided, _expected), do: false

  def replay_entry(kind, actor, data, at_ms \\ System.system_time(:millisecond)) do
    %{kind: kind, actor: actor, data: data, at_ms: at_ms}
  end

  def emit(event, measurements \\ %{}, metadata \\ %{}) do
    :telemetry.execute([:lemon_sim_ui, :hosted_werewolf, event], measurements, metadata)
  end
end
