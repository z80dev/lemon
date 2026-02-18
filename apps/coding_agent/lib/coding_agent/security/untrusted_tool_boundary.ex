defmodule CodingAgent.Security.UntrustedToolBoundary do
  @moduledoc """
  Wraps untrusted tool output blocks before they are sent to the LLM.

  This transform is intended for AgentCore `transform_context`, so wrapping is
  applied only on the pre-LLM boundary and does not mutate persisted history.
  """

  alias Ai.Types.{TextContent, ToolResultMessage}
  alias CodingAgent.Security.ExternalContent

  @external_start "<<<EXTERNAL_UNTRUSTED_CONTENT>>>"
  @external_end "<<<END_EXTERNAL_UNTRUSTED_CONTENT>>>"

  @spec transform([term()], reference() | nil) :: {:ok, [term()]}
  def transform(messages, _signal \\ nil) when is_list(messages) do
    {:ok, Enum.map(messages, &wrap_message/1)}
  end

  defp wrap_message(%ToolResultMessage{trust: trust} = message)
       when trust in [:untrusted, "untrusted"] do
    %{message | content: Enum.map(message.content || [], &wrap_content_block/1)}
  end

  defp wrap_message(other), do: other

  defp wrap_content_block(%TextContent{text: text} = block) when is_binary(text) do
    %{block | text: wrap_text(text)}
  end

  defp wrap_content_block(%{type: :text, text: text} = block) when is_binary(text) do
    %{block | text: wrap_text(text)}
  end

  defp wrap_content_block(%{"type" => "text", "text" => text} = block) when is_binary(text) do
    Map.put(block, "text", wrap_text(text))
  end

  defp wrap_content_block(block), do: block

  defp wrap_text(text) do
    if already_wrapped?(text) do
      text
    else
      ExternalContent.wrap_external_content(text, source: :api, include_warning: true)
    end
  end

  defp already_wrapped?(text) when is_binary(text) do
    String.contains?(text, @external_start) and String.contains?(text, @external_end)
  end

  defp already_wrapped?(_), do: false
end
