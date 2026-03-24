defmodule LemonSim.Examples.Courtroom.ActionSpace do
  @moduledoc false

  @behaviour LemonSim.ActionSpace

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias LemonCore.MapHelpers
  alias LemonSim.Examples.Courtroom.Events
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

      phase == "opening_statements" ->
        {:ok, Enum.map(opening_tools(actor_id), &GameTools.add_thought_param/1)}

      phase == "prosecution_case" ->
        {:ok, Enum.map(prosecution_case_tools(world, actor_id), &GameTools.add_thought_param/1)}

      phase == "cross_examination" ->
        {:ok, Enum.map(cross_examination_tools(world, actor_id), &GameTools.add_thought_param/1)}

      phase == "defense_case" ->
        {:ok, Enum.map(defense_case_tools(world, actor_id), &GameTools.add_thought_param/1)}

      phase == "defense_cross" ->
        {:ok, Enum.map(defense_cross_tools(world, actor_id), &GameTools.add_thought_param/1)}

      phase == "closing_arguments" ->
        {:ok, Enum.map(closing_tools(actor_id), &GameTools.add_thought_param/1)}

      phase == "deliberation" ->
        {:ok, Enum.map(deliberation_tools(world, actor_id), &GameTools.add_thought_param/1)}

      phase == "verdict" ->
        {:ok, Enum.map(verdict_tools(actor_id), &GameTools.add_thought_param/1)}

      true ->
        {:ok, []}
    end
  end

  # -- Opening / Closing Statement Tools --

  defp opening_tools(actor_id) do
    [make_statement_tool(actor_id, "opening statement")]
  end

  defp closing_tools(actor_id) do
    [make_statement_tool(actor_id, "closing argument")]
  end

  defp make_statement_tool(actor_id, statement_type) do
    %AgentTool{
      name: "make_statement",
      description:
        "Deliver your #{statement_type} to the court. " <>
          "Make your case clearly and persuasively — the jury is watching.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "statement" => %{
            "type" => "string",
            "description" => "Your #{statement_type} text. Be persuasive and specific."
          }
        },
        "required" => ["statement"],
        "additionalProperties" => false
      },
      label: "Make Statement",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        statement = Map.get(params, "statement", Map.get(params, :statement, ""))
        event = Events.make_statement(actor_id, statement)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("statement delivered to the court")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # -- Prosecution Case Tools --

  defp prosecution_case_tools(world, actor_id) do
    witness_ids = witness_player_ids(world)
    evidence_ids = available_evidence(world)

    [
      call_witness_tool(actor_id, witness_ids),
      ask_question_tool(actor_id, witness_ids ++ [actor_id]),
      present_evidence_tool(actor_id, evidence_ids),
      object_tool(actor_id)
    ]
  end

  defp defense_case_tools(world, actor_id) do
    witness_ids = witness_player_ids(world)
    evidence_ids = available_evidence(world)

    [
      call_witness_tool(actor_id, witness_ids),
      ask_question_tool(actor_id, witness_ids ++ [actor_id]),
      present_evidence_tool(actor_id, evidence_ids),
      object_tool(actor_id)
    ]
  end

  # -- Cross Examination Tools --

  defp cross_examination_tools(world, actor_id) do
    witness_ids = witness_player_ids(world)
    players = get(world, :players, %{})
    all_ids = Map.keys(players)

    [
      ask_question_tool(actor_id, all_ids),
      object_tool(actor_id),
      challenge_testimony_tool(actor_id, witness_ids)
    ]
  end

  defp defense_cross_tools(world, actor_id) do
    witness_ids = witness_player_ids(world)
    players = get(world, :players, %{})
    all_ids = Map.keys(players)

    [
      ask_question_tool(actor_id, all_ids),
      object_tool(actor_id),
      challenge_testimony_tool(actor_id, witness_ids)
    ]
  end

  # -- Call Witness Tool --

  defp call_witness_tool(actor_id, witness_ids) do
    witness_enum = Enum.map(witness_ids, &%{"const" => &1})

    %AgentTool{
      name: "call_witness",
      description:
        "Call a witness to the stand to testify. " <>
          "Available witnesses: #{Enum.join(witness_ids, ", ")}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "witness_id" => %{
            "type" => "string",
            "description" => "The player_id of the witness to call",
            "anyOf" => witness_enum
          }
        },
        "required" => ["witness_id"],
        "additionalProperties" => false
      },
      label: "Call Witness",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        witness_id = Map.get(params, "witness_id", Map.get(params, :witness_id))
        event = Events.call_witness(actor_id, witness_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("called #{witness_id} to the stand")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # -- Ask Question Tool --

  defp ask_question_tool(actor_id, target_ids) do
    target_enum = Enum.map(target_ids, &%{"const" => &1})

    %AgentTool{
      name: "ask_question",
      description:
        "Ask a question to a witness or the opposing counsel. " <>
          "Use strategic questioning to draw out favorable testimony or expose inconsistencies.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "target_id" => %{
            "type" => "string",
            "description" => "The player_id to question",
            "anyOf" => target_enum
          },
          "question" => %{
            "type" => "string",
            "description" => "The question to ask. Be specific and strategic."
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
           content: [AgentCore.text_content("questioned #{target_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # -- Present Evidence Tool --

  defp present_evidence_tool(actor_id, evidence_ids) do
    evidence_enum = Enum.map(evidence_ids, &%{"const" => &1})

    %AgentTool{
      name: "present_evidence",
      description:
        "Submit a piece of evidence to the court record. " <>
          "Evidence strengthens your case — present what supports your argument. " <>
          "Available: #{Enum.join(evidence_ids, ", ")}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "evidence_id" => %{
            "type" => "string",
            "description" => "The evidence item to present",
            "anyOf" => evidence_enum
          }
        },
        "required" => ["evidence_id"],
        "additionalProperties" => false
      },
      label: "Present Evidence",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        evidence_id = Map.get(params, "evidence_id", Map.get(params, :evidence_id))
        event = Events.present_evidence(actor_id, evidence_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("presented evidence: #{evidence_id}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # -- Object Tool --

  defp object_tool(actor_id) do
    %AgentTool{
      name: "object",
      description:
        "Raise an objection to the current line of questioning or evidence presentation. " <>
          "Objections sustained if well-reasoned (hearsay, relevance, leading question, etc.)",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "reason" => %{
            "type" => "string",
            "description" =>
              "Grounds for the objection (e.g. 'hearsay', 'leading question', 'relevance')"
          }
        },
        "required" => ["reason"],
        "additionalProperties" => false
      },
      label: "Object",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        reason = Map.get(params, "reason", Map.get(params, :reason, ""))
        event = Events.object(actor_id, reason)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("objection raised: #{reason}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # -- Challenge Testimony Tool --

  defp challenge_testimony_tool(actor_id, witness_ids) do
    witness_enum = Enum.map(witness_ids, &%{"const" => &1})

    %AgentTool{
      name: "challenge_testimony",
      description:
        "Challenge a witness's testimony by pointing out inconsistencies or contradictions. " <>
          "Effective challenges can undermine the opposing side's case.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "witness_id" => %{
            "type" => "string",
            "description" => "The witness whose testimony you are challenging",
            "anyOf" => witness_enum
          },
          "challenge" => %{
            "type" => "string",
            "description" => "The specific inconsistency or contradiction you are pointing out"
          }
        },
        "required" => ["witness_id", "challenge"],
        "additionalProperties" => false
      },
      label: "Challenge Testimony",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        witness_id = Map.get(params, "witness_id", Map.get(params, :witness_id))
        challenge = Map.get(params, "challenge", Map.get(params, :challenge, ""))
        event = Events.challenge_testimony(actor_id, witness_id, challenge)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("challenged #{witness_id}'s testimony")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # -- Deliberation Tools --

  defp deliberation_tools(_world, actor_id) do
    [
      jury_discuss_tool(actor_id),
      take_note_tool(actor_id)
    ]
  end

  defp jury_discuss_tool(actor_id) do
    %AgentTool{
      name: "jury_discuss",
      description:
        "Contribute to jury deliberations. Share your analysis of the evidence and testimony. " <>
          "Try to persuade your fellow jurors and reach a reasoned verdict.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "argument" => %{
            "type" => "string",
            "description" =>
              "Your deliberation argument. Reference specific evidence and testimony."
          }
        },
        "required" => ["argument"],
        "additionalProperties" => false
      },
      label: "Jury Discuss",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        argument = Map.get(params, "argument", Map.get(params, :argument, ""))
        event = Events.jury_discuss(actor_id, argument)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("contributed to deliberations")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp take_note_tool(actor_id) do
    %AgentTool{
      name: "take_note",
      description:
        "Record a private note during deliberations. " <>
          "Useful for tracking key evidence and arguments before voting.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "note" => %{
            "type" => "string",
            "description" => "Your private note about the case"
          }
        },
        "required" => ["note"],
        "additionalProperties" => false
      },
      label: "Take Note",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        note = Map.get(params, "note", Map.get(params, :note, ""))
        event = Events.take_note(actor_id, note)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("note recorded")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # -- Verdict Tools --

  defp verdict_tools(actor_id) do
    [cast_verdict_tool(actor_id)]
  end

  defp cast_verdict_tool(actor_id) do
    %AgentTool{
      name: "cast_verdict",
      description:
        "Cast your final verdict. Vote guilty if you believe the defendant committed the crime " <>
          "beyond reasonable doubt. Vote not_guilty otherwise.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "vote" => %{
            "type" => "string",
            "enum" => ["guilty", "not_guilty"],
            "description" => "Your verdict: 'guilty' or 'not_guilty'"
          }
        },
        "required" => ["vote"],
        "additionalProperties" => false
      },
      label: "Cast Verdict",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        vote = Map.get(params, "vote", Map.get(params, :vote, "not_guilty"))
        event = Events.cast_verdict(actor_id, vote)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("verdict cast: #{vote}")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  # -- Helpers --

  defp witness_player_ids(world) do
    players = get(world, :players, %{})

    players
    |> Enum.filter(fn {_id, info} -> get(info, :role) == "witness" end)
    |> Enum.map(fn {id, _} -> id end)
    |> Enum.sort()
  end

  defp available_evidence(world) do
    case_file = get(world, :case_file, %{})
    get(case_file, :evidence_list, [])
  end

  defp get(map, key, default \\ nil)

  defp get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get(_map, _key, default), do: default
end
