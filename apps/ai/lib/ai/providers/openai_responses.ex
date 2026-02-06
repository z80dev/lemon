defmodule Ai.Providers.OpenAIResponses do
  @moduledoc """
  OpenAI Responses API provider.

  This provider implements the OpenAI Responses API which supports:
  - Built-in reasoning/thinking support
  - Prompt caching
  - Service tier selection (flex, auto, priority)
  - Streaming responses

  ## Configuration

  The provider uses the following environment variables:
  - `OPENAI_API_KEY` - API key for OpenAI
  - `PI_CACHE_RETENTION` - Set to "long" for 24h prompt cache retention

  ## Usage

      model = %Model{
        id: "o1-preview",
        api: :openai_responses,
        provider: :openai,
        base_url: "https://api.openai.com/v1",
        reasoning: true
      }

      context = Context.new(
        system_prompt: "You are a helpful assistant.",
        messages: [%UserMessage{content: "Hello!"}]
      )

      {:ok, stream} = OpenAIResponses.stream(model, context, %StreamOptions{})
  """

  @behaviour Ai.Provider

  alias Ai.Types.{
    AssistantMessage,
    Context,
    Cost,
    Model,
    StreamOptions,
    Usage
  }

  alias Ai.EventStream
  alias Ai.Providers.OpenAIResponsesShared

  require Logger

  # Providers that use OpenAI-style tool call IDs
  @tool_call_providers MapSet.new([:openai, :"openai-codex", :opencode])

  # ============================================================================
  # Provider Behaviour
  # ============================================================================

  @impl true
  def api_id, do: :openai_responses

  @impl true
  def provider_id, do: :openai

  @impl true
  def get_env_api_key do
    System.get_env("OPENAI_API_KEY")
  end

  @impl true
  def stream(%Model{} = model, %Context{} = context, %StreamOptions{} = opts) do
    owner = self()
    stream_timeout = opts.stream_timeout || 300_000

    {:ok, stream} =
      EventStream.start_link(
        owner: owner,
        max_queue: 10_000,
        timeout: stream_timeout
      )

    # Start streaming task under supervision
    {:ok, task_pid} =
      Task.Supervisor.start_child(Ai.StreamTaskSupervisor, fn ->
        output = initial_output(model)

        try do
          api_key = opts.api_key || get_env_api_key()

          if !api_key || api_key == "" do
            raise "OpenAI API key is required. Set OPENAI_API_KEY environment variable or pass it as an argument."
          end

          # Build request
          {url, headers, body} = build_request(model, context, opts, api_key)

          EventStream.push_async(stream, {:start, output})

          # Make streaming request
          case stream_request(url, headers, body) do
            {:ok, event_stream} ->
              # Process stream events
              case OpenAIResponsesShared.process_stream(
                     event_stream,
                     output,
                     stream,
                     model,
                     %{
                       service_tier: parse_service_tier(opts),
                       apply_service_tier_pricing:
                         &OpenAIResponsesShared.apply_service_tier_pricing/2
                     }
                   ) do
                {:ok, final_output} ->
                  EventStream.complete(stream, final_output)

                {:error, reason} ->
                  output = %{output | stop_reason: :error, error_message: reason}
                  EventStream.error(stream, output)
              end

            {:error, reason} ->
              output = %{output | stop_reason: :error, error_message: reason}
              EventStream.error(stream, output)
          end
        rescue
          e ->
            output = %{output | stop_reason: :error, error_message: Exception.message(e)}
            EventStream.error(stream, output)
        end
      end)

    # Attach task to stream for lifecycle management
    EventStream.attach_task(stream, task_pid)

    {:ok, stream}
  end

  # ============================================================================
  # Request Building
  # ============================================================================

  defp build_request(model, context, opts, api_key) do
    messages = OpenAIResponsesShared.convert_messages(model, context, @tool_call_providers)

    # Build parameters
    params = %{
      "model" => model.id,
      "input" => messages,
      "stream" => true
    }

    # Add optional parameters
    params = maybe_add_param(params, "prompt_cache_key", opts.session_id)

    params =
      maybe_add_param(params, "prompt_cache_retention", get_cache_retention(model.base_url))

    params = maybe_add_param(params, "max_output_tokens", opts.max_tokens)
    params = maybe_add_param(params, "temperature", opts.temperature)
    params = maybe_add_service_tier(params, opts)

    # Add tools if present
    params =
      if context.tools && context.tools != [] do
        Map.put(params, "tools", OpenAIResponsesShared.convert_tools(context.tools))
      else
        params
      end

    # Add reasoning configuration
    params = add_reasoning_config(params, model, opts, messages)

    # Build URL and headers
    url = "#{normalize_base_url(model.base_url)}/responses"
    headers = build_headers(model, context, opts, api_key)

    {url, headers, params}
  end

  defp normalize_base_url(url) do
    url
    |> String.trim_trailing("/")
    |> then(fn u ->
      if String.ends_with?(u, "/v1"), do: u, else: "#{u}/v1"
    end)
  end

  defp build_headers(model, context, opts, api_key) do
    base_headers = %{
      "Authorization" => "Bearer #{api_key}",
      "Content-Type" => "application/json",
      "Accept" => "text/event-stream"
    }

    # Add model-specific headers
    headers = Map.merge(base_headers, model.headers || %{})

    # Add GitHub Copilot specific headers if applicable
    headers =
      if model.provider in [:github_copilot, :"github-copilot", "github-copilot"] do
        messages = context.messages || []
        last_message = List.last(messages)
        is_agent_call = last_message && last_message.role != :user

        copilot_headers = %{
          "X-Initiator" => if(is_agent_call, do: "agent", else: "user"),
          "Openai-Intent" => "conversation-edits"
        }

        # Check for images
        has_images =
          Enum.any?(messages, fn msg ->
            case msg do
              %{content: content} when is_list(content) ->
                Enum.any?(content, &(&1.type == :image))

              _ ->
                false
            end
          end)

        copilot_headers =
          if has_images do
            Map.put(copilot_headers, "Copilot-Vision-Request", "true")
          else
            copilot_headers
          end

        Map.merge(headers, copilot_headers)
      else
        headers
      end

    # Add user-provided headers last
    Map.merge(headers, opts.headers || %{})
  end

  defp add_reasoning_config(params, model, opts, _messages) do
    if model.reasoning do
      reasoning_effort = opts.reasoning
      # Map :xhigh to "xhigh" if supported, otherwise use opts as-is
      reasoning_summary = Map.get(opts.thinking_budgets || %{}, :summary, "auto")

      if reasoning_effort do
        params
        |> Map.put("reasoning", %{
          "effort" => Atom.to_string(reasoning_effort),
          "summary" => reasoning_summary
        })
        |> Map.put("include", ["reasoning.encrypted_content"])
      else
        # GPT-5 workaround for disabling reasoning
        model_name = String.downcase(model.name || "")
        model_id = String.downcase(model.id || "")

        if String.starts_with?(model_name, "gpt-5") or String.starts_with?(model_id, "gpt-5") do
          juice_message = %{
            "role" => "developer",
            "content" => [%{"type" => "input_text", "text" => "# Juice: 0 !important"}]
          }

          Map.update(params, "input", [juice_message], &(&1 ++ [juice_message]))
        else
          params
        end
      end
    else
      params
    end
  end

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, key, value), do: Map.put(params, key, value)

  defp maybe_add_service_tier(params, opts) do
    case Map.get(opts.thinking_budgets || %{}, :service_tier) do
      nil -> params
      tier -> Map.put(params, "service_tier", tier)
    end
  end

  defp parse_service_tier(opts) do
    Map.get(opts.thinking_budgets || %{}, :service_tier)
  end

  defp get_cache_retention(base_url) do
    retention = System.get_env("PI_CACHE_RETENTION")

    if retention == "long" && String.contains?(base_url, "api.openai.com") do
      "24h"
    else
      nil
    end
  end

  # ============================================================================
  # HTTP Streaming
  # ============================================================================

  defp stream_request(url, headers, body) do
    # Use Finch or Req for HTTP streaming
    # This is a simplified implementation - in production you'd want proper
    # streaming with backpressure handling

    headers_list = Enum.map(headers, fn {k, v} -> {k, v} end)

    case Req.post(url,
           json: body,
           headers: headers_list,
           into: :self,
           receive_timeout: 300_000
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        {:ok, receive_sse_events()}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  defp receive_sse_events do
    Stream.resource(
      fn -> %{buffer: ""} end,
      fn state ->
        receive do
          message ->
            case normalize_sse_message(message) do
              {:data, chunk} ->
                {events, new_buffer} = parse_sse_chunk(state.buffer <> chunk)
                {events, %{state | buffer: new_buffer}}

              :done ->
                {:halt, state}

              {:error, reason} ->
                throw({:stream_error, reason})

              :ignore ->
                {[], state}
            end
        after
          300_000 ->
            {:halt, state}
        end
      end,
      fn _state -> :ok end
    )
  end

  defp normalize_sse_message(message) do
    case message do
      {:data, data} when is_binary(data) ->
        {:data, data}

      {_, {:data, data}} when is_binary(data) ->
        {:data, data}

      {:done, _} ->
        :done

      {_, :done} ->
        :done

      {_, {:done, _}} ->
        :done

      {:error, reason} ->
        {:error, reason}

      {_, {:error, reason}} ->
        {:error, reason}

      _ ->
        :ignore
    end
  end

  defp parse_sse_chunk(buffer) do
    # Split by double newlines (SSE event delimiter)
    parts = String.split(buffer, "\n\n")

    # Last part might be incomplete
    {complete_parts, [incomplete]} =
      if length(parts) > 1 do
        Enum.split(parts, -1)
      else
        {[], parts}
      end

    events =
      complete_parts
      |> Enum.flat_map(fn part ->
        part
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "data:"))
        |> Enum.map(&String.trim_leading(&1, "data:"))
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" || &1 == "[DONE]"))
        |> Enum.flat_map(fn data ->
          case Jason.decode(data) do
            {:ok, event} -> [event]
            _ -> []
          end
        end)
      end)

    {events, incomplete}
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp initial_output(model) do
    %AssistantMessage{
      role: :assistant,
      content: [],
      api: :openai_responses,
      provider: model.provider,
      model: model.id,
      usage: %Usage{
        input: 0,
        output: 0,
        cache_read: 0,
        cache_write: 0,
        total_tokens: 0,
        cost: %Cost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0}
      },
      stop_reason: :stop,
      timestamp: System.system_time(:millisecond)
    }
  end
end
