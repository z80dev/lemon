defmodule LemonAi.StreamAccumulator do
  @moduledoc """
  On-demand snapshots of delta-only provider events.

  Content deltas are retained as reversed binary chunks, never appended to a
  growing shared binary. `apply/2` does not materialize text or decode arguments;
  `snapshot/1` does so only when a caller requests the current partial message.
  Final block events replace their buffered chunks. Initial and terminal
  messages retain provider metadata, including signatures and usage.
  """

  import Kernel, except: [apply: 2]

  alias LemonAi.Types.{AssistantMessage, TextContent, ThinkingContent, ToolCall}

  @opaque t :: %__MODULE__{
            message: AssistantMessage.t(),
            blocks: %{non_neg_integer() => AssistantMessage.content_block()},
            chunks: %{non_neg_integer() => [binary()]}
          }
  defstruct message: %AssistantMessage{}, blocks: %{}, chunks: %{}

  @spec new(AssistantMessage.t()) :: t()
  def new(%AssistantMessage{} = message \\ %AssistantMessage{}) do
    %__MODULE__{
      message: %{message | content: []},
      blocks: message.content |> Enum.with_index() |> Map.new(fn {block, i} -> {i, block} end)
    }
  end

  @spec apply(t(), LemonAi.EventStream.event()) :: t()
  def apply(_acc, {:start, %AssistantMessage{} = message}), do: new(message)

  def apply(acc, {:text_start, index}), do: put_block(acc, index, %TextContent{})
  def apply(acc, {:thinking_start, index}), do: put_block(acc, index, %ThinkingContent{})

  def apply(acc, {:tool_call_start, index, %ToolCall{} = call}),
    do: put_block(acc, index, call)

  def apply(acc, {kind, index, delta})
      when kind in [:text_delta, :thinking_delta, :tool_call_delta] and is_binary(delta) do
    block = Map.get(acc.blocks, index, empty_block(kind))

    %{
      acc
      | blocks: Map.put(acc.blocks, index, block),
        chunks: Map.update(acc.chunks, index, [delta], &[delta | &1])
    }
  end

  def apply(acc, {:text_end, index, text}) when is_binary(text),
    do: put_block(acc, index, %TextContent{text: text})

  def apply(acc, {:thinking_end, index, text}) when is_binary(text),
    do: put_block(acc, index, %ThinkingContent{thinking: text})

  def apply(acc, {:tool_call_end, index, %ToolCall{} = call}),
    do: put_block(acc, index, call)

  def apply(_acc, {kind, _reason, %AssistantMessage{} = message}) when kind in [:done, :error],
    do: new(message)

  def apply(acc, _event), do: acc

  @doc "Return response metadata without materializing buffered content."
  @spec metadata(t()) :: AssistantMessage.t()
  def metadata(%__MODULE__{message: message}), do: message

  @doc "Materialize the current partial answer without changing the buffered chunks."
  @spec snapshot(t()) :: AssistantMessage.t()
  def snapshot(%__MODULE__{} = acc) do
    content =
      acc.blocks
      |> Enum.sort_by(fn {index, _block} -> index end)
      |> Enum.map(fn {index, block} -> materialize(block, Map.get(acc.chunks, index, [])) end)

    %{acc.message | content: content}
  end

  defp put_block(acc, index, block) do
    %{acc | blocks: Map.put(acc.blocks, index, block), chunks: Map.delete(acc.chunks, index)}
  end

  defp empty_block(:text_delta), do: %TextContent{}
  defp empty_block(:thinking_delta), do: %ThinkingContent{}
  defp empty_block(:tool_call_delta), do: %ToolCall{}

  defp materialize(block, []), do: block

  defp materialize(%TextContent{} = block, chunks),
    do: %{block | text: IO.iodata_to_binary([block.text | Enum.reverse(chunks)])}

  defp materialize(%ThinkingContent{} = block, chunks),
    do: %{block | thinking: IO.iodata_to_binary([block.thinking | Enum.reverse(chunks)])}

  defp materialize(%ToolCall{} = block, chunks) do
    arguments =
      chunks
      |> Enum.reverse()
      |> IO.iodata_to_binary()
      |> LemonAi.PartialJson.decode(block.arguments)

    %{block | arguments: arguments}
  end
end
