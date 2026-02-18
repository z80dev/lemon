defmodule LemonPoker.Web.Router do
  @moduledoc false

  use Plug.Router

  alias LemonPoker.MatchServer

  plug(Plug.Logger, log: :debug)

  plug(Plug.Static,
    at: "/",
    from: {:lemon_poker, "priv/poker_ui"},
    only: ~w(app.js styles.css)
  )

  plug(:match)
  plug(:dispatch)

  get "/" do
    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_file(200, ui_path("index.html"))
  end

  get "/healthz" do
    json(conn, 200, %{ok: true, service: "lemon_poker"})
  end

  get "/api/state" do
    json(conn, 200, MatchServer.snapshot())
  end

  post "/api/match/start" do
    with {:ok, payload} <- decode_json_body(conn),
         opts <- build_start_opts(payload),
         {:ok, snapshot} <- MatchServer.start_match(opts) do
      json(conn, 200, %{ok: true, state: snapshot})
    else
      {:error, :invalid_json} -> json(conn, 400, %{ok: false, error: "invalid_json"})
      {:error, :match_running} -> json(conn, 409, %{ok: false, error: "match_running"})
      {:error, reason} -> json(conn, 400, %{ok: false, error: to_string(reason)})
    end
  end

  post "/api/match/pause" do
    case MatchServer.pause_match() do
      {:ok, snapshot} -> json(conn, 200, %{ok: true, state: snapshot})
      {:error, reason} -> json(conn, 409, %{ok: false, error: to_string(reason)})
    end
  end

  post "/api/match/resume" do
    case MatchServer.resume_match() do
      {:ok, snapshot} -> json(conn, 200, %{ok: true, state: snapshot})
      {:error, reason} -> json(conn, 409, %{ok: false, error: to_string(reason)})
    end
  end

  post "/api/match/stop" do
    case MatchServer.stop_match() do
      {:ok, snapshot} -> json(conn, 200, %{ok: true, state: snapshot})
      {:error, reason} -> json(conn, 409, %{ok: false, error: to_string(reason)})
    end
  end

  post "/api/table-talk" do
    with {:ok, payload} <- decode_json_body(conn),
         {:ok, snapshot} <- MatchServer.push_table_talk(payload) do
      json(conn, 200, %{ok: true, state: snapshot})
    else
      {:error, :invalid_json} -> json(conn, 400, %{ok: false, error: "invalid_json"})
      {:error, reason} -> json(conn, 400, %{ok: false, error: to_string(reason)})
    end
  end

  get "/ws" do
    conn
    |> WebSockAdapter.upgrade(LemonPoker.Web.WSConnection, [], timeout: 60_000)
    |> halt()
  end

  match _ do
    json(conn, 404, %{ok: false, error: "not_found"})
  end

  defp decode_json_body(conn) do
    case Plug.Conn.read_body(conn, length: 1_000_000) do
      {:ok, "", _conn} ->
        {:ok, %{}}

      {:ok, body, _conn} ->
        case Jason.decode(body) do
          {:ok, %{} = map} -> {:ok, map}
          _ -> {:error, :invalid_json}
        end

      _ ->
        {:error, :invalid_json}
    end
  rescue
    _ -> {:error, :invalid_json}
  end

  defp build_start_opts(payload) do
    [
      table_id: blank_to_nil(payload["tableId"]),
      hands: parse_positive_integer(payload["hands"], 10),
      players: parse_integer_in_range(payload["players"], 2, 9, 6),
      stack: parse_positive_integer(payload["stack"], 1_000),
      small_blind: parse_positive_integer(payload["smallBlind"], 50),
      big_blind: parse_positive_integer(payload["bigBlind"], 100),
      timeout_ms: parse_positive_integer(payload["timeoutMs"], 90_000),
      max_decisions: parse_positive_integer(payload["maxDecisions"], 200),
      seed: parse_optional_integer(payload["seed"]),
      agent_id: blank_to_default(payload["agentId"], "default"),
      player_agent_ids: parse_string_list(payload["playerAgentIds"]),
      player_labels: parse_string_list(payload["playerLabels"]),
      player_system_prompts: parse_string_list(payload["playerSystemPrompts"]),
      system_prompt: blank_to_nil(payload["systemPrompt"]),
      table_talk_enabled: parse_boolean(payload["tableTalkEnabled"], true)
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp json(conn, status, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(payload))
  end

  defp ui_path(file) do
    :lemon_poker
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("poker_ui/#{file}")
  end

  defp parse_positive_integer(value, _default) when is_integer(value), do: max(value, 1)

  defp parse_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> max(parsed, 1)
      _ -> default
    end
  end

  defp parse_positive_integer(_value, default), do: default

  defp parse_integer_in_range(value, min, max, default) do
    value = parse_positive_integer(value, default)

    cond do
      value < min -> min
      value > max -> max
      true -> value
    end
  end

  defp parse_optional_integer(nil), do: nil

  defp parse_optional_integer(value) when is_integer(value), do: value

  defp parse_optional_integer(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      nil
    else
      case Integer.parse(trimmed) do
        {parsed, ""} -> parsed
        _ -> nil
      end
    end
  end

  defp parse_optional_integer(_), do: nil

  defp parse_boolean(value, _default) when is_boolean(value), do: value

  defp parse_boolean(value, default) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "1" -> true
      "yes" -> true
      "false" -> false
      "0" -> false
      "no" -> false
      _ -> default
    end
  end

  defp parse_boolean(_value, default), do: default

  defp parse_string_list(list) when is_list(list) do
    list
    |> Enum.map(fn
      value when is_binary(value) -> String.trim(value)
      value -> to_string(value)
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_string_list(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_string_list(_), do: []

  defp blank_to_default(value, default) do
    case blank_to_nil(value) do
      nil -> default
      text -> text
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp blank_to_nil(_), do: nil
end
