defmodule Ai.Providers.GoogleVertex do
  @moduledoc """
  Google Vertex AI provider.

  This provider implements streaming for Google Cloud's Vertex AI API,
  which provides enterprise-grade access to Gemini models.

  ## Authentication

  Uses Application Default Credentials (ADC) or service account authentication.
  The following environment variables are required:

  - `GOOGLE_CLOUD_PROJECT` or `GCLOUD_PROJECT`: GCP project ID
  - `GOOGLE_CLOUD_LOCATION`: Region (e.g., "us-central1")

  Authentication is handled via:
  - Application Default Credentials (gcloud auth)
  - Service account key file (GOOGLE_APPLICATION_CREDENTIALS)

  ## Features

  - Streaming text generation
  - Tool/function calling
  - Thinking/reasoning mode (for supported models)
  - Image input (for multimodal models)
  """

  @behaviour Ai.Provider

  alias Ai.EventStream
  alias Ai.Providers.GoogleShared

  alias Ai.Types.{
    AssistantMessage,
    Context,
    Cost,
    Model,
    StreamOptions,
    TextContent,
    ThinkingContent,
    ToolCall,
    Usage
  }

  require Logger

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
        do_stream(stream, model, context, opts)
      end)

    EventStream.attach_task(stream, task_pid)

    {:ok, stream}
  end

  # ============================================================================
  # Streaming Implementation
  # ============================================================================

  defp do_stream(stream, model, context, opts) do
    output = init_output(model)

    try do
      project = resolve_project(opts)
      location = resolve_location(opts)
      access_token = get_access_token(opts)

      url = build_url(project, location, model.id)
      headers = build_headers(access_token, model, opts)
      body = build_request_body(model, context, opts)

      case make_streaming_request(url, headers, body) do
        {:ok, response_stream} ->
          process_stream(stream, response_stream, output, model, opts)

        {:error, reason} ->
          handle_error(stream, output, reason, opts)
      end
    rescue
      e ->
        handle_error(stream, output, Exception.message(e), opts)
    end
  end

  defp init_output(model) do
    %AssistantMessage{
      role: :assistant,
      content: [],
      api: :google_vertex,
      provider: model.provider,
      model: model.id,
      usage: %Usage{cost: %Cost{}},
      stop_reason: :stop,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp resolve_project(opts) do
    project =
      Map.get(opts, :project) ||
        System.get_env("GOOGLE_CLOUD_PROJECT") ||
        System.get_env("GCLOUD_PROJECT")

    unless project do
      raise "Vertex AI requires a project ID. Set GOOGLE_CLOUD_PROJECT/GCLOUD_PROJECT or pass project in options."
    end

    project
  end

  defp resolve_location(opts) do
    location =
      Map.get(opts, :location) ||
        System.get_env("GOOGLE_CLOUD_LOCATION")

    unless location do
      raise "Vertex AI requires a location. Set GOOGLE_CLOUD_LOCATION or pass location in options."
    end

    location
  end

  defp get_access_token(opts) do
    # Try to get token from opts first
    if token = Map.get(opts, :access_token) do
      token
    else
      # Try service account JSON from opts (set via secrets)
      service_account_json = Map.get(opts, :service_account_json)

      cond do
        service_account_json && service_account_json != "" ->
          get_access_token_from_service_account(service_account_json)

        File.exists?(System.get_env("GOOGLE_APPLICATION_CREDENTIALS", "")) ->
          # Use ADC file path
          case System.cmd("gcloud", ["auth", "print-access-token"], stderr_to_stdout: true) do
            {token, 0} -> String.trim(token)
            {error, _} -> raise "Failed to get access token via gcloud: #{error}"
          end

        true ->
          # Try gcloud ADC as fallback
          case System.cmd("gcloud", ["auth", "print-access-token"], stderr_to_stdout: true) do
            {token, 0} ->
              String.trim(token)

            {error, _} ->
              raise "Failed to get access token via gcloud: #{error}. Ensure you're authenticated with 'gcloud auth login' or 'gcloud auth application-default login', or provide service_account_json in options."
          end
      end
    end
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
    # This is a simplified implementation
    # In production, you'd use a proper JWT library like JOSE
    # For now, we'll use a shell command with openssl if available

    header = %{"alg" => "RS256", "typ" => "JWT"}

    header_b64 = Base.url_encode64(Jason.encode!(header), padding: false)
    claims_b64 = Base.url_encode64(Jason.encode!(claims), padding: false)
    signing_input = "#{header_b64}.#{claims_b64}"

    # Write private key to temp file for openssl
    tmp_key_path = Path.join(System.tmp_dir!(), "gcp_key_#{:erlang.unique_integer([:positive])}.pem")
    File.write!(tmp_key_path, private_key)

    try do
      # Sign with openssl
      signature =
        case System.cmd(
               "openssl",
               ["dgst", "-sha256", "-sign", tmp_key_path],
               stdin: signing_input,
               stderr_to_stdout: true
             ) do
          {sig, 0} -> sig
          {error, _} -> raise "OpenSSL signing failed: #{error}"
        end

      signature_b64 = Base.url_encode64(signature, padding: false)
      jwt = "#{signing_input}.#{signature_b64}"

      # Exchange JWT for access token
      exchange_jwt_for_token(jwt, token_uri)
    after
      File.rm(tmp_key_path)
    end
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
    "https://#{location}-aiplatform.googleapis.com/#{@api_version}/projects/#{project}/locations/#{location}/publishers/google/models/#{model_id}:streamGenerateContent?alt=sse"
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
        Map.put(body, "systemInstruction", %{
          "parts" => [%{"text" => GoogleShared.sanitize_surrogates(context.system_prompt)}]
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

    # Handle thinking/reasoning config
    config =
      if model.reasoning and thinking_enabled?(opts) do
        thinking_config = %{"includeThoughts" => true}

        thinking_config =
          cond do
            thinking_level = get_thinking_level(opts) ->
              Map.put(thinking_config, "thinkingLevel", thinking_level)

            thinking_budget = get_thinking_budget(opts) ->
              Map.put(thinking_config, "thinkingBudget", thinking_budget)

            true ->
              thinking_config
          end

        Map.put(config, "thinkingConfig", thinking_config)
      else
        config
      end

    config
  end

  defp opts_has_tool_choice?(%StreamOptions{} = opts) do
    not is_nil(Map.get(opts, :tool_choice))
  end

  defp get_tool_choice(%StreamOptions{} = opts) do
    Map.get(opts, :tool_choice, :auto)
  end

  defp thinking_enabled?(%StreamOptions{reasoning: level})
       when level in [:minimal, :low, :medium, :high], do: true

  defp thinking_enabled?(_), do: false

  defp get_thinking_level(%StreamOptions{thinking_budgets: budgets}) do
    Map.get(budgets, :level)
  end

  defp get_thinking_budget(%StreamOptions{reasoning: level, thinking_budgets: budgets}) do
    Map.get(budgets, :budget_tokens) || Map.get(budgets, level)
  end

  defp make_streaming_request(url, headers, body) do
    case Req.post(url, headers: headers, json: body, receive_timeout: 300_000, into: :self) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        {:ok, :streaming}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{GoogleShared.extract_error_message(inspect(body))}"}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, "Transport error: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  defp process_stream(stream, :streaming, output, model, _opts) do
    EventStream.push_async(stream, {:start, output})

    state = %{
      output: output,
      current_block: nil,
      tool_call_counter: 0
    }

    final_state = receive_sse_events(stream, state, model)

    # Emit final block end if needed
    final_state =
      case final_state.current_block do
        %TextContent{} = block ->
          idx = length(final_state.output.content) - 1
          EventStream.push_async(stream, {:text_end, idx, block.text, final_state.output})
          final_state

        %ThinkingContent{} = block ->
          idx = length(final_state.output.content) - 1
          EventStream.push_async(stream, {:thinking_end, idx, block.thinking, final_state.output})
          final_state

        _ ->
          final_state
      end

    # Check for tool calls to set stop reason
    output = final_state.output

    output =
      if Enum.any?(output.content, &match?(%ToolCall{}, &1)) do
        %{output | stop_reason: :tool_use}
      else
        output
      end

    EventStream.complete(stream, output)
  end

  defp receive_sse_events(stream, state, model) do
    receive do
      msg ->
        case GoogleShared.normalize_sse_message(msg) do
          {:data, data} ->
            new_state = process_sse_data(stream, state, data, model)
            receive_sse_events(stream, new_state, model)

          :done ->
            state

          :down ->
            state

          :ignore ->
            receive_sse_events(stream, state, model)
        end
    after
      300_000 ->
        state
    end
  end

  defp process_sse_data(stream, state, data, model) do
    data
    |> String.split("\n")
    |> Enum.reduce(state, fn line, acc ->
      if String.starts_with?(line, "data:") do
        json_str = String.trim(String.slice(line, 5..-1//1))

        if json_str != "" do
          case Jason.decode(json_str) do
            {:ok, chunk} -> process_chunk(stream, acc, chunk, model)
            _ -> acc
          end
        else
          acc
        end
      else
        acc
      end
    end)
  end

  defp process_chunk(stream, state, chunk, model) do
    candidate = get_in(chunk, ["candidates", Access.at(0)])

    state =
      if candidate && candidate["content"] && candidate["content"]["parts"] do
        Enum.reduce(candidate["content"]["parts"], state, fn part, acc ->
          process_part(stream, acc, part, model)
        end)
      else
        state
      end

    # Handle finish reason
    state =
      if finish_reason = get_in(candidate, ["finishReason"]) do
        output = %{state.output | stop_reason: GoogleShared.map_stop_reason(finish_reason)}
        %{state | output: output}
      else
        state
      end

    # Handle usage metadata
    state =
      if usage = chunk["usageMetadata"] do
        usage_struct = %Usage{
          input: usage["promptTokenCount"] || 0,
          output: (usage["candidatesTokenCount"] || 0) + (usage["thoughtsTokenCount"] || 0),
          cache_read: usage["cachedContentTokenCount"] || 0,
          cache_write: 0,
          total_tokens: usage["totalTokenCount"] || 0,
          cost: %Cost{}
        }

        usage_with_cost = GoogleShared.calculate_cost(model, Map.from_struct(usage_struct))

        output = %{
          state.output
          | usage: %{
              usage_struct
              | cost: %Cost{
                  input: usage_with_cost.cost.input,
                  output: usage_with_cost.cost.output,
                  cache_read: usage_with_cost.cost.cache_read,
                  cache_write: usage_with_cost.cost.cache_write,
                  total: usage_with_cost.cost.total
                }
            }
        }

        %{state | output: output}
      else
        state
      end

    state
  end

  defp process_part(stream, state, part, model) do
    cond do
      Map.has_key?(part, "text") ->
        process_text_part(stream, state, part)

      Map.has_key?(part, "functionCall") ->
        process_function_call_part(stream, state, part, model)

      true ->
        state
    end
  end

  defp process_text_part(stream, state, part) do
    text = part["text"]
    is_thinking = GoogleShared.thinking_part?(part)
    thought_sig = part["thoughtSignature"]

    # Check if we need to start a new block
    {state, idx} =
      case {state.current_block, is_thinking} do
        {nil, true} ->
          block = %ThinkingContent{thinking: "", thinking_signature: nil}
          output = %{state.output | content: state.output.content ++ [block]}
          idx = length(output.content) - 1
          EventStream.push_async(stream, {:thinking_start, idx, output})
          {%{state | output: output, current_block: block}, idx}

        {nil, false} ->
          block = %TextContent{text: "", text_signature: nil}
          output = %{state.output | content: state.output.content ++ [block]}
          idx = length(output.content) - 1
          EventStream.push_async(stream, {:text_start, idx, output})
          {%{state | output: output, current_block: block}, idx}

        {%ThinkingContent{}, false} ->
          old_idx = length(state.output.content) - 1

          EventStream.push_async(
            stream,
            {:thinking_end, old_idx, state.current_block.thinking, state.output}
          )

          block = %TextContent{text: "", text_signature: nil}
          output = %{state.output | content: state.output.content ++ [block]}
          idx = length(output.content) - 1
          EventStream.push_async(stream, {:text_start, idx, output})
          {%{state | output: output, current_block: block}, idx}

        {%TextContent{}, true} ->
          old_idx = length(state.output.content) - 1

          EventStream.push_async(
            stream,
            {:text_end, old_idx, state.current_block.text, state.output}
          )

          block = %ThinkingContent{thinking: "", thinking_signature: nil}
          output = %{state.output | content: state.output.content ++ [block]}
          idx = length(output.content) - 1
          EventStream.push_async(stream, {:thinking_start, idx, output})
          {%{state | output: output, current_block: block}, idx}

        {%ThinkingContent{}, true} ->
          {state, length(state.output.content) - 1}

        {%TextContent{}, false} ->
          {state, length(state.output.content) - 1}
      end

    # Update the current block with new text
    {updated_block, event_type} =
      if is_thinking do
        block = state.current_block
        new_sig = GoogleShared.retain_thought_signature(block.thinking_signature, thought_sig)

        {%{block | thinking: block.thinking <> text, thinking_signature: new_sig},
         :thinking_delta}
      else
        block = state.current_block
        new_sig = GoogleShared.retain_thought_signature(block.text_signature, thought_sig)
        {%{block | text: block.text <> text, text_signature: new_sig}, :text_delta}
      end

    # Update output content
    content = List.replace_at(state.output.content, idx, updated_block)
    output = %{state.output | content: content}

    EventStream.push_async(stream, {event_type, idx, text, output})

    %{state | output: output, current_block: updated_block}
  end

  defp process_function_call_part(stream, state, part, _model) do
    func_call = part["functionCall"]

    # End current text/thinking block if any
    state =
      case state.current_block do
        %TextContent{} = block ->
          idx = length(state.output.content) - 1
          EventStream.push_async(stream, {:text_end, idx, block.text, state.output})
          %{state | current_block: nil}

        %ThinkingContent{} = block ->
          idx = length(state.output.content) - 1
          EventStream.push_async(stream, {:thinking_end, idx, block.thinking, state.output})
          %{state | current_block: nil}

        _ ->
          state
      end

    # Generate tool call ID
    provided_id = func_call["id"]

    needs_new_id =
      is_nil(provided_id) or
        Enum.any?(state.output.content, fn
          %ToolCall{id: id} -> id == provided_id
          _ -> false
        end)

    tool_call_id =
      if needs_new_id do
        counter = state.tool_call_counter + 1
        "#{func_call["name"]}_#{System.system_time(:millisecond)}_#{counter}"
      else
        provided_id
      end

    tool_call = %ToolCall{
      type: :tool_call,
      id: tool_call_id,
      name: func_call["name"] || "",
      arguments: func_call["args"] || %{},
      thought_signature: part["thoughtSignature"]
    }

    output = %{state.output | content: state.output.content ++ [tool_call]}
    idx = length(output.content) - 1

    EventStream.push_async(stream, {:tool_call_start, idx, output})

    EventStream.push_async(
      stream,
      {:tool_call_delta, idx, Jason.encode!(tool_call.arguments), output}
    )

    EventStream.push_async(stream, {:tool_call_end, idx, tool_call, output})

    %{state | output: output, current_block: nil, tool_call_counter: state.tool_call_counter + 1}
  end

  defp handle_error(stream, output, reason, _opts) do
    error_output = %{
      output
      | stop_reason: :error,
        error_message: reason
    }

    EventStream.error(stream, error_output)
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
    Ai.ProviderRegistry.register(:google_vertex, __MODULE__)
    :ignore
  end
end
