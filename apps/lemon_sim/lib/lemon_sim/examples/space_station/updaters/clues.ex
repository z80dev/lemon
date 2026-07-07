defmodule LemonSim.Examples.SpaceStation.Updaters.Clues do
  @moduledoc false

  import LemonSim.Examples.Helpers
  import LemonSim.Examples.Helpers.UpdaterHelpers
  import LemonSim.Examples.SpaceStation.Updaters.Support

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.SpaceStation.{Events, Roles}

  # -- Clue generation --
  # After each round, generate evidence based on actual actions and distribute to random players

  def generate_and_distribute_clues(state, action_log, players, round) do
    living = Roles.living_players(players) |> Enum.map(fn {id, _p} -> id end)

    # Build pool of possible clues from this round's actions
    clue_pool =
      action_log
      |> Enum.flat_map(fn {player_id, action_entry} ->
        action = get_action_field(action_entry, :action)
        system_id = get_action_field(action_entry, :system)
        build_clues_for_action(player_id, action, system_id, players)
      end)

    # Select 2-3 clues to distribute
    clue_count = min(length(clue_pool), Enum.random(2..3))
    selected_clues = clue_pool |> Enum.shuffle() |> Enum.take(clue_count)

    # Distribute each clue to a random living player (not the actor)
    {updated_clues, clue_events, clue_recipients} =
      Enum.reduce(selected_clues, {get(state.world, :clues, %{}), [], []}, fn clue,
                                                                              {acc_clues,
                                                                               acc_events,
                                                                               acc_recipients} ->
        actor_id = Map.get(clue, :about_player)
        eligible = Enum.reject(living, &(&1 == actor_id))

        case eligible do
          [] ->
            {acc_clues, acc_events, acc_recipients}

          recipients ->
            recipient = Enum.random(recipients)
            clue_with_round = Map.put(clue, :round, round)

            player_clues = Map.get(acc_clues, recipient, [])
            updated = Map.put(acc_clues, recipient, player_clues ++ [clue_with_round])

            event = Events.clue_found(recipient, clue_with_round)
            clue_type = Map.get(clue, :type, "evidence")
            {updated, acc_events ++ [event], acc_recipients ++ [{recipient, clue_type}]}
        end
      end)

    updated_state =
      State.put_world(state, world_updates(state.world, %{clues: updated_clues}))

    # Add journal entries for clue recipients
    updated_state =
      Enum.reduce(clue_recipients, updated_state, fn {recipient, clue_type}, acc ->
        add_journal_entry(acc, recipient, "Found a clue: #{clue_type} evidence noted.")
      end)

    {updated_state, clue_events}
  end

  defp build_clues_for_action(player_id, action, system_id, _players) do
    system_name = system_display_name(system_id)

    case action do
      "repair" ->
        [
          Enum.random([
            %{
              type: "tool_marks",
              text:
                "You notice fresh tool marks and repair residue on the #{system_name} system.",
              about_player: player_id
            },
            %{
              type: "sound",
              text:
                "You heard the distinctive hum of repair equipment coming from #{system_name} this round.",
              about_player: player_id
            }
          ])
        ]

      "sabotage" ->
        [
          Enum.random([
            %{
              type: "damage_evidence",
              text:
                "You spot scorch marks and deliberate cuts on the #{system_name} system — this doesn't look like normal wear.",
              about_player: player_id
            },
            %{
              type: "suspicious_activity",
              text:
                "A security camera near #{system_name} captured a blurred figure working hastily, unlike normal repair posture.",
              about_player: player_id
            },
            %{
              type: "chemical_residue",
              text:
                "You detect an unusual chemical residue near the #{system_name} system — consistent with deliberate interference.",
              about_player: player_id
            }
          ])
        ]

      "fake_repair" ->
        [
          %{
            type: "incomplete_work",
            text:
              "The #{system_name} system shows signs someone was there, but no actual repairs were completed.",
            about_player: player_id
          }
        ]

      "vent" ->
        [
          %{
            type: "vent_noise",
            text:
              "You heard unusual sounds from the ventilation system — someone might be moving through the ducts.",
            about_player: player_id
          }
        ]

      "scan" ->
        [
          %{
            type: "scanner_activity",
            text:
              "You noticed a brief spike in the station's bio-scanner array. Someone used the scanning equipment.",
            about_player: player_id
          }
        ]

      _ ->
        []
    end
  end
end
