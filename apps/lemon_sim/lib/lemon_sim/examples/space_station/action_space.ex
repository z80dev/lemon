defmodule LemonSim.Examples.SpaceStation.ActionSpace do
  @moduledoc false

  @behaviour LemonSim.ActionSpace

  import LemonSim.GameHelpers

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias LemonSim.Examples.SpaceStation.{Events, Roles}
  alias LemonSim.GameHelpers.Tools, as: GameTools

  @system_ids ~w(o2 power hull comms nav medbay shields)

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
        {:ok, Enum.map(tools_for_phase_and_role(phase, role, actor_id, world), &GameTools.add_thought_param/1)}
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

  defp tools_for_phase_and_role("discussion", _role, actor_id, world) do
    players = get(world, :players, %{})

    living_others =
      players
      |> Roles.living_players()
      |> Enum.reject(fn {id, _p} -> id == actor_id end)
      |> Enum.map(fn {id, _p} -> id end)

    [
      GameTools.statement_tool(actor_id,
        description:
          "Make a general public statement during the discussion. All players will see what you say. " <>
            "Use this for observations, theories, coordination, or defense. " <>
            "For direct questions or formal accusations, use the dedicated tools instead."
      ),
      ask_question_tool(actor_id, living_others),
      accuse_tool(actor_id, living_others)
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
        "Repair a station system to restore health (capped at 100). " <>
          "Only players at the same system will see you there. " <>
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
        "Sabotage a station system to damage it. You are the saboteur. " <>
          "Only players at the same system will see you there, but won't know you sabotaged. " <>
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
      name: "inspect_system",
      description:
        "Run a diagnostic inspection on a station system. You visit the system and assess its condition " <>
          "without performing active repairs. Other players at that system will see you working there normally. " <>
          "To them, this looks identical to a repair. Available systems: #{systems_desc}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "system_id" => %{
            "type" => "string",
            "description" => "The system to inspect. Must be one of: #{systems_desc}",
            "enum" => system_ids
          }
        },
        "required" => ["system_id"],
        "additionalProperties" => false
      },
      label: "Inspect System",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        system_id = Map.get(params, "system_id", Map.get(params, :system_id))
        event = Events.fake_repair(actor_id, system_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("You inspected the #{system_id} system. To others, this looked like a normal repair.")],
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
          "WARNING: Station interference causes occasional false readings — scans are wrong about 25% of the time. " <>
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

  defp ask_question_tool(actor_id, valid_targets) do
    targets_desc = Enum.join(valid_targets, ", ")

    %AgentTool{
      name: "ask_question",
      description:
        "Publicly ask a specific player a direct question. The question and your target " <>
          "will be visible to all players. This puts pressure on the target to respond " <>
          "and demonstrates your reasoning. Use this to probe inconsistencies, request alibis, " <>
          "or challenge suspicious behavior. Valid targets: #{targets_desc}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "target_id" => %{
            "type" => "string",
            "description" => "The player you are questioning. Must be one of: #{targets_desc}",
            "enum" => valid_targets
          },
          "question" => %{
            "type" => "string",
            "description" =>
              "Your question to the target player. Be specific and pointed (1-2 sentences)."
          }
        },
        "required" => ["target_id", "question"],
        "additionalProperties" => false
      },
      label: "Ask Question",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        target_id = Map.get(params, "target_id", Map.get(params, :target_id))
        question = Map.get(params, "question", Map.get(params, :question, ""))
        event = Events.ask_question(actor_id, target_id, question)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("You asked #{target_id}: \"#{question}\"")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp accuse_tool(actor_id, valid_targets) do
    targets_desc = Enum.join(valid_targets, ", ")

    %AgentTool{
      name: "accuse",
      description:
        "Make a formal accusation against a specific player, presenting your evidence and reasoning. " <>
          "This is a strong move — it signals to the group that you believe this player is the saboteur " <>
          "and want them ejected. All players will see your accusation and evidence. " <>
          "Use this when you have built a case through observations, clues, or scan results. " <>
          "Valid targets: #{targets_desc}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "target_id" => %{
            "type" => "string",
            "description" => "The player you are accusing. Must be one of: #{targets_desc}",
            "enum" => valid_targets
          },
          "evidence" => %{
            "type" => "string",
            "description" =>
              "Your case against this player. Present observations, clues, and reasoning (2-4 sentences)."
          }
        },
        "required" => ["target_id", "evidence"],
        "additionalProperties" => false
      },
      label: "Accuse",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        target_id = Map.get(params, "target_id", Map.get(params, :target_id))
        evidence = Map.get(params, "evidence", Map.get(params, :evidence, ""))
        event = Events.accuse(actor_id, target_id, evidence)

        {:ok,
         %AgentToolResult{
           content: [
             AgentCore.text_content(
               "You formally accused #{target_id}: \"#{evidence}\""
             )
           ],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

end
