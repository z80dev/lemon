defmodule Ai.Providers.AzureOpenAIResponses do
  @moduledoc """
  Azure OpenAI Responses API provider.

  This provider implements the Azure-hosted OpenAI Responses API with support
  for reasoning models and prompt caching.

  ## Key Differences from Standard OpenAI Responses

  - Uses Azure-specific endpoint format
  - Requires Azure API key and resource configuration
  - Supports deployment name mapping for model IDs
  - Uses Azure API versioning

  ## Configuration

  Azure-specific settings should be resolved through canonical Lemon config
  before requests reach this provider. Stream options still take precedence for
  per-request overrides.

  ## Usage

      model = %Model{
        id: "gpt-4o",
        api: :azure_openai_responses,
        provider: :"azure-openai-responses",
        base_url: "https://myresource.openai.azure.com/openai/v1",
        reasoning: false
      }

      context = Context.new(
        system_prompt: "You are a helpful assistant.",
        messages: [%UserMessage{content: "Hello!"}]
      )

      opts = %StreamOptions{
        thinking_budgets: %{
          azure_deployment_name: "my-deployment",
          azure_api_version: "2024-12-01-preview"
        }
      }

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)
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
  alias Ai.Providers.SSEParser
  import Ai.Providers.AssistantMessageHelper
  alias LemonCore.Secrets

  require Logger

  # ============================================================================
  # Configuration
  # ============================================================================

  @default_api_version "v1"

  # Providers that use OpenAI-style tool call IDs
  @tool_call_providers MapSet.new([
                         :openai,
                         :"openai-codex",
                         :opencode,
                         :"azure-openai-responses"
                       ])

  # ============================================================================
  # Provider Behaviour
  # ============================================================================

  @impl true
  def api_id, do: :azure_openai_responses

  @impl true
  def provider_id, do: :"azure-openai-responses"

  @impl true
  def get_env_api_key do
    Secrets.fetch_value("AZURE_OPENAI_API_KEY")
  end

  @impl true
  def stream(%Model{} = model, %Context{} = context, %StreamOptions{} = opts) do
    Ai.Providers.StreamingHelper.start_streaming(model, context, opts, &do_stream/4)
  end

  defp do_stream(stream, model, context, opts) do
    # Resolve provider config from canonical config + env + secrets
    resolved =
      try do
        LemonCore.ProviderConfigResolver.resolve_for_provider(:azure_openai_responses, opts)
      rescue
        e ->
          Logger.warning(
            "Failed to resolve Azure OpenAI provider config: #{Exception.message(e)}"
          )

          %{}
      end

    deployment_name = resolve_deployment_name(model, opts, resolved)
    output = init_assistant_message(model, api_override: :azure_openai_responses)

    try do
      api_key = opts.api_key || Map.get(resolved, :api_key)

      if !api_key || api_key == "" do
        raise "Azure OpenAI API key is required. Configure providers.azure_openai_responses or pass it in stream options."
      end

      # Build request
      {url, headers, body} =
        build_request(model, context, opts, api_key, deployment_name, resolved)

      EventStream.push_async(stream, {:start, output})

      # Make streaming request
      case stream_request(url, headers, body) do
        {:ok, event_stream} ->
          case OpenAIResponsesShared.process_stream(event_stream, output, stream, model) do
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
  end

  # ============================================================================
  # Deployment Name Resolution
  # ============================================================================

  defp resolve_deployment_name(model, opts, resolved) do
    # Check options first
    azure_opts = opts.thinking_budgets || %{}

    case Map.get(azure_opts, :azure_deployment_name) do
      nil ->
        # Try resolved config deployment map, then per-request override map.
        resolved_map = Map.get(resolved, :deployment_name_map) || %{}
        override_map = Map.get(azure_opts, :azure_deployment_name_map) || %{}
        deployment_map = Map.merge(resolved_map, override_map)

        case Map.get(deployment_map, model.id) do
          nil -> model.id
          deployment -> deployment
        end

      deployment ->
        deployment
    end
  end

  # ============================================================================
  # Azure Configuration Resolution
  # ============================================================================

  defp resolve_azure_config(model, opts, resolved) do
    azure_opts = opts.thinking_budgets || %{}

    api_version =
      Map.get(azure_opts, :azure_api_version) ||
        Map.get(resolved, :api_version) ||
        @default_api_version

    base_url =
      case Map.get(azure_opts, :azure_base_url) do
        nil ->
          case Map.get(resolved, :base_url) do
            nil ->
              resource_name =
                Map.get(azure_opts, :azure_resource_name) ||
                  Map.get(resolved, :resource_name)

              if resource_name do
                build_default_base_url(resource_name)
              else
                model.base_url
              end

            url ->
              String.trim(url)
          end

        url ->
          String.trim(url)
      end

    if !base_url || base_url == "" do
      raise "Azure OpenAI base URL is required. Configure providers.azure_openai_responses, pass azure_base_url/azure_resource_name in stream options, or set model.base_url."
    end

    {normalize_base_url(base_url), api_version}
  end

  defp build_default_base_url(resource_name) do
    "https://#{resource_name}.openai.azure.com/openai/v1"
  end

  defp normalize_base_url(url) do
    String.trim_trailing(url, "/")
  end

  # ============================================================================
  # Request Building
  # ============================================================================

  defp build_request(model, context, opts, api_key, deployment_name, resolved) do
    {base_url, api_version} = resolve_azure_config(model, opts, resolved)

    messages = OpenAIResponsesShared.convert_messages(model, context, @tool_call_providers)

    # Build parameters
    params = %{
      "model" => deployment_name,
      "input" => messages,
      "stream" => true
    }

    # Add optional parameters
    params = maybe_add_param(params, "prompt_cache_key", opts.session_id)
    params = maybe_add_param(params, "max_output_tokens", opts.max_tokens)
    params = maybe_add_param(params, "temperature", opts.temperature)

    # Add tools if present
    params =
      if context.tools && context.tools != [] do
        Map.put(params, "tools", OpenAIResponsesShared.convert_tools(context.tools))
      else
        params
      end

    # Add reasoning configuration
    params = add_reasoning_config(params, model, opts, messages)
    params = OpenAIResponsesShared.clamp_function_call_outputs(params)

    # Build URL with api-version query parameter
    base_uri = URI.parse("#{base_url}/responses")

    query =
      case base_uri.query do
        nil ->
          URI.encode_query(%{"api-version" => api_version})

        existing ->
          URI.decode_query(existing)
          |> Map.put("api-version", api_version)
          |> URI.encode_query()
      end

    url = %{base_uri | query: query} |> URI.to_string()
    headers = build_headers(model, opts, api_key)

    {url, headers, params}
  end

  defp build_headers(model, opts, api_key) do
    base_headers = %{
      "api-key" => api_key,
      "Content-Type" => "application/json",
      "Accept" => "text/event-stream"
    }

    # Add model-specific headers
    headers = Map.merge(base_headers, model.headers || %{})

    # Add user-provided headers
    Map.merge(headers, opts.headers || %{})
  end

  defp add_reasoning_config(params, model, opts, _messages) do
    if model.reasoning do
      reasoning_effort = opts.reasoning || :medium
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

        if String.starts_with?(model_name, "gpt-5") do
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

  # ============================================================================
  # HTTP Streaming
  # ============================================================================

  defp stream_request(url, headers, body) do
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
                {events, new_buffer} = SSEParser.parse_sse_chunk(state.buffer <> chunk)
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


  # ============================================================================
  # Helpers
  # ============================================================================

end
