defmodule LemonSim.Examples.Legislature.ActionSpace do
  @moduledoc false

  @behaviour LemonSim.ActionSpace

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias LemonCore.MapHelpers
  alias LemonSim.Examples.Legislature.{Bills, Events}
  alias LemonSim.GameHelpers.Tools, as: GameTools

  @amendment_cost 20

  @impl true
  def tools(state, _opts) do
    world = state.world
    status = MapHelpers.get_key(world, :status)
    phase = MapHelpers.get_key(world, :phase)
    actor_id = MapHelpers.get_key(world, :active_actor_id)

    cond do
      status != "in_progress" ->
        {:ok, []}

      phase == "caucus" ->
        {:ok, Enum.map(caucus_tools(world, actor_id), &GameTools.add_thought_param/1)}

      phase == "floor_debate" ->
        {:ok, Enum.map(floor_debate_tools(world, actor_id), &GameTools.add_thought_param/1)}

      phase == "amendment" ->
        {:ok, Enum.map(amendment_tools(world, actor_id), &GameTools.add_thought_param/1)}

      phase == "amendment_vote" ->
        {:ok, Enum.map(amendment_vote_tools(world, actor_id), &GameTools.add_thought_param/1)}

      phase == "final_vote" ->
        {:ok, Enum.map(final_vote_tools(world, actor_id), &GameTools.add_thought_param/1)}

      true ->
        {:ok, []}
    end
  end

  # -- Caucus phase tools --

  defp caucus_tools(world, actor_id) do
    messages_sent = count_caucus_messages(world, actor_id)
    players = get(world, :players, %{})
    other_players = players |> Map.keys() |> Enum.reject(&(&1 == actor_id))

    tools = []

    tools =
      if messages_sent < 3 and length(other_players) > 0 do
        tools ++
          [
            send_message_tool(actor_id, other_players),
            propose_trade_tool(actor_id, other_players)
          ]
      else
        tools
      end

    tools ++ [end_caucus_tool(actor_id)]
  end

  defp send_message_tool(actor_id, other_players) do
    recipient_enum = Enum.map(other_players, &%{"const" => &1})

    %AgentTool{
      name: "send_message",
      description:
        "Send a private message to another legislator. You have 3 messages per session. " <>
          "Use this to discuss strategy, propose alliances, or coordinate votes. " <>
          "Available recipients: #{Enum.join(other_players, ", ")}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "recipient" => %{
            "type" => "string",
            "description" => "The player_id of the recipient",
            "anyOf" => recipient_enum
          },
          "message" => %{
            "type" => "string",
            "description" =>
              "Your private message. Can include proposals, warnings, or coalition building."
          }
        },
        "required" => ["recipient", "message"],
        "additionalProperties" => false
      },
      label: "Send Message",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        recipient = Map.get(params, "recipient", Map.get(params, :recipient))
        message = Map.get(params, "message", Map.get(params, :message, ""))
        event = Events.send_message(actor_id, recipient, message)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("sent message to #{recipient}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp propose_trade_tool(actor_id, other_players) do
    recipient_enum = Enum.map(other_players, &%{"const" => &1})
    bill_enum = Enum.map(Bills.bill_ids(), &%{"const" => &1})

    %AgentTool{
      name: "propose_trade",
      description:
        "Propose a logrolling deal: offer to vote YES on one bill in exchange for a YES vote on another. " <>
          "This consumes one of your 3 caucus messages. " <>
          "Available recipients: #{Enum.join(other_players, ", ")}. " <>
          "Bill IDs: #{Enum.join(Bills.bill_ids(), ", ")}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "recipient" => %{
            "type" => "string",
            "description" => "The player_id to send the trade proposal to",
            "anyOf" => recipient_enum
          },
          "bill_a" => %{
            "type" => "string",
            "description" => "Bill you promise to vote YES on",
            "anyOf" => bill_enum
          },
          "bill_b" => %{
            "type" => "string",
            "description" => "Bill you want recipient to vote YES on in exchange",
            "anyOf" => bill_enum
          }
        },
        "required" => ["recipient", "bill_a", "bill_b"],
        "additionalProperties" => false
      },
      label: "Propose Trade",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        recipient = Map.get(params, "recipient", Map.get(params, :recipient))
        bill_a = Map.get(params, "bill_a", Map.get(params, :bill_a))
        bill_b = Map.get(params, "bill_b", Map.get(params, :bill_b))
        event = Events.propose_trade(actor_id, recipient, bill_a, bill_b)

        {:ok,
         %AgentToolResult{
           content: [
             AgentCore.text_content(
               "proposed trade to #{recipient}: YES on #{bill_a} for YES on #{bill_b}"
             )
           ],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp end_caucus_tool(actor_id) do
    %AgentTool{
      name: "end_caucus",
      description:
        "End your caucus phase. You will move to floor debate once all legislators finish caucus.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "End Caucus",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.end_caucus(actor_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("ending caucus phase for #{actor_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # -- Floor debate phase tools --

  defp floor_debate_tools(world, actor_id) do
    bill_ids = Bills.bill_ids()
    floor_statements = get(world, :floor_statements, [])

    already_spoke =
      floor_statements
      |> Enum.any?(fn s ->
        Map.get(s, "player_id", Map.get(s, :player_id)) == actor_id
      end)

    tools = []

    tools =
      if not already_spoke do
        tools ++ [make_speech_tool(actor_id, bill_ids)]
      else
        tools
      end

    tools ++ [end_floor_debate_tool(actor_id)]
  end

  defp make_speech_tool(actor_id, bill_ids) do
    bill_enum = Enum.map(bill_ids, &%{"const" => &1})

    %AgentTool{
      name: "make_speech",
      description:
        "Make a public statement about a specific bill during floor debate. " <>
          "Each legislator may speak once per session. " <>
          "Use this to signal your position, persuade colleagues, or apply public pressure. " <>
          "Bill IDs: #{Enum.join(bill_ids, ", ")}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "bill_id" => %{
            "type" => "string",
            "description" => "The bill you are speaking about",
            "anyOf" => bill_enum
          },
          "speech" => %{
            "type" => "string",
            "description" =>
              "Your public speech. Will be visible to all legislators. Make it count."
          }
        },
        "required" => ["bill_id", "speech"],
        "additionalProperties" => false
      },
      label: "Make Speech",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        bill_id = Map.get(params, "bill_id", Map.get(params, :bill_id))
        speech = Map.get(params, "speech", Map.get(params, :speech, ""))
        event = Events.make_speech(actor_id, bill_id, speech)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("made speech about #{bill_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp end_floor_debate_tool(actor_id) do
    %AgentTool{
      name: "end_floor_debate",
      description:
        "End your floor debate phase. You will move to amendments once all legislators finish.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "End Floor Debate",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.end_floor_debate(actor_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("ending floor debate for #{actor_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # -- Amendment phase tools --

  defp amendment_tools(world, actor_id) do
    bill_ids = Bills.bill_ids()
    capital = get_player_capital(world, actor_id)

    tools = []

    tools =
      if capital >= @amendment_cost do
        tools ++ [propose_amendment_tool(actor_id, bill_ids)]
      else
        tools
      end

    tools =
      if capital > 0 do
        tools ++ [lobby_tool(actor_id, bill_ids, capital)]
      else
        tools
      end

    tools ++ [end_amendment_tool(actor_id)]
  end

  defp propose_amendment_tool(actor_id, bill_ids) do
    bill_enum = Enum.map(bill_ids, &%{"const" => &1})

    %AgentTool{
      name: "propose_amendment",
      description:
        "Propose an amendment to a bill. Costs #{@amendment_cost} political capital. " <>
          "Amendment will be voted on in the amendment_vote phase. " <>
          "If passed (+5 bonus points for you), the amendment text is added to the bill. " <>
          "Bill IDs: #{Enum.join(bill_ids, ", ")}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "bill_id" => %{
            "type" => "string",
            "description" => "The bill to amend",
            "anyOf" => bill_enum
          },
          "amendment_text" => %{
            "type" => "string",
            "description" =>
              "The text of your amendment. Should modify or add to the bill's provisions."
          }
        },
        "required" => ["bill_id", "amendment_text"],
        "additionalProperties" => false
      },
      label: "Propose Amendment",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        bill_id = Map.get(params, "bill_id", Map.get(params, :bill_id))
        amendment_text = Map.get(params, "amendment_text", Map.get(params, :amendment_text, ""))
        event = Events.propose_amendment(actor_id, bill_id, amendment_text)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("proposed amendment to #{bill_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp lobby_tool(actor_id, bill_ids, capital) do
    bill_enum = Enum.map(bill_ids, &%{"const" => &1})

    %AgentTool{
      name: "lobby",
      description:
        "Spend political capital to lobby for a bill. " <>
          "Lobbying adds pressure for the bill to pass (public record). " <>
          "You have #{capital} political capital remaining. " <>
          "Capital spent lobbying contributes to your final score (1:1 ratio). " <>
          "Bill IDs: #{Enum.join(bill_ids, ", ")}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "bill_id" => %{
            "type" => "string",
            "description" => "The bill to lobby for",
            "anyOf" => bill_enum
          },
          "capital_spent" => %{
            "type" => "integer",
            "description" =>
              "How much political capital to spend. Must be between 1 and #{capital}.",
            "minimum" => 1,
            "maximum" => capital
          }
        },
        "required" => ["bill_id", "capital_spent"],
        "additionalProperties" => false
      },
      label: "Lobby",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        bill_id = Map.get(params, "bill_id", Map.get(params, :bill_id))
        capital_spent = Map.get(params, "capital_spent", Map.get(params, :capital_spent, 0))
        event = Events.lobby(actor_id, bill_id, capital_spent)

        {:ok,
         %AgentToolResult{
           content: [
             AgentCore.text_content("lobbied for #{bill_id} with #{capital_spent} capital")
           ],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp end_amendment_tool(actor_id) do
    %AgentTool{
      name: "end_amendment",
      description:
        "End your amendment phase. You will move to amendment voting once all legislators finish.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "End Amendment Phase",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.end_amendment(actor_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("ending amendment phase for #{actor_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # -- Amendment vote phase tools --

  defp amendment_vote_tools(world, actor_id) do
    proposed = get(world, :proposed_amendments, [])

    pending_votes =
      Enum.filter(proposed, fn amendment ->
        votes = Map.get(amendment, :votes, %{})
        not Map.has_key?(votes, actor_id)
      end)

    tools =
      Enum.map(pending_votes, fn amendment ->
        amendment_id = Map.get(amendment, :id, "")
        bill_id = Map.get(amendment, :bill_id, "")
        proposer = Map.get(amendment, :proposer_id, "")
        text = Map.get(amendment, :amendment_text, "")

        cast_amendment_vote_tool(actor_id, amendment_id, bill_id, proposer, text)
      end)

    tools ++ [end_amendment_vote_tool(actor_id)]
  end

  defp cast_amendment_vote_tool(actor_id, amendment_id, bill_id, proposer, amendment_text) do
    %AgentTool{
      name: "cast_amendment_vote_#{amendment_id}",
      description:
        "Vote on amendment #{amendment_id} for bill #{bill_id}. " <>
          "Proposed by #{proposer}: \"#{String.slice(amendment_text, 0, 80)}#{if String.length(amendment_text) > 80, do: "...", else: ""}\"",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "vote" => %{
            "type" => "string",
            "enum" => ["yes", "no"],
            "description" => "Your vote on this amendment"
          }
        },
        "required" => ["vote"],
        "additionalProperties" => false
      },
      label: "Vote on Amendment",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        vote = Map.get(params, "vote", Map.get(params, :vote, "no"))
        event = Events.cast_amendment_vote(actor_id, amendment_id, vote, bill_id)

        {:ok,
         %AgentToolResult{
           content: [
             AgentCore.text_content("voted #{vote} on amendment #{amendment_id}")
           ],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp end_amendment_vote_tool(actor_id) do
    %AgentTool{
      name: "end_amendment_vote",
      description:
        "End your amendment voting. Vote YES or NO on all pending amendments before finishing.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "End Amendment Vote",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.end_amendment_vote(actor_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("ending amendment vote for #{actor_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # -- Final vote phase tools --

  defp final_vote_tools(world, actor_id) do
    votes_cast = get(world, :votes_cast, MapSet.new())

    already_voted =
      cond do
        is_struct(votes_cast, MapSet) -> MapSet.member?(votes_cast, actor_id)
        is_list(votes_cast) -> actor_id in votes_cast
        true -> false
      end

    if already_voted do
      []
    else
      [cast_votes_tool(actor_id)]
    end
  end

  defp cast_votes_tool(actor_id) do
    bill_ids = Bills.bill_ids()

    vote_properties =
      Enum.into(bill_ids, %{}, fn bill_id ->
        {bill_id,
         %{
           "type" => "string",
           "enum" => ["yes", "no"],
           "description" => "Your vote on the #{bill_id} bill"
         }}
      end)

    %AgentTool{
      name: "cast_votes",
      description:
        "Cast your simultaneous votes on all 5 bills. " <>
          "Vote YES or NO on each bill. " <>
          "Bills pass with majority support. " <>
          "Scoring: +10 for your #1 preference passing, +7 for #2, +5 for #3, +3 for #4, +1 for #5. " <>
          "Bills: #{Enum.join(bill_ids, ", ")}",
      parameters: %{
        "type" => "object",
        "properties" => vote_properties,
        "required" => bill_ids,
        "additionalProperties" => false
      },
      label: "Cast Final Votes",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        votes =
          Enum.into(bill_ids, %{}, fn bill_id ->
            vote = Map.get(params, bill_id, Map.get(params, String.to_atom(bill_id), "no"))
            {bill_id, vote}
          end)

        event = Events.cast_votes(actor_id, votes)

        {:ok,
         %AgentToolResult{
           content: [
             AgentCore.text_content(
               "cast votes: #{Enum.map_join(votes, ", ", fn {bill, v} -> "#{bill}=#{v}" end)}"
             )
           ],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # -- Helpers --

  defp count_caucus_messages(world, player_id) do
    session = get(world, :session, 1)
    sent_counts = get(world, :caucus_messages_sent, %{})
    Map.get(sent_counts, player_id, %{}) |> Map.get(session, 0)
  end

  defp get_player_capital(world, player_id) do
    players = get(world, :players, %{})
    player_data = Map.get(players, player_id, %{})
    Map.get(player_data, :political_capital, Map.get(player_data, "political_capital", 0))
  end

  defp get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get(_map, _key, default), do: default
end
