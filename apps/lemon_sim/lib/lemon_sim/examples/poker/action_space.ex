defmodule LemonSim.Examples.Poker.ActionSpace do
  @moduledoc false

  @behaviour LemonSim.ActionSpace

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias LemonCore.MapHelpers
  alias LemonSim.Examples.Poker.Engine.Table
  alias LemonSim.Examples.Poker.Events

  @impl true
  def tools(state, opts) do
    include_note_tool? = Keyword.get(opts, :include_note_tool?, true)

    if MapHelpers.get_key(state.world, :status) != "in_progress" do
      {:ok, []}
    else
      table = MapHelpers.get_key(state.world, :table)

      case Table.legal_actions(table) do
        {:ok, legal} ->
          player = Map.fetch!(table.hand.players, legal.seat)

          tools =
            []
            |> maybe_add(include_note_tool?, fn -> note_tool(player, table.hand) end)
            |> maybe_add(:fold in legal.options, fn -> fold_tool(player) end)
            |> maybe_add(:check in legal.options, fn -> check_tool(player) end)
            |> maybe_add(:call in legal.options, fn -> call_tool(player, legal.to_call) end)
            |> maybe_add(:bet in legal.options and is_map(legal.bet), fn ->
              bet_tool(player, legal.bet)
            end)
            |> maybe_add(
              :raise in legal.options and is_map(legal.raise),
              fn -> raise_tool(player, legal.raise) end
            )

          {:ok, tools}

        {:error, :no_hand_in_progress} ->
          {:ok, []}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp fold_tool(player) do
    simple_action_tool(
      "fold",
      "Fold this hand.",
      player,
      :fold,
      "folded"
    )
  end

  defp check_tool(player) do
    simple_action_tool(
      "check",
      "Check and pass action without adding chips.",
      player,
      :check,
      "checked"
    )
  end

  defp call_tool(player, to_call) do
    simple_action_tool(
      "call",
      "Call #{to_call} chips to stay in the hand.",
      player,
      :call,
      "called #{to_call}"
    )
  end

  defp note_tool(player, hand) do
    %AgentTool{
      name: "note",
      description:
        "Write a private note about opponents or the current hand. This does not end your turn.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "content" => %{
            "type" => "string",
            "description" => "Short private note visible only to you in future hands."
          }
        },
        "required" => ["content"],
        "additionalProperties" => false
      },
      label: "Note",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        params = params || %{}

        content =
          params
          |> Map.get("content", Map.get(params, :content, ""))
          |> to_string()
          |> String.trim()

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("Noted: #{content}")],
           details: %{
             "event" =>
               Events.player_note(player.player_id, player.seat, content, %{
                 "hand_id" => hand && hand.id,
                 "street" => hand && to_string(hand.street)
               })
           },
           trust: :trusted
         }}
      end
    }
  end

  defp bet_tool(player, spec) do
    amount_tool(
      "bet_to",
      "Open the betting by committing chips to a total for this street. #{amount_description(spec)}",
      player,
      :bet,
      "bet to"
    )
  end

  defp raise_tool(player, spec) do
    amount_tool(
      "raise_to",
      "Raise by committing chips to a new total for this street. #{amount_description(spec)}",
      player,
      :raise,
      "raised to"
    )
  end

  defp simple_action_tool(name, description, player, action, summary) do
    %AgentTool{
      name: name,
      description: description,
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      label: humanize(name),
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("#{player.player_id} #{summary}")],
           details: %{"event" => Events.player_action(player.player_id, player.seat, action)},
           trust: :trusted
         }}
      end
    }
  end

  defp amount_tool(name, description, player, action, summary) do
    %AgentTool{
      name: name,
      description: description,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "total" => %{
            "type" => "integer",
            "description" => "Total chips committed on this betting round after the action."
          }
        },
        "required" => ["total"],
        "additionalProperties" => false
      },
      label: humanize(name),
      execute: fn _tool_call_id, params, _signal, _on_update ->
        total = Map.get(params || %{}, "total", Map.get(params || %{}, :total))

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("#{player.player_id} #{summary} #{inspect(total)}")],
           details: %{
             "event" => Events.player_action(player.player_id, player.seat, action, total)
           },
           trust: :trusted
         }}
      end
    }
  end

  defp amount_description(%{max: max, all_in_only: true}) do
    "Only an all-in total of #{max} is legal."
  end

  defp amount_description(%{min: min, max: max, all_in_only: false}) do
    "Legal totals are #{min} through #{max}."
  end

  defp maybe_add(list, true, build_tool) when is_function(build_tool, 0),
    do: list ++ [build_tool.()]

  defp maybe_add(list, false, _build_tool), do: list

  defp humanize(name) do
    name
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
