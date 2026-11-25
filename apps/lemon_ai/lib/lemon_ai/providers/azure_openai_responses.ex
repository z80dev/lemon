defmodule LemonAi.Providers.AzureOpenAIResponses do
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

  Azure settings are resolved by the caller and read only from
  `provider_options[:azure_openai_responses]`: `api_key`, `base_url` (or
  `resource_name`), `api_version`, `deployment_name` and
  `deployment_name_map`. The resolved `api_key` takes precedence over
  `StreamOptions.api_key`; a missing or empty key fails before any request.

  Streaming uses `LemonAi.Providers.StreamTransport`: 429/5xx and transport
  failures before the body are retried under the provider retry policy, and the
  response is canceled on every exit.

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
        provider_options: %{
          azure_openai_responses: %{
            api_key: "...",
            deployment_name: "my-deployment",
            api_version: "2024-12-01-preview"
          }
        }
      }

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)
  """

  @behaviour LemonAi.Provider

  alias LemonAi.Types.{
    Context,
    Model,
    StreamOptions
  }

  alias LemonAi.EventStream
  alias LemonAi.Providers.{OpenAIResponsesShared, StreamTransport}
  import LemonAi.Providers.AssistantMessageHelper

  # ============================================================================
  # Configuration
  # ============================================================================

  @default_api_version "v1"

  # Providers that use OpenAI-style tool call IDs
  @tool_call_providers MapSet.new([
                         :openai,
                         :openai_codex,
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
  def stream(%Model{} = model, %Context{} = context, %StreamOptions{} = opts) do
    LemonAi.Providers.StreamingHelper.start_streaming(model, context, opts, &do_stream/4)
  end

  defp do_stream(stream, model, context, opts) do
    resolved = provider_options(:azure_openai_responses, opts)

    deployment_name = resolve_deployment_name(model, resolved)
    output = init_assistant_message(model, api_override: :azure_openai_responses)

    try do
      api_key = present(Map.get(resolved, :api_key)) || present(opts.api_key)

      if is_nil(api_key) do
        raise "Azure OpenAI API key is required. Configure providers.azure_openai_responses or pass it in stream options."
      end

      {url, headers, body} =
        build_request(model, context, opts, api_key, deployment_name, resolved)

      EventStream.push_async(stream, {:start, output})

      result =
        StreamTransport.post_sse(url, headers, body, LemonAi.Provider.retry_policy(opts),
          provider: model.provider,
          idle_timeout: StreamTransport.idle_timeout_for(opts.stream_idle_timeout)
        )

      case result do
        {:ok, events} ->
          case OpenAIResponsesShared.process_stream(events, output, stream, model) do
            {:ok, final_output} -> EventStream.complete(stream, final_output)
            {:error, reason} -> EventStream.error(stream, error_assistant_message(output, reason))
          end

        {:error, details, retry_after_ms} ->
          EventStream.error(stream, error_assistant_message(output, details, retry_after_ms))
      end
    rescue
      e -> EventStream.error(stream, error_assistant_message(output, Exception.message(e)))
    end
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  # ============================================================================
  # Deployment Name Resolution
  # ============================================================================

  defp resolve_deployment_name(model, resolved) do
    deployment_map = Map.get(resolved, :deployment_name_map) || %{}

    Map.get(resolved, :deployment_name) || Map.get(deployment_map, model.id) || model.id
  end

  # ============================================================================
  # Azure Configuration Resolution
  # ============================================================================

  defp resolve_azure_config(model, resolved) do
    api_version = Map.get(resolved, :api_version) || @default_api_version

    base_url =
      cond do
        is_binary(Map.get(resolved, :base_url)) ->
          String.trim(resolved.base_url)

        resource_name = Map.get(resolved, :resource_name) ->
          build_default_base_url(resource_name)

        true ->
          model.base_url
      end

    if !base_url || base_url == "" do
      raise "Azure OpenAI base URL is required. Configure providers.azure_openai_responses base_url or resource_name, or set model.base_url."
    end

    {normalize_base_url(base_url), api_version}
  end

  defp build_default_base_url(resource_name) do
    "https://#{resource_name}.openai.azure.com/openai/v1"
  end

  defp provider_options(key, %StreamOptions{provider_options: options}) when is_map(options) do
    Map.get(options, key) || Map.get(options, Atom.to_string(key)) || %{}
  end

  defp provider_options(_, _), do: %{}

  defp normalize_base_url(url) do
    String.trim_trailing(url, "/")
  end

  # ============================================================================
  # Request Building
  # ============================================================================

  defp build_request(model, context, opts, api_key, deployment_name, resolved) do
    {base_url, api_version} = resolve_azure_config(model, resolved)

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

    params =
      maybe_add_param(params, "temperature", OpenAIResponsesShared.temperature_for(model, opts))

    # Add tools if present
    params =
      if context.tools != [] do
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
    headers = Map.merge(base_headers, model.headers)

    # Add user-provided headers
    Map.merge(headers, opts.headers || %{})
  end

  defp add_reasoning_config(params, model, opts, _messages) do
    if model.reasoning do
      reasoning_effort = LemonAi.Models.reasoning_effort_for(model, opts.reasoning || :medium)
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
        model_name = String.downcase(model.name)

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
  # Helpers
  # ============================================================================
end
