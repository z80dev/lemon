defmodule LemonSim.Examples.SpaceStation.ActionSpace do
  @moduledoc false

  @behaviour LemonSim.ActionSpace

  import LemonSim.GameHelpers

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias LemonSim.Examples.SpaceStation.{Events, Roles}
  alias LemonSim.GameHelpers.Tools, as: GameTools

  @system_ids ~w(o2 power hull comms)

  @impl true
  def tools(state, _opts) do
    world = state.world
    status = get(world, :status, "in_progress")

    if status != "in_progress" do
      {:ok, []}
    else
      phase = get(world, :phase, "action")
      actor_id = get(world, :active_actor_id, nil)
      players = get(world, :players, %{})
      actor = Map.get(players, actor_id)

      if is_nil(actor) or get(actor, :status) != "alive" do
        {:ok, []}
      else
        role = get(actor, :role, "crew")
        {:ok, tools_for_phase_and_role(phase, role, actor_id, world)}
      end
    end
  end

  # -- Action phase tools per role --

  defp tools_for_phase_and_role("action", "crew", actor_id, world) do
    [repair_system_tool(actor_id, available_systems(world))]
  end

  defp tools_for_phase_and_role("action", "engineer", actor_id, world) do
    players = get(world, :players, %{})

    living_others =
      players
      |> Roles.living_players()
      |> Enum.reject(fn {id, _p} -> id == actor_id end)
      |> Enum.map(fn {id, _p} -> id end)

    [
      repair_system_tool(actor_id, available_systems(world)),
      scan_player_tool(actor_id, living_others)
    ]
  end

  defp tools_for_phase_and_role("action", "captain", actor_id, world) do
    emergency_available = get(world, :emergency_meeting_available, true)

    base = [
      repair_system_tool(actor_id, available_systems(world)),
      lock_room_tool(actor_id, available_systems(world))
    ]

    if emergency_available do
      base ++ [call_emergency_meeting_tool(actor_id)]
    else
      base
    end
  end

  defp tools_for_phase_and_role("action", "saboteur", actor_id, world) do
    captain_lock = get(world, :captain_lock, nil)
    unlocked_systems = Enum.reject(@system_ids, &(&1 == captain_lock))

    [
      repair_system_tool(actor_id, available_systems(world)),
      sabotage_system_tool(actor_id, unlocked_systems),
      fake_repair_tool(actor_id, available_systems(world)),
      vent_tool(actor_id)
    ]
  end

  defp tools_for_phase_and_role("discussion", _role, actor_id, _world) do
    [
      GameTools.statement_tool(actor_id,
        description:
          "Make a public statement during the discussion. All players will see what you say. " <>
            "You may accuse others, defend yourself, share observations, or bluff. " <>
            "Be strategic based on your role."
      )
    ]
  end

  defp tools_for_phase_and_role("voting", _role, actor_id, world) do
    players = get(world, :players, %{})

    living_others =
      players
      |> Roles.living_players()
      |> Enum.reject(fn {id, _p} -> id == actor_id end)
      |> Enum.map(fn {id, _p} -> id end)

    [
      GameTools.vote_tool(actor_id, living_others,
        description:
          "Vote to eject a player or skip. Valid targets: #{Enum.join(living_others, ", ")}, or \"skip\" to abstain."
      )
    ]
  end

  defp tools_for_phase_and_role(_phase, _role, _actor_id, _world) do
    []
  end

  # -- Helpers --

  defp available_systems(world) do
    captain_lock = get(world, :captain_lock, nil)
    # All systems are available for repair; lock only prevents sabotage
    # But we still show all systems; the updater will enforce lock for sabotage
    systems = get(world, :systems, %{})

    systems
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
    |> case do
      [] -> @system_ids
      ids -> ids
    end
    |> Enum.reject(fn _ -> false end)
    # Filter note: captain_lock only blocks sabotage, not repair
    # This is handled in the tool descriptions and updater
    |> tap(fn _ ->
      if captain_lock do
        :ok
      end
    end)
  end

  # -- Tool builders --

  defp repair_system_tool(actor_id, system_ids) do
    systems_desc = Enum.join(system_ids, ", ")

    %AgentTool{
      name: "repair_system",
      description:
        "Repair a station system to restore +20 health (capped at 100). " <>
          "Everyone will see which system you visited, but not what you did. " <>
          "Available systems: #{systems_desc}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "system_id" => %{
            "type" => "string",
            "description" => "The system to repair. Must be one of: #{systems_desc}",
            "enum" => system_ids
          }
        },
        "required" => ["system_id"],
        "additionalProperties" => false
      },
      label: "Repair System",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        system_id = Map.get(params, "system_id", Map.get(params, :system_id))
        event = Events.repair_system(actor_id, system_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("You repaired the #{system_id} system.")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp sabotage_system_tool(actor_id, system_ids) do
    systems_desc = Enum.join(system_ids, ", ")

    %AgentTool{
      name: "sabotage_system",
      description:
        "Sabotage a station system to deal -25 health. You are the saboteur. " <>
          "Everyone will see you visited this system but won't know you sabotaged it. " <>
          "Cannot sabotage a room locked by the Captain. " <>
          "Available systems: #{systems_desc}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "system_id" => %{
            "type" => "string",
            "description" => "The system to sabotage. Must be one of: #{systems_desc}",
            "enum" => system_ids
          }
        },
        "required" => ["system_id"],
        "additionalProperties" => false
      },
      label: "Sabotage System",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        system_id = Map.get(params, "system_id", Map.get(params, :system_id))
        event = Events.sabotage_system(actor_id, system_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("You sabotaged the #{system_id} system.")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp fake_repair_tool(actor_id, system_ids) do
    systems_desc = Enum.join(system_ids, ", ")

    %AgentTool{
      name: "fake_repair",
      description:
        "Fake a repair on a station system. You appear to visit the system " <>
          "but it has no effect. Useful for maintaining your cover as crew. " <>
          "Available systems: #{systems_desc}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "system_id" => %{
            "type" => "string",
            "description" => "The system to fake-repair. Must be one of: #{systems_desc}",
            "enum" => system_ids
          }
        },
        "required" => ["system_id"],
        "additionalProperties" => false
      },
      label: "Fake Repair",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        system_id = Map.get(params, "system_id", Map.get(params, :system_id))
        event = Events.fake_repair(actor_id, system_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("You faked a repair on the #{system_id} system.")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp scan_player_tool(actor_id, valid_targets) do
    targets_desc = Enum.join(valid_targets, ", ")

    %AgentTool{
      name: "scan_player",
      description:
        "Scan another player to learn whether they repaired or sabotaged last turn. " <>
          "You are the Engineer. The result is private to you only. " <>
          "Note: this uses your action for the turn (you won't also repair). " <>
          "Valid targets: #{targets_desc}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "target_id" => %{
            "type" => "string",
            "description" => "The player to scan. Must be one of: #{targets_desc}",
            "enum" => valid_targets
          }
        },
        "required" => ["target_id"],
        "additionalProperties" => false
      },
      label: "Scan Player",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        target_id = Map.get(params, "target_id", Map.get(params, :target_id))
        event = Events.scan_player(actor_id, target_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("You are scanning #{target_id}.")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp lock_room_tool(actor_id, system_ids) do
    systems_desc = Enum.join(system_ids, ", ")

    %AgentTool{
      name: "lock_room",
      description:
        "Lock a system room to prevent sabotage there this round. You are the Captain. " <>
          "This also counts as your action (you won't repair). " <>
          "The lock is public information. Available systems: #{systems_desc}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "system_id" => %{
            "type" => "string",
            "description" => "The system room to lock. Must be one of: #{systems_desc}",
            "enum" => system_ids
          }
        },
        "required" => ["system_id"],
        "additionalProperties" => false
      },
      label: "Lock Room",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        system_id = Map.get(params, "system_id", Map.get(params, :system_id))
        event = Events.lock_room(actor_id, system_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("You locked the #{system_id} room.")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp call_emergency_meeting_tool(actor_id) do
    %AgentTool{
      name: "call_emergency_meeting",
      description:
        "Call an emergency meeting! This skips the report phase and goes directly " <>
          "to discussion + vote. You are the Captain. You can only use this once per game. " <>
          "Use it when you have strong suspicions.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "Emergency Meeting",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.call_emergency_meeting(actor_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("EMERGENCY MEETING CALLED!")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp vent_tool(actor_id) do
    %AgentTool{
      name: "vent",
      description:
        "Use the vents to skip being seen in any room this round. You are the saboteur. " <>
          "Other players will not see your location. However, you won't be able to " <>
          "repair or sabotage anything this turn.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "Vent",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.vent(actor_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("You slipped into the vents unseen.")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

end
