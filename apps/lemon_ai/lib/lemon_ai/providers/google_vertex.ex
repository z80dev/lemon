defmodule LemonAi.Providers.GoogleVertex do
  @moduledoc """
  Google Vertex AI provider.

  This provider implements streaming for Google Cloud's Vertex AI API,
  which provides enterprise-grade access to Gemini models.

  ## Authentication

  Requires an OAuth access token for Google Cloud, passed as `access_token`
  (or `api_key`) in stream options together with `project` and `location`. The
  provider never reads credential files, environment variables or runs
  `gcloud`; callers mint and cache the token (Lemon does so in
  `LemonAgent.ModelRuntime.VertexToken`).

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

  @api_version "v1"

  # ============================================================================
  # Provider Callbacks
  # ============================================================================

  @impl true
  def provider_id, do: :google_vertex

  @impl true
  def api_id, do: :google_vertex

  @impl true
  def stream(%Model{} = model, %Context{} = context, %StreamOptions{} = opts) do
    LemonAi.Providers.StreamingHelper.start_streaming(model, context, opts, &do_stream/4)
  end

  # ============================================================================
  # Streaming Implementation
  # ============================================================================

  defp do_stream(stream, model, context, opts) do
    output = init_assistant_message(model, api_override: :google_vertex)

    try do
      resolved = provider_options(opts, :google_vertex)

      project = resolve_project(opts, resolved)
      location = resolve_location(opts, resolved)
      access_token = get_access_token(opts, resolved)

      url = build_url(project, location, model.id)
      headers = build_headers(access_token, model, opts)
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

  defp resolve_project(opts, resolved) do
    project = Map.get(opts, :project) || Map.get(resolved, :project)

    unless project do
      raise "Vertex AI requires a project ID. Configure providers.google_vertex project settings or pass project in options."
    end

    project
  end

  defp provider_options(%StreamOptions{provider_options: options}, key) when is_map(options) do
    Map.get(options, key) || Map.get(options, Atom.to_string(key)) || %{}
  end

  defp provider_options(_, _), do: %{}

  defp resolve_location(opts, resolved) do
    location = Map.get(opts, :location) || Map.get(resolved, :location)

    unless location do
      raise "Vertex AI requires a location. Configure providers.google_vertex location settings or pass location in options."
    end

    location
  end

  # The caller mints the token (`access_token`, or `api_key` from a per-request
  # credential callback). A configured service account the caller could not
  # read is an authoritative refusal.
  defp get_access_token(opts, resolved) do
    cond do
      credential_error?(resolved) ->
        raise "Vertex AI configured service account secret could not be read; refusing the request."

      token = present(opts.access_token) || present(opts.api_key) ->
        token

      true ->
        raise "Vertex AI requires an OAuth access token. Pass access_token in stream options (Lemon mints it from the configured service account, GOOGLE_APPLICATION_CREDENTIALS or gcloud)."
    end
  end

  defp credential_error?(resolved),
    do: not is_nil(Map.get(resolved, :credential_error) || Map.get(resolved, "credential_error"))

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp build_url(project, location, model_id) do
    host =
      if location == "global",
        do: "aiplatform.googleapis.com",
        else: "#{location}-aiplatform.googleapis.com"

    "https://#{host}/#{@api_version}/projects/#{project}/locations/#{location}/publishers/google/models/#{model_id}:streamGenerateContent?alt=sse"
  end

  defp build_headers(access_token, model, opts) do
    base = [
      {"Content-Type", "application/json"},
      {"Authorization", "Bearer #{access_token}"}
    ]

    model_headers = Enum.map(model.headers || %{}, fn {k, v} -> {to_string(k), to_string(v)} end)
    opts_headers = Enum.map(opts.headers || %{}, fn {k, v} -> {to_string(k), to_string(v)} end)

    base ++ model_headers ++ opts_headers
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
    LemonAi.ProviderRegistry.register(:google_vertex, __MODULE__)
    :ignore
  end
end
