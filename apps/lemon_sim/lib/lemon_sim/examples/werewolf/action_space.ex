defmodule LemonSim.Examples.Werewolf.ActionSpace do
  @moduledoc false

  @behaviour LemonSim.ActionSpace

  import LemonSim.GameHelpers

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias LemonSim.Event
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

      # Last words phases allow dead players to speak
      if phase in ["last_words_vote", "last_words_night"] do
        {:ok, Enum.map([last_words_tool(actor_id)], &add_thought_param/1)}
      else
        if is_nil(actor) or get(actor, :status) != "alive" do
          {:ok, []}
        else
          role = get(actor, :role, "villager")
          runoff_candidates = get(world, :runoff_candidates)
          base_tools = tools_for_phase_and_role(phase, role, actor_id, players, runoff_candidates)

          # Add item tools based on player's inventory
          player_items = get(world, :player_items, %{})
          actor_items = Map.get(player_items, actor_id, [])
          item_tools = build_item_tools(actor_id, actor_items, phase)

          {:ok, Enum.map(base_tools ++ item_tools, &add_thought_param/1)}
        end
      end
    end
  end

  # Wolf discussion phase
  defp tools_for_phase_and_role("wolf_discussion", "werewolf", actor_id, players, _runoff) do
    living_non_wolves =
      players
      |> Roles.living_players()
      |> Enum.reject(fn {_id, p} -> get(p, :role) == "werewolf" end)
      |> Enum.map(fn {id, _p} -> id end)

    [wolf_chat_tool(actor_id, living_non_wolves, players)]
  end

  defp tools_for_phase_and_role("wolf_discussion", _role, actor_id, _players, _runoff) do
    [sleep_tool(actor_id)]
  end

  # Night phase
  defp tools_for_phase_and_role("night", "werewolf", actor_id, players, _runoff) do
    living_non_wolves =
      players
      |> Roles.living_players()
      |> Enum.reject(fn {_id, p} -> get(p, :role) == "werewolf" end)
      |> Enum.map(fn {id, _p} -> id end)

    [choose_victim_tool(actor_id, living_non_wolves, players)]
  end

  defp tools_for_phase_and_role("night", "seer", actor_id, players, _runoff) do
    living_others =
      players
      |> Roles.living_players()
      |> Enum.reject(fn {id, _p} -> id == actor_id end)
      |> Enum.map(fn {id, _p} -> id end)

    [investigate_player_tool(actor_id, living_others, players)]
  end

  defp tools_for_phase_and_role("night", "doctor", actor_id, players, _runoff) do
    living =
      players
      |> Roles.living_players()
      |> Enum.map(fn {id, _p} -> id end)

    [protect_player_tool(actor_id, living, players)]
  end

  defp tools_for_phase_and_role("night", _villager, actor_id, _players, _runoff) do
    [sleep_tool(actor_id), wander_tool(actor_id)]
  end

  # Meeting selection
  defp tools_for_phase_and_role("meeting_selection", _role, actor_id, players, _runoff) do
    living_others =
      players
      |> Roles.living_players()
      |> Enum.reject(fn {id, _p} -> id == actor_id end)
      |> Enum.map(fn {id, _p} -> id end)

    [meeting_request_tool(actor_id, living_others)]
  end

  # Private meeting
  defp tools_for_phase_and_role("private_meeting", _role, actor_id, _players, _runoff) do
    [meeting_message_tool(actor_id)]
  end

  # Day discussion (with accusation tool)
  defp tools_for_phase_and_role("day_discussion", _role, actor_id, players, _runoff) do
    living_others =
      players
      |> Roles.living_players()
      |> Enum.reject(fn {id, _p} -> id == actor_id end)
      |> Enum.map(fn {id, _p} -> id end)

    [
      LemonSim.GameHelpers.Tools.statement_tool(actor_id,
        description:
          "Make a public statement during the day discussion. All players will see what you say. " <>
            "You may accuse others, defend yourself, share information, bluff, or stay vague. " <>
            "Be strategic based on your role."
      ),
      accusation_tool(actor_id, living_others)
    ]
  end

  # Runoff discussion (with accusation tool)
  defp tools_for_phase_and_role("runoff_discussion", _role, actor_id, players, _runoff) do
    living_others =
      players
      |> Roles.living_players()
      |> Enum.reject(fn {id, _p} -> id == actor_id end)
      |> Enum.map(fn {id, _p} -> id end)

    [
      LemonSim.GameHelpers.Tools.statement_tool(actor_id,
        description:
          "Make a public statement during the runoff discussion. The top vote-getters are defending themselves. " <>
            "All players will see what you say."
      ),
      accusation_tool(actor_id, living_others)
    ]
  end

  # Day voting
  defp tools_for_phase_and_role("day_voting", _role, actor_id, players, _runoff) do
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

  # Runoff voting (only runoff candidates as targets)
  defp tools_for_phase_and_role("runoff_voting", _role, actor_id, _players, runoff_candidates) do
    targets = (runoff_candidates || []) |> Enum.reject(&(&1 == actor_id))

    [
      LemonSim.GameHelpers.Tools.vote_tool(actor_id, targets,
        description:
          "RUNOFF VOTE: Choose between the final candidates. Valid targets: #{Enum.join(targets, ", ")}, or \"skip\" to abstain."
      )
    ]
  end

  defp tools_for_phase_and_role(_phase, _role, _actor_id, _players, _runoff) do
    []
  end

  # -- Item tools based on inventory --

  defp build_item_tools(actor_id, items, phase) do
    items
    |> Enum.flat_map(fn item ->
      item_type = Map.get(item, :type) || Map.get(item, "type")

      case {item_type, phase} do
        {"anonymous_letter", p} when p in ["day_discussion", "runoff_discussion"] ->
          [anonymous_letter_tool(actor_id)]

        {"lock", "night"} ->
          [lock_tool(actor_id)]

        {"lantern", "night"} ->
          [lantern_tool(actor_id)]

        _ ->
          []
      end
    end)
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
           content: [AgentCore.text_content("You chose to target #{victim_id} tonight.")],
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
           content: [AgentCore.text_content("You are investigating #{target_id}.")],
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
           content: [AgentCore.text_content("You chose to protect #{target_id} tonight.")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp sleep_tool(actor_id) do
    %AgentTool{
      name: "sleep",
      description: "Sleep through the night safely at home. You won't learn anything but you're safe.",
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

  defp wander_tool(actor_id) do
    %AgentTool{
      name: "night_wander",
      description:
        "Instead of sleeping, wander the village at night. " <>
          "You might witness something suspicious near another player's house — " <>
          "or you might see nothing at all. Risky but could provide valuable information.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "Wander",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.night_wander(actor_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("You slip out into the dark village streets...")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp last_words_tool(actor_id) do
    %AgentTool{
      name: "make_last_words",
      description:
        "You have been eliminated. Speak your final words to the village. " <>
          "You may reveal information, make accusations, give advice, or say goodbye. " <>
          "This is your last chance to influence the game.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "statement" => %{
            "type" => "string",
            "description" =>
              "Your final words. Make them count — you won't speak again. (1-3 sentences)"
          }
        },
        "required" => ["statement"],
        "additionalProperties" => false
      },
      label: "Last Words",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        statement = Map.get(params, "statement", Map.get(params, :statement, ""))
        event = Events.make_last_words(actor_id, statement)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("Your last words: \"#{statement}\"")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp wolf_chat_tool(actor_id, potential_victims, _players) do
    victims_desc = Enum.join(potential_victims, ", ")

    %AgentTool{
      name: "wolf_chat",
      description:
        "Discuss strategy with your wolf pack before the hunt. " <>
          "Coordinate who to target tonight. Potential victims: #{victims_desc}. " <>
          "Only other werewolves can see this message.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "message" => %{
            "type" => "string",
            "description" =>
              "Your message to the wolf pack. Discuss who to target and why. (1-3 sentences)"
          }
        },
        "required" => ["message"],
        "additionalProperties" => false
      },
      label: "Wolf Chat",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        message = Map.get(params, "message", Map.get(params, :message, ""))
        event = Events.wolf_chat(actor_id, message)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("You told the pack: \"#{message}\"")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp accusation_tool(actor_id, valid_targets) do
    targets_desc = Enum.join(valid_targets, ", ")

    %AgentTool{
      name: "make_accusation",
      description:
        "Formally accuse another player of being a werewolf. " <>
          "This is a dramatic public accusation — the accused will be forced to respond immediately. " <>
          "Valid targets: #{targets_desc}. Use this when you have strong suspicion.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "target_id" => %{
            "type" => "string",
            "description" => "The player to accuse. Must be one of: #{targets_desc}",
            "enum" => valid_targets
          },
          "reason" => %{
            "type" => "string",
            "description" =>
              "Your reason for the accusation. Be specific about suspicious behavior. (1-2 sentences)"
          }
        },
        "required" => ["target_id", "reason"],
        "additionalProperties" => false
      },
      label: "Accuse",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        target_id = Map.get(params, "target_id", Map.get(params, :target_id))
        reason = Map.get(params, "reason", Map.get(params, :reason, ""))
        event = Events.make_accusation(actor_id, target_id, reason)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("You formally accused #{target_id}: \"#{reason}\"")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp meeting_request_tool(actor_id, valid_targets) do
    targets_desc = Enum.join(valid_targets, ", ")

    %AgentTool{
      name: "request_meeting",
      description:
        "Choose a player for a private 1-on-1 meeting before today's discussion. " <>
          "You'll exchange brief messages that only the two of you can hear. " <>
          "Valid targets: #{targets_desc}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "target_id" => %{
            "type" => "string",
            "description" => "The player you want to meet with. Must be one of: #{targets_desc}",
            "enum" => valid_targets
          }
        },
        "required" => ["target_id"],
        "additionalProperties" => false
      },
      label: "Request Meeting",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        target_id = Map.get(params, "target_id", Map.get(params, :target_id))
        event = Events.request_meeting(actor_id, target_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("You requested a private meeting with #{target_id}.")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp meeting_message_tool(actor_id) do
    %AgentTool{
      name: "meeting_message",
      description:
        "Send a message during your private meeting. Only your meeting partner " <>
          "and spectators can see this. Be strategic — share information, probe for reactions, " <>
          "build alliances, or test loyalty.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "message" => %{
            "type" => "string",
            "description" => "Your private message to your meeting partner. (1-3 sentences)"
          }
        },
        "required" => ["message"],
        "additionalProperties" => false
      },
      label: "Meeting Message",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        message = Map.get(params, "message", Map.get(params, :message, ""))
        event = Events.meeting_message(actor_id, message)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("You said in the meeting: \"#{message}\"")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp anonymous_letter_tool(_actor_id) do
    %AgentTool{
      name: "send_anonymous_letter",
      description:
        "Send an anonymous message that all players will see, but no one will know who sent it. " <>
          "This consumes your anonymous letter item.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "message" => %{
            "type" => "string",
            "description" => "Your anonymous message to the village. (1-3 sentences)"
          }
        },
        "required" => ["message"],
        "additionalProperties" => false
      },
      label: "Anonymous Letter",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        message = Map.get(params, "message", Map.get(params, :message, ""))
        event = Events.anonymous_message(message)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("Your anonymous letter has been posted.")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp lock_tool(actor_id) do
    %AgentTool{
      name: "use_lock",
      description:
        "Use your lock to secure your door tonight. You will be protected from werewolf attacks. " <>
          "This consumes the lock item.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "Use Lock",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Event.new("use_item", %{"player_id" => actor_id, "item_type" => "lock"})

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("You secured your door with the lock.")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp lantern_tool(actor_id) do
    %AgentTool{
      name: "use_lantern",
      description:
        "Use your lantern to illuminate the village tonight. You will definitely see any suspicious " <>
          "activity near the victim's house. This consumes the lantern.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "Use Lantern",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Event.new("use_item", %{"player_id" => actor_id, "item_type" => "lantern"})

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("You light the lantern and peer into the darkness...")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # -- Thought param wrapper --

  defp add_thought_param(tool) do
    props = Map.get(tool.parameters, "properties", %{})

    new_props =
      Map.put(props, "thought", %{
        "type" => "string",
        "description" =>
          "Optional: record a private internal thought about what's happening. " <>
            "Note suspicions, plans, observations. Only you (and spectators) can see this."
      })

    original_execute = tool.execute

    wrapped_execute = fn tool_call_id, params, signal, on_update ->
      case original_execute.(tool_call_id, params, signal, on_update) do
        {:ok, result} ->
          thought = Map.get(params, "thought", Map.get(params, :thought))

          if is_binary(thought) and thought != "" do
            event = Map.get(result.details, "event")

            if event do
              updated_payload = Map.put(event.payload, "thought", thought)
              updated_event = %{event | payload: updated_payload}
              {:ok, %{result | details: Map.put(result.details, "event", updated_event)}}
            else
              {:ok, result}
            end
          else
            {:ok, result}
          end

        other ->
          other
      end
    end

    %{tool | parameters: Map.put(tool.parameters, "properties", new_props), execute: wrapped_execute}
  end
end
