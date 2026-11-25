defmodule LemonAgent.Security.UntrustedToolBoundary do
  @moduledoc """
  Fences tool-result text before it is sent to the model.

  `LemonAgent.Loop` applies this once per model request as the last step, on
  the provider-bound messages `convert_to_llm` produced, so every loop consumer
  is fenced whatever it configured. Wrapping happens on that ephemeral copy and
  never mutates persisted history.

  Trust fails closed:

    * a canonical `LemonAi.Types.ToolResultMessage` is left unwrapped only when
      its `trust` is exactly the atom `:trusted`; strings, `nil`, maps and
      unknown values are untrusted;
    * any other tool-result shape (an atom- or string-keyed map with a
      `tool_result` role, or another app's tool-result struct) is always
      wrapped — only the loop's own canonical message carries attested trust.

  Text is bounded to `:max_tool_result_bytes` (default #{60_000}) including the
  envelope. A message this transform already wrapped carries a details marker
  that is an HMAC of its content under a per-node key, so it is not wrapped
  twice, and any change to the content invalidates the marker.
  """

  alias LemonAgent.Security.ExternalContent
  alias LemonAi.Types.ToolResultMessage

  @default_max_bytes 60_000
  @boundary_marker :__lemon_untrusted_boundary__
  @key_term {__MODULE__, :marker_key}
  @tool_sources %{
    "bash" => :shell,
    "bash_output" => :shell,
    "eval" => :shell,
    "debug" => :shell,
    "find" => :local_search,
    "grep" => :local_search,
    "read" => :local_file,
    "read_skill" => :skill,
    "recall" => :memory,
    "task" => :agent,
    "agent" => :agent,
    "ask_parent" => :agent,
    "webfetch" => :web_fetch,
    "websearch" => :web_search
  }

  @doc "Default byte bound for one fenced tool-result text block."
  @spec default_max_bytes() :: pos_integer()
  def default_max_bytes, do: @default_max_bytes

  @doc """
  Create the per-node marker key. `LemonAgent.Application` calls this before
  starting any worker; it is idempotent.
  """
  @spec init_key() :: :ok
  def init_key do
    if :persistent_term.get(@key_term, nil) == nil,
      do: :persistent_term.put(@key_term, :crypto.strong_rand_bytes(32))

    :ok
  end

  @doc """
  Wrap every untrusted tool result's text blocks in the untrusted-content
  envelope. A message already wrapped by this transform, with unchanged
  content, is left as is.
  """
  @spec transform([term()], LemonAgent.AbortSignal.t() | nil) :: {:ok, [term()]}
  def transform(messages, signal \\ nil) when is_list(messages),
    do: transform(messages, signal, [])

  @spec transform([term()], LemonAgent.AbortSignal.t() | nil, keyword() | map()) ::
          {:ok, [term()]}
  def transform(messages, _signal, opts) when is_list(messages) do
    max_bytes =
      case opt_get(opts, :max_tool_result_bytes) do
        bytes when is_integer(bytes) and bytes > 0 -> bytes
        _ -> @default_max_bytes
      end

    {:ok, Enum.map(messages, &wrap_message(&1, max_bytes))}
  end

  defp wrap_message(%ToolResultMessage{trust: :trusted} = message, _max_bytes), do: message

  defp wrap_message(%ToolResultMessage{} = message, max_bytes) do
    message
    |> wrap_fields(:content, :details, :tool_name, max_bytes)
    |> Map.put(:trust, :untrusted)
  end

  defp wrap_message(%{role: role} = message, max_bytes)
       when role in [:tool_result, "tool_result"] do
    message
    |> wrap_fields(:content, :details, :tool_name, max_bytes)
    |> put_known(:trust, :untrusted)
  end

  defp wrap_message(%{"role" => "tool_result"} = message, max_bytes) do
    message
    |> wrap_fields("content", "details", "tool_name", max_bytes)
    |> Map.put("trust", "untrusted")
  end

  defp wrap_message(other, _max_bytes), do: other

  defp wrap_fields(message, content_key, details_key, name_key, max_bytes) do
    content = Map.get(message, content_key)
    details = Map.get(message, details_key)

    if boundary_applied?(details, content) do
      message
    else
      source = Map.get(@tool_sources, Map.get(message, name_key), :api)
      wrapped = wrap_content(content, source, max_bytes)

      message
      |> Map.put(content_key, wrapped)
      |> put_known(details_key, mark(details, wrapped))
    end
  end

  # Structs keep their shape: a field the struct does not define is not added.
  defp put_known(%_{} = struct, key, value) do
    if Map.has_key?(struct, key), do: Map.put(struct, key, value), else: struct
  end

  defp put_known(map, key, value), do: Map.put(map, key, value)

  defp wrap_content(text, source, max_bytes) when is_binary(text),
    do: wrap_text(text, source, max_bytes)

  defp wrap_content(blocks, source, max_bytes) when is_list(blocks),
    do: Enum.map(blocks, &wrap_block(&1, source, max_bytes))

  defp wrap_content(nil, _source, _max_bytes), do: []
  defp wrap_content(other, _source, _max_bytes), do: other

  defp wrap_block(%{text: text} = block, source, max_bytes) when is_binary(text),
    do: Map.put(block, :text, wrap_text(text, source, max_bytes))

  defp wrap_block(%{"text" => text} = block, source, max_bytes) when is_binary(text),
    do: Map.put(block, "text", wrap_text(text, source, max_bytes))

  defp wrap_block(text, source, max_bytes) when is_binary(text),
    do: wrap_text(text, source, max_bytes)

  defp wrap_block(block, _source, _max_bytes), do: block

  defp wrap_text(text, source, max_bytes) do
    ExternalContent.wrap_external_content(text,
      source: source,
      include_warning: true,
      max_bytes: max_bytes
    )
  end

  defp boundary_applied?(details, content) when is_map(details) do
    case Map.get(details, @boundary_marker) do
      # hash_equals/2 raises on unequal sizes; any non-HMAC-sized tag is forged.
      tag when is_binary(tag) and byte_size(tag) == 32 ->
        :crypto.hash_equals(tag, content_tag(content))

      _ ->
        false
    end
  end

  defp boundary_applied?(_details, _content), do: false

  defp mark(details, content) when is_map(details),
    do: Map.put(details, @boundary_marker, content_tag(content))

  defp mark(nil, content), do: %{@boundary_marker => content_tag(content)}
  defp mark(details, content), do: %{@boundary_marker => content_tag(content), value: details}

  defp content_tag(content),
    do: :crypto.mac(:hmac, :sha256, key(), :erlang.term_to_binary(content, [:deterministic]))

  defp key do
    case :persistent_term.get(@key_term, nil) do
      nil ->
        init_key()
        :persistent_term.get(@key_term)

      key ->
        key
    end
  end

  defp opt_get(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp opt_get(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp opt_get(_opts, _key), do: nil
end
