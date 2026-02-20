defmodule Ai.Providers.Bedrock do
  @moduledoc """
  Amazon Bedrock Converse Stream API provider.

  Implements the Ai.Provider behaviour for streaming responses from
  Amazon Bedrock using the Converse Stream API.

  ## Configuration

  AWS credentials can be provided via:
  - Environment variables: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION
  - Options passed to stream/3

  ## Usage

      model = %Model{id: "anthropic.claude-3-5-sonnet-20240620-v1:0", api: :bedrock_converse_stream, ...}
      context = Context.new(system_prompt: "You are helpful", messages: [...])
      {:ok, stream} = Ai.Providers.Bedrock.stream(model, context, %StreamOptions{})

      stream
      |> EventStream.events()
      |> Enum.each(&IO.inspect/1)
  """

  @behaviour Ai.Provider

  alias Ai.EventStream
  alias Ai.Providers.HttpTrace
  alias Ai.Types.{AssistantMessage, Context, Cost, Model, StreamOptions, Usage}
  alias Ai.Types.{TextContent, ThinkingContent, ToolCall}
  alias Ai.Types.{UserMessage, ToolResultMessage}
  alias Ai.Providers.TextSanitizer

  require Logger

  # ============================================================================
  # Provider Callbacks
  # ============================================================================

  @impl true
  def provider_id, do: :amazon

  @impl true
  def api_id, do: :bedrock_converse_stream

  @impl true
  def get_env_api_key do
    # Bedrock uses AWS credentials, not a simple API key
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
    trace_id = HttpTrace.new_trace_id("bedrock")

    region = get_region(opts)
    credentials = get_credentials(opts)

    case credentials do
      {:error, reason} ->
        HttpTrace.log_error("bedrock", "credentials_error", %{
          trace_id: trace_id,
          model: model.id,
          region: region,
          error: reason
        })

        output = %{output | stop_reason: :error, error_message: reason}
        EventStream.error(stream, output)

      {:ok, access_key, secret_key, session_token} ->
        endpoint = build_endpoint(region, model.id)
        body = build_request_body(model, context, opts)
        message_list = Map.get(body, "messages", [])

        HttpTrace.log(
          "bedrock",
          "request_start",
          summarize_http_request(trace_id, model, context, opts, endpoint, body, message_list)
        )

        case make_signed_request(
               endpoint,
               body,
               region,
               access_key,
               secret_key,
               session_token,
               trace_id
             ) do
          {:ok, response} ->
            EventStream.push_async(stream, {:start, output})
            output = process_event_stream(response.body, output, stream)

            if output.stop_reason in [:error, :aborted] do
              EventStream.error(stream, output)
            else
              EventStream.complete(stream, output)
            end

          {:error, %{status: status, body: body, headers: response_headers}} ->
            HttpTrace.log_error("bedrock", "http_error", %{
              trace_id: trace_id,
              status: status,
              provider_request_id:
                HttpTrace.response_header_value(response_headers, [
                  "x-amzn-requestid",
                  "x-amz-request-id",
                  "x-request-id"
                ]),
              body_bytes: HttpTrace.body_bytes(body),
              body_preview: HttpTrace.body_preview(body),
              model: model.id,
              region: region,
              session_id: opts.session_id,
              converted_messages: length(message_list)
            })

            error_msg = extract_error_message(body, status)
            output = %{output | stop_reason: :error, error_message: error_msg}
            EventStream.push_async(stream, {:start, output})
            EventStream.error(stream, output)

          {:error, reason} ->
            HttpTrace.log_error("bedrock", "transport_error", %{
              trace_id: trace_id,
              error: inspect(reason, limit: 50, printable_limit: 8_000),
              model: model.id,
              region: region,
              session_id: opts.session_id,
              converted_messages: length(message_list)
            })

            error_msg = "Request failed: #{inspect(reason)}"
            output = %{output | stop_reason: :error, error_message: error_msg}
            EventStream.push_async(stream, {:start, output})
            EventStream.error(stream, output)
        end
    end
  end

  defp init_output(model) do
    %AssistantMessage{
      role: :assistant,
      content: [],
      api: :bedrock_converse_stream,
      provider: model.provider || :amazon,
      model: model.id,
      usage: %Usage{
        input: 0,
        output: 0,
        cache_read: 0,
        cache_write: 0,
        total_tokens: 0,
        cost: %Cost{}
      },
      stop_reason: :stop,
      timestamp: System.system_time(:millisecond)
    }
  end

  # ============================================================================
  # AWS Configuration
  # ============================================================================

  defp get_region(opts) do
    # Check options, then environment
    Map.get(opts.headers, "aws_region") ||
      System.get_env("AWS_REGION") ||
      System.get_env("AWS_DEFAULT_REGION") ||
      "us-east-1"
  end

  defp get_credentials(opts) do
    access_key =
      Map.get(opts.headers, "aws_access_key_id") ||
        System.get_env("AWS_ACCESS_KEY_ID")

    secret_key =
      Map.get(opts.headers, "aws_secret_access_key") ||
        System.get_env("AWS_SECRET_ACCESS_KEY")

    session_token =
      Map.get(opts.headers, "aws_session_token") ||
        System.get_env("AWS_SESSION_TOKEN")

    cond do
      is_nil(access_key) ->
        {:error, "AWS_ACCESS_KEY_ID not found"}

      is_nil(secret_key) ->
        {:error, "AWS_SECRET_ACCESS_KEY not found"}

      true ->
        {:ok, access_key, secret_key, session_token}
    end
  end

  defp build_endpoint(region, model_id) do
    host = "bedrock-runtime.#{region}.amazonaws.com"
    path = "/model/#{URI.encode(model_id, &uri_unreserved?/1)}/converse-stream"
    %{host: host, path: path, region: region}
  end

  defp uri_unreserved?(char) do
    char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char in [?-, ?_, ?., ?~]
  end

  # ============================================================================
  # Request Body Building
  # ============================================================================

  defp build_request_body(model, context, opts) do
    body = %{
      "modelId" => model.id,
      "messages" => convert_messages(context, model),
      "inferenceConfig" => build_inference_config(opts)
    }

    body =
      if context.system_prompt do
        Map.put(body, "system", build_system_prompt(context.system_prompt, model))
      else
        body
      end

    body =
      if length(context.tools) > 0 do
        tool_config = convert_tool_config(context.tools, opts)
        if tool_config, do: Map.put(body, "toolConfig", tool_config), else: body
      else
        body
      end

    body =
      case build_additional_model_request_fields(model, opts) do
        nil -> body
        fields -> Map.put(body, "additionalModelRequestFields", fields)
      end

    body
  end

  defp build_inference_config(opts) do
    config = %{}

    config =
      if opts.max_tokens,
        do: Map.put(config, "maxTokens", opts.max_tokens),
        else: config

    config =
      if opts.temperature,
        do: Map.put(config, "temperature", opts.temperature),
        else: config

    config
  end

  defp build_system_prompt(system_prompt, model) do
    blocks = [%{"text" => sanitize_surrogates(system_prompt)}]

    # Add cache point for supported Claude models
    if supports_prompt_caching?(model) do
      blocks ++ [%{"cachePoint" => %{"type" => "default"}}]
    else
      blocks
    end
  end

  defp convert_messages(context, model) do
    {converted_messages, _prev_role} =
      Enum.reduce(context.messages, {[], nil}, fn msg, {acc, prev_role} ->
        case convert_message(msg, model, prev_role) do
          nil -> {acc, prev_role}
          converted -> {acc ++ [converted], converted["role"]}
        end
      end)

    converted_messages
    |> merge_consecutive_tool_results()
    |> add_cache_point_to_last_user_message(model)
  end

  defp convert_message(%UserMessage{} = msg, _model, _prev_role) do
    content =
      cond do
        is_binary(msg.content) ->
          [%{"text" => sanitize_surrogates(msg.content)}]

        is_list(msg.content) ->
          Enum.map(msg.content, fn
            %TextContent{text: text} ->
              %{"text" => sanitize_surrogates(text)}

            %{type: :image, data: data, mime_type: mime_type} ->
              %{"image" => create_image_block(mime_type, data)}
          end)
      end

    %{"role" => "user", "content" => content}
  end

  defp convert_message(%AssistantMessage{content: content}, model, _prev_role) do
    # Skip empty assistant messages
    if Enum.empty?(content) do
      nil
    else
      content_blocks =
        content
        |> Enum.map(fn block -> convert_assistant_block(block, model) end)
        |> Enum.reject(&is_nil/1)

      # Skip if all blocks were filtered out
      if Enum.empty?(content_blocks) do
        nil
      else
        %{"role" => "assistant", "content" => content_blocks}
      end
    end
  end

  defp convert_message(%ToolResultMessage{} = msg, _model, _prev_role) do
    content =
      Enum.map(msg.content, fn
        %TextContent{text: text} ->
          %{"text" => sanitize_surrogates(text)}

        %{type: :image, data: data, mime_type: mime_type} ->
          %{"image" => create_image_block(mime_type, data)}
      end)

    status = if msg.is_error, do: "error", else: "success"

    tool_result = %{
      "toolResult" => %{
        "toolUseId" => normalize_tool_call_id(msg.tool_call_id),
        "content" => content,
        "status" => status
      }
    }

    # Return as user message with tool result
    %{"role" => "user", "content" => [tool_result], "_is_tool_result" => true}
  end

  defp convert_assistant_block(%TextContent{text: text}, _model) do
    # Skip empty text blocks
    if String.trim(text) == "" do
      nil
    else
      %{"text" => sanitize_surrogates(text)}
    end
  end

  defp convert_assistant_block(%ThinkingContent{} = block, model) do
    # Skip empty thinking blocks
    if String.trim(block.thinking) == "" do
      nil
    else
      # Only Anthropic models support the signature field
      if supports_thinking_signature?(model) do
        %{
          "reasoningContent" => %{
            "reasoningText" => %{
              "text" => sanitize_surrogates(block.thinking),
              "signature" => block.thinking_signature || ""
            }
          }
        }
      else
        %{
          "reasoningContent" => %{
            "reasoningText" => %{
              "text" => sanitize_surrogates(block.thinking)
            }
          }
        }
      end
    end
  end

  defp convert_assistant_block(%ToolCall{} = block, _model) do
    %{
      "toolUse" => %{
        "toolUseId" => normalize_tool_call_id(block.id),
        "name" => block.name,
        "input" => block.arguments
      }
    }
  end

  defp convert_assistant_block(_, _model), do: nil

  defp merge_consecutive_tool_results(messages) do
    # Merge consecutive tool result messages (marked with _is_tool_result)
    messages
    |> Enum.reduce([], fn msg, acc ->
      is_tool_result = Map.get(msg, "_is_tool_result", false)

      case {acc, is_tool_result} do
        {[], _} ->
          [Map.delete(msg, "_is_tool_result")]

        {[prev | rest], true} ->
          # Check if previous message can accept tool results
          if can_merge_tool_result?(prev) do
            # Merge tool results into previous user message
            merged_content = prev["content"] ++ msg["content"]
            [prev |> Map.put("content", merged_content) |> Map.delete("_is_tool_result") | rest]
          else
            [Map.delete(msg, "_is_tool_result") | acc]
          end

        _ ->
          [Map.delete(msg, "_is_tool_result") | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp can_merge_tool_result?(prev) do
    # Check if it's marked as a tool result, or if it's a user message with tool results
    Map.get(prev, "_is_tool_result", false) or
      (prev["role"] == "user" and
         is_list(prev["content"]) and
         match?([%{"toolResult" => _} | _], prev["content"]))
  end

  defp add_cache_point_to_last_user_message(messages, model) do
    if supports_prompt_caching?(model) and length(messages) > 0 do
      {last, rest} = List.pop_at(messages, -1)

      if last["role"] == "user" and is_list(last["content"]) do
        updated_content = last["content"] ++ [%{"cachePoint" => %{"type" => "default"}}]
        rest ++ [Map.put(last, "content", updated_content)]
      else
        messages
      end
    else
      messages
    end
  end

  defp convert_tool_config(tools, opts) when is_list(tools) and length(tools) > 0 do
    # Check if tool_choice is "none" via headers
    tool_choice = Map.get(opts.headers, "tool_choice")

    if tool_choice == "none" do
      nil
    else
      bedrock_tools =
        Enum.map(tools, fn tool ->
          %{
            "toolSpec" => %{
              "name" => tool.name,
              "description" => tool.description,
              "inputSchema" => %{"json" => tool.parameters}
            }
          }
        end)

      config = %{"tools" => bedrock_tools}

      case tool_choice do
        "auto" ->
          Map.put(config, "toolChoice", %{"auto" => %{}})

        "any" ->
          Map.put(config, "toolChoice", %{"any" => %{}})

        %{"type" => "tool", "name" => name} ->
          Map.put(config, "toolChoice", %{"tool" => %{"name" => name}})

        _ ->
          config
      end
    end
  end

  defp convert_tool_config(_, _), do: nil

  defp build_additional_model_request_fields(model, opts) do
    if opts.reasoning && model.reasoning do
      if String.contains?(String.downcase(model.id), "anthropic.claude") do
        default_budgets = %{
          minimal: 1024,
          low: 2048,
          medium: 8192,
          high: 16384,
          xhigh: 16384
        }

        level = if opts.reasoning == :xhigh, do: :high, else: opts.reasoning
        budget = Map.get(opts.thinking_budgets, level) || Map.get(default_budgets, opts.reasoning)

        result = %{
          "thinking" => %{
            "type" => "enabled",
            "budget_tokens" => budget
          }
        }

        # Check for interleaved thinking option
        if Map.get(opts.headers, "interleaved_thinking") do
          Map.put(result, "anthropic_beta", ["interleaved-thinking-2025-05-14"])
        else
          result
        end
      else
        nil
      end
    else
      nil
    end
  end

  defp create_image_block(mime_type, data) do
    format =
      case mime_type do
        "image/jpeg" -> "jpeg"
        "image/jpg" -> "jpeg"
        "image/png" -> "png"
        "image/gif" -> "gif"
        "image/webp" -> "webp"
        _ -> raise "Unknown image type: #{mime_type}"
      end

    %{
      "source" => %{"bytes" => Base.decode64!(data)},
      "format" => format
    }
  end

  defp normalize_tool_call_id(id) do
    sanitized =
      id
      |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")

    if String.length(sanitized) > 64 do
      String.slice(sanitized, 0, 64)
    else
      sanitized
    end
  end

  defp supports_prompt_caching?(model) do
    id = String.downcase(model.id)
    # Claude 4.x models (opus-4, sonnet-4, haiku-4)
    # Claude 3.7 Sonnet
    # Claude 3.5 Haiku
    (String.contains?(id, "claude") and
       (String.contains?(id, "-4-") or String.contains?(id, "-4."))) or
      String.contains?(id, "claude-3-7-sonnet") or
      String.contains?(id, "claude-3-5-haiku")
  end

  defp supports_thinking_signature?(model) do
    id = String.downcase(model.id)
    String.contains?(id, "anthropic.claude") or String.contains?(id, "anthropic/claude")
  end

  defp sanitize_surrogates(text), do: TextSanitizer.sanitize(text)

  # ============================================================================
  # AWS Signature V4
  # ============================================================================

  defp make_signed_request(
         endpoint,
         body,
         region,
         access_key,
         secret_key,
         session_token,
         trace_id
       ) do
    url = "https://#{endpoint.host}#{endpoint.path}"
    json_body = Jason.encode!(body)

    now = DateTime.utc_now()
    amz_date = format_amz_date(now)
    date_stamp = format_date_stamp(now)

    headers =
      build_signed_headers(
        endpoint.host,
        endpoint.path,
        json_body,
        region,
        access_key,
        secret_key,
        session_token,
        amz_date,
        date_stamp
      )

    # Use Req for HTTP request with streaming
    case Req.post(url, body: json_body, headers: headers, into: :self, receive_timeout: 600_000) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        HttpTrace.log("bedrock", "response_headers", %{
          trace_id: trace_id,
          status: status,
          provider_request_id:
            HttpTrace.response_header_value(response.headers, [
              "x-amzn-requestid",
              "x-amz-request-id",
              "x-request-id"
            ])
        })

        # Stream the response body
        body_stream = stream_response_body(response)
        {:ok, %{status: status, body: body_stream, headers: response.headers}}

      {:ok, %Req.Response{status: status, body: body, headers: response_headers}} ->
        {:error, %{status: status, body: body, headers: response_headers}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp summarize_http_request(trace_id, model, context, opts, endpoint, _body, messages) do
    %{
      trace_id: trace_id,
      model: model.id,
      provider: model.provider,
      api: model.api,
      region: endpoint.region,
      endpoint: endpoint.host <> endpoint.path,
      session_id: opts.session_id,
      run_id: trace_header(opts.headers, "x-lemon-run-id"),
      session_key: trace_header(opts.headers, "x-lemon-session-key"),
      agent_id: trace_header(opts.headers, "x-lemon-agent-id"),
      raw_message_count: length(context.messages || []),
      converted_message_count: length(messages),
      converted_message_summary: summarize_messages(messages),
      tools_count: length(context.tools || []),
      system_prompt_bytes: HttpTrace.summarize_text_size(context.system_prompt)
    }
  end

  defp summarize_messages(messages) when is_list(messages) do
    messages
    |> Enum.take(20)
    |> Enum.map(fn
      message when is_map(message) ->
        content = Map.get(message, "content")

        %{
          role: Map.get(message, "role"),
          content_items: if(is_list(content), do: length(content), else: 0),
          content_types: summarize_content_types(content),
          text_bytes: summarize_text_bytes(content)
        }

      other ->
        %{
          role: "unknown",
          content_items: 0,
          content_types: %{},
          text_bytes: 0,
          raw: inspect(other)
        }
    end)
  end

  defp summarize_messages(_), do: []

  defp summarize_content_types(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => _} -> "text"
      %{"toolUse" => _} -> "toolUse"
      %{"toolResult" => _} -> "toolResult"
      _ -> "unknown"
    end)
    |> Enum.frequencies()
  end

  defp summarize_content_types(_), do: %{}

  defp summarize_text_bytes(content) when is_list(content) do
    Enum.reduce(content, 0, fn
      %{"text" => text}, acc when is_binary(text) ->
        acc + byte_size(text)

      _, acc ->
        acc
    end)
  end

  defp summarize_text_bytes(_), do: 0

  defp trace_header(headers, key) when is_map(headers), do: Map.get(headers, key)

  defp trace_header(headers, key) when is_list(headers) do
    key_down = String.downcase(key)

    Enum.find_value(headers, fn
      {k, v} when is_binary(k) and is_binary(v) ->
        if String.downcase(k) == key_down, do: v, else: nil

      _ ->
        nil
    end)
  end

  defp trace_header(_headers, _key), do: nil

  defp stream_response_body(response) do
    Stream.resource(
      fn -> response end,
      fn resp ->
        receive do
          {ref, {:data, data}} when ref == resp.async.ref ->
            {[data], resp}

          {ref, :done} when ref == resp.async.ref ->
            {:halt, resp}

          {ref, {:error, reason}} when ref == resp.async.ref ->
            Logger.error("Stream error: #{inspect(reason)}")
            {:halt, resp}
        after
          60_000 ->
            Logger.error("Stream timeout")
            {:halt, resp}
        end
      end,
      fn _resp -> :ok end
    )
  end

  defp build_signed_headers(
         host,
         path,
         body,
         region,
         access_key,
         secret_key,
         session_token,
         amz_date,
         date_stamp
       ) do
    service = "bedrock"
    method = "POST"
    content_type = "application/json"

    payload_hash = hash_sha256(body)

    # Canonical headers
    base_headers = [
      {"host", host},
      {"x-amz-date", amz_date},
      {"content-type", content_type},
      {"x-amz-content-sha256", payload_hash}
    ]

    headers =
      if session_token do
        base_headers ++ [{"x-amz-security-token", session_token}]
      else
        base_headers
      end

    # Sort headers by name
    sorted_headers = Enum.sort_by(headers, &elem(&1, 0))

    canonical_headers =
      sorted_headers
      |> Enum.map(fn {k, v} -> "#{k}:#{v}\n" end)
      |> Enum.join()

    signed_headers =
      sorted_headers
      |> Enum.map(&elem(&1, 0))
      |> Enum.join(";")

    # Canonical request
    canonical_request =
      [
        method,
        path,
        # query string
        "",
        canonical_headers,
        signed_headers,
        payload_hash
      ]
      |> Enum.join("\n")

    # String to sign
    algorithm = "AWS4-HMAC-SHA256"
    credential_scope = "#{date_stamp}/#{region}/#{service}/aws4_request"

    string_to_sign =
      [
        algorithm,
        amz_date,
        credential_scope,
        hash_sha256(canonical_request)
      ]
      |> Enum.join("\n")

    # Signing key
    signing_key = get_signature_key(secret_key, date_stamp, region, service)

    # Signature
    signature = hmac_sha256(signing_key, string_to_sign) |> Base.encode16(case: :lower)

    # Authorization header
    authorization =
      "#{algorithm} Credential=#{access_key}/#{credential_scope}, SignedHeaders=#{signed_headers}, Signature=#{signature}"

    # Return headers as list of tuples
    [
      {"authorization", authorization},
      {"content-type", content_type},
      {"host", host},
      {"x-amz-date", amz_date},
      {"x-amz-content-sha256", payload_hash}
    ] ++ if session_token, do: [{"x-amz-security-token", session_token}], else: []
  end

  defp format_amz_date(datetime) do
    datetime
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end

  defp format_date_stamp(datetime) do
    datetime
    |> Calendar.strftime("%Y%m%d")
  end

  defp hash_sha256(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  defp hmac_sha256(key, data) do
    :crypto.mac(:hmac, :sha256, key, data)
  end

  defp get_signature_key(secret_key, date_stamp, region, service) do
    ("AWS4" <> secret_key)
    |> hmac_sha256(date_stamp)
    |> hmac_sha256(region)
    |> hmac_sha256(service)
    |> hmac_sha256("aws4_request")
  end

  # ============================================================================
  # Event Stream Processing (Bedrock Binary Protocol)
  # ============================================================================

  defp process_event_stream(body_stream, output, stream) do
    # State for tracking content blocks by index
    initial_state = %{
      output: output,
      # Map of content_block_index -> block data
      blocks: %{},
      # Buffer for incomplete frames
      buffer: <<>>
    }

    final_state =
      body_stream
      |> Enum.reduce(initial_state, fn chunk, state ->
        process_chunk(chunk, state, stream)
      end)

    final_state.output
  end

  defp process_chunk(chunk, state, stream) do
    # Append chunk to buffer
    buffer = state.buffer <> chunk

    # Parse frames from buffer
    parse_frames(buffer, state, stream)
  end

  defp parse_frames(buffer, state, stream) do
    case parse_frame(buffer) do
      {:ok, frame, rest} ->
        state = handle_frame(frame, state, stream)
        parse_frames(rest, state, stream)

      :incomplete ->
        %{state | buffer: buffer}

      {:error, reason} ->
        Logger.error("Frame parse error: #{inspect(reason)}")
        %{state | buffer: <<>>}
    end
  end

  defp parse_frame(buffer) when byte_size(buffer) < 12 do
    # Need at least prelude (8 bytes) + prelude CRC (4 bytes)
    :incomplete
  end

  defp parse_frame(buffer) do
    <<total_length::32-unsigned-big, headers_length::32-unsigned-big,
      _prelude_crc::32-unsigned-big, _rest::binary>> = buffer

    # Total length includes prelude (8) + prelude CRC (4) + headers + payload + message CRC (4)
    message_length = total_length

    if byte_size(buffer) < message_length do
      :incomplete
    else
      <<frame_data::binary-size(message_length), remaining::binary>> = buffer

      # Extract headers and payload
      # Frame structure: prelude(8) + prelude_crc(4) + headers + payload + message_crc(4)
      # After prelude + prelude CRC
      headers_start = 12
      payload_start = headers_start + headers_length
      # Subtract prelude, prelude_crc, headers, message_crc
      payload_length = total_length - 12 - headers_length - 4

      headers_data = binary_part(frame_data, headers_start, headers_length)
      payload_data = binary_part(frame_data, payload_start, payload_length)

      headers = parse_headers(headers_data)

      {:ok, %{headers: headers, payload: payload_data}, remaining}
    end
  rescue
    e ->
      {:error, e}
  end

  defp parse_headers(data) do
    parse_headers(data, %{})
  end

  defp parse_headers(<<>>, acc), do: acc

  defp parse_headers(
         <<name_len::8, name::binary-size(name_len), 7::8, value_len::16-big,
           value::binary-size(value_len), rest::binary>>,
         acc
       ) do
    # Type 7 is string
    parse_headers(rest, Map.put(acc, name, value))
  end

  defp parse_headers(<<name_len::8, name::binary-size(name_len), type::8, rest::binary>>, acc) do
    # Handle other types - skip them for now
    case type do
      # bool true
      0 ->
        parse_headers(rest, Map.put(acc, name, true))

      # bool false
      1 ->
        parse_headers(rest, Map.put(acc, name, false))

      # byte
      2 ->
        <<_value::8, rest2::binary>> = rest
        parse_headers(rest2, acc)

      # short
      3 ->
        <<_value::16-big, rest2::binary>> = rest
        parse_headers(rest2, acc)

      # int
      4 ->
        <<_value::32-big, rest2::binary>> = rest
        parse_headers(rest2, acc)

      # long
      5 ->
        <<_value::64-big, rest2::binary>> = rest
        parse_headers(rest2, acc)

      # bytes
      6 ->
        <<len::16-big, _value::binary-size(len), rest2::binary>> = rest
        parse_headers(rest2, acc)

      # timestamp
      8 ->
        <<_value::64-big, rest2::binary>> = rest
        parse_headers(rest2, acc)

      # uuid
      9 ->
        <<_value::binary-size(16), rest2::binary>> = rest
        parse_headers(rest2, acc)

      _ ->
        # Unknown type, stop parsing
        acc
    end
  end

  defp parse_headers(_, acc), do: acc

  defp handle_frame(%{headers: headers, payload: payload}, state, stream) do
    message_type = Map.get(headers, ":message-type")
    event_type = Map.get(headers, ":event-type")

    cond do
      message_type == "exception" ->
        handle_exception(payload, state)

      message_type == "event" ->
        handle_event(event_type, payload, state, stream)

      true ->
        state
    end
  end

  defp handle_exception(payload, state) do
    error_msg =
      case Jason.decode(payload) do
        {:ok, %{"message" => msg}} -> msg
        _ -> "Unknown exception"
      end

    output = %{state.output | stop_reason: :error, error_message: error_msg}
    %{state | output: output}
  end

  defp handle_event("messageStart", _payload, state, _stream) do
    # messageStart just indicates the stream has started
    state
  end

  defp handle_event("contentBlockStart", payload, state, stream) do
    case Jason.decode(payload) do
      {:ok, event} ->
        content_block_index = event["contentBlockIndex"]
        start = event["start"]

        if start["toolUse"] do
          tool_use = start["toolUse"]

          block = %ToolCall{
            type: :tool_call,
            id: tool_use["toolUseId"] || "",
            name: tool_use["name"] || "",
            arguments: %{}
          }

          content = state.output.content ++ [block]
          output = %{state.output | content: content}
          block_data = %{type: :tool_call, index: length(content) - 1, partial_json: ""}

          EventStream.push_async(stream, {:tool_call_start, length(content) - 1, output})

          %{
            state
            | output: output,
              blocks: Map.put(state.blocks, content_block_index, block_data)
          }
        else
          state
        end

      _ ->
        state
    end
  end

  defp handle_event("contentBlockDelta", payload, state, stream) do
    case Jason.decode(payload) do
      {:ok, event} ->
        content_block_index = event["contentBlockIndex"]
        delta = event["delta"]

        cond do
          # Text delta
          delta["text"] != nil ->
            handle_text_delta(content_block_index, delta["text"], state, stream)

          # Tool use delta
          delta["toolUse"] != nil ->
            handle_tool_use_delta(content_block_index, delta["toolUse"], state, stream)

          # Reasoning content delta
          delta["reasoningContent"] != nil ->
            handle_reasoning_delta(content_block_index, delta["reasoningContent"], state, stream)

          true ->
            state
        end

      _ ->
        state
    end
  end

  defp handle_event("contentBlockStop", payload, state, stream) do
    case Jason.decode(payload) do
      {:ok, event} ->
        content_block_index = event["contentBlockIndex"]
        block_data = Map.get(state.blocks, content_block_index)

        if block_data do
          idx = block_data.index
          content = state.output.content
          block = Enum.at(content, idx)

          case block_data.type do
            :text ->
              EventStream.push_async(stream, {:text_end, idx, block.text, state.output})

            :thinking ->
              EventStream.push_async(stream, {:thinking_end, idx, block.thinking, state.output})

            :tool_call ->
              # Final parse of arguments
              arguments = parse_streaming_json(block_data.partial_json || "")
              updated_block = %{block | arguments: arguments}
              updated_content = List.replace_at(content, idx, updated_block)
              output = %{state.output | content: updated_content}
              EventStream.push_async(stream, {:tool_call_end, idx, updated_block, output})
              %{state | output: output}
          end

          state
        else
          state
        end

      _ ->
        state
    end
  end

  defp handle_event("messageStop", payload, state, _stream) do
    case Jason.decode(payload) do
      {:ok, event} ->
        stop_reason = map_stop_reason(event["stopReason"])
        output = %{state.output | stop_reason: stop_reason}
        %{state | output: output}

      _ ->
        state
    end
  end

  defp handle_event("metadata", payload, state, _stream) do
    case Jason.decode(payload) do
      {:ok, event} ->
        usage = event["usage"]

        if usage do
          updated_usage = %Usage{
            input: usage["inputTokens"] || 0,
            output: usage["outputTokens"] || 0,
            cache_read: usage["cacheReadInputTokens"] || 0,
            cache_write: usage["cacheWriteInputTokens"] || 0,
            total_tokens:
              usage["totalTokens"] || (usage["inputTokens"] || 0) + (usage["outputTokens"] || 0),
            # Cost calculation could be added based on model pricing
            cost: %Cost{}
          }

          output = %{state.output | usage: updated_usage}
          %{state | output: output}
        else
          state
        end

      _ ->
        state
    end
  end

  defp handle_event(_event_type, _payload, state, _stream) do
    # Unknown event type, ignore
    state
  end

  # Helper functions for handling deltas
  defp handle_text_delta(content_block_index, text, state, stream) do
    block_data = Map.get(state.blocks, content_block_index)

    {output, block_data, idx} =
      if block_data do
        # Existing text block
        idx = block_data.index
        content = state.output.content
        block = Enum.at(content, idx)
        updated_block = %{block | text: block.text <> text}
        updated_content = List.replace_at(content, idx, updated_block)
        output = %{state.output | content: updated_content}
        {output, block_data, idx}
      else
        # New text block
        block = %TextContent{type: :text, text: text}
        content = state.output.content ++ [block]
        output = %{state.output | content: content}
        idx = length(content) - 1
        block_data = %{type: :text, index: idx}
        EventStream.push_async(stream, {:text_start, idx, output})
        {output, block_data, idx}
      end

    EventStream.push_async(stream, {:text_delta, idx, text, output})

    %{state | output: output, blocks: Map.put(state.blocks, content_block_index, block_data)}
  end

  defp handle_tool_use_delta(content_block_index, tool_use, state, stream) do
    block_data = Map.get(state.blocks, content_block_index)

    if block_data && block_data.type == :tool_call do
      idx = block_data.index
      input_delta = tool_use["input"] || ""
      partial_json = (block_data.partial_json || "") <> input_delta

      # Try to parse partial JSON for arguments
      arguments = parse_streaming_json(partial_json)

      content = state.output.content
      block = Enum.at(content, idx)
      updated_block = %{block | arguments: arguments}
      updated_content = List.replace_at(content, idx, updated_block)
      output = %{state.output | content: updated_content}

      EventStream.push_async(stream, {:tool_call_delta, idx, input_delta, output})

      %{
        state
        | output: output,
          blocks:
            Map.put(state.blocks, content_block_index, %{block_data | partial_json: partial_json})
      }
    else
      state
    end
  end

  defp handle_reasoning_delta(content_block_index, reasoning_content, state, stream) do
    block_data = Map.get(state.blocks, content_block_index)

    text_delta = reasoning_content["text"] || ""
    signature_delta = reasoning_content["signature"] || ""

    {output, block_data, idx} =
      if block_data do
        # Existing thinking block
        idx = block_data.index
        content = state.output.content
        block = Enum.at(content, idx)

        updated_block = %{
          block
          | thinking: block.thinking <> text_delta,
            thinking_signature: (block.thinking_signature || "") <> signature_delta
        }

        updated_content = List.replace_at(content, idx, updated_block)
        output = %{state.output | content: updated_content}
        {output, block_data, idx}
      else
        # New thinking block
        block = %ThinkingContent{
          type: :thinking,
          thinking: text_delta,
          thinking_signature: signature_delta
        }

        content = state.output.content ++ [block]
        output = %{state.output | content: content}
        idx = length(content) - 1
        block_data = %{type: :thinking, index: idx}
        EventStream.push_async(stream, {:thinking_start, idx, output})
        {output, block_data, idx}
      end

    if text_delta != "" do
      EventStream.push_async(stream, {:thinking_delta, idx, text_delta, output})
    end

    %{state | output: output, blocks: Map.put(state.blocks, content_block_index, block_data)}
  end

  defp map_stop_reason(reason) do
    case reason do
      "end_turn" -> :stop
      "stop_sequence" -> :stop
      "max_tokens" -> :length
      "model_context_window_exceeded" -> :length
      "tool_use" -> :tool_use
      _ -> :error
    end
  end

  defp parse_streaming_json(""), do: %{}

  defp parse_streaming_json(partial) do
    # Try to parse partial JSON, falling back to empty map
    # This handles incomplete JSON during streaming
    case Jason.decode(partial) do
      {:ok, result} when is_map(result) ->
        result

      _ ->
        # Try adding closing braces to make it valid
        try_complete_json(partial)
    end
  end

  defp try_complete_json(partial) do
    # Count unclosed braces and brackets
    chars = String.graphemes(partial)

    {braces, brackets} =
      Enum.reduce(chars, {0, 0}, fn char, {b, k} ->
        case char do
          "{" -> {b + 1, k}
          "}" -> {b - 1, k}
          "[" -> {k, k + 1}
          "]" -> {b, k - 1}
          _ -> {b, k}
        end
      end)

    # Try to close with appropriate number of braces/brackets
    closing = String.duplicate("]", max(0, brackets)) <> String.duplicate("}", max(0, braces))

    case Jason.decode(partial <> closing) do
      {:ok, result} when is_map(result) -> result
      _ -> %{}
    end
  end

  defp extract_error_message(body, status) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"message" => msg}} -> msg
      {:ok, %{"Message" => msg}} -> msg
      _ -> "HTTP #{status}: #{body}"
    end
  end

  defp extract_error_message(body, status) do
    "HTTP #{status}: #{inspect(body)}"
  end

  # ============================================================================
  # Provider Registration
  # ============================================================================

  @doc false
  def register do
    Ai.ProviderRegistry.register(:bedrock_converse_stream, __MODULE__)
  end
end
