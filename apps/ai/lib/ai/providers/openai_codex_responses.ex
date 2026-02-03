defmodule Ai.Providers.OpenAICodexResponses do
  @moduledoc """
  OpenAI Codex Responses API provider (ChatGPT Plus/Pro).

  This provider implements the OpenAI Codex API available to ChatGPT Plus and Pro
  subscribers. It uses a different authentication mechanism (JWT tokens) and
  endpoint than the standard OpenAI API.

  ## Key Differences from Standard OpenAI Responses

  - Uses `chatgpt.com/backend-api/codex/responses` endpoint
  - Requires ChatGPT JWT token (not standard API key)
  - Extracts account ID from JWT token
  - Has different rate limiting and quota behavior
  - Supports text verbosity control
  - Uses slightly different event mapping

  ## Configuration

  The provider requires a ChatGPT JWT token, which can be obtained from
  the ChatGPT web interface. Set it via:
  - `OPENAI_CODEX_API_KEY` environment variable
  - `api_key` option in StreamOptions

  ## Usage

      model = %Model{
        id: "gpt-5.2",
        api: :openai_codex_responses,
        provider: :"openai-codex",
        reasoning: true
      }

      context = Context.new(
        system_prompt: "You are a coding assistant.",
        messages: [%UserMessage{content: "Write a function..."}]
      )

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{})
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

  # ============================================================================
  # Configuration
  # ============================================================================

  @codex_url "https://chatgpt.com/backend-api/codex/responses"
  @jwt_claim_path "https://api.openai.com/auth"
  @max_retries 3
  @base_delay_ms 1000

  # Providers that use OpenAI-style tool call IDs
  @tool_call_providers MapSet.new([:openai, :"openai-codex", :opencode])

  @codex_response_statuses MapSet.new([
                             "completed",
                             "incomplete",
                             "failed",
                             "cancelled",
                             "queued",
                             "in_progress"
                           ])

  # ============================================================================
  # Provider Behaviour
  # ============================================================================

  @impl true
  def api_id, do: :openai_codex_responses

  @impl true
  def provider_id, do: :"openai-codex"

  @impl true
  def get_env_api_key do
    System.get_env("OPENAI_CODEX_API_KEY") || System.get_env("CHATGPT_TOKEN")
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

    {:ok, task_pid} =
      Task.Supervisor.start_child(Ai.StreamTaskSupervisor, fn ->
        output = initial_output(model)

        try do
          api_key = opts.api_key || get_env_api_key()

          if !api_key || api_key == "" do
            raise "ChatGPT token is required. Set OPENAI_CODEX_API_KEY or CHATGPT_TOKEN environment variable."
          end

          # Extract account ID from JWT
          account_id = extract_account_id(api_key)

          # Build request
          body = build_request_body(model, context, opts)
          headers = build_headers(model, opts, account_id, api_key)

          EventStream.push_async(stream, {:start, output})

          # Make streaming request with retries
          case stream_with_retries(body, headers, @max_retries) do
            {:ok, event_stream} ->
              # Map codex events to standard OpenAI Responses events
              mapped_events = map_codex_events(event_stream)

              case OpenAIResponsesShared.process_stream(mapped_events, output, stream, model) do
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

    EventStream.attach_task(stream, task_pid)

    {:ok, stream}
  end

  # ============================================================================
  # Request Building
  # ============================================================================

  defp build_request_body(model, context, opts) do
    # System prompt goes in instructions, not in messages
    messages =
      OpenAIResponsesShared.convert_messages(model, context, @tool_call_providers, %{
        include_system_prompt: false
      })

    body = %{
      "model" => model.id,
      "store" => false,
      "stream" => true,
      "instructions" => context.system_prompt,
      "input" => messages,
      "text" => %{"verbosity" => get_text_verbosity(opts)},
      "include" => ["reasoning.encrypted_content"],
      "prompt_cache_key" => opts.session_id,
      "tool_choice" => "auto",
      "parallel_tool_calls" => true
    }

    # Add temperature if specified
    body =
      if opts.temperature do
        Map.put(body, "temperature", opts.temperature)
      else
        body
      end

    # Add tools if present
    body =
      if context.tools && context.tools != [] do
        Map.put(body, "tools", OpenAIResponsesShared.convert_tools(context.tools, %{strict: nil}))
      else
        body
      end

    # Add reasoning configuration
    body =
      if opts.reasoning do
        effort = clamp_reasoning_effort(model.id, opts.reasoning)
        summary = Map.get(opts.thinking_budgets || %{}, :summary, "auto")

        Map.put(body, "reasoning", %{
          "effort" => Atom.to_string(effort),
          "summary" => summary
        })
      else
        body
      end

    body
  end

  defp get_text_verbosity(opts) do
    Map.get(opts.thinking_budgets || %{}, :text_verbosity, "medium")
  end

  defp clamp_reasoning_effort(model_id, effort) do
    # Extract base model ID
    id =
      if String.contains?(model_id, "/") do
        model_id |> String.split("/") |> List.last()
      else
        model_id
      end

    cond do
      String.starts_with?(id, "gpt-5.2") && effort == :minimal -> :low
      id == "gpt-5.1" && effort == :xhigh -> :high
      id == "gpt-5.1-codex-mini" -> if effort in [:high, :xhigh], do: :high, else: :medium
      true -> effort
    end
  end

  defp build_headers(model, opts, account_id, token) do
    # Get OS info for user agent
    {os_name, os_version} = get_os_info()
    arch = :erlang.system_info(:system_architecture) |> to_string()
    user_agent = "pi (#{os_name} #{os_version}; #{arch})"

    base_headers = %{
      "Authorization" => "Bearer #{token}",
      "chatgpt-account-id" => account_id,
      "OpenAI-Beta" => "responses=experimental",
      "originator" => "pi",
      "User-Agent" => user_agent,
      "Accept" => "text/event-stream",
      "Content-Type" => "application/json"
    }

    # Add model headers
    headers = Map.merge(base_headers, model.headers || %{})

    # Add session ID if present
    headers =
      if opts.session_id do
        Map.put(headers, "session_id", opts.session_id)
      else
        headers
      end

    # Add user-provided headers
    Map.merge(headers, opts.headers || %{})
  end

  defp get_os_info do
    case :os.type() do
      {:unix, :darwin} -> {"darwin", get_darwin_version()}
      {:unix, :linux} -> {"linux", get_linux_version()}
      {:win32, _} -> {"win32", ""}
      {family, name} -> {to_string(family), to_string(name)}
    end
  end

  defp get_darwin_version do
    case System.cmd("sw_vers", ["-productVersion"]) do
      {version, 0} -> String.trim(version)
      _ -> ""
    end
  rescue
    _ -> ""
  end

  defp get_linux_version do
    case File.read("/etc/os-release") do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.find_value("", fn line ->
          case String.split(line, "=") do
            ["VERSION_ID", version] -> String.trim(version, "\"")
            _ -> nil
          end
        end)

      _ ->
        ""
    end
  end

  # ============================================================================
  # Authentication
  # ============================================================================

  defp extract_account_id(token) do
    parts = String.split(token, ".")

    if length(parts) != 3 do
      raise "Invalid JWT token format"
    end

    [_header, payload, _signature] = parts

    # Decode base64 payload (add padding if needed)
    padded = pad_base64(payload)

    case Base.decode64(padded) do
      {:ok, decoded} ->
        case Jason.decode(decoded) do
          {:ok, claims} ->
            case get_in(claims, [@jwt_claim_path, "chatgpt_account_id"]) do
              nil -> raise "No account ID found in token"
              account_id -> account_id
            end

          _ ->
            raise "Failed to parse JWT claims"
        end

      _ ->
        raise "Failed to decode JWT payload"
    end
  end

  defp pad_base64(str) do
    case rem(String.length(str), 4) do
      0 -> str
      2 -> str <> "=="
      3 -> str <> "="
      _ -> str
    end
  end

  # ============================================================================
  # HTTP Streaming with Retries
  # ============================================================================

  defp stream_with_retries(body, headers, retries_left) do
    headers_list = Enum.map(headers, fn {k, v} -> {k, v} end)

    case Req.post(@codex_url,
           json: body,
           headers: headers_list,
           into: :self,
           receive_timeout: 300_000
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        {:ok, receive_sse_events()}

      {:ok, %Req.Response{status: status, body: error_body}} when retries_left > 0 ->
        error_text = normalize_error_body(error_body)

        if retryable_error?(status, error_text) do
          delay = @base_delay_ms * :math.pow(2, @max_retries - retries_left) |> round()
          Process.sleep(delay)
          stream_with_retries(body, headers, retries_left - 1)
        else
          {:error, parse_error_response(status, error_text)}
        end

      {:ok, %Req.Response{status: status, body: error_body}} ->
        error_text = normalize_error_body(error_body)
        {:error, parse_error_response(status, error_text)}

      {:error, reason} when retries_left > 0 ->
        error_msg = inspect(reason)

        if not String.contains?(error_msg, "usage limit") do
          delay = @base_delay_ms * :math.pow(2, @max_retries - retries_left) |> round()
          Process.sleep(delay)
          stream_with_retries(body, headers, retries_left - 1)
        else
          {:error, error_msg}
        end

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  defp retryable_error?(status, error_text) do
    status in [429, 500, 502, 503, 504] ||
      Regex.match?(
        ~r/rate.?limit|overloaded|service.?unavailable|upstream.?connect|connection.?refused/i,
        error_text
      )
  end

  defp parse_error_response(status, raw) do
    case Jason.decode(raw) do
      {:ok, %{"error" => error}} ->
        code = error["code"] || error["type"] || ""

        friendly_message =
          if Regex.match?(~r/usage_limit_reached|usage_not_included|rate_limit_exceeded/i, code) ||
               status == 429 do
            plan = if error["plan_type"], do: " (#{String.downcase(error["plan_type"])} plan)", else: ""

            resets_at = error["resets_at"]

            when_str =
              if resets_at do
                now = System.system_time(:millisecond)
                mins = max(0, round((resets_at * 1000 - now) / 60_000))
                " Try again in ~#{mins} min."
              else
                ""
              end

            "You have hit your ChatGPT usage limit#{plan}.#{when_str}"
          else
            nil
          end

        friendly_message || error["message"] || "HTTP #{status}: #{raw}"

      _ ->
        "HTTP #{status}: #{raw}"
    end
  end

  defp normalize_error_body(body) when is_binary(body), do: body

  defp normalize_error_body(%Req.Response.Async{} = async) do
    collect_async_body(async, "")
  end

  defp normalize_error_body(body) when is_map(body), do: Jason.encode!(body)

  defp normalize_error_body(other), do: inspect(other)

  defp collect_async_body(%Req.Response.Async{ref: ref, pid: pid}, acc) do
    receive do
      {^ref, {:data, chunk}} ->
        collect_async_body(%Req.Response.Async{ref: ref, pid: pid}, acc <> chunk)

      {^ref, :done} ->
        acc

      {:DOWN, ^ref, :process, ^pid, _reason} ->
        acc
    after
      1_000 ->
        acc
    end
  end

  defp receive_sse_events do
    Stream.resource(
      fn -> %{buffer: ""} end,
      fn state ->
        receive do
          {:data, chunk} ->
            {events, new_buffer} = parse_sse_chunk(state.buffer <> chunk)
            {events, %{state | buffer: new_buffer}}

          {:done, _} ->
            {:halt, state}

          {:error, reason} ->
            throw({:stream_error, reason})
        after
          300_000 ->
            {:halt, state}
        end
      end,
      fn _state -> :ok end
    )
  end

  defp parse_sse_chunk(buffer) do
    parts = String.split(buffer, "\n\n")

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
  # Event Mapping
  # ============================================================================

  defp map_codex_events(events) do
    Stream.flat_map(events, fn event ->
      type = event["type"]

      cond do
        type == "error" ->
          code = event["code"] || ""
          message = event["message"] || ""
          raise "Codex error: #{message || code || inspect(event)}"

        type == "response.failed" ->
          message = get_in(event, ["response", "error", "message"])
          raise message || "Codex response failed"

        type in ["response.done", "response.completed"] ->
          response = event["response"]

          normalized_response =
            if response do
              status = normalize_codex_status(response["status"])
              Map.put(response, "status", status)
            else
              response
            end

          [Map.merge(event, %{"type" => "response.completed", "response" => normalized_response})]

        true ->
          [event]
      end
    end)
  end

  defp normalize_codex_status(status) when is_binary(status) do
    if MapSet.member?(@codex_response_statuses, status), do: status, else: nil
  end

  defp normalize_codex_status(_), do: nil

  # ============================================================================
  # Helpers
  # ============================================================================

  defp initial_output(model) do
    %AssistantMessage{
      role: :assistant,
      content: [],
      api: :openai_codex_responses,
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
