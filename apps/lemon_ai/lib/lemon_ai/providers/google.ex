defmodule LemonAi.Providers.Google do
  @moduledoc """
  Google Generative AI (AI Studio) provider.

  This provider implements streaming for Google's Generative AI API,
  which is the public API for Gemini models via AI Studio.

  ## Authentication

  Requires a Google AI Studio API key, which can be obtained from:
  https://aistudio.google.com/apikey

  Pass it as `api_key` in stream options; `LemonAi.stream/3` falls back to
  `GOOGLE_GENERATIVE_AI_API_KEY` (then `GOOGLE_API_KEY`, `GEMINI_API_KEY`).

  ## Features

  - Streaming text generation
  - Tool/function calling
  - Thinking/reasoning mode (for supported models)
  - Image input (for multimodal models)
  """

  @behaviour LemonAi.Provider

  alias LemonAi.EventStream
  alias LemonAi.Providers.{GoogleShared, StreamTransport}
  import LemonAi.Providers.AssistantMessageHelper

  alias LemonAi.Types.{Context, Model, StreamOptions}

  # ============================================================================
  # Provider Callbacks
  # ============================================================================

  @impl true
  def provider_id, do: :google

  @impl true
  def api_id, do: :google_generative_ai

  @impl true
  def stream(%Model{} = model, %Context{} = context, %StreamOptions{} = opts) do
    LemonAi.Providers.StreamingHelper.start_streaming(model, context, opts, &do_stream/4)
  end

  # ============================================================================
  # Streaming Implementation
  # ============================================================================

  defp do_stream(stream, model, context, opts) do
    output = init_assistant_message(model, api_override: :google_generative_ai)
    resolved_provider_opts = resolve_provider_options(model, opts)

    try do
      api_key = resolve_api_key(model, opts, resolved_provider_opts)
      base_url = build_base_url(model, resolved_provider_opts)
      url = "#{base_url}/models/#{model.id}:streamGenerateContent?alt=sse"

      headers = build_headers(api_key, model, opts)
      body = build_request_body(model, context, opts)

      result =
        StreamTransport.post_sse(url, headers, body, LemonAi.Provider.retry_policy(opts),
          provider: model.provider,
          idle_timeout: StreamTransport.idle_timeout_for(opts.stream_idle_timeout)
        )

      GoogleShared.stream_response(stream, output, model, result)
    rescue
      e -> EventStream.error(stream, error_assistant_message(output, Exception.message(e)))
    end
  end

  defp resolve_api_key(model, opts, resolved_provider_opts) do
    cond do
      is_binary(opts.api_key) and opts.api_key != "" ->
        opts.api_key

      api_key = Map.get(resolved_provider_opts, :api_key) ->
        api_key

      match?(%{allow_missing_api_key: true}, model.compat) ->
        nil

      true ->
        raise "Google Generative AI API key is required. Pass api_key, or set GOOGLE_GENERATIVE_AI_API_KEY when calling LemonAi.stream/3."
    end
  end

  defp resolve_provider_options(model, opts) do
    provider_options(opts, model.provider)
  end

  defp provider_options(%StreamOptions{provider_options: options}, key)
       when is_map(options) and is_atom(key) do
    Map.get(options, key) || Map.get(options, Atom.to_string(key)) || %{}
  end

  defp provider_options(%StreamOptions{provider_options: options}, key)
       when is_map(options) and is_binary(key) do
    Map.get(options, key) || %{}
  end

  defp provider_options(_, _), do: %{}

  defp build_base_url(%Model{} = model, resolved_provider_opts) do
    cond do
      is_binary(Map.get(resolved_provider_opts, :base_url)) and
          Map.get(resolved_provider_opts, :base_url) != "" ->
        resolved_provider_opts
        |> Map.fetch!(:base_url)
        |> String.trim_trailing("/")

      is_binary(model.base_url) and model.base_url != "" ->
        String.trim_trailing(model.base_url, "/")

      true ->
        "https://generativelanguage.googleapis.com/v1beta"
    end
  end

  defp build_headers(api_key, model, opts) do
    base = %{"content-type" => "application/json"}
    base = if api_key, do: Map.put(base, "x-goog-api-key", api_key), else: base

    base
    |> LemonAi.Providers.RequestHeaders.merge(model.headers)
    |> LemonAi.Providers.RequestHeaders.merge(opts.headers)
    |> Map.to_list()
  end

  defp build_request_body(model, context, opts) do
    contents = GoogleShared.convert_messages(model, context)

    generation_config = build_generation_config(model, opts)

    body = %{
      "contents" => contents
    }

    body =
      if context.system_prompt do
        system_prompt = LemonAi.SystemPrompt.text(context.system_prompt)

        Map.put(body, "systemInstruction", %{
          "parts" => [%{"text" => GoogleShared.sanitize_surrogates(system_prompt)}]
        })
      else
        body
      end

    body =
      case GoogleShared.convert_tools(context.tools) do
        nil -> body
        tools -> Map.put(body, "tools", tools)
      end

    body =
      if context.tools != [] and opts_has_tool_choice?(opts) do
        tool_choice = get_tool_choice(opts)

        Map.put(body, "toolConfig", %{
          "functionCallingConfig" => %{
            "mode" => GoogleShared.map_tool_choice(tool_choice)
          }
        })
      else
        body
      end

    body =
      if map_size(generation_config) > 0 do
        Map.put(body, "generationConfig", generation_config)
      else
        body
      end

    body
  end

  defp build_generation_config(model, opts) do
    config = %{}

    config =
      if opts.temperature do
        Map.put(config, "temperature", opts.temperature)
      else
        config
      end

    config =
      if opts.max_tokens do
        Map.put(config, "maxOutputTokens", opts.max_tokens)
      else
        config
      end

    GoogleShared.put_thinking_config(config, model, opts)
  end

  defp opts_has_tool_choice?(%StreamOptions{} = opts) do
    not is_nil(Map.get(opts, :tool_choice))
  end

  defp get_tool_choice(%StreamOptions{} = opts) do
    Map.get(opts, :tool_choice, :auto)
  end

  # ============================================================================
  # Registration
  # ============================================================================

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :register, [opts]},
      type: :worker,
      restart: :transient
    }
  end

  @doc "Register this provider with the registry"
  def register(_opts \\ []) do
    LemonAi.ProviderRegistry.register(:google_generative_ai, __MODULE__)
    :ignore
  end
end
