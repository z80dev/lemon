defmodule LemonSim.Examples.TicTacToe.OfflineComplete do
  @moduledoc false

  alias Ai.Types.{
    AssistantMessage,
    Context,
    Cost,
    TextContent,
    ToolCall,
    Usage,
    UserMessage
  }

  @board_section_regex ~r/## Current Board\s+```json\n(?<json>\{.*?\})\n```/s

  @spec complete(Ai.Types.Model.t(), Context.t(), map()) ::
          {:ok, AssistantMessage.t()} | {:error, term()}
  def complete(_model, %Context{} = context, _opts) do
    with {:ok, prompt} <- extract_prompt(context),
         {:ok, world} <- extract_world(prompt),
         {:ok, {row, col}} <- choose_move(world) do
      {:ok,
       %AssistantMessage{
         role: :assistant,
         content: [
           %ToolCall{
             id: "offline_place_mark_#{System.unique_integer([:positive])}",
             name: "place_mark",
             arguments: %{"row" => row, "col" => col}
           }
         ],
         api: :offline,
         provider: :offline,
         model: "tic_tac_toe_offline",
         usage: empty_usage(),
         stop_reason: :tool_use,
         timestamp: System.system_time(:millisecond)
       }}
    end
  end

  defp extract_prompt(%Context{messages: messages}) do
    case Enum.find(messages, &match?(%UserMessage{}, &1)) do
      %UserMessage{content: content} when is_binary(content) and content != "" ->
        {:ok, content}

      %UserMessage{content: content} when is_list(content) ->
        text =
          content
          |> Enum.filter(&match?(%TextContent{}, &1))
          |> Enum.map(& &1.text)
          |> Enum.join("\n")

        if text != "", do: {:ok, text}, else: {:error, :missing_prompt}

      _ ->
        {:error, :missing_prompt}
    end
  end

  defp extract_world(prompt) when is_binary(prompt) do
    case Regex.named_captures(@board_section_regex, prompt) do
      %{"json" => json} ->
        Jason.decode(json)

      _ ->
        {:error, :missing_board_section}
    end
  end

  defp choose_move(%{"board" => board, "current_player" => player}) do
    legal_moves = legal_moves(board)
    opponent = other_player(player)

    move =
      winning_move(board, legal_moves, player) ||
        winning_move(board, legal_moves, opponent) ||
        preferred_move(legal_moves, [{1, 1}, {0, 0}, {0, 2}, {2, 0}, {2, 2}]) ||
        List.first(legal_moves)

    case move do
      {row, col} -> {:ok, {row, col}}
      nil -> {:error, :no_legal_moves}
    end
  end

  defp choose_move(_), do: {:error, :invalid_world_state}

  defp legal_moves(board) do
    for row <- 0..2,
        col <- 0..2,
        cell(board, row, col) == " ",
        do: {row, col}
  end

  defp winning_move(board, legal_moves, player) do
    Enum.find(legal_moves, fn {row, col} ->
      board
      |> place(row, col, player)
      |> winner?(player)
    end)
  end

  defp preferred_move(legal_moves, preferred) do
    Enum.find(preferred, &(&1 in legal_moves))
  end

  defp winner?(board, player) do
    lines = [
      [{0, 0}, {0, 1}, {0, 2}],
      [{1, 0}, {1, 1}, {1, 2}],
      [{2, 0}, {2, 1}, {2, 2}],
      [{0, 0}, {1, 0}, {2, 0}],
      [{0, 1}, {1, 1}, {2, 1}],
      [{0, 2}, {1, 2}, {2, 2}],
      [{0, 0}, {1, 1}, {2, 2}],
      [{0, 2}, {1, 1}, {2, 0}]
    ]

    Enum.any?(lines, fn coords ->
      Enum.all?(coords, fn {row, col} -> cell(board, row, col) == player end)
    end)
  end

  defp cell(board, row, col) do
    board
    |> Enum.at(row, [])
    |> Enum.at(col)
  end

  defp place(board, row, col, player) do
    List.update_at(board, row, fn board_row ->
      List.replace_at(board_row, col, player)
    end)
  end

  defp other_player("X"), do: "O"
  defp other_player("O"), do: "X"
  defp other_player(_), do: "X"

  defp empty_usage do
    %Usage{
      input: 0,
      output: 0,
      cache_read: 0,
      cache_write: 0,
      total_tokens: 0,
      cost: %Cost{
        input: 0.0,
        output: 0.0,
        cache_read: 0.0,
        cache_write: 0.0,
        total: 0.0
      }
    }
  end
end
