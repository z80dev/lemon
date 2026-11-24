defmodule LemonAi.Providers.GoogleVertex do
  @moduledoc """
  Google Vertex AI provider.

  This provider implements streaming for Google Cloud's Vertex AI API,
  which provides enterprise-grade access to Gemini models.

  ## Authentication

  Uses Application Default Credentials (ADC) or service account authentication.
  Project, location, and inline service account JSON should be resolved by the
  caller and passed in stream options.

  Authentication is handled via:
  - Application Default Credentials (gcloud auth)
  - Inline service account JSON passed in stream options
  - Service account key file (GOOGLE_APPLICATION_CREDENTIALS)

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
  def get_env_api_key do
    # Vertex AI uses ADC, not API keys
    # Return nil to indicate ADC should be used
    nil
  end

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

  defp get_access_token(opts, resolved) do
    # Try to get token from opts first
    if token = Map.get(opts, :access_token) do
      token
    else
      # Try service account JSON from opts, then resolved config (set via secrets)
      service_account_json =
        Map.get(opts, :service_account_json) ||
          Map.get(resolved, :service_account_json)

      credentials_path = System.get_env("GOOGLE_APPLICATION_CREDENTIALS")

      cond do
        # A configured service-account secret that could not be read refuses
        # the request; ambient credentials must not stand in for it.
        credential_error?(resolved) ->
          raise "Vertex AI configured service account secret could not be read; refusing GOOGLE_APPLICATION_CREDENTIALS and gcloud fallback."

        service_account_json && service_account_json != "" ->
          get_access_token_from_service_account(service_account_json)

        is_binary(credentials_path) and credentials_path != "" and File.exists?(credentials_path) ->
          credentials_path
          |> File.read!()
          |> get_access_token_from_service_account()

        true ->
          get_access_token_from_gcloud()
      end
    end
  end

  defp credential_error?(resolved),
    do: not is_nil(Map.get(resolved, :credential_error) || Map.get(resolved, "credential_error"))

  defp get_access_token_from_gcloud do
    case System.cmd("gcloud", ["auth", "print-access-token"], stderr_to_stdout: true) do
      {token, 0} ->
        String.trim(token)

      {error, _} ->
        raise "Failed to get access token via gcloud: #{error}. Ensure you're authenticated with 'gcloud auth login' or 'gcloud auth application-default login', or provide service_account_json in options."
    end
  rescue
    e in ErlangError ->
      if e.original == :enoent do
        reraise "Failed to get access token via gcloud: command not found. Provide service_account_json, GOOGLE_APPLICATION_CREDENTIALS_JSON, or GOOGLE_APPLICATION_CREDENTIALS.",
                __STACKTRACE__
      end

      reraise e, __STACKTRACE__
  end

  defp get_access_token_from_service_account(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, credentials} ->
        generate_jwt_token(credentials)

      {:error, reason} ->
        raise "Failed to parse service account JSON: #{inspect(reason)}"
    end
  end

  defp generate_jwt_token(credentials) do
    client_email = credentials["client_email"]
    private_key = credentials["private_key"]
    token_uri = credentials["token_uri"] || "https://oauth2.googleapis.com/token"

    unless client_email && private_key do
      raise "Service account JSON missing client_email or private_key"
    end

    now = System.system_time(:second)

    # Build JWT claims
    claims = %{
      "iss" => client_email,
      "sub" => client_email,
      "scope" => "https://www.googleapis.com/auth/cloud-platform",
      "aud" => token_uri,
      "iat" => now,
      "exp" => now + 3600
    }

    # Sign JWT and exchange for access token
    case sign_and_exchange_jwt(claims, private_key, token_uri) do
      {:ok, token} -> token
      {:error, reason} -> raise "Failed to generate access token from service account: #{reason}"
    end
  end

  defp sign_and_exchange_jwt(claims, private_key, token_uri) do
    header = %{"alg" => "RS256", "typ" => "JWT"}

    header_b64 = Base.url_encode64(Jason.encode!(header), padding: false)
    claims_b64 = Base.url_encode64(Jason.encode!(claims), padding: false)
    signing_input = "#{header_b64}.#{claims_b64}"

    # Parse PEM and sign with Erlang's :public_key (no shell needed)
    [pem_entry] = :public_key.pem_decode(private_key)
    rsa_key = :public_key.pem_entry_decode(pem_entry)
    signature = :public_key.sign(signing_input, :sha256, rsa_key)

    signature_b64 = Base.url_encode64(signature, padding: false)
    jwt = "#{signing_input}.#{signature_b64}"

    # Exchange JWT for access token
    exchange_jwt_for_token(jwt, token_uri)
  end

  defp exchange_jwt_for_token(jwt, token_uri) do
    body =
      URI.encode_query(%{
        "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion" => jwt
      })

    headers = [{"Content-Type", "application/x-www-form-urlencoded"}]

    case Req.post(token_uri, headers: headers, body: body) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body["access_token"]}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "Token exchange failed (#{status}): #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

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
