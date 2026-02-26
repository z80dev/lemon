defmodule Ai.PromptDiagnostics do
  @moduledoc """
  Lightweight, opt-in diagnostics for prompt size + token usage.

  This module is intentionally conservative about what it records:
  it captures **sizes, counts, and hashes** (no raw prompt text).

  Enable with:

      export LEMON_AI_PROMPT_DIAGNOSTICS=1

  Optionally set:

      export LEMON_AI_PROMPT_DIAGNOSTICS_LOG_LEVEL=info
      export LEMON_AI_PROMPT_DIAGNOSTICS_TOP_N=5

  Recorded introspection event type:
  - `:ai_llm_call`
  """

  alias Ai.Types.{AssistantMessage, Context, Model, StreamOptions}
  alias LemonCore.Introspection

  require Logger

  @default_top_n 5

  @doc "Return true if diagnostics are enabled via env var."
  @spec enabled?() :: boolean()
  def enabled? do
    System.get_env("LEMON_AI_PROMPT_DIAGNOSTICS")
    |> to_string()
    |> String.downcase()
    |> then(&(&1 in ["1", "true", "yes", "on"]))
  end

  @doc "Compute a conservative size breakdown for an LLM context."
  @spec stats(Context.t()) :: map()
  def stats(%Context{} = ctx) do
    system_prompt = ctx.system_prompt || ""
    system_prompt_bytes = byte_size(system_prompt)

    {messages_bytes, per_role_bytes, per_role_counts, largest_messages} =
      message_rollup(ctx.messages)

    {tools_bytes, tools_hash} = tools_bytes_and_hash(ctx.tools)

    total_bytes = system_prompt_bytes + messages_bytes + tools_bytes

    %{
      system_prompt_bytes: system_prompt_bytes,
      system_prompt_sha256: sha256_hex(system_prompt),
      message_count: length(ctx.messages),
      messages_bytes: messages_bytes,
      messages_bytes_by_role: per_role_bytes,
      messages_count_by_role: per_role_counts,
      largest_messages: largest_messages,
      tool_count: length(ctx.tools),
      tools_bytes: tools_bytes,
      tools_sha256: tools_hash,
      total_bytes: total_bytes,
      approx_input_tokens: approx_tokens_from_bytes(total_bytes)
    }
  end

  @doc """
  Record a combined prompt+usage snapshot for a completed LLM call.

  This records a single introspection event (`:ai_llm_call`) containing:
  - request sizing (bytes + hashes)
  - response usage (tokens, including cache read/write when available)
  """
  @spec record_llm_call(Model.t(), Context.t(), StreamOptions.t(), AssistantMessage.t()) :: :ok
  def record_llm_call(%Model{} = model, %Context{} = ctx, %StreamOptions{} = opts, %AssistantMessage{} = msg) do
    if enabled?() do
      prompt_stats = stats(ctx)
      usage_stats = usage_stats(msg)

      data =
        prompt_stats
        |> Map.merge(usage_stats)
        |> Map.merge(%{
          provider: to_string(model.provider),
          api: to_string(model.api),
          model: model.id,
          # helpful for debugging prompt caching on OpenAI-compatible endpoints
          prompt_cache_key: opts.session_id
        })

      record_introspection(data, opts)
      log_snapshot(data)
    end

    :ok
  end

  @doc "Record a combined prompt+usage snapshot for non-streaming calls."
  @spec record_complete_call(Model.t(), Context.t(), StreamOptions.t() | map(), AssistantMessage.t()) :: :ok
  def record_complete_call(%Model{} = model, %Context{} = ctx, opts, %AssistantMessage{} = msg) do
    stream_opts =
      case opts do
        %StreamOptions{} = so ->
          so

        m when is_map(m) ->
          allowed_keys = Map.keys(%StreamOptions{}) |> Enum.reject(&(&1 == :__struct__))
          struct(StreamOptions, Map.take(m, allowed_keys))

        _ ->
          %StreamOptions{}
      end

    record_llm_call(model, ctx, stream_opts, msg)
  end

  # --------------------------------------------------------------------------
  # Internal helpers
  # --------------------------------------------------------------------------

  defp usage_stats(%AssistantMessage{usage: nil, stop_reason: stop_reason, error_message: error}) do
    %{
      stop_reason: stop_reason,
      error_message: error,
      usage_present: false
    }
  end

  defp usage_stats(%AssistantMessage{usage: usage, stop_reason: stop_reason, error_message: error}) do
    %{
      stop_reason: stop_reason,
      error_message: error,
      usage_present: true,
      input_tokens: usage.input,
      output_tokens: usage.output,
      cache_read_tokens: usage.cache_read,
      cache_write_tokens: usage.cache_write,
      total_tokens: usage.total_tokens,
      total_input_tokens: usage.input + usage.cache_read + usage.cache_write
    }
  end

  defp record_introspection(data, %StreamOptions{} = opts) do
    headers = opts.headers || %{}

    Introspection.record(
      :ai_llm_call,
      data,
      engine: "ai",
      session_key: trace_header(headers, "x-lemon-session-key"),
      agent_id: trace_header(headers, "x-lemon-agent-id"),
      run_id: trace_header(headers, "x-lemon-run-id")
    )

    :ok
  end

  defp trace_header(headers, key) when is_map(headers) do
    case Map.get(headers, key) do
      "" -> nil
      nil -> nil
      v -> v
    end
  end

  defp log_snapshot(data) do
    # Keep the log line short-ish and non-sensitive.
    level =
      System.get_env("LEMON_AI_PROMPT_DIAGNOSTICS_LOG_LEVEL")
      |> to_string()
      |> String.downcase()
      |> case do
        "debug" -> :debug
        "warning" -> :warning
        "warn" -> :warning
        "error" -> :error
        _ -> :info
      end

    msg =
      "ai_llm_call " <>
        "model=#{data.model} provider=#{data.provider} " <>
        "bytes=#{data.total_bytes} (~#{data.approx_input_tokens} tok est) " <>
        "msgs=#{data.message_count} tools=#{data.tool_count} " <>
        "usage_in=#{Map.get(data, :total_input_tokens, "?")} " <>
        "usage_out=#{Map.get(data, :output_tokens, "?")} " <>
        "cache_read=#{Map.get(data, :cache_read_tokens, "?")} " <>
        "cache_write=#{Map.get(data, :cache_write_tokens, "?")} " <>
        "stop=#{inspect(data.stop_reason)}"

    Logger.log(level, msg)
  end

  defp tools_bytes_and_hash(tools) when is_list(tools) do
    # Tools are structs (not JSON-encodable by default), so we normalize into
    # plain maps. We hash using `term_to_binary/1` so map key ordering doesn't
    # impact the fingerprint.
    normalized = Enum.map(tools, &normalize_tool/1)

    hash =
      normalized
      |> :erlang.term_to_binary()
      |> sha256_hex()

    bytes =
      case Jason.encode(normalized) do
        {:ok, json} -> byte_size(json)
        _ -> byte_size(:erlang.term_to_binary(normalized))
      end

    {bytes, hash}
  end

  defp normalize_tool(%{name: name, description: desc, parameters: params}) do
    %{
      name: to_string(name),
      description: to_string(desc),
      parameters: params
    }
  end

  defp normalize_tool(other), do: %{tool: inspect(other, limit: 5_000)}

  defp message_rollup(messages) when is_list(messages) do
    {bytes, per_role_bytes, per_role_counts, sized} =
      Enum.with_index(messages)
      |> Enum.reduce({0, %{}, %{}, []}, fn {msg, idx}, {total, role_bytes, role_counts, acc} ->
        role = message_role(msg)
        msg_bytes = message_bytes(msg)

        role_bytes = Map.update(role_bytes, role, msg_bytes, &(&1 + msg_bytes))
        role_counts = Map.update(role_counts, role, 1, &(&1 + 1))

        {total + msg_bytes, role_bytes, role_counts, [{msg_bytes, idx, role} | acc]}
      end)

    top_n = top_n()

    largest_messages =
      sized
      |> Enum.sort_by(fn {b, _idx, _role} -> -b end)
      |> Enum.take(top_n)
      |> Enum.map(fn {b, idx, role} -> %{index: idx, role: role, bytes: b} end)

    {bytes, per_role_bytes, per_role_counts, largest_messages}
  end

  defp top_n do
    case Integer.parse(to_string(System.get_env("LEMON_AI_PROMPT_DIAGNOSTICS_TOP_N"))) do
      {n, _} when n > 0 and n < 50 -> n
      _ -> @default_top_n
    end
  end

  defp message_role(%{role: role}) when is_atom(role), do: role
  defp message_role(%{role: role}) when is_binary(role), do: role
  defp message_role(_), do: :unknown

  defp message_bytes(%Ai.Types.UserMessage{content: content}), do: content_bytes(content)
  defp message_bytes(%Ai.Types.ToolResultMessage{content: content}), do: content_bytes(content)
  defp message_bytes(%Ai.Types.AssistantMessage{content: content}), do: content_bytes(content)

  # Fallback for custom/unknown message types
  defp message_bytes(%{content: content}) when is_binary(content) or is_list(content),
    do: content_bytes(content)

  defp message_bytes(_), do: 0

  defp content_bytes(content) when is_binary(content), do: byte_size(content)

  defp content_bytes(content) when is_list(content) do
    Enum.reduce(content, 0, fn block, acc -> acc + content_block_bytes(block) end)
  end

  defp content_bytes(_), do: 0

  defp content_block_bytes(%Ai.Types.TextContent{text: text}), do: byte_size(text)
  defp content_block_bytes(%Ai.Types.ThinkingContent{thinking: thinking}), do: byte_size(thinking)
  defp content_block_bytes(%Ai.Types.ImageContent{data: data}), do: byte_size(data)

  defp content_block_bytes(%Ai.Types.ToolCall{name: name, id: id, arguments: args}) do
    args_bytes =
      case Jason.encode(args) do
        {:ok, json} -> byte_size(json)
        _ -> byte_size(inspect(args, limit: 50_000))
      end

    byte_size(to_string(name)) + byte_size(to_string(id)) + args_bytes
  end

  defp content_block_bytes(other) when is_map(other) do
    # Defensive fallback: avoid logging raw data, but account for some size.
    byte_size(inspect(other, limit: 5_000))
  end

  defp content_block_bytes(_), do: 0

  defp approx_tokens_from_bytes(bytes) when is_integer(bytes) and bytes >= 0 do
    # Very rough but directionally useful for regressions.
    # Most English text averages ~3-4 chars/token.
    div(bytes + 3, 4)
  end

  defp sha256_hex(data) when is_binary(data) do
    :crypto.hash(:sha256, data)
    |> Base.encode16(case: :lower)
  end
end
