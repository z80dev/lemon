defmodule LemonSim.Examples.MurderMystery.ActionSpace do
  @moduledoc false

  @behaviour LemonSim.ActionSpace

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias LemonCore.MapHelpers
  alias LemonSim.Examples.MurderMystery.Events
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

      phase == "investigation" ->
        {:ok, Enum.map(investigation_tools(world, actor_id), &GameTools.add_thought_param/1)}

      phase == "interrogation" ->
        {:ok, Enum.map(interrogation_tools(world, actor_id), &GameTools.add_thought_param/1)}

      phase == "discussion" ->
        {:ok, Enum.map(discussion_tools(world, actor_id), &GameTools.add_thought_param/1)}

      phase == "killer_action" ->
        {:ok, Enum.map(killer_action_tools(world, actor_id), &GameTools.add_thought_param/1)}

      phase == "deduction_vote" ->
        {:ok, Enum.map(deduction_tools(world, actor_id), &GameTools.add_thought_param/1)}

      true ->
        {:ok, []}
    end
  end

  # ---------------------------------------------------------------------------
  # Investigation phase
  # ---------------------------------------------------------------------------

  defp investigation_tools(world, actor_id) do
    rooms = get(world, :rooms, %{})
    searched_this_round = get(world, :searched_this_round, MapSet.new())
    already_searched = MapSet.member?(searched_this_round, actor_id)

    if already_searched do
      []
    else
      all_rooms = Map.keys(rooms)
      [search_room_tool(actor_id, all_rooms)]
    end
  end

  defp search_room_tool(actor_id, available_rooms) do
    room_enum = Enum.map(available_rooms, &%{"const" => &1})

    %AgentTool{
      name: "search_room",
      description:
        "Search a room of the mansion for clues. You will find all clues currently present in that room. " <>
          "Available rooms: #{Enum.join(available_rooms, ", ")}.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "room_id" => %{
            "type" => "string",
            "description" => "The room to search",
            "anyOf" => room_enum
          }
        },
        "required" => ["room_id"],
        "additionalProperties" => false
      },
      label: "Search Room",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        room_id = Map.get(params, "room_id", Map.get(params, :room_id))
        event = Events.search_room(actor_id, room_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("searching room: #{room_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # ---------------------------------------------------------------------------
  # Interrogation phase
  # ---------------------------------------------------------------------------

  defp interrogation_tools(world, actor_id) do
    pending = get(world, :pending_question, nil)
    asked_this_round = get(world, :asked_this_round, MapSet.new())
    already_asked = MapSet.member?(asked_this_round, actor_id)

    pending_target =
      case pending do
        nil -> nil
        map -> Map.get(map, "target_id") || Map.get(map, :target_id)
      end

    cond do
      pending_target == actor_id ->
        [answer_question_tool(actor_id)]

      already_asked ->
        []

      true ->
        players = get(world, :players, %{})
        other_players = players |> Map.keys() |> Enum.reject(&(&1 == actor_id))

        if other_players == [] do
          []
        else
          [ask_player_tool(actor_id, other_players)]
        end
    end
  end

  defp ask_player_tool(actor_id, other_players) do
    player_enum = Enum.map(other_players, &%{"const" => &1})

    %AgentTool{
      name: "ask_player",
      description:
        "Ask another guest a question during the interrogation phase. " <>
          "They must answer before the round proceeds. " <>
          "Use this to probe alibis, challenge timelines, or gather information. " <>
          "Available targets: #{Enum.join(other_players, ", ")}.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "target_id" => %{
            "type" => "string",
            "description" => "The player to interrogate",
            "anyOf" => player_enum
          },
          "question" => %{
            "type" => "string",
            "description" => "Your question for the target guest"
          }
        },
        "required" => ["target_id", "question"],
        "additionalProperties" => false
      },
      label: "Ask Player",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        target_id = Map.get(params, "target_id", Map.get(params, :target_id))
        question = Map.get(params, "question", Map.get(params, :question, ""))
        event = Events.ask_player(actor_id, target_id, question)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("asked #{target_id}: #{question}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp answer_question_tool(actor_id) do
    %AgentTool{
      name: "answer_question",
      description:
        "Answer the question that was directed to you. " <>
          "You may answer truthfully or lie — but your alibi will be scrutinised. " <>
          "If you are the killer, protect your identity.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "answer" => %{
            "type" => "string",
            "description" => "Your answer to the question"
          }
        },
        "required" => ["answer"],
        "additionalProperties" => false
      },
      label: "Answer Question",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        answer = Map.get(params, "answer", Map.get(params, :answer, ""))
        event = Events.answer_question(actor_id, answer)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("answered: #{String.slice(answer, 0, 60)}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # ---------------------------------------------------------------------------
  # Discussion phase
  # ---------------------------------------------------------------------------

  defp discussion_tools(_world, actor_id) do
    [
      share_finding_tool(actor_id),
      make_theory_tool(actor_id),
      end_discussion_tool(actor_id)
    ]
  end

  defp share_finding_tool(actor_id) do
    %AgentTool{
      name: "share_finding",
      description:
        "Share a clue or finding with the group publicly. " <>
          "Use this to report what you found while searching rooms.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "finding" => %{
            "type" => "string",
            "description" => "The finding or clue detail you want to share"
          }
        },
        "required" => ["finding"],
        "additionalProperties" => false
      },
      label: "Share Finding",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        finding = Map.get(params, "finding", Map.get(params, :finding, ""))
        event = Events.share_finding(actor_id, finding)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("shared finding: #{String.slice(finding, 0, 60)}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp make_theory_tool(actor_id) do
    %AgentTool{
      name: "make_theory",
      description:
        "Propose a theory about the murder — who, with what, and where. " <>
          "This allows others to confirm or refute your reasoning.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "theory" => %{
            "type" => "string",
            "description" => "Your theory about the killer, weapon, and room"
          }
        },
        "required" => ["theory"],
        "additionalProperties" => false
      },
      label: "Make Theory",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        theory = Map.get(params, "theory", Map.get(params, :theory, ""))
        event = Events.make_theory(actor_id, theory)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("proposed theory: #{String.slice(theory, 0, 60)}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp end_discussion_tool(actor_id) do
    %AgentTool{
      name: "end_discussion",
      description: "End your turn in the discussion phase without sharing anything further.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "End Discussion",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.end_discussion(actor_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("ending discussion for #{actor_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # ---------------------------------------------------------------------------
  # Killer action phase
  # ---------------------------------------------------------------------------

  defp killer_action_tools(world, actor_id) do
    players = get(world, :players, %{})
    actor_player = Map.get(players, actor_id, %{})
    role = get(actor_player, :role, "investigator")

    if role == "killer" do
      rooms = get(world, :rooms, %{})
      room_ids = Map.keys(rooms)
      destroyed = get(world, :destroyed_evidence, [])

      destroyable =
        Enum.flat_map(rooms, fn {room_id, room_data} ->
          clues = get(room_data, :clues_present, [])

          clues
          |> Enum.reject(&(&1 in destroyed))
          |> Enum.map(fn cid -> {room_id, cid} end)
        end)

      base_tools = [
        plant_evidence_tool(actor_id, room_ids),
        do_nothing_tool(actor_id)
      ]

      if destroyable != [] do
        [destroy_clue_tool(actor_id, destroyable) | base_tools]
      else
        base_tools
      end
    else
      []
    end
  end

  defp plant_evidence_tool(actor_id, room_ids) do
    room_enum = Enum.map(room_ids, &%{"const" => &1})

    %AgentTool{
      name: "plant_evidence",
      description:
        "Plant a false clue in a room to misdirect investigators. " <>
          "The clue will appear to point to an innocent guest. " <>
          "Available rooms: #{Enum.join(room_ids, ", ")}.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "room_id" => %{
            "type" => "string",
            "description" => "The room in which to plant the false clue",
            "anyOf" => room_enum
          },
          "clue_type" => %{
            "type" => "string",
            "enum" => [
              "fingerprint",
              "footprint",
              "weapon_trace",
              "bloodstain",
              "thread",
              "hair_sample"
            ],
            "description" => "The type of false clue to plant"
          }
        },
        "required" => ["room_id", "clue_type"],
        "additionalProperties" => false
      },
      label: "Plant Evidence",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        room_id = Map.get(params, "room_id", Map.get(params, :room_id))
        clue_type = Map.get(params, "clue_type", Map.get(params, :clue_type, "fingerprint"))
        event = Events.plant_evidence(actor_id, room_id, clue_type)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("planted #{clue_type} evidence in #{room_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp destroy_clue_tool(actor_id, destroyable) do
    clue_enum = Enum.map(destroyable, fn {_room, cid} -> %{"const" => cid} end)

    room_enum =
      destroyable
      |> Enum.map(fn {room, _cid} -> %{"const" => room} end)
      |> Enum.uniq()

    %AgentTool{
      name: "destroy_clue",
      description:
        "Destroy an existing clue to prevent investigators from finding it. " <>
          "You must specify both the room and the clue ID.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "room_id" => %{
            "type" => "string",
            "description" => "The room where the clue is located",
            "anyOf" => room_enum
          },
          "clue_id" => %{
            "type" => "string",
            "description" => "The ID of the clue to destroy",
            "anyOf" => clue_enum
          }
        },
        "required" => ["room_id", "clue_id"],
        "additionalProperties" => false
      },
      label: "Destroy Clue",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        room_id = Map.get(params, "room_id", Map.get(params, :room_id))
        clue_id = Map.get(params, "clue_id", Map.get(params, :clue_id))
        event = Events.destroy_clue(actor_id, room_id, clue_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("destroyed clue #{clue_id} in #{room_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp do_nothing_tool(actor_id) do
    %AgentTool{
      name: "do_nothing",
      description:
        "Take no action this round. The investigation proceeds without killer interference.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "Do Nothing",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.killer_do_nothing(actor_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("#{actor_id} does nothing")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # ---------------------------------------------------------------------------
  # Deduction vote phase
  # ---------------------------------------------------------------------------

  defp deduction_tools(world, actor_id) do
    players = get(world, :players, %{})
    actor_player = Map.get(players, actor_id, %{})
    accusations_remaining = get(actor_player, :accusations_remaining, 0)
    other_players = players |> Map.keys() |> Enum.reject(&(&1 == actor_id))

    base_tools = [skip_accusation_tool(actor_id)]

    if accusations_remaining > 0 and other_players != [] do
      [make_accusation_tool(actor_id, other_players) | base_tools]
    else
      base_tools
    end
  end

  defp make_accusation_tool(actor_id, suspects) do
    suspect_enum = Enum.map(suspects, &%{"const" => &1})

    %AgentTool{
      name: "make_accusation",
      description:
        "Formally accuse a guest of the murder, specifying the weapon and room. " <>
          "A correct accusation (correct killer, weapon, AND room) wins for investigators. " <>
          "An incorrect accusation costs one of your remaining accusations. " <>
          "Suspects: #{Enum.join(suspects, ", ")}.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "accused_id" => %{
            "type" => "string",
            "description" => "The guest you are accusing",
            "anyOf" => suspect_enum
          },
          "weapon" => %{
            "type" => "string",
            "enum" => ["candlestick", "knife", "lead_pipe", "revolver", "rope", "wrench"],
            "description" => "The murder weapon"
          },
          "room_id" => %{
            "type" => "string",
            "enum" => ["library", "ballroom", "conservatory", "study", "kitchen", "cellar"],
            "description" => "The room where the murder was committed"
          }
        },
        "required" => ["accused_id", "weapon", "room_id"],
        "additionalProperties" => false
      },
      label: "Make Accusation",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        accused_id = Map.get(params, "accused_id", Map.get(params, :accused_id))
        weapon = Map.get(params, "weapon", Map.get(params, :weapon, ""))
        room_id = Map.get(params, "room_id", Map.get(params, :room_id, ""))
        event = Events.make_accusation(actor_id, accused_id, weapon, room_id)

        {:ok,
         %AgentToolResult{
           content: [
             AgentCore.text_content("accused #{accused_id} with #{weapon} in #{room_id}")
           ],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp skip_accusation_tool(actor_id) do
    %AgentTool{
      name: "skip_accusation",
      description:
        "Pass on making an accusation this round. Use this if you are not confident enough to accuse yet.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "Skip Accusation",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.skip_accusation(actor_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("#{actor_id} passes on accusation")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp get(map, key, default)
  defp get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get(_map, _key, default), do: default
end
