defmodule CodingAgent.ContextGuardrails do
  @moduledoc """
  Hard guardrails applied right before messages are sent to the LLM.

  Goals:
  - Cap tool outputs / images / tool-call args deterministically (cache-friendly)
  - Optionally spill large blobs to disk and replace with stable references
  - Drop or clamp thinking blocks

  `max_tool_result_images` (default 3) is a budget for the whole context: the
  most recent N images across all tool results are sent as images, and older
  ones are replaced by spill placeholders. Screenshots and image reads reach
  the model without every historical image riding along on each request.
  """

  require Logger

  alias LemonAi.Types.{AssistantMessage, ToolResultMessage, UserMessage}
  alias LemonAi.Types.{TextContent, ImageContent, ThinkingContent, ToolCall}

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
    max_tool_result_images: 3,
    max_thinking_bytes: 0,
    max_tool_call_arg_string_bytes: 12_000,
    spill_dir: nil
  }

  @doc """
  Transform messages for LLM input (LemonAgent transform_context-compatible).

  Return value can be:
    - list(messages)
    - {:ok, list(messages)}

  This function never raises unless mode=:error and we detect an overflow we can't trim.
  """
  @spec transform([term()], reference() | nil, map() | keyword()) :: {:ok, [term()]} | [term()]
  def transform(messages, _signal \\ nil, opts \\ %{}) when is_list(messages) do
    opts = normalize_opts(opts)

    if opts.enabled do
      budgets = image_budgets(messages, opts.max_tool_result_images)

      transformed =
        messages
        |> Enum.with_index()
        |> Enum.map(fn {message, index} ->
          guard_message(message, Map.put(opts, :image_budget, Map.get(budgets, index, 0)))
        end)

      {:ok, transformed}
    else
      {:ok, messages}
    end
  end

  defp normalize_opts(opts) when is_list(opts),
    do: opts |> Enum.into(%{}) |> normalize_opts()

  defp normalize_opts(opts) when is_map(opts),
    do: Map.merge(@default_opts, opts)

  # Assign the image budget newest-first: message index => images it may keep.
  defp image_budgets(messages, max_images) when is_integer(max_images) and max_images > 0 do
    {budgets, _left} =
      messages
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.reduce({%{}, max_images}, fn
        {%ToolResultMessage{content: content}, index}, {acc, left}
        when is_list(content) and left > 0 ->
          keep = min(Enum.count(content, &match?(%ImageContent{}, &1)), left)
          {Map.put(acc, index, keep), left - keep}

        _message, acc ->
          acc
      end)

    budgets
  end

  defp image_budgets(_messages, _max_images), do: %{}

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

    cond do
      byte_size(thinking) <= maxb ->
        [block]

      # A provider signature covers the exact thinking text (Anthropic rejects
      # a modified signed block), so an oversized signed block is dropped whole
      # rather than replayed truncated under a signature that no longer matches.
      signed?(block) ->
        Logger.warning(
          "Signed thinking block dropped: #{byte_size(thinking)} bytes exceeds #{maxb}"
        )

        []

      true ->
        {tr, meta} =
          truncate_with_meta(thinking, maxb, spill_label: "assistant_thinking", opts: opts)

        Logger.warning("Thinking block truncated: #{inspect(meta)}")
        [%{block | thinking: tr}]
    end
  end

  defp signed?(%ThinkingContent{thinking_signature: signature}),
    do: is_binary(signature) and signature != ""

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
        "artifact_uri" => meta.artifact_uri,
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
    {clamped_text, meta} =
      if text == "" do
        {"", nil}
      else
        if byte_size(text) <= opts.max_tool_result_bytes do
          {text, nil}
        else
          truncate_with_meta(text, opts.max_tool_result_bytes,
            spill_label: "tool_result:#{tool_name(msg)}",
            opts: Map.put(opts, :existing_artifact, existing_artifact(msg, opts))
          )
        end
      end

    header =
      if clamped_text != text do
        # Important: deterministic header (no timestamps).
        sha = if(meta, do: meta.sha256, else: sha256_hex(text))
        spill_path = if(meta, do: meta.spill_path, else: nil)
        artifact_uri = if(meta, do: meta.artifact_uri, else: nil)

        [
          "[tool_result truncated]",
          "tool=#{tool_name(msg)}",
          "original_bytes=#{byte_size(text)}",
          if(meta && meta.existing_artifact, do: "preview_sha256=#{sha}", else: "sha256=#{sha}"),
          if(artifact_uri, do: "artifact_uri=#{artifact_uri}", else: nil),
          if(spill_path && is_nil(artifact_uri), do: "spill_path=#{spill_path}", else: nil)
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
    # Keep this message's share of the context image budget (its newest
    # images); spill the rest to text placeholders.
    keep_count = opts[:image_budget] || 0

    {spill, kept_images} = Enum.split(images, max(length(images) - keep_count, 0))

    placeholders =
      spill
      |> Enum.map(fn
        %ImageContent{data: b64, mime_type: mime} ->
          case Base.decode64(b64) do
            {:ok, raw_bytes} ->
              sha = sha256_hex(raw_bytes)
              ext = mime_to_ext(mime)
              path = stable_spill_path(opts[:spill_dir], "tool_image", sha, ext)

              {path, artifact_uri} = spill_reference(path, raw_bytes, opts)

              %TextContent{
                type: :text,
                text:
                  "[tool_result image spilled] tool=#{tname} mime=#{mime} sha256=#{sha}" <>
                    cond do
                      artifact_uri -> " artifact_uri=#{artifact_uri}"
                      path -> " spill_path=#{path}"
                      true -> " (full image unavailable)"
                    end
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
    existing = opts[:existing_artifact]

    {path, artifact_uri} =
      existing ||
        spill_reference(stable_spill_path(opts[:spill_dir], label, sha, "txt"), text, opts)

    truncated =
      LemonAi.Text.truncate_middle_utf8(text, max_bytes,
        marker: fn removed -> "\n... [TRUNCATED #{removed} bytes] ...\n" end
      )

    meta = %{
      original_bytes: byte_size(text),
      truncated_bytes: byte_size(truncated),
      sha256: sha,
      spill_path: path,
      artifact_uri: artifact_uri,
      existing_artifact: not is_nil(existing),
      label: label
    }

    {truncated, meta}
  end

  defp existing_artifact(%ToolResultMessage{details: %{artifact_uri: uri}}, opts)
       when is_binary(uri) do
    case CodingAgent.Artifacts.resolve_in_dir(uri, opts[:spill_dir]) do
      {:ok, path} -> {path, uri}
      {:error, _} -> nil
    end
  end

  defp existing_artifact(_message, _opts), do: nil

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

  defp spill_reference(path, data, opts) do
    CodingAgent.SessionMaintenance.with_root_lock(fn ->
      spill_reference_locked(path, data, opts)
    end)
  end

  defp spill_reference_locked(path, data, opts) do
    case maybe_write_spill(path, data) do
      :ok ->
        case CodingAgent.Artifacts.register_in_dir(path, opts[:spill_dir]) do
          {:ok, uri} -> {path, uri}
          {:error, _} -> {path, nil}
        end

      {:error, _} ->
        {nil, nil}
    end
  end

  defp maybe_write_spill(nil, _data), do: {:error, :disabled}

  defp maybe_write_spill(path, data) when is_binary(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      case File.stat(path) do
        {:ok, %File.Stat{type: :regular}} -> :ok
        {:ok, _} -> {:error, :not_a_regular_file}
        {:error, :enoent} -> File.write(path, data)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp sha256_hex(bin) when is_binary(bin) do
    :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)
  end
end
