defmodule LemonSim.Examples.StartupIncubator.ActionSpace do
  @moduledoc false

  @behaviour LemonSim.ActionSpace

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias LemonCore.MapHelpers
  alias LemonSim.Examples.StartupIncubator.Events
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

      phase == "pitch" ->
        {:ok, Enum.map(pitch_tools(world, actor_id), &GameTools.add_thought_param/1)}

      phase == "due_diligence" ->
        {:ok, Enum.map(due_diligence_tools(world, actor_id), &GameTools.add_thought_param/1)}

      phase == "negotiation" ->
        {:ok, Enum.map(negotiation_tools(world, actor_id), &GameTools.add_thought_param/1)}

      phase == "operations" ->
        {:ok, Enum.map(operations_tools(world, actor_id), &GameTools.add_thought_param/1)}

      true ->
        {:ok, []}
    end
  end

  # ---------------------------------------------------------------------------
  # Pitch phase tools
  # ---------------------------------------------------------------------------

  defp pitch_tools(world, actor_id) do
    players = get(world, :players, %{})
    actor = Map.get(players, actor_id, %{})
    role = get(actor, :role, "founder")

    if role == "founder" do
      [make_pitch_tool(actor_id), end_phase_tool(actor_id, "pitch")]
    else
      [end_phase_tool(actor_id, "pitch")]
    end
  end

  defp make_pitch_tool(actor_id) do
    %AgentTool{
      name: "make_pitch",
      description:
        "Deliver your public pitch to all investors. You may exaggerate traction, " <>
          "highlight strengths, and downplay weaknesses. This is your chance to attract investment.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "pitch_text" => %{
            "type" => "string",
            "description" =>
              "Your pitch statement. Make it compelling. You can be creative with the numbers."
          }
        },
        "required" => ["pitch_text"],
        "additionalProperties" => false
      },
      label: "Make Pitch",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        pitch_text = Map.get(params, "pitch_text", Map.get(params, :pitch_text, ""))
        event = Events.make_pitch(actor_id, pitch_text)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("pitch delivered by #{actor_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # ---------------------------------------------------------------------------
  # Due diligence phase tools
  # ---------------------------------------------------------------------------

  defp due_diligence_tools(world, actor_id) do
    players = get(world, :players, %{})
    actor = Map.get(players, actor_id, %{})
    role = get(actor, :role, "founder")

    if role == "investor" do
      founders = player_ids_with_role(players, "founder")
      [ask_question_tool(actor_id, founders), end_phase_tool(actor_id, "due_diligence")]
    else
      # Founders answer questions in this phase
      investors = player_ids_with_role(players, "investor")
      [answer_question_tool(actor_id, investors), end_phase_tool(actor_id, "due_diligence")]
    end
  end

  defp ask_question_tool(actor_id, founders) do
    founder_enum = Enum.map(founders, &%{"const" => &1})

    %AgentTool{
      name: "ask_question",
      description:
        "Ask a founder a private due diligence question about their startup. " <>
          "Probe their metrics, team, and market claims. Available founders: #{Enum.join(founders, ", ")}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "founder_id" => %{
            "type" => "string",
            "description" => "The founder to question",
            "anyOf" => founder_enum
          },
          "question" => %{
            "type" => "string",
            "description" => "Your due diligence question"
          }
        },
        "required" => ["founder_id", "question"],
        "additionalProperties" => false
      },
      label: "Ask Question",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        founder_id = Map.get(params, "founder_id", Map.get(params, :founder_id))
        question = Map.get(params, "question", Map.get(params, :question, ""))
        event = Events.ask_question(actor_id, founder_id, question)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("question sent to #{founder_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp answer_question_tool(actor_id, investors) do
    investor_enum = Enum.map(investors, &%{"const" => &1})

    %AgentTool{
      name: "answer_question",
      description:
        "Answer a pending due diligence question from an investor. " <>
          "You may reveal true metrics or craft a misleading answer to protect your valuation. " <>
          "Available investors: #{Enum.join(investors, ", ")}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "investor_id" => %{
            "type" => "string",
            "description" => "The investor asking the question",
            "anyOf" => investor_enum
          },
          "answer" => %{
            "type" => "string",
            "description" => "Your answer. You choose how much truth to reveal."
          }
        },
        "required" => ["investor_id", "answer"],
        "additionalProperties" => false
      },
      label: "Answer Question",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        investor_id = Map.get(params, "investor_id", Map.get(params, :investor_id))
        answer = Map.get(params, "answer", Map.get(params, :answer, ""))
        event = Events.answer_question(actor_id, investor_id, answer)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("answered #{investor_id}'s question")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # ---------------------------------------------------------------------------
  # Negotiation phase tools
  # ---------------------------------------------------------------------------

  defp negotiation_tools(world, actor_id) do
    players = get(world, :players, %{})
    actor = Map.get(players, actor_id, %{})
    role = get(actor, :role, "founder")

    if role == "investor" do
      founders = player_ids_with_role(players, "founder")
      [make_offer_tool(actor_id, founders), end_phase_tool(actor_id, "negotiation")]
    else
      # Founders: counter, accept, reject, merge
      investors = player_ids_with_role(players, "investor")

      other_founders =
        players |> player_ids_with_role("founder") |> Enum.reject(&(&1 == actor_id))

      active_offers = get_active_offers_for(world, actor_id, investors)

      tools =
        if length(active_offers) > 0 do
          [
            counter_offer_tool(actor_id, active_offers),
            accept_deal_tool(actor_id, active_offers),
            reject_deal_tool(actor_id, active_offers)
          ]
        else
          []
        end

      tools =
        if length(other_founders) > 0 do
          tools ++ [merge_startups_tool(actor_id, other_founders)]
        else
          tools
        end

      tools ++ [end_phase_tool(actor_id, "negotiation")]
    end
  end

  defp make_offer_tool(actor_id, founders) do
    founder_enum = Enum.map(founders, &%{"const" => &1})

    %AgentTool{
      name: "make_offer",
      description:
        "Make a term sheet offer to a founder — specify amount in USD and equity percentage. " <>
          "Available founders: #{Enum.join(founders, ", ")}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "founder_id" => %{
            "type" => "string",
            "description" => "The founder to make an offer to",
            "anyOf" => founder_enum
          },
          "amount" => %{
            "type" => "integer",
            "description" => "Investment amount in USD (e.g. 500000)"
          },
          "equity_pct" => %{
            "type" => "number",
            "description" => "Equity percentage requested (e.g. 15.0 for 15%)"
          }
        },
        "required" => ["founder_id", "amount", "equity_pct"],
        "additionalProperties" => false
      },
      label: "Make Offer",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        founder_id = Map.get(params, "founder_id", Map.get(params, :founder_id))
        amount = Map.get(params, "amount", Map.get(params, :amount, 0))
        equity_pct = Map.get(params, "equity_pct", Map.get(params, :equity_pct, 0.0))
        event = Events.make_offer(actor_id, founder_id, amount, equity_pct)

        {:ok,
         %AgentToolResult{
           content: [
             AgentCore.text_content("offer sent to #{founder_id}: $#{amount} for #{equity_pct}%")
           ],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp counter_offer_tool(actor_id, active_offers) do
    investor_enum = Enum.map(active_offers, &%{"const" => &1})

    %AgentTool{
      name: "counter_offer",
      description:
        "Counter an investor's offer with different terms. " <>
          "Investors with active offers: #{Enum.join(active_offers, ", ")}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "investor_id" => %{
            "type" => "string",
            "description" => "The investor whose offer you are countering",
            "anyOf" => investor_enum
          },
          "amount" => %{
            "type" => "integer",
            "description" => "Counter amount in USD"
          },
          "equity_pct" => %{
            "type" => "number",
            "description" => "Counter equity percentage"
          }
        },
        "required" => ["investor_id", "amount", "equity_pct"],
        "additionalProperties" => false
      },
      label: "Counter Offer",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        investor_id = Map.get(params, "investor_id", Map.get(params, :investor_id))
        amount = Map.get(params, "amount", Map.get(params, :amount, 0))
        equity_pct = Map.get(params, "equity_pct", Map.get(params, :equity_pct, 0.0))
        event = Events.counter_offer(actor_id, investor_id, amount, equity_pct)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("counter offer sent to #{investor_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp accept_deal_tool(actor_id, active_offers) do
    investor_enum = Enum.map(active_offers, &%{"const" => &1})

    %AgentTool{
      name: "accept_deal",
      description:
        "Accept an investor's current offer and close the deal. " <>
          "Investors with active offers: #{Enum.join(active_offers, ", ")}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "investor_id" => %{
            "type" => "string",
            "description" => "The investor whose offer you are accepting",
            "anyOf" => investor_enum
          }
        },
        "required" => ["investor_id"],
        "additionalProperties" => false
      },
      label: "Accept Deal",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        investor_id = Map.get(params, "investor_id", Map.get(params, :investor_id))
        event = Events.accept_deal(actor_id, investor_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("accepted deal from #{investor_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp reject_deal_tool(actor_id, active_offers) do
    investor_enum = Enum.map(active_offers, &%{"const" => &1})

    %AgentTool{
      name: "reject_deal",
      description:
        "Reject an investor's current offer. " <>
          "Investors with active offers: #{Enum.join(active_offers, ", ")}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "investor_id" => %{
            "type" => "string",
            "description" => "The investor whose offer you are rejecting",
            "anyOf" => investor_enum
          }
        },
        "required" => ["investor_id"],
        "additionalProperties" => false
      },
      label: "Reject Deal",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        investor_id = Map.get(params, "investor_id", Map.get(params, :investor_id))
        event = Events.reject_deal(actor_id, investor_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("rejected deal from #{investor_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp merge_startups_tool(actor_id, other_founders) do
    founder_enum = Enum.map(other_founders, &%{"const" => &1})

    %AgentTool{
      name: "merge_startups",
      description:
        "Propose to merge your startup with another founder's startup. " <>
          "Merging combines traction and employees but you keep your sector. " <>
          "Available founders: #{Enum.join(other_founders, ", ")}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "founder_b_id" => %{
            "type" => "string",
            "description" => "The founder to merge with",
            "anyOf" => founder_enum
          }
        },
        "required" => ["founder_b_id"],
        "additionalProperties" => false
      },
      label: "Merge Startups",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        founder_b_id = Map.get(params, "founder_b_id", Map.get(params, :founder_b_id))
        event = Events.merge_startups(actor_id, founder_b_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("merge proposed with #{founder_b_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # ---------------------------------------------------------------------------
  # Operations phase tools
  # ---------------------------------------------------------------------------

  defp operations_tools(world, actor_id) do
    players = get(world, :players, %{})
    actor = Map.get(players, actor_id, %{})
    role = get(actor, :role, "founder")

    if role == "founder" do
      [allocate_funds_tool(actor_id, world), end_phase_tool(actor_id, "operations")]
    else
      [end_phase_tool(actor_id, "operations")]
    end
  end

  defp allocate_funds_tool(actor_id, world) do
    startups = get(world, :startups, %{})
    startup = Map.get(startups, actor_id, %{})
    cash = Map.get(startup, :cash_on_hand, Map.get(startup, "cash_on_hand", 0))

    %AgentTool{
      name: "allocate_funds",
      description:
        "Allocate cash from your startup's treasury. " <>
          "Modes: 'growth' (boosts traction via marketing), " <>
          "'hiring' (increases headcount), " <>
          "'pivot' (change sector, costs traction), " <>
          "'reserve' (hold cash). " <>
          "Your current cash on hand: $#{cash}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "allocation_type" => %{
            "type" => "string",
            "enum" => ["growth", "hiring", "pivot", "reserve"],
            "description" => "How to allocate funds"
          },
          "amount" => %{
            "type" => "integer",
            "description" => "Amount in USD to allocate (must not exceed cash on hand)"
          }
        },
        "required" => ["allocation_type", "amount"],
        "additionalProperties" => false
      },
      label: "Allocate Funds",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        allocation_type =
          Map.get(params, "allocation_type", Map.get(params, :allocation_type, "reserve"))

        amount = Map.get(params, "amount", Map.get(params, :amount, 0))
        event = Events.allocate_funds(actor_id, allocation_type, amount)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("allocated $#{amount} to #{allocation_type}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # ---------------------------------------------------------------------------
  # Shared tools
  # ---------------------------------------------------------------------------

  defp end_phase_tool(actor_id, phase) do
    %AgentTool{
      name: "end_phase",
      description: "Signal that you are done with the #{phase} phase.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "End Phase",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.end_phase(actor_id, phase)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("#{actor_id} ending #{phase} phase")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp get_active_offers_for(world, founder_id, investors) do
    term_sheets = get(world, :term_sheets, %{})

    Enum.filter(investors, fn inv_id ->
      sheet_key = "#{inv_id}->#{founder_id}"

      case Map.get(term_sheets, sheet_key) do
        nil -> false
        sheet -> Map.get(sheet, "status") in ["pending", "countered"]
      end
    end)
  end

  defp player_ids_with_role(players, role) do
    players
    |> Enum.filter(fn {_id, p} -> get(p, :role, "founder") == role end)
    |> Enum.map(fn {id, _p} -> id end)
  end

  defp get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get(_map, _key, default), do: default
end
