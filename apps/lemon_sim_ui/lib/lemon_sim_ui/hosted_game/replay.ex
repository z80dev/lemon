defmodule LemonSimUi.HostedGame.Replay do
  @moduledoc false

  alias LemonSim.Examples.Werewolf
  alias LemonSim.Examples.Werewolf.RulesConfig
  alias LemonSim.Kernel.{Event, Runner, State}

  def verify(export) when is_map(export) do
    config = value(export, :config, %{})
    seats = value(export, :seats, %{})
    seed = value(config, :seed)
    player_ids = value(export, :player_ids, Map.keys(seats)) |> Enum.sort()
    previous_seed = :rand.export_seed()

    try do
      :rand.seed(:exsss, {seed, seed + 1, seed + 2})

      initial_opts = [
        sim_id: "hosted_replay_verification",
        player_count: value(config, :player_count),
        generate_lore?: false
      ]

      initial_opts =
        if value(export, :match_number, 1) > 1 do
          Keyword.put(initial_opts, :player_ids, player_ids)
        else
          initial_opts
        end

      state = Werewolf.initial_state(initial_opts)

      if MapSet.new(Map.keys(state.world.players)) != MapSet.new(player_ids) do
        raise ArgumentError, "replay player IDs do not match the seeded game"
      end

      state =
        put_in(
          state.world[:rules],
          config
          |> value(:rules_preset)
          |> RulesConfig.for_preset()
          |> Map.put(:turn_timeout_seconds, value(config, :turn_timeout_seconds))
        )

      with {:ok, final_state} <- replay_commands(state, value(export, :replay, [])),
           true <- state_hash(final_state) == value(export, :final_state_hash) do
        {:ok, %{commands: value(export, :command_seq, 0), state_hash: state_hash(final_state)}}
      else
        false -> {:error, :final_state_hash_mismatch}
        {:error, _reason} = error -> error
      end
    after
      restore_rng(previous_seed)
    end
  rescue
    _ -> {:error, :invalid_replay}
  end

  def verify(_export), do: {:error, :invalid_replay}

  def state_hash(%State{} = state) do
    world = state.world |> Map.delete(:journals) |> Map.delete("journals")

    :crypto.hash(:sha256, :erlang.term_to_binary({state.version, world}))
    |> Base.url_encode64(padding: false)
  end

  defp replay_commands(state, entries) do
    entries
    |> Enum.filter(&(value(&1, :kind) == "command"))
    |> Enum.reduce_while({:ok, state}, fn entry, {:ok, current_state} ->
      data = value(entry, :data, %{})
      expected_hash = value(data, :state_hash)

      events =
        data
        |> value(:events, [])
        |> Enum.map(fn event ->
          Event.new(value(event, :kind), value(event, :payload, %{}))
        end)

      case Runner.ingest_events(current_state, events, Werewolf.Updater, halt_on_decide?: false) do
        {:ok, next_state, _signal} ->
          if state_hash(next_state) == expected_hash do
            {:cont, {:ok, next_state}}
          else
            {:halt, {:error, :command_state_hash_mismatch}}
          end

        {:error, reason} ->
          {:halt, {:error, {:replay_event_rejected, reason}}}
      end
    end)
  end

  defp value(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp restore_rng(:undefined), do: :rand.seed(:default)
  defp restore_rng(seed), do: :rand.seed(seed)
end
