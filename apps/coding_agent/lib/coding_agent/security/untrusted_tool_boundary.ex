defmodule CodingAgent.Security.UntrustedToolBoundary do
  @moduledoc """
  Wraps untrusted tool output blocks before they are sent to the LLM.

  This transform is intended for LemonAgent `transform_context`, so wrapping is
  applied only on the pre-LLM boundary and does not mutate persisted history.
  """

  alias LemonAi.Types.{TextContent, ToolResultMessage}
  alias CodingAgent.Security.ExternalContent

  # This opaque marker is attached only to the ephemeral pre-LLM copy. Tool
  # result details are data and may claim any public trust-metadata shape, so
  # no value returned by a tool is accepted as proof that this transform ran.
  @boundary_token :crypto.strong_rand_bytes(32)
  @boundary_marker :__lemon_untrusted_boundary__
  @prewrapped_tools MapSet.new(["webfetch", "websearch"])
  @tool_sources %{
    "bash" => :shell,
    "find" => :local_search,
    "grep" => :local_search,
    "read" => :local_file,
    "read_skill" => :skill,
    "webfetch" => :web_fetch,
    "websearch" => :web_search
  }

  @doc """
  Wrap untrusted tool result text blocks with external content markers.

  Only wraps `ToolResultMessage` entries where `trust` is `:untrusted` or
  `"untrusted"`. Already-wrapped text is not double-wrapped.
  """
  @spec transform([term()], reference() | nil) :: {:ok, [term()]}
  def transform(messages, _signal \\ nil) when is_list(messages) do
    transform(messages, nil, [])
  end

  @doc false
  @spec transform([term()], reference() | nil, keyword() | map()) :: {:ok, [term()]}
  def transform(messages, _signal, opts) when is_list(messages) do
    max_bytes = opt_get(opts, :max_tool_result_bytes)
    {:ok, Enum.map(messages, &wrap_message(&1, max_bytes))}
  end

  defp wrap_message(%ToolResultMessage{trust: trust} = message, max_bytes)
       when trust in [:untrusted, "untrusted"] do
    if boundary_applied?(message.details) do
      message
    else
      source = Map.get(@tool_sources, message.tool_name, :api)

      message = %{
        message
        | content:
            Enum.map(
              message.content || [],
              &wrap_content_block(&1, message.tool_name, source, max_bytes)
            )
      }

      mark_boundary_applied(message)
    end
  end

  defp wrap_message(other, _max_bytes), do: other

  defp wrap_content_block(%TextContent{text: text} = block, tool_name, source, max_bytes)
       when is_binary(text) do
    %{block | text: maybe_wrap_text(text, tool_name, source, max_bytes)}
  end

  defp wrap_content_block(%{type: :text, text: text} = block, tool_name, source, max_bytes)
       when is_binary(text) do
    %{block | text: maybe_wrap_text(text, tool_name, source, max_bytes)}
  end

  defp wrap_content_block(
         %{"type" => "text", "text" => text} = block,
         tool_name,
         source,
         max_bytes
       )
       when is_binary(text) do
    Map.put(block, "text", maybe_wrap_text(text, tool_name, source, max_bytes))
  end

  defp wrap_content_block(block, _tool_name, _source, _max_bytes), do: block

  defp maybe_wrap_text(text, tool_name, source, max_bytes) do
    if MapSet.member?(@prewrapped_tools, tool_name) and canonical_envelope?(text) do
      text
    else
      wrap_text(text, source, max_bytes)
    end
  end

  defp wrap_text(text, source, max_bytes) do
    ExternalContent.wrap_external_content(text,
      source: source,
      include_warning: true,
      max_bytes: max_bytes
    )
  end

  defp canonical_envelope?(text) do
    trimmed = String.trim(text)

    String.starts_with?(trimmed, "<<<EXTERNAL_UNTRUSTED_CONTENT>>>") and
      String.ends_with?(trimmed, "<<<END_EXTERNAL_UNTRUSTED_CONTENT>>>")
  end

  defp boundary_applied?(details) when is_map(details) do
    Map.get(details, @boundary_marker) == @boundary_token
  end

  defp boundary_applied?(_details), do: false

  defp mark_boundary_applied(%ToolResultMessage{} = message) do
    details =
      case message.details do
        details when is_map(details) -> Map.put(details, @boundary_marker, @boundary_token)
        nil -> %{@boundary_marker => @boundary_token}
        details -> %{@boundary_marker => @boundary_token, value: details}
      end

    %{message | details: details}
  end

  defp opt_get(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp opt_get(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp opt_get(_opts, _key), do: nil
end
