defmodule LemonSim.Examples.Survivor.ActionSpace do
  @moduledoc false

  @behaviour LemonSim.ActionSpace

  import LemonSim.GameHelpers

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias LemonSim.GameHelpers.Tools, as: GameTools
  alias LemonSim.Examples.Survivor.{Events, Tribes}

  @impl true
  def tools(state, _opts) do
    world = state.world
    status = get(world, :status, "in_progress")

    if status != "in_progress" do
      {:ok, []}
    else
      phase = get(world, :phase, "challenge")
      actor_id = get(world, :active_actor_id, nil)
      players = get(world, :players, %{})
      actor = Map.get(players, actor_id)

      if is_nil(actor) do
        {:ok, []}
      else
        actor_status = get(actor, :status)

        cond do
          # Jury members act during final tribal council
          phase == "final_tribal_council" and actor_status == "eliminated" and
              get(actor, :jury_member) ->
            sub_phase = get(world, :ftc_sub_phase, "jury_statements")

            {:ok,
             Enum.map(tools_for_ftc(sub_phase, actor_id, players), &GameTools.add_thought_param/1)}

          # Finalists plead during final tribal council
          phase == "final_tribal_council" and actor_status == "alive" ->
            sub_phase = get(world, :ftc_sub_phase, "jury_statements")

            {:ok,
             Enum.map(tools_for_ftc(sub_phase, actor_id, players), &GameTools.add_thought_param/1)}

          # Normal phases require alive status
          actor_status != "alive" ->
            {:ok, []}

          true ->
            {:ok,
             Enum.map(
               tools_for_phase(phase, actor_id, players, world),
               &GameTools.add_thought_param/1
             )}
        end
      end
    end
  end

  # -- Phase-specific tool generation --

  defp tools_for_phase("challenge", actor_id, _players, _world) do
    [choose_strategy_tool(actor_id)]
  end

  defp tools_for_phase("strategy", actor_id, players, _world) do
    living_others =
      players
      |> Tribes.living_players()
      |> Enum.reject(fn {id, _p} -> id == actor_id end)
      |> Enum.map(fn {id, _p} -> id end)

    [
      GameTools.statement_tool(actor_id,
        description:
          "Make a public strategic statement. All players in your group will see this. " <>
            "Use it to build trust, form alliances, or cast suspicion on others."
      ),
      GameTools.whisper_tool(actor_id, living_others,
        description:
          "Send a private whisper to another player. Only they will see the message content, " <>
            "but ALL players can see THAT you whispered to someone (visible social graph). " <>
            "Valid targets: #{Enum.join(living_others, ", ")}"
      )
    ]
  end

  defp tools_for_phase("tribal_council", actor_id, players, world) do
    actor = Map.get(players, actor_id, %{})
    has_idol = get(actor, :has_idol, false)
    idol_phase_done = get(world, :idol_phase_done, false)

    tc_voters = get(world, :tc_voters, [])
    immune_player = get(world, :immune_player, nil)

    if not idol_phase_done do
      # Idol decision phase
      if has_idol do
        [play_idol_tool(actor_id), skip_idol_tool(actor_id)]
      else
        [skip_idol_tool(actor_id)]
      end
    else
      # Voting phase
      valid_targets =
        tc_voters
        |> Enum.reject(fn id -> id == actor_id end)
        |> Enum.reject(fn id -> id == immune_player end)
        |> Enum.reject(fn id -> id == get(world, :idol_played_by) end)

      [
        GameTools.vote_tool(actor_id, valid_targets,
          include_skip: false,
          description:
            "Vote to eliminate a player from the game. Valid targets: #{Enum.join(valid_targets, ", ")}"
        )
      ]
    end
  end

  defp tools_for_phase(_phase, _actor_id, _players, _world) do
    []
  end

  # -- Final tribal council tools --

  defp tools_for_ftc("jury_statements", actor_id, _players) do
    [jury_statement_tool(actor_id)]
  end

  defp tools_for_ftc("finalist_pleas", actor_id, _players) do
    [make_final_plea_tool(actor_id)]
  end

  defp tools_for_ftc("jury_voting", actor_id, players) do
    finalists =
      players
      |> Tribes.living_players()
      |> Enum.map(fn {id, _p} -> id end)

    [jury_vote_tool(actor_id, finalists)]
  end

  defp tools_for_ftc(_sub_phase, _actor_id, _players) do
    []
  end

  # -- Game-specific tool builders --

  defp choose_strategy_tool(actor_id) do
    strategies = ["physical", "puzzle", "endurance"]
    desc = Enum.join(strategies, ", ")

    %AgentTool{
      name: "choose_strategy",
      description:
        "Choose your challenge strategy. Each strategy beats one and loses to another " <>
          "(physical beats endurance, endurance beats puzzle, puzzle beats physical). " <>
          "Valid strategies: #{desc}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "strategy" => %{
            "type" => "string",
            "description" => "Your challenge strategy. Must be one of: #{desc}",
            "enum" => strategies
          }
        },
        "required" => ["strategy"],
        "additionalProperties" => false
      },
      label: "Choose Strategy",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        strategy = Map.get(params, "strategy", Map.get(params, :strategy))
        event = Events.challenge_choice(actor_id, strategy)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("You chose the #{strategy} strategy.")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp play_idol_tool(actor_id) do
    %AgentTool{
      name: "play_idol",
      description:
        "Play your Hidden Immunity Idol BEFORE votes are read. " <>
          "All votes cast against you will be negated. The idol is consumed after use.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "Play Idol",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.play_idol(actor_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("You played your Hidden Immunity Idol!")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp skip_idol_tool(actor_id) do
    %AgentTool{
      name: "skip_idol",
      description: "Choose NOT to play an idol (or you don't have one). Proceed to voting.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: "Skip Idol",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.skip_idol(actor_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("You chose not to play an idol.")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp jury_statement_tool(actor_id) do
    %AgentTool{
      name: "jury_statement",
      description:
        "As a jury member, make a statement or question to the finalists. " <>
          "This is your chance to influence the outcome and hold finalists accountable.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "statement" => %{
            "type" => "string",
            "description" =>
              "Your statement or question to the finalists. Keep it concise (1-3 sentences)."
          }
        },
        "required" => ["statement"],
        "additionalProperties" => false
      },
      label: "Jury Statement",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        statement = Map.get(params, "statement", Map.get(params, :statement, ""))
        event = Events.jury_statement(actor_id, statement)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("You said to the finalists: \"#{statement}\"")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp make_final_plea_tool(actor_id) do
    %AgentTool{
      name: "make_final_plea",
      description:
        "As a finalist, make your case to the jury for why you should win. " <>
          "Address their concerns, highlight your strategic moves, and explain your game.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "plea" => %{
            "type" => "string",
            "description" =>
              "Your final plea to the jury. Keep it concise but persuasive (2-4 sentences)."
          }
        },
        "required" => ["plea"],
        "additionalProperties" => false
      },
      label: "Make Final Plea",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        plea = Map.get(params, "plea", Map.get(params, :plea, ""))
        event = Events.make_final_plea(actor_id, plea)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("You pleaded: \"#{plea}\"")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp jury_vote_tool(actor_id, finalists) do
    targets_desc = Enum.join(finalists, ", ")

    %AgentTool{
      name: "jury_vote",
      description:
        "As a jury member, cast your vote for the player you think should be the Sole Survivor. " <>
          "Valid targets: #{targets_desc}",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "target_id" => %{
            "type" => "string",
            "description" =>
              "The finalist you're voting for to win. Must be one of: #{targets_desc}",
            "enum" => finalists
          }
        },
        "required" => ["target_id"],
        "additionalProperties" => false
      },
      label: "Jury Vote",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        target_id = Map.get(params, "target_id", Map.get(params, :target_id))
        event = Events.jury_vote(actor_id, target_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("You voted for #{target_id} to win.")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end
end
