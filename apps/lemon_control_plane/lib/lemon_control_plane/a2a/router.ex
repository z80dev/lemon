defmodule LemonControlPlane.A2A.Router do
  @moduledoc "A2A v1.0 Agent Card, JSON-RPC, and SSE endpoint."

  use Plug.Router

  alias LemonControlPlane.A2A.{Auth, Config, Handler, RateLimiter, TaskView}
  alias LemonCore.A2A.Protocol
  alias LemonCore.A2AStore

  plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
  plug(:match)
  plug(:dispatch)

  get "/.well-known/agent-card.json" do
    json(conn, 200, agent_card())
  end

  get "/.well-known/agent.json" do
    json(conn, 200, agent_card())
  end

  get "/healthz" do
    json(conn, 200, %{"ok" => true, "protocolVersion" => "1.0"})
  end

  post "/" do
    dispatch_rpc(conn)
  end

  post "/a2a" do
    dispatch_rpc(conn)
  end

  match _ do
    json(conn, 404, %{"error" => "Not found"})
  end

  defp dispatch_rpc(conn) do
    id = conn.body_params["id"]
    method = conn.body_params["method"]
    params = conn.body_params["params"] || %{}

    with "2.0" <- conn.body_params["jsonrpc"],
         true <- is_binary(method),
         {:ok, peer_id} <- Auth.authenticate(conn),
         true <- RateLimiter.allow?(peer_id) do
      case Handler.handle(method, params, peer_id) do
        {:ok, result} -> json(conn, 200, Protocol.response(id, result))
        {:stream, task_id} -> stream_task(conn, id, task_id)
        {:error, code, message} -> json(conn, 200, Protocol.error(id, code, message))
      end
    else
      {:error, :unauthorized} ->
        json(conn, 401, Protocol.error(id, -32_000, "Unauthorized"))

      false when is_binary(method) ->
        json(conn, 429, Protocol.error(id, -32_000, "Rate limit exceeded"))

      _ ->
        json(conn, 400, Protocol.error(id, -32_600, "Invalid Request"))
    end
  end

  defp stream_task(conn, request_id, task_id) do
    topic = "a2a:task:#{task_id}"
    :ok = LemonCore.Bus.subscribe(topic)

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    try do
      task = A2AStore.get_task(task_id)

      case stream_json(conn, request_id, %{"task" => TaskView.render(task)}) do
        {:ok, conn} ->
          if Protocol.terminal_state?(task.state) or
               task.state in ["TASK_STATE_INPUT_REQUIRED", "TASK_STATE_AUTH_REQUIRED"] do
            finish_stream(conn)
          else
            receive do
              {:a2a_task_terminal, ^task_id} ->
                final = A2AStore.get_task(task_id)

                update = %{
                  "statusUpdate" => %{
                    "taskId" => final.id,
                    "contextId" => final.context_id,
                    "status" => TaskView.render(final)["status"]
                  }
                }

                with {:ok, conn} <- stream_json(conn, request_id, update),
                     do: finish_stream(conn)
            after
              Config.current().reply_timeout_ms -> finish_stream(conn)
            end
          end

        _ ->
          conn
      end
    after
      LemonCore.Bus.unsubscribe(topic)
    end
  end

  defp stream_json(conn, request_id, result) do
    chunk(conn, "data: " <> Jason.encode!(Protocol.response(request_id, result)) <> "\n\n")
  end

  defp finish_stream(conn) do
    case chunk(conn, ": done\n\n") do
      {:ok, conn} -> conn
      _ -> conn
    end
  end

  defp agent_card do
    config = Config.current()
    url = config.public_url || "http://#{config.host}:#{config.port}"

    auth? =
      Enum.any?(config.peers, fn {_id, peer} -> peer.inbound_token_secret || peer.token_secret end)

    %{
      "name" => config.name,
      "description" => config.description,
      "url" => url,
      "version" => "1.0.0",
      "protocolVersion" => "1.0",
      "provider" => %{"organization" => "Lemon", "url" => url},
      "supportedInterfaces" => [
        %{"url" => url, "protocolBinding" => "JSONRPC", "protocolVersion" => "1.0"}
      ],
      "capabilities" => %{
        "streaming" => true,
        "pushNotifications" => false,
        "stateTransitionHistory" => false,
        "extendedAgentCard" => false
      },
      "defaultInputModes" => ["text/plain"],
      "defaultOutputModes" => ["text/plain"],
      "skills" =>
        Enum.map(config.skills, fn skill ->
          %{"id" => skill, "name" => skill, "description" => "Lemon #{skill}", "tags" => [skill]}
        end)
    }
    |> maybe_security(auth?)
  end

  defp maybe_security(card, true) do
    card
    |> Map.put("securitySchemes", %{"bearer" => %{"type" => "http", "scheme" => "bearer"}})
    |> Map.put("security", [%{"bearer" => []}])
  end

  defp maybe_security(card, false), do: card

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
