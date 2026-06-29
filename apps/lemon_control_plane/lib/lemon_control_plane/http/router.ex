defmodule LemonControlPlane.HTTP.Router do
  @moduledoc """
  HTTP router for the control plane.

  Provides:
  - `/ws` - WebSocket endpoint for the control plane protocol
  - `/healthz` - Health check endpoint (HTTP GET)
  """

  use Plug.Router

  plug(Plug.Logger, log: :debug)
  plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
  plug(:match)
  plug(:dispatch)

  get "/healthz" do
    send_resp(conn, 200, Jason.encode!(%{ok: true}))
  end

  get "/v1/health" do
    with_openai_auth(conn, fn conn ->
      json(conn, 200, LemonControlPlane.OpenAICompat.health())
    end)
  end

  get "/v1/capabilities" do
    with_openai_auth(conn, fn conn ->
      json(conn, 200, LemonControlPlane.OpenAICompat.capabilities())
    end)
  end

  get "/v1/models" do
    with_openai_auth(conn, fn conn ->
      json(conn, 200, LemonControlPlane.OpenAICompat.models())
    end)
  end

  get "/v1/models/*model_id" do
    with_openai_auth(conn, fn conn ->
      model_id
      |> Enum.join("/")
      |> LemonControlPlane.OpenAICompat.model()
      |> send_openai_result(conn)
    end)
  end

  post "/v1/chat/completions" do
    with_openai_auth(conn, fn conn ->
      if LemonControlPlane.OpenAICompat.stream_requested?(conn.body_params) do
        conn.body_params
        |> LemonControlPlane.OpenAICompat.chat_completion_stream()
        |> send_openai_stream(conn, :chat)
      else
        conn.body_params
        |> LemonControlPlane.OpenAICompat.chat_completion()
        |> send_openai_result(conn)
      end
    end)
  end

  post "/v1/responses" do
    with_openai_auth(conn, fn conn ->
      if LemonControlPlane.OpenAICompat.stream_requested?(conn.body_params) do
        conn.body_params
        |> LemonControlPlane.OpenAICompat.response_stream()
        |> send_openai_stream(conn, :response)
      else
        conn.body_params
        |> LemonControlPlane.OpenAICompat.response()
        |> send_openai_result(conn)
      end
    end)
  end

  get "/v1/responses/:response_id" do
    with_openai_auth(conn, fn conn ->
      response_id
      |> LemonControlPlane.OpenAICompat.stored_response()
      |> send_openai_result(conn)
    end)
  end

  get "/v1/runs/:run_id" do
    with_openai_auth(conn, fn conn ->
      run_id
      |> LemonControlPlane.OpenAICompat.run_status()
      |> send_openai_result(conn)
    end)
  end

  post "/v1/runs/:run_id/cancel" do
    with_openai_auth(conn, fn conn ->
      run_id
      |> LemonControlPlane.OpenAICompat.cancel_run()
      |> send_openai_result(conn)
    end)
  end

  post "/acp" do
    with_acp_auth(conn, fn conn ->
      conn.body_params
      |> LemonControlPlane.ACP.handle_jsonrpc()
      |> send_acp_result(conn)
    end)
  end

  get "/ws" do
    conn
    |> WebSockAdapter.upgrade(LemonControlPlane.WS.Connection, [], timeout: 60_000)
    |> halt()
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "Not found"}))
  end

  defp send_openai_result({:ok, body}, conn), do: json(conn, 200, body)

  defp send_openai_result({:error, {status, message}}, conn) do
    json(conn, status, %{
      "error" => %{
        "message" => message,
        "type" => openai_error_type(status)
      }
    })
  end

  defp openai_error_type(status) when status >= 500, do: "server_error"
  defp openai_error_type(_status), do: "invalid_request_error"

  defp send_acp_result({:ok, body}, conn), do: json(conn, 200, body)
  defp send_acp_result(:noreply, conn), do: send_resp(conn, 204, "")

  defp send_openai_stream({:ok, result}, conn, kind) do
    topic = LemonCore.Bus.run_topic(result.run_id)
    :ok = LemonCore.Bus.subscribe(topic)

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    try do
      with {:ok, conn} <- stream_start(conn, result, kind),
           {:ok, conn} <- stream_loop(conn, result, kind, stream_deadline_ms(result.stream_timeout_ms)) do
        conn
      else
        {:error, _reason} -> conn
      end
    after
      LemonCore.Bus.unsubscribe(topic)
    end
  end

  defp send_openai_stream({:error, _reason} = error, conn, _kind),
    do: send_openai_result(error, conn)

  defp stream_start(conn, result, kind) do
    chunk(conn, sse_data(stream_start_object(result, kind)))
  end

  defp stream_loop(conn, result, kind, deadline_ms) do
    case stream_remaining_timeout_ms(deadline_ms) do
      0 ->
        chunk(conn, sse_data(%{"error" => %{"message" => "stream timed out"}}))

      timeout_ms ->
        receive do
          %LemonCore.Event{type: :delta, payload: payload} ->
            text = map_get(payload, :text) || ""

            stream_delta(conn, result, kind, text)
            |> then(fn
              {:ok, conn} -> stream_loop(conn, result, kind, deadline_ms)
              error -> error
            end)

          %LemonCore.Event{type: :engine_action, payload: payload} ->
            stream_tool_progress(conn, result, kind, payload)
            |> then(fn
              {:ok, conn} -> stream_loop(conn, result, kind, deadline_ms)
              error -> error
            end)

          %LemonCore.Event{type: :run_completed, payload: payload} ->
            stream_completed(conn, result, kind, payload)

          %{type: :run_completed, payload: payload} ->
            stream_completed(conn, result, kind, payload)
        after
          timeout_ms ->
            chunk(conn, sse_data(%{"error" => %{"message" => "stream timed out"}}))
        end
    end
  end

  defp stream_deadline_ms(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    System.monotonic_time(:millisecond) + timeout_ms
  end

  defp stream_deadline_ms(_timeout_ms), do: System.monotonic_time(:millisecond)

  defp stream_remaining_timeout_ms(deadline_ms) do
    max(deadline_ms - System.monotonic_time(:millisecond), 0)
  end

  defp stream_delta(conn, result, :chat, text) do
    chunk(conn, sse_data(chat_stream_chunk(result, %{"content" => text}, nil)))
  end

  defp stream_delta(conn, result, :response, text) do
    chunk(conn, sse_event("response.output_text.delta", response_delta_chunk(result, text)))
  end

  defp stream_tool_progress(conn, result, :chat, payload) do
    chunk(conn, sse_event("lemon.tool_progress", tool_progress_chunk(result, payload, :chat)))
  end

  defp stream_tool_progress(conn, result, :response, payload) do
    chunk(
      conn,
      sse_event("response.tool_progress", tool_progress_chunk(result, payload, :response))
    )
  end

  defp stream_completed(conn, result, :chat, payload) do
    completed = map_get(payload, :completed) || payload
    finish_reason = if map_get(completed, :ok) == false, do: "error", else: "stop"

    with {:ok, conn} <- chunk(conn, sse_data(chat_stream_chunk(result, %{}, finish_reason))) do
      chunk(conn, "data: [DONE]\n\n")
    end
  end

  defp stream_completed(conn, result, :response, payload) do
    completed = map_get(payload, :completed) || payload
    status = if map_get(completed, :ok) == false, do: "failed", else: "completed"

    with {:ok, conn} <-
           chunk(conn, sse_event("response.completed", response_done_chunk(result, status))) do
      chunk(conn, "data: [DONE]\n\n")
    end
  end

  defp stream_start_object(result, :chat) do
    %{
      "id" => "chatcmpl_#{result.run_id}",
      "object" => "chat.completion.chunk",
      "created" => System.system_time(:second),
      "model" => result.model,
      "choices" => [%{"index" => 0, "delta" => %{"role" => "assistant"}, "finish_reason" => nil}],
      "lemon" => stream_lemon_metadata(result)
    }
  end

  defp stream_start_object(result, :response) do
    %{
      "type" => "response.created",
      "response" => %{
        "id" => "resp_#{result.run_id}",
        "object" => "response",
        "status" => "in_progress",
        "model" => result.model
      },
      "lemon" => stream_lemon_metadata(result)
    }
  end

  defp chat_stream_chunk(result, delta, finish_reason) do
    %{
      "id" => "chatcmpl_#{result.run_id}",
      "object" => "chat.completion.chunk",
      "created" => System.system_time(:second),
      "model" => result.model,
      "choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => finish_reason}],
      "lemon" => stream_lemon_metadata(result)
    }
  end

  defp response_delta_chunk(result, text) do
    %{
      "type" => "response.output_text.delta",
      "response_id" => "resp_#{result.run_id}",
      "delta" => text,
      "lemon" => stream_lemon_metadata(result)
    }
  end

  defp response_done_chunk(result, status) do
    %{
      "type" => "response.completed",
      "response" => %{
        "id" => "resp_#{result.run_id}",
        "status" => status,
        "model" => result.model
      },
      "lemon" => stream_lemon_metadata(result)
    }
  end

  defp tool_progress_chunk(result, payload, kind) do
    action = map_get(payload, :action) || %{}

    %{
      "type" => tool_progress_type(kind),
      "id" => "#{tool_progress_prefix(kind)}_#{result.run_id}",
      "object" => tool_progress_object(kind),
      "action" => %{
        "id" => map_get(action, :id),
        "kind" => atom_to_string(map_get(action, :kind)),
        "title" => map_get(action, :title)
      },
      "phase" => atom_to_string(map_get(payload, :phase)),
      "ok" => map_get(payload, :ok),
      "message" => truncate_string(map_get(payload, :message), 240),
      "lemon" => stream_lemon_metadata(result)
    }
  end

  defp tool_progress_type(:chat), do: "lemon.tool_progress"
  defp tool_progress_type(:response), do: "response.tool_progress"

  defp tool_progress_prefix(:chat), do: "chatcmpl"
  defp tool_progress_prefix(:response), do: "resp"

  defp tool_progress_object(:chat), do: "chat.completion.tool_progress"
  defp tool_progress_object(:response), do: "response.tool_progress"

  defp stream_lemon_metadata(result) do
    %{
      "runId" => result.run_id,
      "sessionKey" => result.session_key
    }
  end

  defp sse_data(data), do: "data: #{Jason.encode!(data)}\n\n"
  defp sse_event(event, data), do: "event: #{event}\n" <> sse_data(data)

  defp with_openai_auth(conn, fun) do
    case openai_auth_result(conn) do
      :ok -> fun.(conn)
      {:error, status, message} -> send_openai_result({:error, {status, message}}, conn)
    end
  end

  defp with_acp_auth(conn, fun) do
    case acp_auth_result(conn) do
      :ok ->
        fun.(conn)

      {:error, status, message} ->
        json(conn, status, %{
          "jsonrpc" => "2.0",
          "id" => nil,
          "error" => %{"code" => -32010, "message" => message}
        })
    end
  end

  defp openai_auth_result(conn) do
    case openai_compat_api_token() do
      nil ->
        :ok

      token ->
        if presented_openai_token(conn) == token do
          :ok
        else
          missing? = is_nil(presented_openai_token(conn))
          status = if missing?, do: 401, else: 403

          message =
            if missing?,
              do: "authorization token is required",
              else: "authorization token is invalid"

          {:error, status, message}
        end
    end
  end

  defp openai_compat_api_token do
    token =
      Application.get_env(:lemon_control_plane, :openai_compat_api_token) ||
        System.get_env("LEMON_OPENAI_COMPAT_API_TOKEN") ||
        System.get_env("LEMON_OPENAI_COMPAT_TOKEN")

    case token do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp acp_auth_result(conn) do
    case acp_api_token() do
      nil ->
        :ok

      token ->
        if presented_openai_token(conn) == token do
          :ok
        else
          missing? = is_nil(presented_openai_token(conn))
          status = if missing?, do: 401, else: 403

          message =
            if missing?,
              do: "authorization token is required",
              else: "authorization token is invalid"

          {:error, status, message}
        end
    end
  end

  defp acp_api_token do
    token =
      Application.get_env(:lemon_control_plane, :acp_api_token) ||
        System.get_env("LEMON_ACP_API_TOKEN")

    case token do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp presented_openai_token(conn) do
    bearer_token(conn) || api_key_header(conn)
  end

  defp bearer_token(conn) do
    conn
    |> get_req_header("authorization")
    |> List.first()
    |> case do
      "Bearer " <> token when token != "" -> token
      _ -> nil
    end
  end

  defp api_key_header(conn) do
    conn
    |> get_req_header("x-api-key")
    |> List.first()
  end

  defp map_get(nil, _key), do: nil

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp atom_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_to_string(value), do: value

  defp truncate_string(value, max) when is_binary(value) and byte_size(value) > max do
    String.slice(value, 0, max) <> "..."
  end

  defp truncate_string(value, _max), do: value

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
