defmodule LemonSim.Examples.Skirmish.Updater do
  @moduledoc false

  @behaviour LemonSim.Updater

  import LemonSim.GameHelpers

  alias LemonCore.MapHelpers
  alias LemonSim.State

  alias LemonSim.Examples.Skirmish.{
    Events,
    Outcome,
    PhaseEngine,
    Rng,
    UnitClasses
  }

  @impl true
  def apply_event(%State{} = state, raw_event, _opts) do
    event = Events.normalize(raw_event)

    case event.kind do
      "move_requested" -> apply_move_requested(state, event)
      "attack_requested" -> apply_attack_requested(state, event)
      "cover_requested" -> apply_cover_requested(state, event)
      "end_turn_requested" -> apply_end_turn_requested(state, event)
      "heal_requested" -> apply_heal_requested(state, event)
      "sprint_requested" -> apply_sprint_requested(state, event)
      _ -> {:error, {:invalid_event_kind, event.kind}}
    end
  end

  defp apply_move_requested(%State{} = state, event) do
    unit_id = fetch(event.payload, :unit_id, "unit_id")
    x = fetch(event.payload, :x, "x")
    y = fetch(event.payload, :y, "y")

    move_cost = move_ap_cost(state.world, x, y)

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_main_phase(state.world),
         :ok <- ensure_active_actor(state.world, unit_id),
         {:ok, unit} <- fetch_living_unit(state.world, unit_id),
         :ok <- ensure_ap(unit, move_cost),
         :ok <- ensure_coords(x, y),
         :ok <- ensure_in_bounds(state.world, x, y),
         :ok <- ensure_not_wall(state.world, x, y),
         :ok <- ensure_move_range(unit, x, y),
         :ok <- ensure_unoccupied(state.world, unit_id, x, y) do
      on_cover = on_cover_tile?(state.world, x, y)

      next_world =
        state.world
        |> put_unit(
          unit_id,
          unit |> Map.put(:ap, get(unit, :ap, 0) - move_cost) |> Map.put(:cover?, on_cover) |> put_pos(x, y)
        )

      action_events = [
        Events.ap_spent(unit_id, move_cost, unit_ap(next_world, unit_id)),
        Events.unit_moved(unit_id, x, y)
      ]

      state
      |> append_action(event, next_world, action_events)
      |> continue_or_advance(unit_id)
    else
      {:error, reason} ->
        reject_action(state, event, unit_id, reason)
    end
  end

  defp apply_sprint_requested(%State{} = state, event) do
    unit_id = fetch(event.payload, :unit_id, "unit_id")
    x = fetch(event.payload, :x, "x")
    y = fetch(event.payload, :y, "y")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_main_phase(state.world),
         :ok <- ensure_active_actor(state.world, unit_id),
         {:ok, unit} <- fetch_living_unit(state.world, unit_id),
         :ok <- ensure_ability(unit, :sprint),
         :ok <- ensure_ap(unit, 1),
         :ok <- ensure_coords(x, y),
         :ok <- ensure_in_bounds(state.world, x, y),
         :ok <- ensure_not_wall(state.world, x, y),
         :ok <- ensure_sprint_range(unit, x, y),
         :ok <- ensure_unoccupied(state.world, unit_id, x, y) do
      on_cover = on_cover_tile?(state.world, x, y)

      next_world =
        state.world
        |> put_unit(
          unit_id,
          unit |> Map.put(:ap, get(unit, :ap, 0) - 1) |> Map.put(:cover?, on_cover) |> put_pos(x, y)
        )

      action_events = [
        Events.ap_spent(unit_id, 1, unit_ap(next_world, unit_id)),
        Events.unit_sprinted(unit_id, x, y)
      ]

      state
      |> append_action(event, next_world, action_events)
      |> continue_or_advance(unit_id)
    else
      {:error, reason} ->
        reject_action(state, event, unit_id, reason)
    end
  end

  defp apply_heal_requested(%State{} = state, event) do
    healer_id = fetch(event.payload, :healer_id, "healer_id")
    target_id = fetch(event.payload, :target_id, "target_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_main_phase(state.world),
         :ok <- ensure_active_actor(state.world, healer_id),
         {:ok, healer} <- fetch_living_unit(state.world, healer_id),
         {:ok, target} <- fetch_living_unit(state.world, target_id),
         :ok <- ensure_ability(healer, :heal),
         :ok <- ensure_ally(healer, target),
         :ok <- ensure_ap(healer, 1),
         :ok <- ensure_in_range(healer, target),
         :ok <- ensure_wounded(target) do
      heal_amount = get(healer, :heal_amount, 3)
      max_hp = get(target, :max_hp, get(target, :hp, 0))
      new_hp = min(get(target, :hp, 0) + heal_amount, max_hp)
      actual_heal = new_hp - get(target, :hp, 0)

      updated_healer = Map.put(healer, :ap, get(healer, :ap, 0) - 1)
      updated_target = Map.put(target, :hp, new_hp)

      next_world =
        state.world
        |> put_unit(healer_id, updated_healer)
        |> put_unit(target_id, updated_target)

      action_events = [
        Events.ap_spent(healer_id, 1, unit_ap(next_world, healer_id)),
        Events.heal_applied(healer_id, target_id, actual_heal, new_hp)
      ]

      state
      |> append_action(event, next_world, action_events)
      |> continue_or_advance(healer_id)
    else
      {:error, reason} ->
        reject_action(state, event, healer_id, reason)
    end
  end

  defp apply_attack_requested(%State{} = state, event) do
    attacker_id = fetch(event.payload, :attacker_id, "attacker_id")
    target_id = fetch(event.payload, :target_id, "target_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_main_phase(state.world),
         :ok <- ensure_active_actor(state.world, attacker_id),
         {:ok, attacker} <- fetch_living_unit(state.world, attacker_id),
         {:ok, target} <- fetch_living_unit(state.world, target_id),
         :ok <- ensure_enemy(attacker, target),
         :ok <- ensure_ap(attacker, 1),
         :ok <- ensure_in_range(attacker, target) do
      {roll, next_seed} = Rng.roll(get(state.world, :rng_seed, 0))
      chance = hit_chance_with_terrain(attacker, target, state.world)

      outcome =
        Outcome.attack(
          roll,
          chance,
          get(attacker, :attack_damage, 0),
          get(target, :hp, 0)
        )

      updated_target =
        target
        |> Map.put(:hp, outcome.defender_hp)
        |> Map.put(
          :status,
          if(outcome.defender_died?, do: "dead", else: get(target, :status, "alive"))
        )

      updated_units =
        state.world
        |> get(:units, %{})
        |> Map.put(attacker_id, Map.put(attacker, :ap, get(attacker, :ap, 0) - 1))
        |> Map.put(target_id, updated_target)

      winner = Outcome.winner(updated_units)
      outcome = Outcome.with_winner(outcome, winner)

      next_world =
        state.world
        |> Map.put(:units, updated_units)
        |> Map.put(:rng_seed, next_seed)
        |> Map.put(:winner, winner)
        |> Map.put(:status, if(is_binary(winner), do: "won", else: "in_progress"))
        |> Map.put(:phase, if(is_binary(winner), do: "game_over", else: "main"))
        |> Map.put(
          :active_actor_id,
          if(is_binary(winner), do: nil, else: MapHelpers.get_key(state.world, :active_actor_id))
        )

      action_events =
        [
          Events.ap_spent(
            attacker_id,
            1,
            unit_ap(%{state.world | units: updated_units}, attacker_id)
          ),
          Events.attack_resolved(
            attacker_id,
            target_id,
            outcome.roll,
            outcome.chance,
            outcome.hit?,
            outcome.damage
          )
        ] ++
          maybe_damage_event(target_id, outcome) ++
          maybe_death_event(target_id, updated_target, outcome) ++
          maybe_game_over_event(outcome)

      if is_binary(winner) do
        {:ok, append_action(state, event, next_world, action_events), :skip}
      else
        state
        |> append_action(event, next_world, action_events)
        |> continue_or_advance(attacker_id)
      end
    else
      {:error, reason} ->
        reject_action(state, event, attacker_id, reason)
    end
  end

  defp apply_cover_requested(%State{} = state, event) do
    unit_id = fetch(event.payload, :unit_id, "unit_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_main_phase(state.world),
         :ok <- ensure_active_actor(state.world, unit_id),
         {:ok, unit} <- fetch_living_unit(state.world, unit_id),
         :ok <- ensure_ap(unit, 1) do
      updated_unit =
        unit
        |> Map.put(:ap, get(unit, :ap, 0) - 1)
        |> Map.put(:cover?, true)

      next_world = put_unit(state.world, unit_id, updated_unit)

      action_events = [
        Events.ap_spent(unit_id, 1, unit_ap(next_world, unit_id)),
        Events.cover_applied(unit_id)
      ]

      state
      |> append_action(event, next_world, action_events)
      |> continue_or_advance(unit_id)
    else
      {:error, reason} ->
        reject_action(state, event, unit_id, reason)
    end
  end

  defp apply_end_turn_requested(%State{} = state, event) do
    unit_id = fetch(event.payload, :unit_id, "unit_id")

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_active_actor(state.world, unit_id),
         {next_world, phase_events} <- PhaseEngine.advance_turn(state.world) do
      next_state = append_action(state, event, next_world, phase_events)
      {:ok, next_state, {:decide, "#{MapHelpers.get_key(next_world, :active_actor_id)} turn"}}
    else
      {:error, reason} ->
        reject_action(state, event, unit_id, reason)
    end
  end

  defp continue_or_advance(%State{} = state, unit_id) do
    unit = fetch_unit(state.world, unit_id)

    cond do
      is_nil(unit) ->
        {:ok, state, {:decide, "next actor turn"}}

      MapHelpers.get_key(unit, :status) == "dead" ->
        advance_turn(state)

      get(unit, :ap, 0) <= 0 ->
        advance_turn(state)

      true ->
        remaining = get(unit, :ap, 0)
        {:ok, state, {:decide, "#{unit_id} has #{remaining} ap remaining"}}
    end
  end

  defp advance_turn(%State{} = state) do
    {next_world, phase_events} = PhaseEngine.advance_turn(state.world)
    next_state = append_action(state, nil, next_world, phase_events, true)
    {:ok, next_state, {:decide, "#{MapHelpers.get_key(next_world, :active_actor_id)} turn"}}
  end

  defp append_action(
         %State{} = state,
         event,
         next_world,
         action_events,
         include_world_update \\ true
       ) do
    base_state =
      state
      |> maybe_append_event(event)
      |> maybe_update_world(next_world, include_world_update)

    append_events(base_state, action_events)
  end

  defp maybe_update_world(%State{} = state, next_world, true),
    do: State.update_world(state, fn _ -> next_world end)

  defp maybe_update_world(%State{} = state, _next_world, false), do: state

  defp maybe_append_event(%State{} = state, nil), do: state
  defp maybe_append_event(%State{} = state, event), do: State.append_event(state, event)

  defp append_events(%State{} = state, events) do
    State.append_events(state, Enum.reject(events, &is_nil/1))
  end

  defp reject_action(%State{} = state, event, unit_id, reason) do
    message = rejection_reason(reason)

    next_state =
      state
      |> State.append_event(event)
      |> State.append_event(
        Events.action_rejected(event.kind, to_string(unit_id || "unknown"), message)
      )

    {:ok, next_state, {:decide, message}}
  end

  defp ensure_in_progress(world) do
    if MapHelpers.get_key(world, :status) == "in_progress", do: :ok, else: {:error, :game_over}
  end

  defp ensure_main_phase(world) do
    if MapHelpers.get_key(world, :phase) == "main", do: :ok, else: {:error, :wrong_phase}
  end

  defp ensure_active_actor(world, unit_id) do
    if MapHelpers.get_key(world, :active_actor_id) == unit_id,
      do: :ok,
      else: {:error, :not_active_actor}
  end

  defp fetch_living_unit(world, unit_id) when is_binary(unit_id) do
    case fetch_unit(world, unit_id) do
      nil ->
        {:error, :unknown_unit}

      unit ->
        if MapHelpers.get_key(unit, :status) == "dead" or get(unit, :hp, 0) <= 0 do
          {:error, :unit_dead}
        else
          {:ok, unit}
        end
    end
  end

  defp fetch_living_unit(_world, _unit_id), do: {:error, :invalid_unit}

  defp ensure_enemy(attacker, target) do
    if MapHelpers.get_key(attacker, :team) != MapHelpers.get_key(target, :team),
      do: :ok,
      else: {:error, :friendly_target}
  end

  defp ensure_ap(unit, cost) do
    if get(unit, :ap, 0) >= cost, do: :ok, else: {:error, :insufficient_ap}
  end

  defp ensure_coords(x, y) when is_integer(x) and is_integer(y), do: :ok
  defp ensure_coords(_x, _y), do: {:error, :invalid_coords}

  defp ensure_in_bounds(world, x, y) do
    map = get(world, :map, %{})
    width = get(map, :width, 0)
    height = get(map, :height, 0)

    if x >= 0 and x < width and y >= 0 and y < height, do: :ok, else: {:error, :out_of_bounds}
  end

  defp ensure_move_range(unit, x, y) do
    pos = get(unit, :pos, %{})
    distance = abs(get(pos, :x, 0) - x) + abs(get(pos, :y, 0) - y)
    if distance >= 1 and distance <= 2, do: :ok, else: {:error, :move_out_of_range}
  end

  defp ensure_unoccupied(world, moving_unit_id, x, y) do
    occupied? =
      world
      |> get(:units, %{})
      |> Enum.any?(fn {unit_id, unit} ->
        unit_id != moving_unit_id and MapHelpers.get_key(unit, :status) != "dead" and
          get(get(unit, :pos, %{}), :x, nil) == x and
          get(get(unit, :pos, %{}), :y, nil) == y
      end)

    if occupied?, do: {:error, :tile_occupied}, else: :ok
  end

  defp ensure_in_range(attacker, target) do
    attacker_pos = get(attacker, :pos, %{})
    target_pos = get(target, :pos, %{})

    distance =
      abs(get(attacker_pos, :x, 0) - get(target_pos, :x, 0)) +
        abs(get(attacker_pos, :y, 0) - get(target_pos, :y, 0))

    if distance <= get(attacker, :attack_range, 0),
      do: :ok,
      else: {:error, :target_out_of_range}
  end

  defp hit_chance_with_terrain(attacker, target, world) do
    base = get(attacker, :attack_chance, 80)
    cover_modifier = if get(target, :cover?, false), do: 20, else: 0
    high_ground_bonus = if world && on_high_ground?(world, attacker), do: 15, else: 0
    max(base - cover_modifier + high_ground_bonus, 5)
  end

  defp maybe_damage_event(_target_id, %Outcome{damage: 0}), do: []

  defp maybe_damage_event(target_id, %Outcome{} = outcome) do
    [Events.damage_applied(target_id, outcome.damage, outcome.defender_hp)]
  end

  defp maybe_death_event(_target_id, _target, %Outcome{defender_died?: false}), do: []

  defp maybe_death_event(target_id, target, %Outcome{defender_died?: true}) do
    [Events.unit_died(target_id, MapHelpers.get_key(target, :team))]
  end

  defp maybe_game_over_event(%Outcome{winner: nil}), do: []
  defp maybe_game_over_event(%Outcome{winner: winner}), do: [Events.game_over(winner)]

  defp fetch_unit(world, unit_id) do
    world
    |> get(:units, %{})
    |> Map.get(unit_id)
  end

  defp unit_ap(world, unit_id) do
    world
    |> fetch_unit(unit_id)
    |> case do
      nil -> 0
      unit -> get(unit, :ap, 0)
    end
  end

  defp put_unit(world, unit_id, unit) do
    Map.update(world, :units, %{unit_id => unit}, &Map.put(&1, unit_id, unit))
  end

  defp put_pos(unit, x, y), do: Map.put(unit, :pos, %{x: x, y: y})

  defp ensure_not_wall(world, x, y) do
    walls = get(get(world, :map, %{}), :walls, [])

    is_wall =
      Enum.any?(walls, fn w ->
        get_coord(w, :x) == x and get_coord(w, :y) == y
      end)

    if is_wall, do: {:error, :tile_is_wall}, else: :ok
  end

  defp ensure_sprint_range(unit, x, y) do
    pos = get(unit, :pos, %{})
    distance = abs(get(pos, :x, 0) - x) + abs(get(pos, :y, 0) - y)
    if distance >= 1 and distance <= 3, do: :ok, else: {:error, :sprint_out_of_range}
  end

  defp ensure_ability(unit, ability) do
    if UnitClasses.has_ability?(unit, ability), do: :ok, else: {:error, :no_ability}
  end

  defp ensure_ally(unit_a, unit_b) do
    if MapHelpers.get_key(unit_a, :team) == MapHelpers.get_key(unit_b, :team),
      do: :ok,
      else: {:error, :not_ally}
  end

  defp ensure_wounded(target) do
    hp = get(target, :hp, 0)
    max_hp = get(target, :max_hp, hp)
    if hp < max_hp, do: :ok, else: {:error, :target_full_hp}
  end

  defp move_ap_cost(world, x, y) do
    water = get(get(world, :map, %{}), :water, [])

    is_water =
      Enum.any?(water, fn w ->
        get_coord(w, :x) == x and get_coord(w, :y) == y
      end)

    if is_water, do: 2, else: 1
  end

  defp on_cover_tile?(world, x, y) do
    cover = get(get(world, :map, %{}), :cover, [])

    Enum.any?(cover, fn c ->
      get_coord(c, :x) == x and get_coord(c, :y) == y
    end)
  end

  defp on_high_ground?(world, unit) do
    pos = get(unit, :pos, %{})
    ux = get(pos, :x, -1)
    uy = get(pos, :y, -1)
    high_ground = get(get(world, :map, %{}), :high_ground, [])

    Enum.any?(high_ground, fn hg ->
      get_coord(hg, :x) == ux and get_coord(hg, :y) == uy
    end)
  end

  defp get_coord(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), 0))
  end

  defp get_coord(_, _), do: 0

  defp rejection_reason(:game_over), do: "game already over"
  defp rejection_reason(:wrong_phase), do: "wrong phase"
  defp rejection_reason(:not_active_actor), do: "not the active actor"
  defp rejection_reason(:unknown_unit), do: "unknown unit"
  defp rejection_reason(:invalid_unit), do: "invalid unit"
  defp rejection_reason(:unit_dead), do: "unit is dead"
  defp rejection_reason(:friendly_target), do: "cannot target ally"
  defp rejection_reason(:insufficient_ap), do: "insufficient ap"
  defp rejection_reason(:invalid_coords), do: "invalid coordinates"
  defp rejection_reason(:out_of_bounds), do: "out of bounds"
  defp rejection_reason(:move_out_of_range), do: "move must be within 2 tiles"
  defp rejection_reason(:tile_occupied), do: "destination occupied"
  defp rejection_reason(:target_out_of_range), do: "target out of range"
  defp rejection_reason(:tile_is_wall), do: "cannot move onto wall"
  defp rejection_reason(:sprint_out_of_range), do: "sprint must be 1-3 tiles"
  defp rejection_reason(:no_ability), do: "unit does not have that ability"
  defp rejection_reason(:not_ally), do: "target is not an ally"
  defp rejection_reason(:target_full_hp), do: "target is at full health"
  defp rejection_reason(other), do: "rejected: #{inspect(other)}"

end
