defmodule LemonSim.Examples.Werewolf.ActionSpace do
  @moduledoc false

  @behaviour LemonSim.ActionSpace

  import LemonSim.GameHelpers

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias LemonSim.Examples.Werewolf.{Events, Roles}

  @impl true
  def tools(state, _opts) do
    world = state.world
    status = get(world, :status, "in_progress")

    if status != "in_progress" do
      {:ok, []}
    else
      phase = get(world, :phase, "night")
      actor_id = get(world, :active_actor_id, nil)
      players = get(world, :players, %{})
      actor = Map.get(players, actor_id)

      if is_nil(actor) or get(actor, :status) != "alive" do
        {:ok, []}
      else
        role = get(actor, :role, "villager")
        {:ok, tools_for_phase_and_role(phase, role, actor_id, players)}
      end
    end
  end

  defp tools_for_phase_and_role("night", "werewolf", actor_id, players) do
    living_non_wolves =
      players
      |> Roles.living_players()
      |> Enum.reject(fn {_id, p} -> get(p, :role) == "werewolf" end)
      |> Enum.map(fn {id, _p} -> id end)

    [choose_victim_tool(actor_id, living_non_wolves, players)]
  end

  defp tools_for_phase_and_role("night", "seer", actor_id, players) do
    living_others =
      players
      |> Roles.living_players()
      |> Enum.reject(fn {id, _p} -> id == actor_id end)
      |> Enum.map(fn {id, _p} -> id end)

    [investigate_player_tool(actor_id, living_others, players)]
  end

  defp tools_for_phase_and_role("night", "doctor", actor_id, players) do
    living =
      players
      |> Roles.living_players()
      |> Enum.map(fn {id, _p} -> id end)

    [protect_player_tool(actor_id, living, players)]
  end

  defp tools_for_phase_and_role("night", _villager, actor_id, _players) do
    [sleep_tool(actor_id)]
  end

  defp tools_for_phase_and_role("day_discussion", actor_id_role, actor_id, _players)
       when actor_id_role in ["werewolf", "seer", "doctor", "villager"] do
    [
      LemonSim.GameHelpers.Tools.statement_tool(actor_id,
        description:
          "Make a public statement during the day discussion. All players will see what you say. " <>
            "You may accuse others, defend yourself, share information, bluff, or stay vague. " <>
            "Be strategic based on your role."
      )
    ]
  end

  defp tools_for_phase_and_role("day_discussion", _role, actor_id, _players) do
    [
      LemonSim.GameHelpers.Tools.statement_tool(actor_id,
        description:
          "Make a public statement during the day discussion. All players will see what you say. " <>
            "You may accuse others, defend yourself, share information, bluff, or stay vague. " <>
            "Be strategic based on your role."
      )
    ]
  end

  defp tools_for_phase_and_role("day_voting", _role, actor_id, players) do
    living_others =
      players
      |> Roles.living_players()
      |> Enum.reject(fn {id, _p} -> id == actor_id end)
      |> Enum.map(fn {id, _p} -> id end)

    [
      LemonSim.GameHelpers.Tools.vote_tool(actor_id, living_others,
        description:
          "Vote to eliminate a player or skip. Valid targets: #{Enum.join(living_others, ", ")}, or \"skip\" to abstain."
      )
    ]
  end

  defp tools_for_phase_and_role(_phase, _role, _actor_id, _players) do
    []
  end

  # -- Tool builders --

  defp choose_victim_tool(actor_id, valid_targets, _players) do
    targets_desc = Enum.join(valid_targets, ", ")

    %AgentTool{
      name: "choose_victim",
      description:
        "Choose a player to kill tonight. You are a werewolf. Valid targets: #{targets_desc}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "victim_id" => %{
            "type" => "string",
            "description" => "The player to kill. Must be one of: #{targets_desc}",
            "enum" => valid_targets
          }
        },
        "required" => ["victim_id"],
        "additionalProperties" => false
      },
      label: "Choose Victim",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        victim_id = Map.get(params, "victim_id", Map.get(params, :victim_id))
        event = Events.choose_victim(actor_id, victim_id)

        {:ok,
         %AgentToolResult{
           content: [
             AgentCore.text_content(
               "You chose to target #{victim_id} tonight."
             )
           ],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp investigate_player_tool(actor_id, valid_targets, _players) do
    targets_desc = Enum.join(valid_targets, ", ")

    %AgentTool{
      name: "investigate_player",
      description:
        "Investigate a player to learn their role. You are the Seer. Valid targets: #{targets_desc}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "target_id" => %{
            "type" => "string",
            "description" => "The player to investigate. Must be one of: #{targets_desc}",
            "enum" => valid_targets
          }
        },
        "required" => ["target_id"],
        "additionalProperties" => false
      },
      label: "Investigate Player",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        target_id = Map.get(params, "target_id", Map.get(params, :target_id))
        event = Events.investigate_player(actor_id, target_id)

        {:ok,
         %AgentToolResult{
           content: [
             AgentCore.text_content("You are investigating #{target_id}.")
           ],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp protect_player_tool(actor_id, valid_targets, _players) do
    targets_desc = Enum.join(valid_targets, ", ")

    %AgentTool{
      name: "protect_player",
      description:
        "Choose a player to protect tonight. You are the Doctor. Valid targets: #{targets_desc}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "target_id" => %{
            "type" => "string",
            "description" => "The player to protect. Must be one of: #{targets_desc}",
            "enum" => valid_targets
          }
        },
        "required" => ["target_id"],
        "additionalProperties" => false
      },
      label: "Protect Player",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        target_id = Map.get(params, "target_id", Map.get(params, :target_id))
        event = Events.protect_player(actor_id, target_id)

        {:ok,
         %AgentToolResult{
           content: [
             AgentCore.text_content(
               "You chose to protect #{target_id} tonight."
             )
           ],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp sleep_tool(actor_id) do
    %AgentTool{
      name: "sleep",
      description: "You are a villager. Sleep through the night. There is nothing you can do.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "Sleep",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.sleep(actor_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("You sleep through the night.")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

end
