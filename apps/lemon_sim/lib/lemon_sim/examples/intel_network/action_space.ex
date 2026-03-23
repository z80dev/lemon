defmodule LemonSim.Examples.IntelNetwork.ActionSpace do
  @moduledoc false

  @behaviour LemonSim.ActionSpace

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias LemonCore.MapHelpers
  alias LemonSim.Examples.IntelNetwork.{Events, NetworkGraph}
  alias LemonSim.GameHelpers.Tools, as: GameTools

  @impl true
  def tools(state, _opts) do
    world = state.world
    status = MapHelpers.get_key(world, :status)
    phase = MapHelpers.get_key(world, :phase)
    actor_id = MapHelpers.get_key(world, :active_actor_id)

    cond do
      status != "in_progress" ->
        {:ok, []}

      phase == "intel_briefing" ->
        {:ok, Enum.map(briefing_tools(world, actor_id), &GameTools.add_thought_param/1)}

      phase == "communication" ->
        {:ok, Enum.map(communication_tools(world, actor_id), &GameTools.add_thought_param/1)}

      phase == "analysis" ->
        {:ok, Enum.map(analysis_tools(world, actor_id), &GameTools.add_thought_param/1)}

      phase == "operation" ->
        {:ok, Enum.map(operation_tools(world, actor_id), &GameTools.add_thought_param/1)}

      phase == "mole_action" ->
        {:ok, Enum.map(mole_action_tools(world, actor_id), &GameTools.add_thought_param/1)}

      true ->
        {:ok, []}
    end
  end

  # -- Intel Briefing Phase --

  defp briefing_tools(_world, actor_id) do
    [end_briefing_tool(actor_id)]
  end

  defp end_briefing_tool(actor_id) do
    %AgentTool{
      name: "end_briefing",
      description:
        "Acknowledge your intel briefing and proceed. Your intel fragment has been assigned — " <>
          "review it in your world state. Call this to advance past the briefing phase.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "End Briefing",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.end_communication(actor_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("acknowledged briefing for #{actor_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # -- Communication Phase --

  defp communication_tools(world, actor_id) do
    messages_sent = count_messages_sent(world, actor_id)
    adjacency = get(world, :adjacency, %{})
    neighbors = NetworkGraph.local_view(adjacency, actor_id)

    tools = []

    tools =
      if messages_sent < 2 and length(neighbors) > 0 do
        tools ++ [send_message_tool(actor_id, neighbors)]
      else
        tools
      end

    tools ++ [end_communication_tool(actor_id)]
  end

  defp send_message_tool(actor_id, neighbors) do
    neighbor_enum = Enum.map(neighbors, &%{"const" => &1})

    %AgentTool{
      name: "send_message",
      description:
        "Send a secure message to an adjacent node in your network. " <>
          "You may only contact your DIRECT neighbors — you do not know the full topology. " <>
          "Use messages to share intel, request relays, or discuss suspicions. " <>
          "You have #{2} messages per round. " <>
          "Adjacent nodes: #{Enum.join(neighbors, ", ")}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "recipient_id" => %{
            "type" => "string",
            "description" => "The agent ID of the recipient (must be adjacent to you)",
            "anyOf" => neighbor_enum
          },
          "content" => %{
            "type" => "string",
            "description" =>
              "Your message content. Can include intel sharing, suspicion, or requests."
          }
        },
        "required" => ["recipient_id", "content"],
        "additionalProperties" => false
      },
      label: "Send Message",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        recipient_id = Map.get(params, "recipient_id", Map.get(params, :recipient_id))
        content = Map.get(params, "content", Map.get(params, :content, ""))
        event = Events.send_message(actor_id, recipient_id, content)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("sent message to #{recipient_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp end_communication_tool(actor_id) do
    %AgentTool{
      name: "end_communication",
      description:
        "End your communication phase. Communication moves to next agent, then all proceed to analysis.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "End Communication",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.end_communication(actor_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("ending communication phase for #{actor_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # -- Analysis Phase --

  defp analysis_tools(_world, actor_id) do
    [submit_analysis_tool(actor_id)]
  end

  defp submit_analysis_tool(actor_id) do
    %AgentTool{
      name: "submit_analysis",
      description:
        "Submit your private analysis notes for this round. " <>
          "Record what intel you have, who you trust, and any suspicions about the mole. " <>
          "Your notes are PRIVATE — no other agent can read them. " <>
          "Be thorough: your analysis informs your operations strategy.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "notes" => %{
            "type" => "string",
            "description" =>
              "Your private analysis. Include: intel fragments you hold, " <>
                "messages received, trust assessments, mole suspicions."
          }
        },
        "required" => ["notes"],
        "additionalProperties" => false
      },
      label: "Submit Analysis",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        notes = Map.get(params, "notes", Map.get(params, :notes, ""))
        event = Events.submit_analysis(actor_id, notes)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("analysis submitted for #{actor_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # -- Operation Phase --

  defp operation_tools(world, actor_id) do
    adjacency = get(world, :adjacency, %{})
    neighbors = NetworkGraph.local_view(adjacency, actor_id)
    neighbor_enum = Enum.map(neighbors, &%{"const" => &1})

    tools = []

    tools =
      if length(neighbors) > 0 do
        tools ++ [propose_operation_tool(actor_id, neighbor_enum, neighbors)]
      else
        tools
      end

    tools ++ [end_operations_tool(actor_id)]
  end

  defp propose_operation_tool(actor_id, neighbor_enum, neighbors) do
    %AgentTool{
      name: "propose_operation",
      description:
        "Propose an operation targeting an adjacent node. Operations: " <>
          "'share_intel' (give a fragment to neighbor), " <>
          "'relay_message' (pass a message through you), " <>
          "'verify_agent' (request trust verification of neighbor), " <>
          "'report_suspicion' (flag a neighbor as potentially compromised). " <>
          "Adjacent nodes: #{Enum.join(neighbors, ", ")}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "operation_type" => %{
            "type" => "string",
            "enum" => ["share_intel", "relay_message", "verify_agent", "report_suspicion"],
            "description" => "Type of operation to perform"
          },
          "target_id" => %{
            "type" => "string",
            "description" => "The target agent ID (must be adjacent)",
            "anyOf" => neighbor_enum
          }
        },
        "required" => ["operation_type", "target_id"],
        "additionalProperties" => false
      },
      label: "Propose Operation",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        operation_type = Map.get(params, "operation_type", Map.get(params, :operation_type))
        target_id = Map.get(params, "target_id", Map.get(params, :target_id))
        event = Events.propose_operation(actor_id, operation_type, target_id)

        {:ok,
         %AgentToolResult{
           content: [
             AgentCore.text_content("proposed #{operation_type} on #{target_id}")
           ],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp end_operations_tool(actor_id) do
    %AgentTool{
      name: "end_operations",
      description:
        "End your operations phase. Once all agents finish, the mole takes their hidden action.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "End Operations",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.end_operations(actor_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("ending operations for #{actor_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # -- Mole Action Phase --

  defp mole_action_tools(world, actor_id) do
    adjacency = get(world, :adjacency, %{})
    neighbors = NetworkGraph.local_view(adjacency, actor_id)
    neighbor_enum = Enum.map(neighbors, &%{"const" => &1})
    players = get(world, :players, %{})
    mole = Map.get(players, actor_id, %{})
    fragments = get(mole, :intel_fragments, [])

    tools = [mole_action_tool(actor_id, neighbor_enum, neighbors, fragments)]
    tools
  end

  defp mole_action_tool(actor_id, neighbor_enum, neighbors, fragments) do
    can_leak = length(fragments) > 0

    leak_desc =
      if can_leak,
        do: "'leak_intel' (secretly leak a fragment to adversary)",
        else: "'leak_intel' (no fragments to leak — will pass)"

    %AgentTool{
      name: "mole_action",
      description:
        "Take your hidden mole action. This is NEVER visible to other agents. " <>
          "Actions: #{leak_desc}, " <>
          "'frame_agent' (plant suspicion on an innocent adjacent agent), " <>
          "'pass' (take no action this round). " <>
          "You win by leaking 5+ fragments OR surviving to the end undetected. " <>
          "Adjacent nodes: #{Enum.join(neighbors, ", ")}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "action_type" => %{
            "type" => "string",
            "enum" => ["leak_intel", "frame_agent", "pass"],
            "description" => "Your mole action this round"
          },
          "target_id" => %{
            "type" => "string",
            "description" =>
              "Target agent for frame_agent (must be adjacent, ignored for other actions)",
            "anyOf" => neighbor_enum
          }
        },
        "required" => ["action_type"],
        "additionalProperties" => false
      },
      label: "Mole Action",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        action_type = Map.get(params, "action_type", Map.get(params, :action_type))
        target_id = Map.get(params, "target_id", Map.get(params, :target_id))
        event = Events.mole_action(actor_id, action_type, target_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("mole action: #{action_type}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # -- Helpers --

  defp count_messages_sent(world, player_id) do
    round = get(world, :round, 1)
    messages_sent = get(world, :messages_sent_this_round, %{})
    Map.get(messages_sent, player_id, %{}) |> Map.get(round, 0)
  end

  defp get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get(_map, _key, default), do: default
end
