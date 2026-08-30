defmodule CodingAgent.Security.UntrustedToolBoundary do
  @moduledoc """
  Wraps untrusted tool output blocks before they are sent to the LLM.

  This transform is intended for LemonAgent `transform_context`, so wrapping is
  applied only on the pre-LLM boundary and does not mutate persisted history.
  """

  alias LemonAi.Types.{TextContent, ToolResultMessage}
  alias CodingAgent.Security.ExternalContent

  @external_start "<<<EXTERNAL_UNTRUSTED_CONTENT>>>"
  @external_end "<<<END_EXTERNAL_UNTRUSTED_CONTENT>>>"

  @doc """
  Wrap untrusted tool result text blocks with external content markers.

  Only wraps `ToolResultMessage` entries where `trust` is `:untrusted` or
  `"untrusted"`. Already-wrapped text is not double-wrapped.
  """
  @spec transform([term()], reference() | nil) :: {:ok, [term()]}
  def transform(messages, _signal \\ nil) when is_list(messages) do
    {:ok, Enum.map(messages, &wrap_message/1)}
  end

  defp wrap_message(%ToolResultMessage{trust: trust} = message)
       when trust in [:untrusted, "untrusted"] do
    boundary = trust_boundary(message.details)
    source = trust_source(boundary)

    if wrapping_applied?(boundary) do
      message
    else
      %{message | content: Enum.map(message.content || [], &wrap_content_block(&1, source))}
    end
  end

  defp wrap_message(other), do: other

  defp wrap_content_block(%TextContent{text: text} = block, source) when is_binary(text) do
    %{block | text: wrap_text(text, source)}
  end

  defp wrap_content_block(%{type: :text, text: text} = block, source) when is_binary(text) do
    %{block | text: wrap_text(text, source)}
  end

  defp wrap_content_block(%{"type" => "text", "text" => text} = block, source)
       when is_binary(text) do
    Map.put(block, "text", wrap_text(text, source))
  end

  defp wrap_content_block(block, _source), do: block

  defp wrap_text(text, source) do
    if already_wrapped?(text) do
      text
    else
      ExternalContent.wrap_external_content(text, source: source, include_warning: true)
    end
  end

  defp trust_source(boundary) when is_map(boundary) do
    source = Map.get(boundary, :source) || Map.get(boundary, "source")

    case source do
      value when is_binary(value) -> String.to_existing_atom(value)
      value when is_atom(value) -> value
      _ -> :api
    end
  rescue
    ArgumentError -> :api
  end

  defp trust_source(_boundary), do: :api

  defp trust_boundary(details) when is_map(details) do
    Map.get(details, :trust_boundary) || Map.get(details, "trust_boundary") ||
      Map.get(details, :trust_metadata) || Map.get(details, "trust_metadata") ||
      Map.get(details, :trustMetadata) || Map.get(details, "trustMetadata") || %{}
  end

  defp trust_boundary(_details), do: %{}

  defp wrapping_applied?(boundary) when is_map(boundary) do
    Map.get(boundary, :wrapping_applied) == true or
      Map.get(boundary, "wrapping_applied") == true or
      Map.get(boundary, :wrappingApplied) == true or
      Map.get(boundary, "wrappingApplied") == true
  end

  defp wrapping_applied?(_boundary), do: false

  defp already_wrapped?(text) when is_binary(text) do
    trimmed = String.trim(text)

    String.starts_with?(
      trimmed,
      "SECURITY NOTICE: The following content is from an EXTERNAL, UNTRUSTED source."
    ) and String.contains?(trimmed, @external_start) and String.ends_with?(trimmed, @external_end)
  end

  defp already_wrapped?(_), do: false
end
