defmodule LemonAi.Providers.OpenAICodexResponses do
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
  - Supports reasoning summaries, prompt caching and service tiers
  - Omits sampling parameters and output caps rejected by the Codex endpoint

  ## Configuration

  Pass the ChatGPT OAuth access token via `api_key` in `StreamOptions`, or set
  `OPENAI_CODEX_API_KEY` / `CHATGPT_TOKEN`. Lemon's runtime resolves configured
  encrypted credentials before invoking the provider; this module neither reads
  the secret store nor refreshes credentials.

  ## Usage

      model = %Model{
        id: "gpt-6-sol",
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

  @behaviour LemonAi.Provider

  alias LemonAi.Types.{
    Context,
    Model,
    StreamOptions
  }

  alias LemonAi.EventStream
  alias LemonAi.Providers.OpenAIResponsesShared
  alias LemonAi.Providers.RetryHelper
  alias LemonAi.Providers.SSEParser
  alias LemonAi.Providers.StreamingHelper
  import LemonAi.Providers.AssistantMessageHelper

  # ============================================================================
  # Configuration
  # ============================================================================

  @codex_url "https://chatgpt.com/backend-api/codex/responses"
  @jwt_claim_path "https://api.openai.com/auth"
  @affinity_headers ["session_id", "conversation_id", "x-client-request-id"]
  @client_version "0.159.0"
  @controlled_headers ["version" | @affinity_headers]

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
  @default_instructions "You are a coding assistant."

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
    StreamingHelper.start_streaming(model, context, opts, &do_stream/4)
  end

  defp do_stream(stream, model, context, opts) do
    opts = %{opts | session_id: OpenAIResponsesShared.normalize_prompt_cache_key(opts.session_id)}
    output = init_assistant_message(model, api_override: :openai_codex_responses)

    try do
      api_key = opts.api_key || get_env_api_key()

      if !api_key || api_key == "" do
        raise "ChatGPT token is required. Set OPENAI_CODEX_API_KEY / CHATGPT_TOKEN, or configure an OAuth api_key_secret."
      end

      # Extract account ID from JWT
      account_id = extract_account_id(api_key)

      # Build request
      body = build_request_body(model, context, opts)

      if is_function(opts.on_payload, 2) do
        opts.on_payload.(body, %{
          provider: :"openai-codex",
          model: model.id,
          session_id: opts.session_id
        })
      end

      headers = build_headers(model, opts, account_id, api_key)

      EventStream.push_async(stream, {:start, output})

      # Make streaming request with retries
      case stream_with_retries(
             responses_url(model.base_url),
             body,
             headers,
             RetryHelper.policy(opts),
             0
           ) do
        {:ok, event_stream} ->
          # Map codex events to standard OpenAI Responses events
          mapped_events = event_stream |> observe_usage(model, opts) |> map_codex_events()

          case OpenAIResponsesShared.process_stream(mapped_events, output, stream, model, %{
                 service_tier: Map.get(opts.thinking_budgets || %{}, :service_tier),
                 apply_service_tier_pricing: fn usage, tier ->
                   OpenAIResponsesShared.apply_service_tier_pricing(
                     usage,
                     tier,
                     model.service_tier_cost
                   )
                 end
               }) do
            {:ok, final_output} ->
              EventStream.complete(stream, final_output)

            {:error, reason} ->
              output = error_assistant_message(output, reason)
              EventStream.error(stream, output)
          end

        {:error, reason, retry_after_ms} ->
          output = error_assistant_message(output, reason, retry_after_ms)

          EventStream.error(stream, output)
      end
    rescue
      e ->
        output = error_assistant_message(output, e)
        EventStream.error(stream, output)
    end
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
      "instructions" => normalize_instructions(context.system_prompt),
      "input" => messages,
      "text" => %{"verbosity" => get_text_verbosity(opts)},
      "include" => ["reasoning.encrypted_content"],
      "prompt_cache_key" => opts.session_id,
      "tool_choice" => "auto",
      "parallel_tool_calls" => true
    }

    # Add tools if present
    body =
      if context.tools && context.tools != [] do
        Map.put(
          body,
          "tools",
          OpenAIResponsesShared.convert_tools(context.tools, %{strict: false})
        )
      else
        body
      end

    # Add reasoning configuration
    body =
      if opts.reasoning do
        effort = LemonAi.Models.reasoning_effort_for(model, opts.reasoning)
        summary = Map.get(opts.thinking_budgets || %{}, :summary, "auto")

        Map.put(body, "reasoning", %{
          "effort" => Atom.to_string(effort),
          "summary" => summary
        })
      else
        body
      end

    body =
      case Map.get(opts.thinking_budgets || %{}, :service_tier) do
        nil -> body
        tier -> Map.put(body, "service_tier", tier)
      end

    body =
      if opts.tool_choice do
        Map.put(body, "tool_choice", opts.tool_choice)
      else
        body
      end

    OpenAIResponsesShared.clamp_function_call_outputs(body)
  end

  defp get_text_verbosity(opts) do
    Map.get(opts.thinking_budgets || %{}, :text_verbosity, "medium")
  end

  defp normalize_instructions(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "", do: @default_instructions, else: prompt
  end

  defp normalize_instructions(_), do: @default_instructions

  defp build_headers(model, opts, account_id, token) do
    # Get OS info for user agent
    {os_name, os_version} = get_os_info()
    arch = :erlang.system_info(:system_architecture) |> to_string()
    user_agent = "pi/#{@client_version} (#{os_name} #{os_version}; #{arch})"

    base_headers = %{
      "Authorization" => "Bearer #{token}",
      "chatgpt-account-id" => account_id,
      "OpenAI-Beta" => "responses=experimental",
      "originator" => "pi",
      "version" => @client_version,
      "User-Agent" => user_agent,
      "Accept" => "text/event-stream",
      "Content-Type" => "application/json"
    }

    headers =
      base_headers
      |> Map.merge(model.headers || %{})
      |> Map.merge(opts.headers || %{})
      |> Map.reject(fn {key, _} -> String.downcase(to_string(key)) in @controlled_headers end)
      |> Map.put("version", @client_version)

    # The wire cache key and routing identity must agree across every turn.
    Enum.reduce(@affinity_headers, headers, fn key, headers ->
      if opts.session_id do
        Map.put(headers, key, opts.session_id)
      else
        Map.delete(headers, key)
      end
    end)
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

    case Base.url_decode64(payload, padding: false) do
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

  # ============================================================================
  # HTTP Streaming with Retries
  # ============================================================================

  defp responses_url(base_url)
       when base_url in [nil, "", "https://chatgpt.com", "https://chatgpt.com/"],
       do: @codex_url

  defp responses_url(base_url) do
    base_url = String.trim_trailing(base_url, "/")

    cond do
      String.ends_with?(base_url, "/codex/responses") -> base_url
      String.ends_with?(base_url, "/codex") -> base_url <> "/responses"
      true -> base_url <> "/codex/responses"
    end
  end

  defp stream_with_retries(url, body, headers, policy, attempt) do
    headers_list = Enum.map(headers, fn {k, v} -> {k, v} end)
    retry_allowed? = RetryHelper.retry_allowed?(attempt, policy)

    case Req.post(url,
           json: body,
           headers: headers_list,
           into: :self,
           retry: false,
           receive_timeout: 300_000
         ) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        {:ok, SSEParser.events(response)}

      {:ok, %Req.Response{status: status, body: error_body, headers: response_headers}} ->
        error_text = normalize_error_body(error_body)

        retry_delay =
          if retry_allowed? and RetryHelper.retryable_http_error?(status, error_text) do
            RetryHelper.http_retry_delay_ms(
              attempt,
              response_headers,
              policy,
              {:http_error, status, error_text}
            )
          else
            :give_up
          end

        case retry_delay do
          :give_up ->
            {:error, parse_error_response(status, error_text),
             RetryHelper.retry_after_ms(response_headers)}

          delay_ms ->
            RetryHelper.sleep(delay_ms)
            stream_with_retries(url, body, headers, policy, attempt + 1)
        end

      {:error, reason} ->
        cond do
          retry_allowed? and RetryHelper.retryable_transport_error?(reason) ->
            RetryHelper.sleep(RetryHelper.backoff_delay_ms(attempt, policy))
            stream_with_retries(url, body, headers, policy, attempt + 1)

          true ->
            {:error, reason, nil}
        end
    end
  end

  defp parse_error_response(status, raw) do
    case Jason.decode(raw) do
      {:ok, %{"error" => error}} when is_map(error) ->
        code = error["code"] || error["type"] || ""

        friendly_message =
          if Regex.match?(~r/usage_limit_reached|usage_not_included/i, code) do
            plan =
              if error["plan_type"],
                do: " (#{String.downcase(error["plan_type"])} plan)",
                else: ""

            resets_at = error["resets_at"]

            when_str =
              if resets_at do
                now = System.system_time(:millisecond)
                mins = max(0, round((resets_at * 1000 - now) / 60_000))
                " Try again in ~#{mins} min."
              else
                ""
              end

            "HTTP #{status}: #{code}: You have hit your ChatGPT usage limit#{plan}.#{when_str}"
          else
            nil
          end

        friendly_message || "HTTP #{status}: #{code}: #{error["message"] || raw}"

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

  # ============================================================================
  # Event Mapping
  # ============================================================================

  defp observe_usage(events, model, opts) do
    if is_function(opts.on_usage, 2) do
      metadata = %{provider: :"openai-codex", model: model.id, session_id: opts.session_id}

      Stream.transform(events, false, fn
        %{"type" => type, "response" => %{"usage" => usage}} = event, false
        when type in [
               "response.completed",
               "response.incomplete",
               "response.done",
               "response.failed"
             ] and is_map(usage) ->
          opts.on_usage.(usage, metadata)
          {[event], true}

        event, seen ->
          {[event], seen}
      end)
    else
      events
    end
  end

  defp map_codex_events(events) do
    Stream.flat_map(events, fn event ->
      type = event["type"]

      cond do
        type == "error" ->
          code =
            event["code"] || get_in(event, ["error", "code"]) || get_in(event, ["error", "type"])

          message = event["message"] || get_in(event, ["error", "message"])

          detail =
            cond do
              is_binary(message) and String.trim(message) != "" ->
                message

              is_binary(code) and String.trim(code) != "" ->
                code

              true ->
                inspect(event, limit: 500)
            end

          raise "Codex error: #{detail}"

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
end
