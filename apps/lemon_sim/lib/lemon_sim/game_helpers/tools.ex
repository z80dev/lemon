defmodule LemonSim.GameHelpers.Tools do
  @moduledoc """
  Shared tool builders for common game mechanics.

  Provides pre-built AgentTool structs for actions shared across multiple
  games: public statements, voting, and private whispers.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias LemonSim.Event

  @doc """
  Builds a make_statement tool for public discussion.

  ## Options
    * `:description` - custom tool description
  """
  def statement_tool(actor_id, opts \\ []) do
    description =
      Keyword.get(
        opts,
        :description,
        "Make a public statement during the discussion. All players will see what you say. " <>
          "You may accuse, defend, share information, bluff, or stay vague. Be strategic."
      )

    %AgentTool{
      name: "make_statement",
      description: description,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "statement" => %{
            "type" => "string",
            "description" =>
              "Your public statement. Keep it concise (1-3 sentences)."
          }
        },
        "required" => ["statement"],
        "additionalProperties" => false
      },
      label: "Make Statement",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        statement = Map.get(params, "statement", Map.get(params, :statement, ""))
        event = Event.new("make_statement", %{"player_id" => actor_id, "statement" => statement})

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("You said: \"#{statement}\"")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  @doc """
  Builds a cast_vote tool for voting phases.

  ## Options
    * `:description` - custom tool description
    * `:include_skip` - whether to include "skip" option (default true)
  """
  def vote_tool(actor_id, valid_targets, opts \\ []) do
    targets_desc = Enum.join(valid_targets, ", ")
    include_skip = Keyword.get(opts, :include_skip, true)
    options = if include_skip, do: valid_targets ++ ["skip"], else: valid_targets

    description =
      Keyword.get(opts, :description, build_vote_description(targets_desc, include_skip))

    %AgentTool{
      name: "cast_vote",
      description: description,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "target_id" => %{
            "type" => "string",
            "description" =>
              "The player to vote against. Must be one of: #{Enum.join(options, ", ")}",
            "enum" => options
          }
        },
        "required" => ["target_id"],
        "additionalProperties" => false
      },
      label: "Cast Vote",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        target_id = Map.get(params, "target_id", Map.get(params, :target_id, "skip"))
        event = Event.new("cast_vote", %{"player_id" => actor_id, "target_id" => target_id})

        message =
          if target_id == "skip",
            do: "You abstained from voting.",
            else: "You voted to eliminate #{target_id}."

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content(message)],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  @doc """
  Builds a send_whisper tool for private messaging.

  ## Options
    * `:description` - custom tool description
  """
  def whisper_tool(actor_id, valid_targets, opts \\ []) do
    targets_desc = Enum.join(valid_targets, ", ")

    description =
      Keyword.get(
        opts,
        :description,
        "Send a private message to another player. Only they will see the content, " <>
          "but other players can see that you whispered. Valid targets: #{targets_desc}"
      )

    %AgentTool{
      name: "send_whisper",
      description: description,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "to_id" => %{
            "type" => "string",
            "description" => "The player to whisper to. Must be one of: #{targets_desc}",
            "enum" => valid_targets
          },
          "message" => %{
            "type" => "string",
            "description" => "Your private message. Keep it concise (1-2 sentences)."
          }
        },
        "required" => ["to_id", "message"],
        "additionalProperties" => false
      },
      label: "Send Whisper",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        to_id = Map.get(params, "to_id", Map.get(params, :to_id))
        message = Map.get(params, "message", Map.get(params, :message, ""))

        event =
          Event.new("send_whisper", %{
            "player_id" => actor_id,
            "to_id" => to_id,
            "message" => message
          })

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("You whispered to #{to_id}: \"#{message}\"")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp build_vote_description(targets_desc, true),
    do:
      "Vote to eliminate a player or skip. Valid targets: #{targets_desc}, or \"skip\" to abstain."

  defp build_vote_description(targets_desc, false),
    do: "Vote for a player. Valid targets: #{targets_desc}."
end
