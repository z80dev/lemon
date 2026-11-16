defmodule LemonAgent.InterruptedToolResult do
  @moduledoc """
  Builds truthful results when a tool has no recorded final result.

  Every started call has an unknown outcome, regardless of tool type. Consumers
  should use `details.outcome` and `details.reason`, not parse display text.
  Unknown does not authorize a retry: effects may already have occurred.
  """

  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  @spec build(:aborted | :timeout | :crashed | :interrupted | :skipped, keyword()) ::
          AgentToolResult.t()
  def build(reason, opts \\ [])
      when reason in [:aborted, :timeout, :crashed, :interrupted, :skipped] do
    started = Keyword.get(opts, :started, reason != :skipped)
    partial = Keyword.get(opts, :partial)
    outcome = if started, do: :unknown, else: :not_started

    notice =
      if started do
        "Tool execution #{reason}; no final result was recorded. Outcome is unknown. " <>
          "Any nested tool effects are also unknown. " <>
          "Do not assume it did not run or automatically repeat it."
      else
        "Tool execution #{reason} before the call started. Outcome: not started. " <>
          "Review the current instructions before attempting this tool call."
      end

    details =
      opts
      |> Keyword.get(:details, %{})
      |> Map.merge(%{
        outcome: outcome,
        reason: reason,
        started: started,
        partial: partial != nil,
        partial_details: if(partial, do: partial.details, else: nil)
      })

    %AgentToolResult{
      content: if(partial, do: partial.content, else: []) ++ [%TextContent{text: notice}],
      trust: if(partial, do: partial.trust, else: :trusted),
      is_error: true,
      details: details
    }
  end
end
