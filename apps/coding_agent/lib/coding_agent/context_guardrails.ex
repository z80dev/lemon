defmodule CodingAgent.ContextGuardrails do
  @moduledoc """
  Hard guardrails applied right before messages are sent to the LLM.

  Goals:
  - Cap tool outputs / images / tool-call args deterministically (cache-friendly)
  - Optionally spill large blobs to disk and replace with stable references
  - Drop or clamp thinking blocks
  """

  require Logger

  alias Ai.Types.{AssistantMessage, ToolResultMessage, UserMessage}
  alias Ai.Types.{TextContent, ImageContent, ThinkingContent, ToolCall}

  @type opts :: %{
          enabled: boolean(),
          mode: :trim | :error,
          max_tool_result_bytes: non_neg_integer(),
          max_tool_result_images: non_neg_integer(),
          max_thinking_bytes: non_neg_integer(),
          max_tool_call_arg_string_bytes: non_neg_integer(),
          spill_dir: String.t() | nil
        }

  @default_opts %{
    enabled: true,
    mode: :trim,
    max_tool_result_bytes: 60_000,
    max_tool_result_images: 0,
    max_thinking_bytes: 0,
    max_tool_call_arg_string_bytes: 12_000,
    spill_dir: nil
  }

  @doc """
  Transform messages for LLM input (AgentCore transform_context-compatible).

  Return value can be:
    - list(messages)
    - {:ok, list(messages)}

  This function never raises unless mode=:error and we detect an overflow we can't trim.
  """
  @spec transform([term()], reference() | nil, map() | keyword()) :: {:ok, [term()]} | [term()]
  def transform(messages, _signal \\ nil, opts \\ %{}) when is_list(messages) do
    opts = normalize_opts(opts)

    if opts.enabled do
      transformed =
        messages
        |> Enum.map(&guard_message(&1, opts))

      {:ok, transformed}
    else
      {:ok, messages}
    end
  end

  defp normalize_opts(opts) when is_list(opts),
    do: opts |> Enum.into(%{}) |> normalize_opts()

  defp normalize_opts(opts) when is_map(opts),
    do: Map.merge(@default_opts, opts)

  # ----------------------------------------------------------------------------
  # Message guards
  # ----------------------------------------------------------------------------

  defp guard_message(%ToolResultMessage{} = msg, opts), do: guard_tool_result(msg, opts)
  defp guard_message(%AssistantMessage{} = msg, opts), do: guard_assistant(msg, opts)
  defp guard_message(%UserMessage{} = msg, _opts), do: msg
  defp guard_message(other, _opts), do: other

  defp guard_assistant(%AssistantMessage{content: blocks} = msg, opts) when is_list(blocks) do
    blocks =
      blocks
      |> Enum.flat_map(fn
        %ThinkingContent{} = t ->
          guard_thinking_block(t, opts)

        %ToolCall{} = tc ->
          [%{tc | arguments: guard_tool_call_args(tc.arguments, opts)}]

        other ->
          [other]
      end)

    %{msg | content: blocks}
  end

  defp guard_assistant(msg, _opts), do: msg

  defp guard_thinking_block(%ThinkingContent{}, %{max_thinking_bytes: 0}), do: []

  defp guard_thinking_block(%ThinkingContent{thinking: thinking} = block, opts) do
    maxb = opts.max_thinking_bytes

    if byte_size(thinking) <= maxb do
      [block]
    else
      {tr, meta} = truncate_with_meta(thinking, maxb, spill_label: "assistant_thinking", opts: opts)

      Logger.warning("Thinking block truncated: #{inspect(meta)}")
      [%{block | thinking: tr}]
    end
  end

  defp guard_tool_call_args(args, opts) when is_map(args) do
    maxb = opts.max_tool_call_arg_string_bytes

    args
    |> Enum.map(fn {k, v} ->
      {k, guard_arg_value(v, maxb, opts)}
    end)
    |> Enum.into(%{})
  end

  defp guard_tool_call_args(other, _opts), do: other

  defp guard_arg_value(v, _maxb, _opts) when is_number(v) or is_boolean(v) or is_nil(v), do: v

  defp guard_arg_value(v, maxb, opts) when is_binary(v) do
    if byte_size(v) <= maxb do
      v
    else
      {tr, meta} = truncate_with_meta(v, maxb, spill_label: "tool_call_arg", opts: opts)

      %{
        "_truncated" => true,
        "bytes" => meta.original_bytes,
        "sha256" => meta.sha256,
        "spill_path" => meta.spill_path,
        "head_tail_excerpt" => tr
      }
    end
  end

  defp guard_arg_value(v, maxb, opts) when is_list(v),
    do: Enum.map(v, &guard_arg_value(&1, maxb, opts))

  defp guard_arg_value(v, maxb, opts) when is_map(v) do
    v
    |> Enum.map(fn {k, vv} -> {k, guard_arg_value(vv, maxb, opts)} end)
    |> Enum.into(%{})
  end

  defp guard_arg_value(v, _maxb, _opts), do: v

  # ----------------------------------------------------------------------------
  # Tool result guards (text + images)
  # ----------------------------------------------------------------------------

  defp guard_tool_result(%ToolResultMessage{} = msg, opts) do
    content = msg.content || []

    {texts, non_texts} =
      Enum.split_with(content, fn
        %TextContent{} -> true
        _ -> false
      end)

    {images, other_blocks} =
      Enum.split_with(non_texts, fn
        %ImageContent{} -> true
        _ -> false
      end)

    text =
      texts
      |> Enum.map(fn %TextContent{text: t} -> t end)
      |> Enum.join("\n")

    # Handle images first (spill by default)
    {image_placeholders, kept_images} =
      spill_or_keep_images(images, opts, tool_name(msg))

    # Then clamp text
    {clamped_text, _meta} =
      if text == "" do
        {"", nil}
      else
        if byte_size(text) <= opts.max_tool_result_bytes do
          {text, nil}
        else
          truncate_with_meta(text, opts.max_tool_result_bytes,
            spill_label: "tool_result:#{tool_name(msg)}",
            opts: opts
          )
        end
      end

    header =
      if clamped_text != text do
        # Important: deterministic header (no timestamps).
        sha = sha256_hex(text)
        spill_path = stable_spill_path(opts[:spill_dir], "tool_result", sha, "txt")

        [
          "[tool_result truncated]",
          "tool=#{tool_name(msg)}",
          "original_bytes=#{byte_size(text)}",
          "sha256=#{sha}",
          if(spill_path, do: "spill_path=#{spill_path}", else: nil)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" ")
      else
        nil
      end

    final_text =
      cond do
        header && clamped_text != "" -> header <> "\n" <> clamped_text
        header -> header
        true -> clamped_text
      end

    new_blocks =
      []
      |> maybe_add_text(final_text)
      |> Kernel.++(image_placeholders)
      |> Kernel.++(kept_images)
      |> Kernel.++(other_blocks)

    %{msg | content: new_blocks}
  end

  defp tool_name(%ToolResultMessage{tool_name: t}) when is_binary(t) and t != "", do: t
  defp tool_name(_), do: "tool"

  defp maybe_add_text(blocks, text) when is_list(blocks) do
    if is_binary(text) and text != "" do
      blocks ++ [%TextContent{type: :text, text: text}]
    else
      blocks
    end
  end

  defp spill_or_keep_images(images, opts, tname) do
    # Keep at most N images as actual ImageContent; spill the rest to text placeholders.
    max_images = opts[:max_tool_result_images] || 0

    {keep, spill} = Enum.split(images, max_images)

    kept_images = keep

    placeholders =
      spill
      |> Enum.map(fn
        %ImageContent{data: b64, mime_type: mime} ->
          case Base.decode64(b64) do
            {:ok, raw_bytes} ->
              sha = sha256_hex(raw_bytes)
              ext = mime_to_ext(mime)
              path = stable_spill_path(opts[:spill_dir], "tool_image", sha, ext)

              _ = maybe_write_spill(path, raw_bytes)

              %TextContent{
                type: :text,
                text:
                  "[tool_result image spilled] tool=#{tname} mime=#{mime} sha256=#{sha}" <>
                    if(path, do: " spill_path=#{path}", else: "")
              }

            :error ->
              %TextContent{type: :text, text: "[tool_result image omitted: invalid base64]"}
          end

        other ->
          %TextContent{type: :text, text: "[tool_result image omitted] #{inspect(other)}"}
      end)

    {placeholders, kept_images}
  end

  defp mime_to_ext("image/png"), do: "png"
  defp mime_to_ext("image/jpeg"), do: "jpg"
  defp mime_to_ext("image/webp"), do: "webp"
  defp mime_to_ext(_), do: "bin"

  # ----------------------------------------------------------------------------
  # Truncation + spill helpers (deterministic)
  # ----------------------------------------------------------------------------

  defp truncate_with_meta(text, max_bytes, spill_label: label, opts: opts) do
    sha = sha256_hex(text)
    path = stable_spill_path(opts[:spill_dir], label, sha, "txt")

    _ = maybe_write_spill(path, text)

    truncated = truncate_middle_utf8(text, max_bytes)

    meta = %{
      original_bytes: byte_size(text),
      truncated_bytes: byte_size(truncated),
      sha256: sha,
      spill_path: path,
      label: label
    }

    {truncated, meta}
  end

  defp stable_spill_path(nil, _label, _sha, _ext), do: nil

  defp stable_spill_path(dir, label, sha, ext) when is_binary(dir) do
    safe_label =
      label
      |> to_string()
      |> String.replace(~r/[^a-zA-Z0-9_\-:.]+/, "_")
      |> String.slice(0, 80)

    Path.join([expand_home(dir), safe_label, "#{sha}.#{ext}"])
  end

  defp expand_home(path) do
    case path do
      "~" <> rest -> Path.join(System.user_home!(), String.trim_leading(rest, "/"))
      other -> other
    end
  end

  defp maybe_write_spill(nil, _data), do: :ok

  defp maybe_write_spill(path, data) when is_binary(path) do
    try do
      File.mkdir_p!(Path.dirname(path))

      case File.stat(path) do
        {:ok, _} ->
          :ok

        {:error, :enoent} ->
          File.write!(path, data)
          :ok

        {:error, _} ->
          :ok
      end
    rescue
      _ -> :ok
    end
  end

  defp sha256_hex(bin) when is_binary(bin) do
    :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)
  end

  # Keep head + tail; deterministic; preserve UTF-8 validity.
  defp truncate_middle_utf8(text, max_bytes) when byte_size(text) <= max_bytes, do: text

  defp truncate_middle_utf8(_text, max_bytes) when max_bytes <= 0, do: ""

  defp truncate_middle_utf8(text, max_bytes) do
    marker_reserve = 256
    budget = max(max_bytes - marker_reserve, 0)

    head_bytes = div(budget * 70, 100)
    tail_bytes = budget - head_bytes

    head = trim_to_valid_utf8(binary_part(text, 0, head_bytes))
    tail = trim_to_valid_utf8(binary_part(text, byte_size(text) - tail_bytes, tail_bytes))

    removed = byte_size(text) - byte_size(head) - byte_size(tail)

    marker = "\n... [TRUNCATED #{removed} bytes] ...\n"

    out = head <> marker <> tail

    if byte_size(out) <= max_bytes do
      out
    else
      trim_to_valid_utf8(binary_part(out, 0, max_bytes))
    end
  end

  defp trim_to_valid_utf8(<<>>), do: ""

  defp trim_to_valid_utf8(bin) when is_binary(bin) do
    if String.valid?(bin) do
      bin
    else
      bin
      |> binary_part(0, byte_size(bin) - 1)
      |> trim_to_valid_utf8()
    end
  end
end
